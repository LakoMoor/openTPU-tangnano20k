// VOP (docs/isa.md "VOP"), one element at a time: read A and B, compute through the shared
// multiply-add or the composite engine, write. Valid programs have no read-after-write hazard
// inside a VOP (isasim checks it), so the element order is the only order that matters:
//   - row sums (RSUM, RSSQ, RDOT) keep the 64 interleaved partials isum_64 defines in vbuf[0..63],
//     add the +0 pad terms and fold them in the tree order (fp32.interleaved_sum);
//   - OUTER first copies its column vectors Cv (vbuf[256..]) and Dv (vbuf[0..]), which may overlap
//     dst, then updates in place: t = B(r) * Cv(c) + (-0), y = old * Dv(c) + t.
module lite_vpu
  import lite_pkg::*;
  import otpu_fp::*;
(
  input  logic        clk,
  input  logic        rst,
  input  logic        start,
  input  cmd_t        cmd,
  output logic        done,
  output logic        err,
  // TMEM
  output logic        t_re,
  output logic [31:0] t_ra,
  input  logic [31:0] t_rd,
  output logic        t_we,
  output logic [31:0] t_wa,
  output logic [31:0] t_wd,
  // multiply-add
  output logic        f_v,
  output logic [31:0] f_a, f_b, f_c,
  input  logic        f_ov,
  input  logic [31:0] f_y,
  // composite engine
  output logic        c_start,
  output logic [1:0]  c_fn,
  output logic [31:0] c_x,
  input  logic        c_done,
  input  logic [31:0] c_y
);
  localparam f32_t NZERO = 32'h8000_0000;

  typedef enum logic [4:0] {
    S_IDLE, S_OPRE, S_OPRE_W, S_ROW, S_PINIT, S_RDA, S_RDB, S_OP, S_FI, S_FW, S_CW, S_WR,
    S_PRD, S_PFI, S_PFW, S_PAD, S_FOLD_RA, S_FOLD_RB, S_FOLD_I, S_FOLD_W, S_RWR, S_RWR2, S_DONE
  } st_t;
  st_t st;

  // fields
  logic [15:0] rows, cols, drs, ars, brs;
  logic [7:0]  fn;
  logic [1:0]  bmode;
  assign rows = cmd.w4[15:0];
  assign cols = cmd.w4[31:16];
  assign drs = cmd.w5[15:0];
  assign ars = cmd.w5[31:16];
  assign brs = cmd.w6[15:0];
  assign fn = cmd.w6[23:16];
  assign bmode = cmd.w6[25:24];

  wire is_red   = (fn == V_RSUM || fn == V_RSSQ || fn == V_RDOT);
  wire is_max   = (fn == V_RMAX || fn == V_ARGMAX);
  wire is_outer = (fn == V_OUTER);
  wire binary   = (fn == V_ADD || fn == V_SUB || fn == V_RSUB || fn == V_MUL || fn == V_MAX ||
                   fn == V_MIN || fn == V_FILL || fn == V_EXP2SUB);
  wire reads_b  = binary || fn == V_RDOT;
  wire need_a   = (fn != V_FILL);
  wire tmem_b   = is_outer || (reads_b && bmode != B_SCALAR);
  wire known    = binary || is_red || is_max || is_outer || fn == V_COPY || fn == V_EXP2 ||
                  fn == V_RECIP || fn == V_RSQRT || fn == V_ABS || fn == V_LOG2;

  // vbuf: the partials / OUTER's column vectors
  logic [31:0] vbuf [512];
  logic        vb_we;
  logic [8:0]  vb_wa, vb_ra;
  logic [31:0] vb_wd, vb_rd;
  always_ff @(posedge clk) begin
    if (vb_we) vbuf[vb_wa] <= vb_wd;
    vb_rd <= vbuf[vb_ra];
  end

  logic [15:0] r, c;
  logic [31:0] abase, bbase, dbase;
  logic [31:0] va, vb, vr, vp, vd;
  logic        two;                          // OUTER / EXP2SUB: the second op
  logic [31:0] mx;                           // RMAX / ARGMAX
  logic [15:0] mxi;
  logic [6:0]  q;                            // partial index / pad / fold counters
  logic [6:0]  fn_n;                         // fold: the level's n
  logic [8:0]  pre;                          // OUTER copy index

  wire [31:0] a_addr = abase + 32'(c);
  wire [31:0] b_addr = (bmode == B_FULL) ? bbase + 32'(c) :
                       (bmode == B_COL)  ? cmd.f3 + 32'(c) : bbase;
  wire [31:0] d_addr = dbase + 32'(c);

  // the element's multiply-add operands
  f32_t ea, eb, ec;
  always_comb begin
    ea = va; eb = F_ONE; ec = vb;
    case (fn)
      V_ADD:     begin ea = va; eb = F_ONE; ec = vb; end
      V_SUB, V_EXP2SUB: begin ea = va; eb = F_ONE; ec = fneg(vb); end
      V_RSUB:    begin ea = vb; eb = F_ONE; ec = fneg(va); end
      V_MUL:     begin ea = va; eb = vb; ec = NZERO; end
      V_RSUM:    begin ea = va; eb = F_ONE; ec = vp; end
      V_RSSQ:    begin ea = va; eb = va; ec = vp; end
      V_RDOT:    begin ea = va; eb = vb; ec = vp; end
      V_OUTER:   if (!two) begin ea = vb; eb = vp; ec = NZERO; end   // B(r) * Cv(c)
                 else begin ea = va; eb = vd; ec = vr; end           // old * Dv(c) + t
      default: ;
    endcase
  end

  logic fold_issue;
  f32_t fold_a;
  always_comb begin
    t_re = 1'b0; t_ra = '0; t_we = 1'b0; t_wa = '0; t_wd = '0;
    f_v = 1'b0; f_a = '0; f_b = '0; f_c = '0;
    c_start = 1'b0; c_fn = '0; c_x = '0;
    vb_we = 1'b0; vb_wa = '0; vb_wd = '0; vb_ra = '0;
    case (st)
      S_OPRE: begin                          // read Cv(pre), then Dv(pre)
        t_re = 1'b1;
        t_ra = two ? (cmd.flags[0] ? cmd.f2 : cmd.f2 + 32'(pre)) : cmd.f7 + 32'(pre);
      end
      S_OPRE_W: begin
        vb_we = 1'b1;
        vb_wa = two ? pre : 9'd256 + pre;
        vb_wd = (two && cmd.flags[1]) ? F_ONE : t_rd;      // DONE: Dv = 1.0
      end
      S_PINIT: begin vb_we = 1'b1; vb_wa = {2'b00, q}; vb_wd = F_ZERO; end
      S_RDA: begin
        t_re = need_a;
        t_ra = is_outer ? d_addr : a_addr;
        vb_ra = is_outer ? 9'd256 + 9'(c) : {3'b000, c[5:0]};   // Cv(c) / partial c % 64
      end
      S_RDB: begin
        t_re = tmem_b;
        t_ra = b_addr;
        vb_ra = 9'(c);                        // OUTER: Dv(c)
      end
      S_FI: begin f_v = 1'b1; f_a = ea; f_b = eb; f_c = ec; end
      S_OP: if (fn == V_EXP2 || fn == V_RECIP || fn == V_RSQRT || fn == V_LOG2) begin
        c_start = 1'b1;
        c_fn = (fn == V_EXP2) ? 2'd0 : (fn == V_RECIP) ? 2'd1 : (fn == V_RSQRT) ? 2'd2 : 2'd3;
        c_x = va;
      end
      S_FW: if (f_ov && fn == V_EXP2SUB) begin c_start = 1'b1; c_fn = 2'd0; c_x = f_y; end
      S_WR: begin t_we = 1'b1; t_wa = d_addr; t_wd = vr; end
      S_PRD: vb_ra = {2'b00, q};             // pad term: partial q
      S_PFI: begin f_v = 1'b1; f_a = F_ZERO; f_b = F_ONE; f_c = vb_rd; end
      S_PFW: if (f_ov) begin vb_we = 1'b1; vb_wa = {2'b00, q}; vb_wd = f_y; end
      S_FOLD_RA: vb_ra = {2'b00, q};
      S_FOLD_RB: vb_ra = {2'b00, q + fn_n};
      S_FOLD_I: begin f_v = 1'b1; f_a = vp; f_b = F_ONE; f_c = vb_rd; end
      S_FOLD_W: if (f_ov) begin vb_we = 1'b1; vb_wa = {2'b00, q}; vb_wd = f_y; end
      S_RWR: begin
        t_we = 1'b1;
        t_wa = dbase;
        t_wd = is_max ? mx : vr;
      end
      S_RWR2: begin                          // ARGMAX's index
        logic [31:0] ci;
        ci = 32'(mxi) + cmd.f7;
        t_we = 1'b1;
        t_wa = dbase + 32'd1;
        t_wd = i2f(ci);
      end
      default: ;
    endcase
    if (st == S_FW && f_ov && is_red) begin   // the partial back
      vb_we = 1'b1; vb_wa = {3'b000, c[5:0]}; vb_wd = f_y;
    end
  end

  // the row is over: c is the last column
  wire last_c = (c + 16'd1 == cols);

  task automatic next_elem();
    if (!last_c) begin
      c <= c + 16'd1;
      st <= S_RDA;
    end else if (is_red) begin
      q <= 7'(cols[5:0]);                    // pad partials cols % 64 .. 63 (none if 0)
      st <= (cols[5:0] == 0) ? S_FOLD_RA : S_PRD;
      fn_n <= 7'd32;
      if (cols[5:0] == 0) q <= 7'd0;
    end else if (is_max) begin
      st <= S_RWR;
    end else begin
      next_row();
    end
  endtask

  task automatic next_row();
    if (r + 16'd1 == rows) begin
      st <= S_DONE;
    end else begin
      r <= r + 16'd1;
      abase <= abase + 32'(ars);
      bbase <= bbase + 32'(brs);
      dbase <= dbase + 32'(drs);
      st <= S_ROW;
    end
  endtask

  always_ff @(posedge clk) begin
    done <= 1'b0;
    err <= 1'b0;
    if (rst) begin
      st <= S_IDLE;
    end else begin
      case (st)
        S_IDLE: if (start) begin
          r <= '0;
          abase <= cmd.f2;
          bbase <= cmd.f3;
          dbase <= cmd.f1;
          pre <= '0;
          two <= 1'b0;
          if (!known || (is_outer && (bmode != B_ROW || cols > 16'd256))) begin
            err <= 1'b1;
          end else if (rows == 0 || cols == 0) begin
            done <= 1'b1;
          end else begin
            st <= is_outer ? S_OPRE : S_ROW;
          end
        end
        S_OPRE: st <= S_OPRE_W;
        S_OPRE_W: begin
          if (!two) two <= 1'b1;
          else begin
            two <= 1'b0;
            pre <= pre + 9'd1;
          end
          st <= (two && pre + 9'd1 == 9'(cols)) ? S_ROW : S_OPRE;
        end
        S_ROW: begin
          c <= '0;
          q <= '0;
          st <= is_red ? S_PINIT : S_RDA;
        end
        S_PINIT: begin
          q <= q + 7'd1;
          if (q == 7'd63) st <= S_RDA;
        end
        S_RDA: st <= S_RDB;
        S_RDB: begin
          va <= t_rd;                        // (need_a)
          vp <= vb_rd;                       // Cv(c) / the partial
          st <= S_OP;
        end
        S_OP: begin
          logic [31:0] bv;
          bv = tmem_b ? t_rd : cmd.f7;
          vb <= bv;
          vd <= vb_rd;                       // OUTER: Dv(c)
          case (fn)
            V_MAX:  begin vr <= fp_mm(va, bv, 1'b0); st <= S_WR; end
            V_MIN:  begin vr <= fp_mm(va, bv, 1'b1); st <= S_WR; end
            V_COPY: begin vr <= ftz(va); st <= S_WR; end
            V_ABS:  begin vr <= fabs(va); st <= S_WR; end
            V_FILL: begin vr <= ftz(bv); st <= S_WR; end
            V_EXP2, V_RECIP, V_RSQRT, V_LOG2: st <= S_CW;
            V_RMAX, V_ARGMAX: begin
              if (c == 0 || fp_gt(va, mx)) begin mx <= ftz(va); mxi <= c; end
              next_elem();
            end
            V_OUTER: begin
              st <= S_FI;
            end
            default: st <= S_FI;
          endcase
        end
        S_FI: st <= S_FW;
        S_FW: if (f_ov) begin
          vr <= f_y;
          if (fn == V_EXP2SUB) st <= S_CW;
          else if (is_red) next_elem();
          else if (is_outer && !two) begin
            two <= 1'b1;
            st <= S_FI;
          end else begin
            two <= 1'b0;
            st <= S_WR;
          end
        end
        S_CW: if (c_done) begin vr <= c_y; st <= S_WR; end
        S_WR: next_elem();
        // ---- row sums: the pad terms, then the folding tree
        S_PRD: st <= S_PFI;
        S_PFI: st <= S_PFW;
        S_PFW: if (f_ov) begin
          if (q == 7'd63) begin q <= 7'd0; st <= S_FOLD_RA; end
          else begin q <= q + 7'd1; st <= S_PRD; end
        end
        S_FOLD_RA: st <= S_FOLD_RB;
        S_FOLD_RB: begin vp <= vb_rd; st <= S_FOLD_I; end
        S_FOLD_I: st <= S_FOLD_W;
        S_FOLD_W: if (f_ov) begin
          vr <= f_y;                         // the last one is the row's sum
          if (q + 7'd1 == fn_n) begin
            q <= 7'd0;
            if (fn_n == 7'd1) st <= S_RWR;
            else begin fn_n <= fn_n >> 1; st <= S_FOLD_RA; end
          end else begin
            q <= q + 7'd1;
            st <= S_FOLD_RA;
          end
        end
        S_RWR: begin
          if (fn == V_ARGMAX) st <= S_RWR2;
          else next_row();
        end
        S_RWR2: next_row();
        default: begin                       // S_DONE
          done <= 1'b1;
          st <= S_IDLE;
        end
      endcase
    end
  end
endmodule
