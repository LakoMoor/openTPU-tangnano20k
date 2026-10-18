// Behavioural model of an SDHC card in SD mode, 4-bit reads: CMD0, 8, 55, ACMD41, 2, 3, 7,
// ACMD6, 16, 6 (switch function: a 64-byte status, high speed supported), 18 (multi-block read from the block in the argument), 12. The card's bytes come
// from the testbench (DPI: sd_byte). Commands are sampled on the rising clock, responses and
// data driven on the falling one. CRCs are not checked; data CRCs are sent as zeros. Every
// STALL_EVERY-th multi-block read (0: none) stops sending after its third block until CMD12,
// as a card that stalls (the host restarts the read). The data CRC16s are the real ones; every
// ERR_EVERY-th block (0: none) has a data bit flipped after its CRC was computed.
module sd_model #(parameter int STALL_EVERY = 0, parameter int ERR_EVERY = 0) (
  input  logic       sd_clk,
  inout  wire        sd_cmd,
  output logic [3:0] sd_dat
);
  import "DPI-C" function int sd_byte(input longint addr);
  logic        cmd_oe, cmd_o;
  assign sd_cmd = cmd_oe ? cmd_o : 1'bz;
  wire cmd_in = (sd_cmd === 1'b0) ? 1'b0 : 1'b1;

  logic [47:0] rx;
  logic [7:0]  rxn;
  logic        inc;                       // receiving a command
  logic [135:0] tx;
  logic [7:0]  txn;                       // response bits left
  logic [7:0]  delay;
  logic        acmd;
  logic [3:0]  a41;
  // data
  logic        rd_on, stop, sw;           // sw: the data is CMD6's status
  int          nreads, nblk;
  logic        hold;                      // stalled
  logic [15:0] crc [4];
  int          nall;                      // blocks sent

  function automatic logic [15:0] crc16(input logic [15:0] c, input logic b);
    return {c[14:0], 1'b0} ^ ((b ^ c[15]) ? 16'h1021 : 16'h0000);
  endfunction
  logic [31:0] blk;
  logic [11:0] dn;                        // nibble position in the block frame
  logic [7:0]  gap;
  logic [7:0]  busy;

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
  function automatic logic [47:0] r48(input logic [5:0] idx, input logic [31:0] arg);
    return {2'b00, idx, arg, crc7({2'b00, idx, arg}), 1'b1};
  endfunction

  initial begin sw = 0; hold = 0; nreads = 0; nblk = 0; nall = 0; cmd_oe = 0; sd_dat = 4'hF; inc = 0; txn = 0; rd_on = 0; busy = 0; a41 = 0; acmd = 0; end

  always @(posedge sd_clk) begin
    if (txn == 0 && !cmd_oe) begin
      if (!inc) begin
        if (!cmd_in) begin inc <= 1; rxn <= 1; rx <= 48'd0; end
      end else begin
        rx <= {rx[46:0], cmd_in};
        rxn <= rxn + 1;
        if (rxn == 47) begin
          logic [47:0] c;
          logic [5:0]  idx;
          logic [31:0] arg;
          c = {1'b0, rx[45:0], cmd_in};
          idx = c[45:40];
          arg = c[39:8];
          inc <= 0;
          delay <= 2;
          if (acmd) begin
            acmd <= 0;
            case (idx)
              6'd41: begin
                a41 <= a41 + 1;
                tx[135:88] <= {2'b00, 6'h3F, (a41 >= 2) ? 32'hC0FF_8000 : 32'h00FF_8000, 7'h7F, 1'b1};
                txn <= 48;
              end
              default: begin tx[135:88] <= r48(idx, 32'h0000_0920); txn <= 48; end
            endcase
          end else case (idx)
            6'd0: txn <= 0;
            6'd8: begin tx[135:88] <= r48(6'd8, arg); txn <= 48; end
            6'd55: begin acmd <= 1; tx[135:88] <= r48(6'd55, 32'h0000_0120); txn <= 48; end
            6'd2: begin tx <= {2'b00, 6'h3F, 127'h1234_5678_9ABC_DEF0_1234_5678_9ABC_DE, 1'b1}; txn <= 136; end
            6'd3: begin tx[135:88] <= r48(6'd3, 32'h1234_0500); txn <= 48; end
            6'd7: begin tx[135:88] <= r48(6'd7, 32'h0000_0700); txn <= 48; busy <= 20; end
            6'd16: begin tx[135:88] <= r48(6'd16, 32'h0000_0900); txn <= 48; end
            6'd6: begin
              tx[135:88] <= r48(6'd6, 32'h0000_0900); txn <= 48;
              rd_on <= 1; stop <= 0; sw <= 1; dn <= 0; gap <= 10;
            end
            6'd18: begin
              tx[135:88] <= r48(6'd18, 32'h0000_0900); txn <= 48;
              rd_on <= 1; stop <= 0; sw <= 0; blk <= arg; dn <= 0; gap <= 10;
              nreads <= nreads + 1; nblk <= 0;
              hold <= 0;
            end
            6'd12: begin tx[135:88] <= r48(6'd12, 32'h0000_0B00); txn <= 48; stop <= 1; busy <= 30; end
            default: begin tx[135:88] <= r48(idx, 32'h0000_0900); txn <= 48; end
          endcase
        end
      end
    end
  end

  // responses and data on the falling clock
  always @(negedge sd_clk) begin
    if (txn != 0) begin
      if (delay != 0) delay <= delay - 1;
      else begin
        cmd_oe <= 1;
        cmd_o <= tx[135];
        tx <= {tx[134:0], 1'b1};
        txn <= txn - 1;
      end
    end else cmd_oe <= 0;
    // data: start nibble, 1024 data nibbles, 16 CRC nibbles, the end nibble, a gap
    if (rd_on && !stop && hold) sd_dat <= 4'hF;
    else if (rd_on && !stop) begin
      if (gap != 0) begin gap <= gap - 1; sd_dat <= 4'hF; end
      else begin
        if (dn == 0) begin
          sd_dat <= 4'h0;
          for (int i = 0; i < 4; i++) crc[i] <= '0;
        end else if (sw) begin                 // status nibbles: 27 (bits 403:400), 33 (379:376)
          sd_dat <= (dn == 28) ? 4'h3 : (dn == 34) ? 4'h1 : (dn <= 144) ? 4'h0 : 4'hF;
          dn <= dn + 1;
          if (dn == 145) begin rd_on <= 0; sw <= 0; end
        end else if (dn <= 1024) begin
          logic [7:0] b;
          logic [3:0] v;
          b = 8'(sd_byte({blk, 9'd0} + 64'((dn - 1) >> 1)));
          v = ((dn - 1) & 1) ? b[3:0] : b[7:4];
          for (int i = 0; i < 4; i++) crc[i] <= crc16(crc[i], v[i]);
          if (ERR_EVERY != 0 && nall % ERR_EVERY == ERR_EVERY - 1 && dn == 101) v[0] = !v[0];
          sd_dat <= v;
        end else if (dn <= 1040) begin
          for (int i = 0; i < 4; i++) sd_dat[i] <= crc[i][15 - (dn - 1025)];
        end
        else sd_dat <= 4'hF;
        if (!sw || dn == 0) dn <= dn + 1;
        if (!sw && dn == 1041) begin
          dn <= 0; blk <= blk + 1; gap <= 4;
          nblk <= nblk + 1;
          nall <= nall + 1;
          if (STALL_EVERY != 0 && nreads % STALL_EVERY == 0 && nblk == 2) hold <= 1;
        end
      end
    end else if (busy != 0) begin
      busy <= busy - 1;
      sd_dat <= {3'b111, (busy == 1)};     // D0 low while busy
      if (stop) rd_on <= 0;
    end else sd_dat <= 4'hF;
  end
endmodule
