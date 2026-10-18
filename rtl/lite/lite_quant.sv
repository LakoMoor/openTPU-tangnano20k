// QACT and QST (docs/isa.md "Quantization"), a row at a time in two passes over TMEM:
//   pass 1: x = T[src + r*srs + c] (QACT: * T[w5 + r] with RSCALE, then * T[w4 + c] with
//           CSCALE), amax = the largest |x| by its flushed bits;
//           S = amax * f32(1/127), inv = 127 * recip(amax) (both 0 for amax 0);
//   pass 2: per group (QACT: D/4 elements, QST: D) x again into qbuf and its a_g, d_g =
//           mx_offset(a_g, amax) (0 in ROW mode), invg = inv * 2^d_g, q = q8(x * invg).
// QACT writes the bytes to ACT row r and each block's scale record (S and its four d); QST
// writes them to DRAM at dst + r*drs + c*es (byte writes; HALF: c < KB*D/2 only) and its scale
// row: ROW the word S at sdst + 4r, else S and the blocks' d bytes at sdst + r*(4 + 4*ceil(KB/4)).
module lite_quant
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
  // TMEM reads
  output logic          t_re,
  output logic [31:0]   t_ra,
  input  logic [31:0]   t_rd,
  // multiply-add, composite engine
  output logic          f_v,
  output logic [31:0]   f_a, f_b, f_c,
  input  logic          f_ov,
  input  logic [31:0]   f_y,
  output logic          c_start,
  output logic [1:0]    c_fn,
  output logic [31:0]   c_x,
  input  logic          c_done,
  input  logic [31:0]   c_y,
  // ACT RAM: a byte of row aw_row; a (row, block) scale record
  output logic          aw_we,
  output logic [1:0]    aw_row,
  output logic [AW-1:0] aw_addr,
  output logic [7:0]    aw_data,
  output logic          as_we,
  output logic [1:0]    as_row,
  output logic [BW-1:0] as_blk,
  output logic [31:0]   as_sa,
  output logic [19:0]   as_da,
  // DRAM writes (QST)
  output logic          m_req,
  output logic [31:0]   m_addr,
  output logic [31:0]   m_wd,
  output logic [3:0]    m_be,
  input  logic          m_rdy
);
  localparam f32_t NZERO = 32'h8000_0000;
  localparam int LD = $clog2(D);

  typedef enum logic [4:0] {
    S_IDLE, S_ROW, X_RD, X_A, X_RS, X_M1, X_W1, X_CSR, X_CS, X_M2, X_W2, X_GOT,
    S_SC_M, S_SC_W, S_INV_C, S_INV_W, S_INV_M, S_INV_F, S_GRP, S_G_M, S_G_W, S_Q_RD, S_Q_M,
    S_Q_W, S_Q_OUT, S_REC, S_DW, S_SW, S_NEXT
  } st_t;
  st_t st;

  wire        qst  = (cmd.op == OP_QST);
  wire        rowm = cmd.flags[0];
  wire        csc  = !qst && cmd.flags[1];
  wire        rsc  = !qst && cmd.flags[2];
  wire [15:0] rows = qst ? cmd.w4[15:0] : 16'(cmd.w2[7:0]);
  wire [15:0] kb   = qst ? cmd.w4[31:16] : cmd.w2[31:16];
  wire [7:0]  ab   = cmd.w2[15:8];
  wire [31:0] srs  = qst ? cmd.w5 : cmd.w3;
  wire [6:0]  gsz  = qst ? 7'(D) : 7'(D / 4);
  wire        half = qst && cmd.flags[1];
  wire [31:0] srw  = 32'd4 + {(32'(kb) + 32'd3) >> 2, 2'b00};   // QST int8 scale row bytes

  logic [15:0] r, n, c, g0;
  logic [6:0]  gi;
  logic        pass2;
  logic [31:0] srow, brow, bptr, sbase;        // src row, dst row / byte, scale row
  logic [31:0] x, rsv, amax, s, inv, invg, ag;
  logic [4:0]  dg;
  logic [19:0] da;
  logic [31:0] dword;
  logic [31:0] qbuf [64];
  logic [31:0] qv;

  function automatic logic [4:0] mxoff(input logic [31:0] a, input logic [31:0] m);
    logic signed [9:0] d;
    if (a[30:0] == 0) return 5'd0;
    d = $signed(10'(m[30:23])) - $signed(10'(a[30:23])) - ((a[22:0] > m[22:0]) ? 10'sd1 : 10'sd0);
    if (d < 0) return 5'd0;
    if (d > 31) return 5'd31;
    return 5'(d);
  endfunction

  wire [15:0] ne = half ? (n >> 1) : n;
  wire [15:0] blk = g0 >> LD;                  // the group's block
  always_ff @(posedge clk) qv <= qbuf[gi[5:0]];

  always_comb begin
    t_re = 1'b0; t_ra = '0;
    f_v = 1'b0; f_a = '0; f_b = '0; f_c = '0;
    c_start = 1'b0; c_fn = 2'd0; c_x = '0;
    aw_we = 1'b0; aw_row = '0; aw_addr = '0; aw_data = '0;
    as_we = 1'b0; as_row = '0; as_blk = '0; as_sa = '0; as_da = '0;
    m_req = 1'b0; m_addr = '0; m_wd = '0; m_be = '0;
    case (st)
      X_RD:  begin t_re = 1'b1; t_ra = srow + 32'(c); end
      X_A:   if (rsc) begin t_re = 1'b1; t_ra = cmd.w5 + 32'(r); end
      X_M1:  begin f_v = 1'b1; f_a = x; f_b = rsv; f_c = NZERO; end
      X_CSR: begin t_re = 1'b1; t_ra = cmd.w4 + 32'(c); end
      X_M2:  begin f_v = 1'b1; f_a = x; f_b = t_rd; f_c = NZERO; end
      S_SC_M: begin f_v = 1'b1; f_a = amax; f_b = F_INV127; f_c = NZERO; end
      S_INV_C: begin c_start = 1'b1; c_fn = 2'd1; c_x = amax; end
      S_INV_M: begin f_v = 1'b1; f_a = F_127; f_b = inv; f_c = NZERO; end   // inv: recip(amax)
      S_G_M: begin f_v = 1'b1; f_a = inv; f_b = {1'b0, 8'd127 + 8'(dg), 23'd0}; f_c = NZERO; end
      S_Q_M: begin f_v = 1'b1; f_a = qv; f_b = invg; f_c = NZERO; end
      S_Q_OUT: if (!qst) begin
        aw_we = 1'b1;
        aw_row = r[1:0];
        aw_addr = AW'({ab, {LD{1'b0}}}) + AW'(g0) + AW'(gi);
        aw_data = x[7:0];
      end else begin
        m_req = (g0 + 16'(gi) < ne);
        m_addr = {bptr[31:2], 2'b00};
        m_be = 4'b0001 << bptr[1:0];
        m_wd = {4{x[7:0]}};
      end
      S_REC: begin
        as_we = 1'b1;
        as_row = r[1:0];
        as_blk = BW'(32'(ab) + 32'(blk));
        as_sa = s;
        as_da = da;
      end
      S_DW: begin                              // QST: a word of d bytes (blocks blk-3 .. blk)
        m_req = 1'b1;
        m_be = 4'hF;
        m_addr = sbase + 32'd4 + {16'd0, blk[15:2], 2'b00};
        m_wd = dword;
      end
      S_SW: begin
        m_req = 1'b1;
        m_be = 4'hF;
        m_addr = sbase;
        m_wd = s;
      end
      default: ;
    endcase
  end

  task automatic next_group();
    if (g0 + 16'(gsz) == n) begin
      st <= qst ? S_SW : S_NEXT;
    end else begin
      g0 <= g0 + 16'(gsz);
      c <= g0 + 16'(gsz);
      ag <= '0;
      gi <= '0;
      st <= X_RD;
    end
  endtask

  // x is the element: pass 1 folds amax, pass 2 fills qbuf
  task automatic got_x(input logic [31:0] v);
    logic [31:0] fx;
    fx = fabs(v);
    if (!pass2) begin
      if (fx[30:0] > amax[30:0]) amax <= fx;
      if (c + 16'd1 == n) st <= S_SC_M;
      else begin c <= c + 16'd1; st <= X_RD; end
    end else begin
      qbuf[gi[5:0]] <= v;
      if (fx[30:0] > ag[30:0]) ag <= fx;
      if (gi + 7'd1 == gsz) begin gi <= '0; st <= S_GRP; end
      else begin gi <= gi + 7'd1; c <= c + 16'd1; st <= X_RD; end
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
          srow <= cmd.f1;
          brow <= cmd.f2;
          sbase <= cmd.f3;
          n <= kb << LD;
          if (!qst && (cmd.flags[3] || rows > 16'(MCOLS) || 32'(ab) + 32'(kb) > ACT_BLOCKS))
            err <= 1'b1;                       // DUP is not in this build; ACT RAM bounds
          else if (half && !rowm) err <= 1'b1;
          else if (rows == 0 || kb == 0) done <= 1'b1;
          else st <= S_ROW;
        end
        S_ROW: begin
          c <= '0;
          amax <= '0;
          pass2 <= 1'b0;
          bptr <= brow;
          st <= X_RD;
        end
        // ---- the element x = T[src + r*srs + c], scaled
        X_RD: st <= X_A;
        X_A: begin
          x <= t_rd;
          if (rsc) st <= X_RS;
          else if (csc) st <= X_CSR;
          else got_x(t_rd);
        end
        X_RS: begin rsv <= t_rd; st <= X_M1; end
        X_M1: st <= X_W1;
        X_W1: if (f_ov) begin
          x <= f_y;
          if (csc) st <= X_CSR;
          else got_x(f_y);
        end
        X_CSR: st <= X_CS;
        X_CS: st <= X_M2;                      // t_rd: the column scale (issued in X_M2)
        X_M2: st <= X_W2;
        X_W2: if (f_ov) begin x <= f_y; got_x(f_y); end
        // ---- the row's scale and inverse
        S_SC_M: st <= S_SC_W;
        S_SC_W: if (f_ov) begin
          pass2 <= 1'b1;
          c <= '0;
          g0 <= '0;
          gi <= '0;
          ag <= '0;
          da <= '0;
          dword <= '0;
          if (amax[30:0] == 0) begin
            s <= F_ZERO;
            inv <= F_ZERO;
            st <= X_RD;
          end else begin
            s <= f_y;
            st <= S_INV_C;
          end
        end
        S_INV_C: st <= S_INV_W;
        S_INV_W: if (c_done) begin inv <= c_y; st <= S_INV_M; end
        S_INV_M: st <= S_INV_F;
        S_INV_F: if (f_ov) begin inv <= f_y; st <= X_RD; end
        // ---- a group: its offset, invg, then its bytes
        S_GRP: begin dg <= rowm ? 5'd0 : mxoff(ag, amax); st <= S_G_M; end
        S_G_M: st <= S_G_W;
        S_G_W: if (f_ov) begin invg <= f_y; gi <= '0; st <= S_Q_RD; end
        S_Q_RD: st <= S_Q_M;                     // qv = qbuf[gi]
        S_Q_M: st <= S_Q_W;
        S_Q_W: if (f_ov) begin x <= {24'd0, q8(f_y)}; st <= S_Q_OUT; end
        S_Q_OUT: if (!m_req || m_rdy) begin
          bptr <= bptr + cmd.w7;
          if (gi + 7'd1 != gsz) begin
            gi <= gi + 7'd1;
            st <= S_Q_RD;
          end else if (!qst) begin
            da[5 * int'(g0[LD-1:LD-2]) +: 5] <= dg;
            if (g0[LD-1:LD-2] == 2'd3) st <= S_REC;
            else next_group();
          end else begin
            dword[8 * int'(blk[1:0]) +: 8] <= {3'd0, dg};
            if (!rowm && (blk[1:0] == 2'd3 || g0 + 16'(gsz) == n)) st <= S_DW;
            else next_group();
          end
        end
        S_REC: next_group();
        S_DW: if (m_rdy) begin dword <= '0; next_group(); end
        S_SW: if (m_rdy) st <= S_NEXT;
        S_NEXT: begin
          if (r + 16'd1 == rows) begin
            done <= 1'b1;
            st <= S_IDLE;
          end else begin
            r <= r + 16'd1;
            srow <= srow + srs;
            brow <= brow + cmd.w6;
            sbase <= sbase + (rowm ? 32'd4 : srw);
            st <= S_ROW;
          end
        end
        default: ;
      endcase
    end
  end
endmodule
