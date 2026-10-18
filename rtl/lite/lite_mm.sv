// MM (docs/isa.md "MM"): each output is one exact integer and an fp32 epilogue.
//   acc[j] = sum over blocks k and groups g of (sh >= 0 ? m << sh : 0) * c[j],
//   c[j] = sum_{i in g} ACT[j][(ab+k)*D + i] * w[i],  sh = W - dw(n,k,g) - da[j][ab+k][b]
//   y = (i2f(acc) * Sw[n]) * (Sa[j][ab] * 2^-W); ASCALE: old * alpha[j] + y; ACC: old + y.
// The fetch side requests, per weight row n, its Sw word, then per block the block's scale
// word(s) and its weight words, in the order the compute side consumes them (the memory path
// answers in order; a 32-word FIFO holds what has arrived). Elements go one at a time with all
// M <= MCOLS rows in parallel (an int8 x int8 product per row): the SD card, not this loop,
// bounds the speed. Not in this build: PAIR (ERROR).
module lite_mm
  import lite_pkg::*;
  import otpu_fp::*;
#(
  parameter int D = 64,
  parameter int MCOLS = 4,
  parameter int ACT_BLOCKS = 64,
  localparam int AW = $clog2(ACT_BLOCKS * D),
  localparam int BW = $clog2(ACT_BLOCKS)
) (
  input  logic          clk,
  input  logic          rst,
  input  logic          start,
  input  cmd_t          cmd,
  output logic          done,
  output logic          err,
  // TMEM
  output logic          t_re,
  output logic [31:0]   t_ra,
  input  logic [31:0]   t_rd,
  output logic          t_we,
  output logic [31:0]   t_wa,
  output logic [31:0]   t_wd,
  // multiply-add
  output logic          f_v,
  output logic [31:0]   f_a, f_b, f_c,
  input  logic          f_ov,
  input  logic [31:0]   f_y,
  // ACT RAM reads: the four rows' bytes at a_ra; a (row, block) scale record
  output logic          a_re,
  output logic [AW-1:0] a_ra,
  input  logic [31:0]   a_rd,
  output logic          s_re,
  output logic [1:0]    s_row,
  output logic [BW-1:0] s_blk,
  input  logic [31:0]   s_sa,
  input  logic [19:0]   s_da,
  // DRAM reads
  output logic          m_req,
  output logic [31:0]   m_addr,
  input  logic          m_rdy,
  input  logic          m_rv,
  input  logic [31:0]   m_rd
);
  localparam f32_t NZERO = 32'h8000_0000;
  localparam int LD = $clog2(D);

  // ---- fields
  wire        unit  = cmd.flags[0];
  wire        accf  = cmd.flags[1];
  wire        rmaxf = cmd.flags[2];
  wire        ascl  = cmd.flags[3];
  wire [1:0]  wf    = cmd.flags[5:4];
  wire        pair  = cmd.flags[6];
  wire        rscf  = cmd.flags[7];
  wire [15:0] N     = cmd.w4[15:0];
  wire [7:0]  KB    = cmd.w4[23:16];
  wire [7:0]  k0    = cmd.w4[31:24];
  wire [15:0] ors   = cmd.w6[15:0];
  wire [7:0]  M     = cmd.w6[23:16];
  wire [7:0]  ab    = cmd.w6[31:24];
  wire        scales = !unit && !rscf;                       // per-block scale words
  wire [1:0]  nsc   = !scales ? 2'd0 : (wf == 2'd3) ? 2'd2 : 2'd1;
  wire [5:0]  bpw   = (wf == 2'd0) ? 6'(D / 4) : 6'(D / 8);   // weight words a block
  wire [4:0]  wsh   = (wf == 2'd0) ? 5'd16 : (wf == 2'd3) ? 5'd13 : 5'd11;   // W
  wire [31:0] two_mw = (wf == 2'd0) ? 32'h3780_0000 : (wf == 2'd3) ? 32'h3900_0000 : 32'h3A00_0000;

  // the word address of a block's scale word s (0, 1) in the row's scale row at sr
  function automatic logic [31:0] sc_addr(input logic [31:0] sr, input logic [7:0] k,
                                          input logic s);
    logic [31:0] kk;
    kk = 32'(k0) + 32'(k);
    case (wf)
      2'd0:    return sr + ((32'd4 + kk) & ~32'd3);
      2'd3:    return sr + 32'd16 + (kk << 3) + (s ? 32'd4 : 32'd0);
      default: return sr + 32'd8 + (kk << 2);
    endcase
  endfunction

  // ================= fetch =================
  typedef enum logic [1:0] { F_SW, F_SC, F_W, F_END } fst_t;
  fst_t fst;
  logic        fact;                          // fetching
  logic [15:0] fn;
  logic [7:0]  fk;
  logic [5:0]  fi;
  logic [31:0] fw_row, fs_row;
  logic [5:0]  credit;                         // FIFO places not yet promised

  // the response FIFO
  logic [31:0] fifo [32];
  logic [4:0]  wp, rp;
  logic [5:0]  cnt;
  logic        pop;
  wire  [31:0] head = fifo[rp];
  wire         have = (cnt != 0);

  always_comb begin
    m_req = fact && fst != F_END && credit != 0;
    m_addr = '0;                                 // OR-shared: zero while not requesting
    if (m_req) case (fst)
      F_SW:    m_addr = fs_row;
      F_SC:    m_addr = sc_addr(fs_row, fk, fi[0]);
      default: m_addr = fw_row + ((32'(fk) << LD) >> (wf != 2'd0)) + {24'd0, fi, 2'b00};
    endcase
  end
  wire take = m_req && m_rdy;

  always_ff @(posedge clk) begin
    if (m_rv) begin
      fifo[wp] <= m_rd;
      wp <= wp + 5'd1;
    end
    cnt <= cnt + (m_rv ? 6'd1 : 6'd0) - (pop ? 6'd1 : 6'd0);
    if (pop) rp <= rp + 5'd1;
    credit <= credit - (take ? 6'd1 : 6'd0) + (pop ? 6'd1 : 6'd0);
    if (rst || (start && !fact)) begin
      wp <= '0; rp <= '0; cnt <= '0; credit <= 6'd32;
    end
  end

  // the fetch sequence: [Sw] then per block [scale words] [weight words], row after row
  task automatic f_next_block();
    if (fk + 8'd1 == KB) begin
      fk <= '0;
      fw_row <= fw_row + cmd.w5;
      fs_row <= fs_row + cmd.w7;
      if (fn + 16'd1 == N) fst <= F_END;
      else begin
        fn <= fn + 16'd1;
        fst <= unit ? (scales ? F_SC : F_W) : F_SW;
      end
    end else begin
      fk <= fk + 8'd1;
      fst <= scales ? F_SC : F_W;
    end
    fi <= '0;
  endtask

  always_ff @(posedge clk) begin
    if (rst) fact <= 1'b0;
    else if (fstart) begin
      fact <= 1'b1;
      fn <= '0; fk <= '0; fi <= '0;
      fw_row <= cmd.f1;
      fs_row <= cmd.f2;
      fst <= unit ? F_W : F_SW;
    end else if (take) begin
      case (fst)
        F_SW: begin fst <= scales ? F_SC : F_W; fi <= '0; end
        F_SC: if (fi[0] || nsc == 2'd1) begin fst <= F_W; fi <= '0; end
              else fi <= fi + 6'd1;
        F_W:  if (fi + 6'd1 == bpw) f_next_block();
              else fi <= fi + 6'd1;
        default: ;
      endcase
    end
    if (cdone) fact <= 1'b0;
  end

  // ================= compute =================
  typedef enum logic [4:0] {
    C_IDLE, C_PRE_S, C_PRE_SW, C_PRE_M, C_PRE_MW, C_PRE_A, C_PRE_AW, C_ROW, C_SW, C_BLK,
    C_DA, C_DAW, C_SCW, C_E1, C_E2, C_GE, C_EP_I0, C_EP_I, C_EP_IW, C_EP_S, C_EP_SW, C_EP_O, C_EP_A,
    C_EP_AW, C_EP_W, C_RMX, C_END
  } cst_t;
  cst_t cs;
  logic        fstart, cdone;
  logic [1:0]  j;
  logic [15:0] n;
  logic [7:0]  k;
  logic [6:0]  e;                              // element in the block
  logic [31:0] sw, wcur;
  logic [31:0] s2 [MCOLS], alpha [MCOLS], ob [MCOLS], mx [MCOLS];
  logic [19:0] da [MCOLS];
  logic signed [47:0] acc [MCOLS];
  logic signed [19:0] cc [MCOLS];
  logic [7:0]  dw [8];
  logic [5:0]  mg [8];
  logic signed [7:0] wv;
  logic [31:0] y, old;

  wire [2:0] gidx = (wf == 2'd3) ? 3'(e >> (LD - 3)) : 3'(e >> (LD - 2));   // the group
  wire [1:0] bsub = 2'(e >> (LD - 2));                                     // its sub-block
  wire glast = (wf == 2'd3) ? (e[LD-4:0] == '1) : (e[LD-3:0] == '1);

  // the element's weight from the current word
  function automatic logic signed [7:0] dec4(input logic [3:0] cnib, input logic fp);
    logic [3:0] mag;
    if (!fp) return 8'(signed'(cnib));
    case (cnib[2:0])
      3'd0: mag = 4'd0; 3'd1: mag = 4'd1; 3'd2: mag = 4'd2; 3'd3: mag = 4'd3;
      3'd4: mag = 4'd4; 3'd5: mag = 4'd6; 3'd6: mag = 4'd8; default: mag = 4'd12;
    endcase
    return cnib[3] ? -8'(mag) : 8'(mag);
  endfunction
  wire [31:0] wword = ((wf == 2'd0) ? (e[1:0] == 0) : (e[2:0] == 0)) ? head : wcur;
  always_comb begin
    if (wf == 2'd0) wv = wword[8 * e[1:0] +: 8];
    else wv = dec4(wword[4 * e[2:0] +: 4], wf != 2'd1);
  end

  // the group's term for row j
  logic signed [5:0]  shs;
  logic signed [47:0] term;
  always_comb begin
    logic signed [26:0] p;
    shs = $signed(6'(wsh)) - $signed({1'b0, dw[gidx] > 8'd31 ? 5'd31 : dw[gidx][4:0]})
          - $signed({1'b0, da[j][5 * int'(bsub) +: 5]});
    if (dw[gidx] > 8'd16) shs = -6'sd1;
    p = $signed({1'b0, mg[gidx]}) * cc[j];
    term = (shs < 0) ? 48'sd0 : (48'(p) <<< shs[4:0]);
  end

  always_comb begin
    t_re = 1'b0; t_ra = '0; t_we = 1'b0; t_wa = '0; t_wd = '0;
    f_v = 1'b0; f_a = '0; f_b = '0; f_c = '0;    // OR-shared: zero while not issuing
    a_re = 1'b0; a_ra = '0; s_re = 1'b0; s_row = '0; s_blk = '0;
    pop = 1'b0;
    case (cs)
      C_PRE_S: begin s_re = 1'b1; s_row = j; s_blk = BW'(ab); end
      C_PRE_M: begin f_v = 1'b1; f_a = s_sa; f_b = two_mw; f_c = NZERO; end
      C_PRE_A: begin t_re = 1'b1; t_ra = cmd.f2 + 32'(j); end
      C_SW:    pop = have;
      C_DA:    begin s_re = 1'b1; s_row = j; s_blk = BW'(32'(ab) + 32'(k)); end
      C_SCW:   pop = have;
      C_E1: begin
        a_re = 1'b1;
        a_ra = AW'({ab + k, LD'(0)}) + AW'(e);
        pop = have && ((wf == 2'd0) ? (e[1:0] == 0) : (e[2:0] == 0));
      end
      C_EP_I:  begin f_v = 1'b1; f_a = y; f_b = sw; f_c = NZERO; end
      C_EP_S:  begin f_v = 1'b1; f_a = y; f_b = s2[j]; f_c = NZERO; end
      C_EP_O:  begin t_re = 1'b1; t_ra = ob[j] + 32'(n); end
      C_EP_A:  begin f_v = 1'b1; f_a = t_rd; f_b = ascl ? alpha[j] : F_ONE; f_c = y; end
      C_EP_W:  begin t_we = 1'b1; t_wa = ob[j] + 32'(n); t_wd = y; end
      C_RMX:   begin t_we = 1'b1; t_wa = ob[mlast] + 32'(ors) + 32'(j); t_wd = mx[j]; end   // out + M*ors + j
      default: ;
    endcase
  end

  wire [1:0] mlast = 2'(M - 8'd1);

  always_ff @(posedge clk) begin
    done <= 1'b0;
    err <= 1'b0;
    fstart <= 1'b0;
    cdone <= 1'b0;
    if (rst) begin
      cs <= C_IDLE;
    end else begin
      case (cs)
        C_IDLE: if (start) begin
          j <= '0;
          if (N == 0 || KB == 0 || M == 0 || M > 8'(MCOLS) || 32'(ab) + 32'(KB) > ACT_BLOCKS ||
              pair || (ascl && !(unit && accf)) || (rscf && wf == 2'd3))
            err <= 1'b1;
          else cs <= C_PRE_S;
        end
        // ---- per row j: s2 = Sa[j][ab] * 2^-W, alpha (ASCALE), the output row's base
        C_PRE_S: cs <= C_PRE_SW;
        C_PRE_SW: cs <= C_PRE_M;
        C_PRE_M: cs <= C_PRE_MW;
        C_PRE_MW: if (f_ov) begin
          s2[j] <= f_y;
          ob[j] <= (j == 0) ? cmd.f3 : ob[j - 1] + 32'(ors);
          cs <= ascl ? C_PRE_A : C_PRE_AW;
        end
        C_PRE_A: cs <= C_PRE_AW;
        C_PRE_AW: begin
          if (ascl) alpha[j] <= t_rd;
          if (j == mlast) begin
            j <= '0;
            n <= '0;
            fstart <= 1'b1;
            cs <= C_ROW;
          end else begin
            j <= j + 2'd1;
            cs <= C_PRE_S;
          end
        end
        // ---- a weight row
        C_ROW: begin
          for (int q = 0; q < MCOLS; q++) acc[q] <= '0;
          k <= '0;
          if (unit) begin sw <= F_ONE; cs <= C_BLK; end
          else cs <= C_SW;
        end
        C_SW: if (have) begin sw <= head; cs <= C_BLK; end
        C_BLK: begin                            // the block's da (every row), then its scales
          j <= '0;
          e <= '0;
          for (int q = 0; q < MCOLS; q++) cc[q] <= '0;
          cs <= C_DA;
        end
        C_DA: cs <= C_DAW;
        C_DAW: begin
          da[j] <= s_da;
          if (j == mlast) begin
            j <= '0;
            if (!scales) begin
              for (int g = 0; g < 8; g++) begin dw[g] <= '0; mg[g] <= 6'd1; end
              cs <= C_E1;
            end else cs <= C_SCW;
            e <= '0;
          end else begin
            j <= j + 2'd1;
            cs <= C_DA;
          end
        end
        C_SCW: if (have) begin                  // the block's scale word(s)
          case (wf)
            2'd0: begin
              logic [7:0] b;
              b = head[8 * int'((32'd4 + 32'(k0) + 32'(k)) % 4) +: 8];
              for (int g = 0; g < 8; g++) begin dw[g] <= b; mg[g] <= 6'd1; end
              cs <= C_E1;
            end
            2'd3: begin
              for (int g = 0; g < 4; g++) begin
                logic [7:0] sb;
                logic [3:0] ee;
                sb = head[8 * g +: 8];
                ee = sb[6:3];
                mg[e[0] * 4 + g] <= (ee != 0) ? 6'(8 + sb[2:0]) : 6'(sb[2:0]);
                dw[e[0] * 4 + g] <= 8'(15 - ((ee > 1) ? ee : 4'd1));
              end
              if (e[0]) begin e <= '0; cs <= C_E1; end
              else e <= 7'd1;
            end
            default: begin
              for (int g = 0; g < 4; g++) begin
                dw[g] <= head[7:0];
                mg[g] <= head[8 + 6 * g +: 6];
              end
              cs <= C_E1;
            end
          endcase
        end
        // ---- an element: its weight and ACT bytes, then the M products
        C_E1: if (have || !((wf == 2'd0) ? (e[1:0] == 0) : (e[2:0] == 0))) begin
          wcur <= wword;
          y <= 32'(wv);                         // the element's weight (y as a temp)
          cs <= C_E2;
        end
        C_E2: begin
          for (int q = 0; q < MCOLS; q++) begin
            logic signed [15:0] pr;
            pr = $signed(a_rd[8 * q +: 8]) * $signed(y[7:0]);
            cc[q] <= cc[q] + 20'(pr);
          end
          if (glast) begin j <= '0; cs <= C_GE; end
          else begin e <= e + 7'd1; cs <= C_E1; end
        end
        C_GE: begin                             // the group's term into each row's acc
          acc[j] <= acc[j] + term;
          cc[j] <= '0;
          if (j == mlast) begin
            j <= '0;
            if (e == 7'(D - 1)) begin
              if (k + 8'd1 == KB) cs <= C_EP_I0;
              else begin k <= k + 8'd1; cs <= C_BLK; end
            end else begin
              e <= e + 7'd1;
              for (int q = 0; q < MCOLS; q++) cc[q] <= '0;
              cs <= C_E1;
            end
          end else j <= j + 2'd1;
        end
        // ---- the epilogue, row by row
        C_EP_I0: begin y <= i2f48(acc[j]); cs <= C_EP_I; end
        C_EP_I: cs <= C_EP_IW;
        C_EP_IW: if (f_ov) begin y <= f_y; cs <= C_EP_S; end
        C_EP_S: cs <= C_EP_SW;
        C_EP_SW: if (f_ov) begin y <= f_y; cs <= (accf || ascl) ? C_EP_O : C_EP_W; end
        C_EP_O: cs <= C_EP_A;
        C_EP_A: cs <= C_EP_AW;
        C_EP_AW: if (f_ov) begin y <= f_y; cs <= C_EP_W; end
        C_EP_W: begin
          if (n == 0 || fp_gt(y, mx[j])) mx[j] <= y;
          if (j == mlast) begin
            j <= '0;
            if (n + 16'd1 == N) begin
              cs <= rmaxf ? C_RMX : C_END;
            end else begin
              n <= n + 16'd1;
              cs <= C_ROW;
            end
          end else begin
            j <= j + 2'd1;
            cs <= C_EP_I0;
          end
        end
        C_RMX: begin
          if (j == mlast) cs <= C_END;
          else j <= j + 2'd1;
        end
        default: begin                          // C_END
          cdone <= 1'b1;
          done <= 1'b1;
          cs <= C_IDLE;
        end
      endcase
    end
  end
endmodule
