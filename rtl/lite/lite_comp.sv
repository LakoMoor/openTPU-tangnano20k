// The composite functions (docs/isa.md "Arithmetic"): exp2, recip, rsqrt, log2, one element at
// a time as fixed sequences of the shared multiply-add (lite_fma). Each step is otpu_fp's
// fp_exp2 / fp_recip / fp_rsqrt / fp_log2 step, rewritten as one a * b + c:
//   fp_sub(K, fp_mul(a, y)) = (-a) * y + K     (a negated product rounds to the negated product;
//                                              a NaN product is the canonical NaN either way)
//   fp_mul(a, b)            = a * b + (-0)
//   fp_add(x, K)            = x * 1 + K
// so the results are the reference functions' bit for bit (tests: tools/tang/cosim.py).
module lite_comp
  import otpu_fp::*;
(
  input  logic        clk,
  input  logic        rst,
  input  logic        start,
  input  logic [1:0]  fn,          // 0 exp2, 1 recip, 2 rsqrt, 3 log2
  input  logic [31:0] x_in,
  output logic        done,        // one cycle, y valid
  output logic [31:0] y,
  // the multiply-add (OR-shared: zero while idle)
  output logic        f_v,
  output logic [31:0] f_a, f_b, f_c,
  input  logic        f_ov,
  input  logic [31:0] f_y
);
  localparam logic [1:0] FN_EXP2 = 0, FN_RECIP = 1, FN_RSQRT = 2, FN_LOG2 = 3;
  localparam f32_t NZERO = 32'h8000_0000;

  typedef enum logic [1:0] { S_IDLE, S_ISSUE, S_WAIT, S_POST } st_t;
  st_t st;
  logic [1:0]  f;
  logic [3:0]  step, nsteps;
  f32_t        rx, ry, rt, rh, ra;
  logic [31:0] ri;               // exp2: i; log2: e (signed)
  logic        lo, hi, sgn;
  logic [8:0]  ek;

  function automatic f32_t ec(input int k);   // EXP2_C0..C7
    case (k)
      0: return EXP2_C0; 1: return EXP2_C1; 2: return EXP2_C2; 3: return EXP2_C3;
      4: return EXP2_C4; 5: return EXP2_C5; 6: return EXP2_C6; default: return EXP2_C7;
    endcase
  endfunction
  function automatic f32_t lc(input int k);   // LOG2_C1..C9
    case (k)
      1: return LOG2_C1; 2: return LOG2_C2; 3: return LOG2_C3; 4: return LOG2_C4;
      5: return LOG2_C5; 6: return LOG2_C6; 7: return LOG2_C7; 8: return LOG2_C8;
      default: return LOG2_C9;
    endcase
  endfunction

  wire f32_t fi = i2f(ri);                 // exp2's i2f(i), log2's i2f(e): one converter

  // the step's operands, and where its result goes (0 ry, 1 rt, 2 rh)
  f32_t sa, sb, sc;
  logic [1:0] dst;
  always_comb begin
    sa = '0; sb = '0; sc = NZERO; dst = 2'd0;
    case (f)
      FN_EXP2: begin
        if (step == 0) begin                          // f = x - i2f(i)
          sa = rx; sb = F_ONE; sc = fneg(fi); dst = 2'd1;
        end else begin                                // p = p*f + C(7-step)
          sa = (step == 1) ? EXP2_C7 : ry; sb = rt; sc = ec(7 - int'(step));
        end
      end
      FN_RECIP: begin
        case (step)
          0, 2: begin sa = fneg(ra); sb = ry; sc = F_TWO; dst = 2'd1; end
          1, 3: begin sa = ry; sb = rt; sc = NZERO; end
          4:    begin sa = fneg(ra); sb = ry; sc = F_ONE; dst = 2'd1; end
          default: begin sa = ry; sb = rt; sc = ry; end
        endcase
      end
      FN_RSQRT: begin
        case (step)
          0:       begin sa = F_HALF; sb = rx; sc = NZERO; dst = 2'd2; end
          1, 4, 7: begin sa = ry; sb = ry; sc = NZERO; dst = 2'd1; end
          2, 5:    begin sa = fneg(rh); sb = rt; sc = F_1P5; dst = 2'd1; end
          3, 6:    begin sa = ry; sb = rt; sc = NZERO; end
          8:       begin sa = fneg(rh); sb = rt; sc = F_HALF; dst = 2'd1; end
          default: begin sa = ry; sb = rt; sc = ry; end
        endcase
      end
      default: begin                                  // log2
        if (step == 0) begin                          // t = m - 1
          sa = rx; sb = F_ONE; sc = F_M1; dst = 2'd1;
        end else if (step == 9) begin                 // q*t + i2f(e)
          sa = ry; sb = rt; sc = fi;
        end else begin                                // q = q*t + C(9-step)
          sa = (step == 1) ? LOG2_C9 : ry; sb = rt; sc = lc(9 - int'(step));
        end
      end
    endcase
  end

  assign f_v = (st == S_ISSUE);
  assign f_a = (st == S_ISSUE) ? sa : '0;
  assign f_b = (st == S_ISSUE) ? sb : '0;
  assign f_c = (st == S_ISSUE) ? sc : '0;

  always_ff @(posedge clk) begin
    done <= 1'b0;
    if (rst) begin
      st <= S_IDLE;
    end else begin
      case (st)
        S_IDLE: if (start) begin
          f32_t x;
          x = ftz(x_in);
          f <= fn;
          step <= '0;
          rx <= x;
          st <= S_ISSUE;
          case (fn)
            FN_EXP2: begin
              nsteps <= 4'd8;
              ri <= 32'(ffloor(x));
              if (is_nan(x))               begin y <= F_INF;  done <= 1'b1; st <= S_IDLE; end
              else if (fp_gt(F_M126, x))   begin y <= F_ZERO; done <= 1'b1; st <= S_IDLE; end
              else if (!fp_gt(F_128, x))   begin y <= F_INF;  done <= 1'b1; st <= S_IDLE; end
            end
            FN_RECIP: begin
              nsteps <= 4'd6;
              ra <= {9'h07F, x[22:0]};
              ry <= RECIP_MAGIC - {9'h07F, x[22:0]};
              ek <= rcp_ek(x);
              sgn <= x[31];
              if (x[30:0] == 0)                  begin y <= F_ZERO; done <= 1'b1; st <= S_IDLE; end
              else if (x[30:0] >= 31'h7E80_0000) begin y <= {x[31], 31'b0}; done <= 1'b1; st <= S_IDLE; end
            end
            FN_RSQRT: begin
              f32_t xs;
              nsteps <= 4'd10;
              lo <= rsq_lo(x);
              hi <= rsq_hi(x);
              xs = x;
              if (rsq_lo(x)) xs = x + 32'h0200_0000;
              if (rsq_hi(x)) xs = x - 32'h0200_0000;
              rx <= xs;
              ry <= RSQRT_MAGIC - (xs >> 1);
              if (x[31] || x[30:0] == 0 || x == 32'h7F80_0000) begin
                y <= F_ZERO; done <= 1'b1; st <= S_IDLE;
              end
            end
            default: begin
              logic ge;
              nsteps <= 4'd10;
              ge = (x[22:0] >= LOG2_SQRT2);
              ri <= 32'(x[30:23]) - 32'sd127 + 32'(ge);
              rx <= {1'b0, ge ? 8'd126 : 8'd127, x[22:0]};
              if (x[30:0] == 0)              begin y <= F_NINF; done <= 1'b1; st <= S_IDLE; end
              else if (x[31] || is_nan(x))   begin y <= F_NAN;  done <= 1'b1; st <= S_IDLE; end
              else if (x == F_INF)           begin y <= F_INF;  done <= 1'b1; st <= S_IDLE; end
            end
          endcase
        end
        S_ISSUE: st <= S_WAIT;
        S_WAIT: if (f_ov) begin
          case (dst)
            2'd0: ry <= f_y;
            2'd1: rt <= f_y;
            default: rh <= f_y;
          endcase
          step <= step + 4'd1;
          st <= (step + 4'd1 == nsteps) ? S_POST : S_ISSUE;
        end
        default: begin                                // S_POST: ry holds the last result
          case (f)
            FN_EXP2:  y <= ry + (ri << 23);
            FN_RECIP: begin
              f32_t t;
              t = ry + {ek, 23'd0};
              y <= sgn ? fneg(t) : t;
            end
            FN_RSQRT: y <= lo ? ry + 32'h0100_0000 : hi ? ry - 32'h0100_0000 : ry;
            default:  y <= ry;
          endcase
          done <= 1'b1;
          st <= S_IDLE;
        end
      endcase
    end
  end
endmodule
