// The host link of the Tang Nano 20K build: a binary protocol over the BL616's USB UART, and
// the control registers (the openTPU register map's subset the host uses, docs/observability.md,
// plus the board's own at 0x200; opentpu/host/tang.py speaks it). Little endian:
//   0x57 'W' addr[4] n[2] word[4] x n  DRAM word writes             -> 0xA5
//   0x52 'R' addr[4] n[2]              DRAM word reads               -> word[4] x n
//   0x53 'S' addr[4] n[2]              the card's raw bytes (addr = block * 512 + offset)
//   0x77 'w' reg[2] val[4]             register write                -> 0xA5
//   0x72 'r' reg[2]                    register read                 -> val[4]
//   0x00                               no-op (the host resynchronizes with a few of them)
// A command that stalls for ~2.6 ms mid-way is dropped (the parser waits for an opcode again).
module tang_host #(
  parameter int    DIV       = 25,
  parameter int    CORE_KHZ  = 50000,
  parameter logic [31:0] BUILD_ID  = 32'h0,
  parameter logic [31:0] ARCH_HASH = 32'h0,
  parameter int    D = 64, MCOLS = 4, ACT_BLOCKS = 64, TMEM_WORDS = 8192, IMEM_WORDS = 4096,
  parameter int    PLATFORM = 3
) (
  input  logic        clk,
  input  logic        rst,
  input  logic        uart_rx,
  output logic        uart_tx,
  // DRAM (tang_mem's host port)
  output logic        h_req, h_we, h_raw,
  output logic [31:0] h_addr, h_wd,
  output logic [3:0]  h_be,
  input  logic        h_rdy,
  input  logic        h_rv,
  input  logic [31:0] h_rd,
  // the core
  output logic        core_rst,
  output logic        core_start,
  output logic [31:0] prog_addr, prog_n,
  output logic [31:0] args [8],
  input  logic        halted, error, loading,
  input  logic [3:0]  ecode,
  input  logic [31:0] icount,
  // the memory system and the card
  output logic [31:0] img_lba, img_bytes,
  output logic        map_reset,
  input  logic        map_busy, mem_idle, fault, sdram_ready, sd_ready, sd_fail, sdhc,
  input  logic [31:0] fault_addr, line_fills,
  input  logic [15:0] cow_used,
  input  logic [7:0]  sd_state,
  input  logic [19:0] sd_info,
  input  logic [15:0] sd_tmo,
  input  logic [15:0] sd_retry,
  output logic [7:0]  sd_div,            // 0x220: the SD settings (tang_sd's cfg_*)
  output logic [1:0]  sd_samp,
  output logic        sd_hs, sd_pol, sd_neg,
  input  logic [5:0]  sd_hs_stat,
  output logic        sd_reinit,
  output logic [2:0]  sd_rsel,
  input  logic [31:0] sd_resp,
  input  logic [7:0]  sd_rtmo,
  output logic [2:0]  led
);
  typedef enum logic [3:0] { P_OP, P_HDR, P_DATA, P_MW, P_MR, P_MRW, P_REGW, P_SEND, P_ACK } pst_t;
  pst_t ps;
  logic [15:0] left;
  // ---- UART
  logic       rx_v, rv, tv, trdy;
  logic [7:0] rx_d, rd8, td8;
  tang_uart_rx #(.DIV(DIV)) u_rx (.clk, .rst, .rx(uart_rx), .v(rx_v), .d(rx_d));
  // the received bytes wait here while a command's memory access runs (a write's copy of its
  // page from the card takes milliseconds): the host sends at most 64 words a command and waits
  // for its acknowledgement, which fits (there is no flow control on the BL616's UART)
  logic [7:0] rxf [512];
  logic [8:0] rx_wp, rx_rp;
  always_ff @(posedge clk) begin
    if (rx_v) begin rxf[rx_wp] <= rx_d; rx_wp <= rx_wp + 9'd1; end
    if (rv) rx_rp <= rx_rp + 9'd1;
    if (rst) begin rx_wp <= '0; rx_rp <= '0; end
  end
  assign rd8 = rxf[rx_rp];
  tang_uart_tx #(.DIV(DIV)) u_tx (.clk, .rst, .v(tv), .d(td8), .rdy(trdy), .tx(uart_tx));

  // ---- registers
  logic        run;
  logic [63:0] cycles;
  logic [31:0] scratch;
  wire  [31:0] status = {22'd0, (ecode == 4'd4), run, sd_ready, sdram_ready && !map_busy,
                         1'b0, mem_idle && !h_req, loading, error, halted && mem_idle};
  function automatic logic [31:0] reg_rd(input logic [15:0] a);
    case (a)
      16'h000: return 32'h4F54_5055;                              // "OTPU"
      16'h004: return {16'(D), 8'(MCOLS), 8'd1};
      16'h008: return {31'd0, run};
      16'h00C: return status;
      16'h010: return prog_addr;
      16'h014: return prog_n;
      16'h018: return cycles[31:0];
      16'h01C: return cycles[63:32];
      16'h020: return icount;
      16'h038: return scratch;
      16'h03C: return 32'd5;                                     // REGMAP
      // CAPS: bit24 ACT_ROWS, bit25 run arguments, bit29 MX numerics, bit30 the decode loop's
      // RLD / ARGMAX / HALT CHAIN, bit31 WAITW
      16'h040: return 32'hE300_0000;
      16'h044: return 32'(CORE_KHZ);
      16'h048: return BUILD_ID;
      16'h058: return 32'(MCOLS);                                // ACT_ROWS
      16'h05C: return 32'd0;                                     // CAPS2: no GATHER
      16'h060, 16'h064, 16'h068, 16'h06C, 16'h070, 16'h074, 16'h078, 16'h07C:
               return args[a[4:2]];
      16'h080: return 32'd1;
      16'h084: return 32'(TMEM_WORDS);
      16'h088: return 32'(IMEM_WORDS);
      16'h08C: return 32'(ACT_BLOCKS);
      16'h090: return {8'd0, 8'd30, 8'd1, 8'd30};               // 1 GiB, one channel
      16'h094: return 32'h0001_0000;                            // CFG_UARCH: ULANES 1
      16'h098: return 32'(PLATFORM);
      16'h09C: return ARCH_HASH;
      // the board's own
      16'h200: return img_lba;
      16'h204: return img_bytes;
      16'h208: return {31'd0, map_busy};
      16'h20C: return {fault, 15'd0, cow_used};
      16'h210: return fault_addr;
      16'h214: return line_fills;
      16'h218: return {sd_state, sd_info, sdhc, sd_fail, sd_ready, sdram_ready};
      16'h21C: return {28'd0, ecode};
      16'h220: return {sd_tmo, sd_div, sd_hs_stat, sd_samp};
      16'h224: return sd_resp;                                    // the response 0x228 selects
      16'h228: return {16'd0, sd_rtmo, 5'd0, sd_rsel};
      16'h22C: return {16'd0, sd_retry};                         // reads restarted (stalls)
      default: return 32'hDEAD_BEEF;
    endcase
  endfunction

  // ---- the parser
  logic [7:0]  op;
  logic [3:0]  hn;                       // header bytes received
  logic [47:0] hdr;                      // addr[4] n[2] / reg[2] val[4], little endian
  logic [31:0] word;
  logic [1:0]  bn;
  logic [31:0] sendw;
  logic [2:0]  sendn;
  logic [17:0] idle;
  wire  [3:0]  hlen = (op == 8'h72) ? 4'd2 : 4'd6;
  // a byte is taken where the parser wants one
  assign rv = (rx_wp != rx_rp) && (ps == P_OP || ps == P_HDR || (ps == P_DATA && left != 0));

  always_comb begin
    tv = 1'b0; td8 = '0;
    if (ps == P_SEND && trdy) begin tv = 1'b1; td8 = sendw[8 * (3'd4 - sendn) +: 8]; end
    if (ps == P_ACK && trdy) begin tv = 1'b1; td8 = 8'hA5; end
  end

  logic run_q;
  always_ff @(posedge clk) begin
    map_reset <= 1'b0;
    sd_reinit <= 1'b0;
    core_start <= 1'b0;
    run_q <= run;
    if (run && !run_q) core_start <= 1'b1;
    if (run && !halted) cycles <= cycles + 64'd1;
    if (rv || !(ps == P_HDR || ps == P_DATA)) idle <= '0;   // only while waiting for the host's bytes
    else if (idle != '1) idle <= idle + 18'd1;
    if (rst) begin
      ps <= P_OP; run <= 1'b0; h_req <= 1'b0; img_lba <= '0; img_bytes <= '0;
      sd_div <= '0; sd_samp <= 2'd1; sd_hs <= 1'b0; sd_pol <= 1'b0; sd_neg <= 1'b0;
      for (int k = 0; k < 8; k++) args[k] <= '0;
    end else if (idle == '1) begin
      ps <= P_OP;                         // a stalled command: dropped
    end else begin
      case (ps)
        P_OP: if (rv && rd8 != 8'h00) begin op <= rd8; hn <= '0; ps <= P_HDR; end
        P_HDR: if (rv) begin
          hdr <= {rd8, hdr[47:8]};
          hn <= hn + 4'd1;
          if (hn + 4'd1 == hlen) begin
            if (op == 8'h72) begin
              sendw <= reg_rd({rd8, hdr[47:40]});
              sendn <= 3'd4;
              ps <= P_SEND;
            end else if (op == 8'h77 || op == 8'h57 || op == 8'h52 || op == 8'h53) begin
              ps <= (op == 8'h57) ? P_DATA : (op == 8'h77) ? P_REGW : P_MR;
              left <= {rd8, hdr[47:40]};    // n (W, R, S)
              bn <= '0;
            end else ps <= P_OP;
          end
        end
        P_REGW: begin                       // hdr: val[31:0] in [47:16], reg in [15:0]
          case (hdr[15:0])
            16'h008: begin
              run <= hdr[16] && sdram_ready && !map_busy;
              if (hdr[18]) cycles <= '0;
            end
            16'h010: prog_addr <= hdr[47:16];
            16'h014: prog_n <= hdr[47:16];
            16'h038: scratch <= hdr[47:16];
            16'h060, 16'h064, 16'h068, 16'h06C, 16'h070, 16'h074, 16'h078, 16'h07C:
              args[hdr[4:2]] <= hdr[47:16];
            16'h200: img_lba <= hdr[47:16];
            16'h204: img_bytes <= hdr[47:16];
            16'h208: map_reset <= hdr[16];
            16'h228: sd_rsel <= hdr[18:16];
            16'h220: begin
              sd_samp <= hdr[17:16];
              sd_hs <= hdr[18];
              sd_pol <= hdr[19];
              sd_neg <= hdr[20];
              sd_div <= hdr[31:24];
              sd_reinit <= hdr[47];
            end
            default: ;
          endcase
          ps <= P_ACK;
        end
        // ---- W: words in, one write each
        P_DATA: begin
          if (left == 0) ps <= P_ACK;
          else if (rv) begin
            word <= {rd8, word[31:8]};
            bn <= bn + 2'd1;
            if (bn == 2'd3) begin
              h_req <= 1'b1; h_we <= 1'b1; h_raw <= 1'b0; h_be <= 4'hF;
              h_addr <= hdr[31:0]; h_wd <= {rd8, word[31:8]};
              ps <= P_MW;
            end
          end
        end
        P_MW: if (h_rdy) begin
          h_req <= 1'b0;
          hdr[31:0] <= hdr[31:0] + 32'd4;
          left <= left - 16'd1;
          ps <= P_DATA;
        end
        // ---- R / S: one read each, sent as it returns
        P_MR: begin
          if (left == 0) ps <= P_OP;
          else begin
            h_req <= 1'b1; h_we <= 1'b0; h_raw <= (op == 8'h53); h_addr <= hdr[31:0];
            ps <= P_MRW;
          end
        end
        P_MRW: begin
          if (h_req && h_rdy) h_req <= 1'b0;
          if (h_rv) begin
            sendw <= h_rd;
            sendn <= 3'd4;
            hdr[31:0] <= hdr[31:0] + 32'd4;
            left <= left - 16'd1;
            ps <= P_SEND;
          end
        end
        P_SEND: if (trdy) begin
          sendn <= sendn - 3'd1;
          if (sendn == 3'd1) ps <= (op == 8'h52 || op == 8'h53) ? P_MR : P_OP;
        end
        default: if (trdy) ps <= P_OP;      // P_ACK: the byte goes out this cycle
      endcase
    end
  end

  assign core_rst = !run;
  // LEDs (active low on the board, inverted at the top): running, error, the card ready
  assign led = {sd_ready, error, run && !halted};
endmodule
