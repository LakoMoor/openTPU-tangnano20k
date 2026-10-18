// SD card reader, native mode, 4-bit bus (the Tang Nano 20K's TF slot). Reads only: the model
// image is written on a PC. After reset it initializes the card at ~400 kHz (CMD0, CMD8,
// ACMD41 until ready, CMD2, CMD3, CMD7, ACMD6 4-bit, CMD16 for SDSC), then runs at clk / (2 *
// FAST_DIV), or, after a switch to high speed (CMD6; the host asks for it), at clk itself (clk,
// or its inverse, muxed onto the pin).
// A read of n blocks from block lba is CMD18 (SDHC: block address; SDSC: bytes) and
// the blocks' data streamed out as little-endian words (dv / dw, 128 per block), then CMD12 and
// the card's busy. Each block's CRC16 (one per DAT line) is checked: a block that fails it, or a
// card that stalls, restarts the read from that block (up to 4 times; then the block counts as
// lost, rd_tmo, and its words stand). blk_ok marks each block accepted, blk_bad one to discard.
module tang_sd #(
  parameter int SLOW_DIV = 64,           // half periods of the 400 kHz init clock (clk / 128)
  parameter int FAST_DIV = 1,            // half periods of the data clock (50 MHz / 2 = 25 MHz)
  parameter int IDLE_BITS = 22           // a block's wait before a restart: 2^IDLE_BITS card clocks
) (
  input  logic        clk,
  input  logic        rst,
  output logic        ready,             // initialized
  output logic        fail,              // initialization failed (no card, no response)
  output logic        sdhc,
  output logic [7:0]  state_dbg,
  output logic [19:0] info_dbg,          // {a response seen, last timed out, last command, tries}
  // bring-up settings from the host: the data clock's divider, the sampling delay in clk
  // cycles after the card clock's rising edge, and a restart of the initialization
  input  logic [7:0]  cfg_div,
  input  logic [1:0]  cfg_samp,
  input  logic        cfg_hs,            // switch to high speed (once; reinit to undo)
  input  logic        cfg_pol,           // high speed: 0 the card clock in phase with clk, 1 inverted
  input  logic        cfg_neg,           // sample the pins on clk's falling edge (half a cycle earlier)
  output logic [5:0]  hs_stat,           // {high speed on, CMD6 done, CMD6's function 1 result}
  input  logic        reinit,
  output logic [15:0] rd_tmo,            // blocks the card never sent (read as 0)
  output logic [15:0] rd_retry,          // reads restarted after the card stalled
  input  logic [2:0]  resp_sel,          // the last response to CMD8, ACMD41, CMD3, CMD7, ACMD6,
  output logic [31:0] resp_dbg,          // CMD16, CMD18, CMD12 (bring-up); bit 32: timed out
  output logic [7:0]  resp_tmo,
  input  logic        rd_req,            // start a read (ready, not busy)
  input  logic [31:0] rd_lba,
  input  logic [15:0] rd_n,              // blocks, >= 1
  output logic        busy,
  output logic        dv,
  output logic [31:0] dw,
  output logic        blk_ok,            // the block's words stand (pulse)
  output logic        blk_bad,           // discard the block's words: it comes again (pulse)
  // pins
  output logic        sd_clk,
  inout  wire         sd_cmd,
  input  logic [3:0]  sd_dat
);
  // ---------------------------------------------------------------- the card clock
  logic [7:0] div, dcnt;
  logic       rise, fall;                // this cycle the card clock rises / falls
  logic       clk_en;                    // run the clock
  logic       hs_on;                     // high speed: the card clock is clk
  logic       sdc;                       // the divided clock
  wire        tog = clk_en && (dcnt + 8'd1 >= div);
  wire        sdc_n = tog ? ~sdc : sdc;
  always_ff @(posedge clk) begin
    rise <= hs_on || (tog && !sdc);
    fall <= hs_on || (tog && sdc);
    if (rst) begin
      sdc <= 1'b0; dcnt <= '0;
    end else if (clk_en) begin
      sdc <= sdc_n;
      dcnt <= tog ? 8'd0 : dcnt + 8'd1;
    end
  end
  assign sd_clk = hs_on ? clk ^ cfg_pol : sdc;
  // the registered pins: cmd out on a falling edge, cmd / dat sampled with the rising edge
  logic cmd_oe, cmd_o;
  // (high speed, the card clock in phase with clk: CMD changes on clk's falling edge, half a
  // card clock from the card's sampling edge)
  logic cmd_oe_n, cmd_o_n;
  always_ff @(negedge clk) begin cmd_oe_n <= cmd_oe; cmd_o_n <= cmd_o; end
  wire  cmd_late = hs_on && !cfg_pol;
  assign sd_cmd = (cmd_late ? cmd_oe_n : cmd_oe) ? (cmd_late ? cmd_o_n : cmd_o) : 1'bz;
  logic       cmd_i;
  logic [3:0] dat_i;
  logic [4:0] pin_q [4];                 // the pins, delayed 1..4 cycles
  logic [4:0] pin_n;
  always_ff @(negedge clk) pin_n <= {sd_cmd, sd_dat};
  always_ff @(posedge clk) begin
    pin_q[0] <= cfg_neg ? pin_n : {sd_cmd, sd_dat};
    for (int k = 1; k < 4; k++) pin_q[k] <= pin_q[k - 1];
  end
  assign {cmd_i, dat_i} = pin_q[cfg_samp];

  function automatic logic [6:0] crc7(input logic [39:0] d);
    logic [6:0] c;
    c = '0;
    for (int i = 39; i >= 0; i--) begin
      logic fb;
      fb = d[i] ^ c[6];
      c = {c[5:0], 1'b0};
      if (fb) c = c ^ 7'h09;
    end
    return c;
  endfunction

  // ---------------------------------------------------------------- command engine
  logic        c_go, c_done, c_tmo;
  logic [5:0]  c_idx;
  logic [31:0] c_arg;
  logic [1:0]  c_rt;                     // 0 none, 1 48-bit, 2 136-bit
  logic [47:0] c_frame;
  logic [7:0]  c_bit;
  logic [135:0] c_resp;
  logic [7:0]  c_wait;
  logic        c_seen;                   // any response since reset (bring-up)
  typedef enum logic [2:0] { K_IDLE, K_SEND, K_WAITR, K_RECV, K_GAP } kst_t;
  kst_t kst;
  wire [31:0] r_arg = c_resp[39:8];       // a 48-bit response's argument

  always_ff @(posedge clk) begin
    c_done <= 1'b0;
    if (rst) begin
      kst <= K_IDLE; cmd_oe <= 1'b0; cmd_o <= 1'b1; c_seen <= 1'b0;
    end else case (kst)
      K_IDLE: if (c_go) begin
        c_frame <= {2'b01, c_idx, c_arg, crc7({2'b01, c_idx, c_arg}), 1'b1};
        c_bit <= 8'd47;
        c_tmo <= 1'b0;
        kst <= K_SEND;
      end
      K_SEND: if (fall) begin
        cmd_oe <= 1'b1;
        cmd_o <= c_frame[c_bit];
        if (c_bit == 0) begin
          kst <= K_WAITR;
          c_wait <= 8'd0;
        end else c_bit <= c_bit - 8'd1;
      end
      K_WAITR: begin
        if (fall && cmd_oe) cmd_oe <= 1'b0;   // the end bit has been out a full clock
        if (c_rt == 0) begin
          if (fall && !cmd_oe) begin c_wait <= 8'd8; kst <= K_GAP; end
        end else if (rise && !cmd_oe) begin
          if (!cmd_i) begin                  // the start bit
            c_seen <= 1'b1;
            c_bit <= (c_rt == 2'd2) ? 8'd134 : 8'd46;
            c_resp <= '0;
            kst <= K_RECV;
          end else if (c_wait == 8'd255) begin
            c_tmo <= 1'b1; c_wait <= 8'd8; kst <= K_GAP;
          end else c_wait <= c_wait + 8'd1;
        end
      end
      K_RECV: if (rise) begin
        c_resp <= {c_resp[134:0], cmd_i};
        if (c_bit == 0) begin c_wait <= 8'd8; kst <= K_GAP; end
        else c_bit <= c_bit - 8'd1;
      end
      default: if (rise) begin               // K_GAP: eight clocks between commands (Nrc)
        if (c_wait == 0) begin c_done <= 1'b1; kst <= K_IDLE; end
        else c_wait <= c_wait - 8'd1;
      end
    endcase
  end
  // c_resp holds the response without its start bit: [46:0] of a 48-bit one

  logic [31:0] resp_r [8];
  logic [2:0]  resp_k;
  always_comb case (c_idx)
    6'd8: resp_k = 3'd0;  6'd41: resp_k = 3'd1; 6'd3: resp_k = 3'd2;  6'd7: resp_k = 3'd3;
    6'd6: resp_k = 3'd4;  6'd16: resp_k = 3'd5; 6'd18: resp_k = 3'd6; default: resp_k = 3'd7;
  endcase
  always_ff @(posedge clk) if (c_done) begin
    resp_r[resp_k] <= r_arg;
    resp_tmo[resp_k] <= c_tmo;
  end
  assign resp_dbg = resp_r[resp_sel];

  // ---------------------------------------------------------------- data receiver
  logic        d_en;                     // receive blocks
  logic [15:0] d_left;
  logic [10:0] d_cnt;                    // nibbles of the block (1024) and CRC (16) + end
  logic        d_in;                     // inside a block
  logic [31:0] d_sr;
  logic [2:0]  d_nib;
  logic        d_blk;                    // a block completed (pulse)
  logic        d_fake;                   // the card stopped sending: the block's words read as 0
  logic        d_stall;                  // no block for ~2^22 card clocks (pulse): restart
  logic [2:0]  d_tries;                  // restarts left in this read (then d_fake)
  logic [IDLE_BITS-1:0] d_idle;          // (SDHC: up to 100 ms a block; 2^22 = 87 ms at 48 MHz)
  logic [3:0]  d_slow;
  logic        d_short;                  // CMD6's 64-byte status, kept here (not streamed)
  logic [3:0]  sw_res, sw_sup;           // its function group 1 result / support nibbles
  logic        d_bad;                    // a block's CRC failed, restart (pulse)
  logic        d_lost;                   // a block taken although its CRC failed (pulse)
  logic [15:0] d_crc [4], d_rcrc [4];    // CRC16 of each DAT line's data / as received

  assign blk_ok  = d_blk && !d_short;
  assign blk_bad = d_bad;

  function automatic logic [15:0] crc16(input logic [15:0] c, input logic b);
    return {c[14:0], 1'b0} ^ ((b ^ c[15]) ? 16'h1021 : 16'h0000);
  endfunction

  always_ff @(posedge clk) begin
    dv <= 1'b0;
    d_blk <= 1'b0;
    d_stall <= 1'b0;
    d_bad <= 1'b0;
    d_lost <= 1'b0;
    if (rst || !d_en) begin
      d_in <= 1'b0; d_fake <= 1'b0; d_idle <= '0;
    end else if (d_fake) begin
      d_slow <= d_slow + 4'd1;               // (the rest of the read too)
      if (d_slow == 0) begin
        dw <= '0;
        dv <= 1'b1;
        d_cnt <= d_cnt + 11'd8;
        if (d_cnt == 11'd1016) begin d_cnt <= '0; d_blk <= 1'b1; end
      end
    end else if (!d_in && d_left != 0 && &d_idle) begin
      d_idle <= '0;
      if (d_tries != 0 && !d_short) d_stall <= 1'b1;
      else begin d_fake <= 1'b1; d_in <= 1'b1; d_cnt <= '0; d_slow <= '0; end
    end else if (rise) begin
      if (!d_in) d_idle <= d_idle + 1'b1;
      if (!d_in) begin
        if (dat_i == 4'b0000 && d_left != 0) begin
          d_in <= 1'b1; d_cnt <= '0; d_nib <= '0; d_idle <= '0;
          for (int i = 0; i < 4; i++) d_crc[i] <= '0;
        end
      end else begin
        d_cnt <= d_cnt + 11'd1;
        if (d_short) begin
          if (d_cnt == 11'd27) sw_sup <= dat_i;   // status bits 403:400 (401: high speed)
          if (d_cnt == 11'd33) sw_res <= dat_i;   // bits 379:376: 1 = switched, F = cannot
          if (d_cnt == 11'd144) begin d_in <= 1'b0; d_blk <= 1'b1; end
        end else if (d_cnt < 11'd1024) begin
          // a byte is two nibbles, the high one first; a word is four bytes, little endian
          d_sr <= {d_sr[27:0], dat_i};
          d_nib <= d_nib + 3'd1;
          for (int i = 0; i < 4; i++) d_crc[i] <= crc16(d_crc[i], dat_i[i]);
          if (d_nib == 3'd7) begin
            logic [31:0] w;
            w = {d_sr[27:0], dat_i};          // bytes b0 b1 b2 b3 in arrival order
            dw <= {w[7:0], w[15:8], w[23:16], w[31:24]};
            dv <= 1'b1;
          end
        end else if (d_cnt < 11'd1040) begin    // 16 CRC nibbles
          for (int i = 0; i < 4; i++) d_rcrc[i] <= {d_rcrc[i][14:0], dat_i[i]};
        end else begin                          // the end bit
          logic ok;
          ok = 1'b1;
          for (int i = 0; i < 4; i++) if (d_crc[i] != d_rcrc[i]) ok = 1'b0;
          d_in <= 1'b0;
          if (ok || d_tries == 0) begin d_blk <= 1'b1; d_lost <= !ok; end
          else d_bad <= 1'b1;
        end
      end
    end
  end

  // ---------------------------------------------------------------- the controller
  typedef enum logic [4:0] {
    M_PWR, M_CMD0, M_CMD8, M_CMD55, M_ACMD41, M_CMD2, M_CMD3, M_CMD7, M_BUSY7, M_CMD55B,
    M_ACMD6, M_CMD16, M_READY, M_CMD18, M_DATA, M_CMD12, M_BUSY12, M_FAIL, M_WAIT, M_CMD6D,
    M_RBUSY
  } mst_t;
  mst_t ms, after;
  logic [15:0] tries;
  logic [15:0] rca;
  logic        v2;
  logic [7:0]  pwr;
  logic [25:0] retry;
  logic [31:0] r_lba;                    // the read's first block and length (restarts)
  logic [15:0] r_n;
  logic        hs_done;
  assign hs_stat = {hs_on, hs_done, sw_res};
  assign state_dbg = {kst, ms};
  assign info_dbg = {c_seen, c_tmo, c_idx, tries[11:0]};
  assign busy = (ms != M_READY) || rd_req;

  task automatic issue(input logic [5:0] idx, input logic [31:0] arg, input logic [1:0] rt,
                       input mst_t nxt);
    c_idx <= idx; c_arg <= arg; c_rt <= rt; c_go <= 1'b1;
    after <= nxt;
    ms <= M_WAIT;
  endtask

  always_ff @(posedge clk) begin
    c_go <= 1'b0;
    if (rst) begin
      ms <= M_PWR; ready <= 1'b0; fail <= 1'b0; sdhc <= 1'b0; clk_en <= 1'b1; rd_tmo <= '0;
      rd_retry <= '0;
      div <= 8'(SLOW_DIV); pwr <= '0; tries <= '0; d_en <= 1'b0; v2 <= 1'b0; retry <= '0;
      hs_on <= 1'b0; hs_done <= 1'b0; d_short <= 1'b0;
    end else if (reinit) begin
      ms <= M_PWR; ready <= 1'b0; fail <= 1'b0; div <= 8'(SLOW_DIV); pwr <= '0; tries <= '0;
      d_en <= 1'b0; v2 <= 1'b0; retry <= '0; hs_on <= 1'b0; hs_done <= 1'b0; d_short <= 1'b0;
    end else case (ms)
      M_PWR: if (rise) begin                 // 80+ clocks, CMD high
        pwr <= pwr + 8'd1;
        if (pwr == 8'd90) ms <= M_CMD0;
      end
      M_CMD0: issue(6'd0, 32'd0, 2'd0, M_CMD8);
      M_CMD8: issue(6'd8, 32'h0000_01AA, 2'd1, M_CMD55);
      M_CMD55: begin
        if (after == M_CMD55 && c_idx == 6'd8) v2 <= !c_tmo && r_arg[7:0] == 8'hAA;
        issue(6'd55, 32'd0, 2'd1, M_ACMD41);
      end
      M_ACMD41: issue(6'd41, v2 ? 32'h40FF_8000 : 32'h00FF_8000, 2'd1, M_CMD2);
      M_CMD2: begin
        if (c_idx == 6'd41) begin
          if (c_tmo || !r_arg[31]) begin       // still busy (or no answer): again
            tries <= tries + 16'd1;
            if (tries == 16'd20000) ms <= M_FAIL;
            else issue(6'd55, 32'd0, 2'd1, M_ACMD41);
          end else begin
            sdhc <= r_arg[30];
            issue(6'd2, 32'd0, 2'd2, M_CMD3);
          end
        end
      end
      M_CMD3: issue(6'd3, 32'd0, 2'd1, M_CMD7);
      M_CMD7: begin
        if (c_tmo) ms <= M_FAIL;
        else begin
          rca <= r_arg[31:16];
          issue(6'd7, {r_arg[31:16], 16'd0}, 2'd1, M_BUSY7);
        end
      end
      M_BUSY7: if (rise && dat_i[0]) issue(6'd55, {rca, 16'd0}, 2'd1, M_ACMD6);
      M_ACMD6: issue(6'd6, 32'd2, 2'd1, M_CMD16);
      M_CMD16: issue(6'd16, 32'd512, 2'd1, M_READY);
      M_READY: begin
        if (!ready) begin
          ready <= 1'b1;
          fail <= 1'b0;
        end
        div <= (cfg_div == 0) ? 8'(FAST_DIV) : cfg_div;
        if (cfg_hs && !hs_done && !rd_req) begin   // CMD6: switch function 1 to high speed
          d_left <= 16'd1;
          d_en <= 1'b1;
          d_short <= 1'b1;
          retry <= '0;
          issue(6'd6, 32'h80FF_FFF1, 2'd1, M_CMD6D);
        end else if (rd_req) begin
          d_left <= rd_n;
          d_en <= 1'b1;
          d_tries <= 3'd4;
          r_lba <= rd_lba;
          r_n <= rd_n;
          retry <= '0;
          issue(6'd18, sdhc ? rd_lba : {rd_lba[22:0], 9'd0}, 2'd1, M_DATA);
        end
      end
      M_DATA: begin
        if (d_stall || d_bad) begin          // the card stalled, or sent a bad block: stop,
          d_en <= 1'b0;                      // then read on from the block it owes
          d_tries <= d_tries - 3'd1;
          if (rd_retry != '1) rd_retry <= rd_retry + 16'd1;
          retry <= '0;
          issue(6'd12, 32'd0, 2'd1, M_RBUSY);
        end else if (d_blk) begin
          if ((d_fake || d_lost) && rd_tmo != '1) rd_tmo <= rd_tmo + 16'd1;
          d_tries <= 3'd4;                   // (restarts per block)
          d_left <= d_left - 16'd1;
          if (d_left == 16'd1) issue(6'd12, 32'd0, 2'd1, M_BUSY12);
        end
      end
      M_BUSY12: begin
        d_en <= 1'b0;
        retry <= retry + 26'd1;
        if ((rise && dat_i[0]) || &retry[21:0]) ms <= M_READY;
      end
      M_WAIT: if (c_done) ms <= after;
      M_RBUSY: begin
        logic [31:0] nl;
        nl = r_lba + 32'(r_n - d_left);
        retry <= retry + 26'd1;
        if ((rise && dat_i[0]) || &retry[21:0]) begin
          d_en <= 1'b1;
          issue(6'd18, sdhc ? nl : {nl[22:0], 9'd0}, 2'd1, M_DATA);
        end
      end
      M_CMD6D: begin                         // the status block, then the faster clock
        retry <= retry + 26'd1;
        if (d_blk || &retry[21:0]) begin
          d_en <= 1'b0;
          d_short <= 1'b0;
          hs_done <= 1'b1;
          hs_on <= d_blk && !d_fake && sw_res == 4'd1;
          ms <= M_READY;
        end
      end
      default: begin                         // M_FAIL: try again about a second later (a card
        fail <= 1'b1;                        // inserted after the configuration)
        retry <= retry + 26'd1;
        if (&retry) begin
          ms <= M_PWR; div <= 8'(SLOW_DIV); pwr <= '0; tries <= '0; v2 <= 1'b0;
        end
      end
    endcase
  end
endmodule
