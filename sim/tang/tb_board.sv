// The Tang Nano 20K build without its PLL (the testbench drives clk and the 180-degree clk_p),
// with the SDRAM and SD card models: tb_board.cpp talks to it over the UART.
module tb_board #(parameter logic [31:0] ARCH_HASH = 32'h0) (
  input  logic clk,
  input  logic clk_p,
  input  logic rst,
  input  logic uart_rx,
  output logic uart_tx,
  output logic [2:0] led
);
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

  logic        m_ready, m_req, m_we, m_ack, m_wtake, m_rv;
  logic [20:0] m_addr;
  logic [8:0]  m_len;
  logic [31:0] m_wd, m_rd;
  logic [3:0]  m_wbe;
  wire         s_clk, s_cke, s_cs, s_ras, s_cas, s_we;
  wire  [3:0]  s_dqm;
  wire  [10:0] s_addr;
  wire  [1:0]  s_ba;
  wire  [31:0] s_dq;
  tang_sdram #(.INIT_WAIT(200)) u_sdram (
    .clk, .rst, .ready(m_ready), .req(m_req), .we(m_we), .addr(m_addr), .len(m_len), .ack(m_ack),
    .wtake(m_wtake), .wd(m_wd), .wbe(m_wbe), .rv(m_rv), .rd(m_rd),
    .O_sdram_clk(s_clk), .O_sdram_cke(s_cke), .O_sdram_cs_n(s_cs), .O_sdram_ras_n(s_ras),
    .O_sdram_cas_n(s_cas), .O_sdram_wen_n(s_we), .O_sdram_dqm(s_dqm), .O_sdram_addr(s_addr),
    .O_sdram_ba(s_ba), .IO_sdram_dq(s_dq), .clk_sdram_p(clk_p));
  sdram_model u_sdm (.clk_p(s_clk), .cke(s_cke), .cs_n(s_cs), .ras_n(s_ras), .cas_n(s_cas),
                     .we_n(s_we), .dqm(s_dqm), .addr(s_addr), .ba(s_ba), .dq(s_dq));

  logic        sd_ready, sd_fail, sdhc, sd_req, sd_busy, sd_dv, sd_clk;
  logic [7:0]  sd_state;
  logic [31:0] sd_lba, sd_dw;
  logic [15:0] sd_n;
  tri1         sd_cmd;                  // the card slot's pull-up
  wire  [3:0]  sd_dat;
  tang_sd #(.SLOW_DIV(4)) u_sd (
    .clk, .rst, .ready(sd_ready), .fail(sd_fail), .sdhc, .state_dbg(sd_state),
    .rd_req(sd_req), .rd_lba(sd_lba), .rd_n(sd_n), .busy(sd_busy), .dv(sd_dv), .dw(sd_dw),
    .sd_clk, .sd_cmd, .sd_dat);
  sd_model u_sdc (.sd_clk, .sd_cmd, .sd_dat);

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

  tang_host #(.DIV(24), .CORE_KHZ(48000), .ARCH_HASH(ARCH_HASH)) u_host (
    .clk, .rst, .uart_rx, .uart_tx,
    .h_req, .h_we, .h_raw, .h_addr, .h_wd, .h_be, .h_rdy, .h_rv, .h_rd,
    .core_rst, .core_start, .prog_addr, .prog_n, .args, .halted, .error, .loading, .ecode,
    .icount, .img_lba, .img_bytes, .map_reset, .map_busy, .mem_idle, .fault,
    .sdram_ready(m_ready), .sd_ready, .sd_fail, .sdhc, .fault_addr, .line_fills, .cow_used,
    .sd_state, .led);
endmodule
