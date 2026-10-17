// The lite core's one fp32 unit: y = add(mul(a, b), c), two roundings, as the ISA's composite
// steps are defined (docs/isa.md "Arithmetic"; otpu_fp's staged functions, bit-exact with
// opentpu/fp32.py). Every other operation is a case of it:
//   mul(a, b)  = a * b + (-0)       (x + -0 = x for every x, +-0 and NaN included)
//   add(a, c)  = a * 1.0 + c        (a * 1.0 = ftz(a); a NaN becomes the canonical one, as add's)
//   sub(a, c)  = a * 1.0 + (-c)
// Fully pipelined, LAT = 6 cycles from in_v to out_v.
module lite_fma
  import otpu_fp::*;
(
  input  logic        clk,
  input  logic        in_v,
  input  logic [31:0] a, b, c,
  output logic        out_v,
  output logic [31:0] y
);
  localparam int LAT = 6;
  fmul_mid_t  m1;
  f32_t       c1, c2, p2;
  fadd_p1_t   s3;
  fadd_p2_t   s4;
  fadd_nm_t   s5;
  logic [LAT-1:0] v;

  always_ff @(posedge clk) begin
    v  <= {v[LAT-2:0], in_v};
    m1 <= fp_mul_s1(a, b);
    c1 <= c;
    p2 <= fp_mul_s2(m1);
    c2 <= c1;
    s3 <= fp_add_s1(p2, c2);
    s4 <= fp_add_s2(s3);
    s5 <= fp_add_s3(s4);
    y  <= fp_add_s4(s5);
  end
  assign out_v = v[LAT-1];
endmodule
