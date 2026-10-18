// openTPU lite core: the sequencer, the four units, TMEM, ACT RAM, the shared multiply-add and
// the composite engine (rtl/lite/lite_pkg.sv). One instruction runs at a time, so the units
// share every resource by OR: an idle unit drives zeros.
//
// The DRAM port: m_req / m_we / m_addr (bytes, word aligned) / m_wd / m_be, taken when m_rdy;
// read data comes back in request order on m_rv / m_rd, and is always accepted. The memory path
// must keep reads and writes in order (a read after a write returns the write).
module lite_core
  import lite_pkg::*;
#(
  parameter int D          = 64,
  parameter int MCOLS      = 4,
  parameter int ACT_BLOCKS = 64,
  parameter int TMEM_WORDS = 8192,
  parameter int IMEM_N     = 512
) (
  input  logic        clk,
  input  logic        rst,             // high: stopped
  input  logic        start,
  input  logic [31:0] prog_addr,
  input  logic [31:0] prog_n,
  input  logic [31:0] args [8],
  output logic        halted,
  output logic        error,
  output logic [3:0]  ecode,
  output logic [31:0] icount,
  output logic        loading,
  // DRAM
  output logic        m_req,
  output logic        m_we,
  output logic [31:0] m_addr,
  output logic [31:0] m_wd,
  output logic [3:0]  m_be,
  input  logic        m_rdy,
  input  logic        m_rv,
  input  logic [31:0] m_rd,
  // TMEM debug access (simulation / host diagnostics; while halted)
  input  logic        dbg_re,
  input  logic [31:0] dbg_ra,
  output logic [31:0] dbg_rd,
  input  logic        dbg_we,
  input  logic [31:0] dbg_wa,
  input  logic [31:0] dbg_wd
);
  localparam int TW = $clog2(TMEM_WORDS);
  localparam int AW = $clog2(ACT_BLOCKS * D);
  localparam int BW = $clog2(ACT_BLOCKS);

  cmd_t       cmd;
  logic [3:0] u_start;
  logic       d_done, mm_done, q_done, v_done, d_err, mm_err, q_err, v_err;

  // ---- shared buses: each source's outputs
  logic        sq_tre, dm_tre, mm_tre, qn_tre, vp_tre;
  logic [31:0] sq_tra, dm_tra, mm_tra, qn_tra, vp_tra;
  logic        dm_twe, mm_twe, vp_twe;
  logic [31:0] dm_twa, mm_twa, vp_twa, dm_twd, mm_twd, vp_twd;
  logic        mm_fv, qn_fv, vp_fv, cp_fv;
  logic [31:0] mm_fa, mm_fb, mm_fc, qn_fa, qn_fb, qn_fc, vp_fa, vp_fb, vp_fc, cp_fa, cp_fb, cp_fc;
  logic        qn_cs, vp_cs;
  logic [1:0]  qn_cf, vp_cf;
  logic [31:0] qn_cx, vp_cx;
  logic        sq_mreq, dm_mreq, mm_mreq, qn_mreq, dm_mwe;
  logic [31:0] sq_maddr, dm_maddr, mm_maddr, qn_maddr, dm_mwd, qn_mwd;
  logic [3:0]  dm_mbe, qn_mbe;

  // ---- TMEM
  logic        t_re, t_we;
  logic [31:0] t_ra, t_wa, t_wd, t_rd;
  assign t_re = sq_tre | dm_tre | mm_tre | qn_tre | vp_tre | dbg_re;
  assign t_ra = sq_tra | dm_tra | mm_tra | qn_tra | vp_tra | (dbg_re ? dbg_ra : 32'd0);
  assign t_we = dm_twe | mm_twe | vp_twe | dbg_we;
  assign t_wa = dm_twa | mm_twa | vp_twa | (dbg_we ? dbg_wa : 32'd0);
  assign t_wd = dm_twd | mm_twd | vp_twd | (dbg_we ? dbg_wd : 32'd0);
  logic [31:0] tmem [TMEM_WORDS];
  always_ff @(posedge clk) begin
    if (t_we) tmem[t_wa[TW-1:0]] <= t_wd;
    if (t_re) t_rd <= tmem[t_ra[TW-1:0]];
  end
  assign dbg_rd = t_rd;

  // ---- the multiply-add and the composite engine
  logic        f_v, f_ov;
  logic [31:0] f_a, f_b, f_c, f_y;
  assign f_v = mm_fv | qn_fv | vp_fv | cp_fv;
  assign f_a = mm_fa | qn_fa | vp_fa | cp_fa;
  assign f_b = mm_fb | qn_fb | vp_fb | cp_fb;
  assign f_c = mm_fc | qn_fc | vp_fc | cp_fc;
  lite_fma u_fma (.clk, .in_v(f_v), .a(f_a), .b(f_b), .c(f_c), .out_v(f_ov), .y(f_y));

  logic        c_done;
  logic [31:0] c_y;
  lite_comp u_comp (.clk, .rst, .start(qn_cs | vp_cs), .fn(qn_cf | vp_cf), .x_in(qn_cx | vp_cx),
                    .done(c_done), .y(c_y),
                    .f_v(cp_fv), .f_a(cp_fa), .f_b(cp_fb), .f_c(cp_fc), .f_ov, .f_y);

  // ---- ACT RAM: a byte RAM per row, read together; the scale records
  logic          aw_we, as_we, a_re, s_re;
  logic [1:0]    aw_row, as_row, s_row;
  logic [AW-1:0] aw_addr, a_ra;
  logic [7:0]    aw_data;
  logic [BW-1:0] as_blk, s_blk;
  logic [31:0]   as_sa, a_rd, s_sa;
  logic [19:0]   as_da, s_da;
  for (genvar r = 0; r < MCOLS; r++) begin : g_act
    logic [7:0] mem [ACT_BLOCKS * D];
    always_ff @(posedge clk) begin
      if (aw_we && aw_row == 2'(r)) mem[aw_addr] <= aw_data;
      if (a_re) a_rd[8 * r +: 8] <= mem[a_ra];
    end
  end
  logic [31:0] sa_mem [MCOLS * ACT_BLOCKS];
  logic [19:0] da_mem [MCOLS * ACT_BLOCKS];
  always_ff @(posedge clk) begin
    if (as_we) begin
      sa_mem[{as_row, as_blk}] <= as_sa;
      da_mem[{as_row, as_blk}] <= as_da;
    end
    if (s_re) begin
      s_sa <= sa_mem[{s_row, s_blk}];
      s_da <= da_mem[{s_row, s_blk}];
    end
  end

  // ---- DRAM
  assign m_req  = sq_mreq | dm_mreq | mm_mreq | qn_mreq;
  assign m_we   = dm_mwe | qn_mreq;
  assign m_addr = sq_maddr | dm_maddr | mm_maddr | qn_maddr;
  assign m_wd   = dm_mwd | qn_mwd;
  assign m_be   = dm_mbe | qn_mbe;

  // ---- the sequencer and the units
  wire       u_done = d_done | mm_done | q_done | v_done;
  wire       u_err  = d_err | mm_err | q_err | v_err;
  wire [3:0] u_ecode = d_err ? E_WAITW : mm_err ? E_MM : q_err ? E_QUANT : E_VFUNC;

  lite_seq #(.IMEM_N(IMEM_N)) u_seq (
    .clk, .rst, .start, .prog_addr, .prog_n, .args, .halted, .error, .ecode, .icount, .loading,
    .cmd, .u_start, .u_done, .u_err, .u_ecode,
    .t_re(sq_tre), .t_ra(sq_tra), .t_rd,
    .m_req(sq_mreq), .m_addr(sq_maddr), .m_rdy, .m_rv, .m_rd);

  lite_dma u_dma (
    .clk, .rst, .start(u_start[0]), .cmd, .done(d_done), .err(d_err),
    .t_re(dm_tre), .t_ra(dm_tra), .t_rd, .t_we(dm_twe), .t_wa(dm_twa), .t_wd(dm_twd),
    .m_req(dm_mreq), .m_we(dm_mwe), .m_addr(dm_maddr), .m_wd(dm_mwd), .m_be(dm_mbe), .m_rdy,
    .m_rv, .m_rd);

  lite_mm #(.D(D), .MCOLS(MCOLS), .ACT_BLOCKS(ACT_BLOCKS)) u_mm (
    .clk, .rst, .start(u_start[1]), .cmd, .done(mm_done), .err(mm_err),
    .t_re(mm_tre), .t_ra(mm_tra), .t_rd, .t_we(mm_twe), .t_wa(mm_twa), .t_wd(mm_twd),
    .f_v(mm_fv), .f_a(mm_fa), .f_b(mm_fb), .f_c(mm_fc), .f_ov, .f_y,
    .a_re, .a_ra, .a_rd, .s_re, .s_row, .s_blk, .s_sa, .s_da,
    .m_req(mm_mreq), .m_addr(mm_maddr), .m_rdy, .m_rv, .m_rd);

  lite_quant #(.D(D), .MCOLS(MCOLS), .ACT_BLOCKS(ACT_BLOCKS)) u_quant (
    .clk, .rst, .start(u_start[2]), .cmd, .done(q_done), .err(q_err),
    .t_re(qn_tre), .t_ra(qn_tra), .t_rd,
    .f_v(qn_fv), .f_a(qn_fa), .f_b(qn_fb), .f_c(qn_fc), .f_ov, .f_y,
    .c_start(qn_cs), .c_fn(qn_cf), .c_x(qn_cx), .c_done, .c_y,
    .aw_we, .aw_row, .aw_addr, .aw_data, .as_we, .as_row, .as_blk, .as_sa, .as_da,
    .m_req(qn_mreq), .m_addr(qn_maddr), .m_wd(qn_mwd), .m_be(qn_mbe), .m_rdy);

  lite_vpu u_vpu (
    .clk, .rst, .start(u_start[3]), .cmd, .done(v_done), .err(v_err),
    .t_re(vp_tre), .t_ra(vp_tra), .t_rd, .t_we(vp_twe), .t_wa(vp_twa), .t_wd(vp_twd),
    .f_v(vp_fv), .f_a(vp_fa), .f_b(vp_fb), .f_c(vp_fc), .f_ov, .f_y,
    .c_start(vp_cs), .c_fn(vp_cf), .c_x(vp_cx), .c_done, .c_y);
endmodule
