// openTPU on the Sipeed Tang Nano 20K (GW2AR-LV18QN88C8/I7): the lite core (rtl/lite), the
// SDRAM-and-SD memory system, the UART host link. docs/tangnano20k.md.
module tang_top #(
  parameter logic [31:0] BUILD_ID  = 32'h0,
  parameter logic [31:0] ARCH_HASH = 32'h0
) (
  input  logic        sys_clk,          // 27 MHz
  input  logic        s1,               // button: reset
  input  logic        uart_rx,
  output logic        uart_tx,
  output logic [5:0]  led,              // active low
  output logic        sd_clk,
  inout  wire         sd_cmd,
  input  logic [3:0]  sd_dat,
  // the embedded SDRAM
  output logic        O_sdram_clk,
  output logic        O_sdram_cke,
  output logic        O_sdram_cs_n,
  output logic        O_sdram_cas_n,
  output logic        O_sdram_ras_n,
  output logic        O_sdram_wen_n,
  output logic [3:0]  O_sdram_dqm,
  output logic [10:0] O_sdram_addr,
  output logic [1:0]  O_sdram_ba,
  inout  wire  [31:0] IO_sdram_dq
);
  localparam int CORE_KHZ = 48000;
  logic clk, clk_p, locked;
  tang_pll u_pll (.clock_in(sys_clk), .clk, .clk_p, .locked);

  // reset: until the PLL locks, and while S1 is held
  logic [15:0] rcnt;
  logic        rst;
  always_ff @(posedge clk) begin
    if (!locked || s1) begin rcnt <= '0; rst <= 1'b1; end
    else if (rcnt != '1) rcnt <= rcnt + 16'd1;
    else rst <= 1'b0;
  end

  // ---- the core
  logic        core_rst, core_start, halted, error, loading;
  logic [3:0]  ecode;
  logic [31:0] icount, prog_addr, prog_n;
  logic [31:0] args [8];
  logic        c_req, c_we, c_rdy, c_rv;
  logic [31:0] c_addr, c_wd, c_rd;
  logic [3:0]  c_be;
  lite_core #(.D(64), .MCOLS(4), .ACT_BLOCKS(64), .TMEM_WORDS(8192), .IMEM_N(512)) u_core (
    .clk, .rst(rst || core_rst), .start(core_start), .prog_addr, .prog_n, .args,
    .halted, .error, .ecode, .icount, .loading,
    .m_req(c_req), .m_we(c_we), .m_addr(c_addr), .m_wd(c_wd), .m_be(c_be), .m_rdy(c_rdy),
    .m_rv(c_rv), .m_rd(c_rd),
    .dbg_re(1'b0), .dbg_ra(32'd0), .dbg_rd(), .dbg_we(1'b0), .dbg_wa(32'd0), .dbg_wd(32'd0));

  // ---- memory: SDRAM, SD card, the address space
  logic        m_ready, m_req, m_we, m_ack, m_wtake, m_rv;
  logic [20:0] m_addr;
  logic [8:0]  m_len;
  logic [31:0] m_wd, m_rd;
  logic [3:0]  m_wbe;
  tang_sdram u_sdram (
    .clk, .rst, .ready(m_ready), .req(m_req), .we(m_we), .addr(m_addr), .len(m_len), .ack(m_ack),
    .wtake(m_wtake), .wd(m_wd), .wbe(m_wbe), .rv(m_rv), .rd(m_rd),
    .O_sdram_clk, .O_sdram_cke, .O_sdram_cs_n, .O_sdram_ras_n, .O_sdram_cas_n, .O_sdram_wen_n,
    .O_sdram_dqm, .O_sdram_addr, .O_sdram_ba, .IO_sdram_dq, .clk_sdram_p(clk_p));

  logic        sd_ready, sd_fail, sdhc, sd_req, sd_busy, sd_dv;
  logic [7:0]  sd_state;
  logic [31:0] sd_lba, sd_dw;
  logic [15:0] sd_n;
  tang_sd u_sd (
    .clk, .rst, .ready(sd_ready), .fail(sd_fail), .sdhc, .state_dbg(sd_state),
    .rd_req(sd_req), .rd_lba(sd_lba), .rd_n(sd_n), .busy(sd_busy), .dv(sd_dv), .dw(sd_dw),
    .sd_clk, .sd_cmd, .sd_dat);

  logic        h_req, h_we, h_raw, h_rdy, h_rv;
  logic [31:0] h_addr, h_wd, h_rd;
  logic [3:0]  h_be;
  logic [31:0] img_lba, img_bytes, fault_addr, line_fills;
  logic        map_reset, map_busy, fault, mem_idle;
  logic [15:0] cow_used;
  tang_mem u_mem (
    .clk, .rst, .img_lba, .img_bytes, .map_reset, .map_busy, .mem_idle, .fault, .fault_addr,
    .cow_used, .line_fills,
    .c_req, .c_we, .c_addr, .c_wd, .c_be, .c_rdy, .c_rv, .c_rd,
    .h_req, .h_we, .h_raw, .h_addr, .h_wd, .h_be, .h_rdy, .h_rv, .h_rd,
    .sd_ready, .sd_req, .sd_lba, .sd_n, .sd_busy, .sd_dv, .sd_dw,
    .m_ready, .m_req, .m_we, .m_addr, .m_len, .m_ack, .m_wtake, .m_wd, .m_wbe, .m_rv, .m_rd);

  // ---- the host
  logic [2:0] hled;
  tang_host #(.DIV(CORE_KHZ / 2000), .CORE_KHZ(CORE_KHZ), .BUILD_ID(BUILD_ID),
              .ARCH_HASH(ARCH_HASH)) u_host (
    .clk, .rst, .uart_rx, .uart_tx,
    .h_req, .h_we, .h_raw, .h_addr, .h_wd, .h_be, .h_rdy, .h_rv, .h_rd,
    .core_rst, .core_start, .prog_addr, .prog_n, .args, .halted, .error, .loading, .ecode,
    .icount, .img_lba, .img_bytes, .map_reset, .map_busy, .mem_idle, .fault,
    .sdram_ready(m_ready), .sd_ready, .sd_fail, .sdhc, .fault_addr, .line_fills, .cow_used,
    .sd_state, .led(hled));

  // LEDs: 0 running, 1 error, 2 card ready, 3 SDRAM ready, 4 memory fault, 5 heartbeat
  logic [24:0] hb;
  always_ff @(posedge clk) hb <= hb + 25'd1;
  assign led = ~{hb[24], fault, m_ready, hled[2], hled[1], hled[0]};
endmodule
