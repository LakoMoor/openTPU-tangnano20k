// The Tang Nano 20K's DRAM: a 512 MiB address space (the core's and the host's) backed by the
// model image file on the SD card, with the 8 MiB SDRAM as its cache and its writable copy.
//
//   SDRAM (words)          what
//   0x000000 .. 0x00FFFF   the page table: a half word per 4 KiB page of the 512 MiB space
//                          (bit 15: the page has its own copy, bits 10:0 its COW page)
//   0x010000 .. 0x04FFFF   the SD line cache: 16 lines of 64 KiB (fully associative)
//   0x050000 .. 0x1FFFFF   COW pages: 1728 x 4 KiB
//
// A read of a page without a copy reads the image (the line holding it, from the SD card on a
// miss); past the image's end it reads 0. The first write to such a page copies it (from the
// image, or zeros past its end) to the next free COW page and maps it, so every write lands in
// the SDRAM and the image itself is never written. A small TLB (256 entries, direct mapped) keeps
// recent page-table entries, an 8-word chunk buffer the last chunk read (sequential reads).
// Requests run one at a time, in order (a read after a write sees it). The host may also read
// the card by its physical address (raw: byte address = block * 512), for the FAT.
module tang_mem #(
  parameter int NLINE = 16,
  parameter int NCOW  = 1728
) (
  input  logic        clk,
  input  logic        rst,
  // configuration (the host's registers)
  input  logic [31:0] img_lba,           // the image's first block on the card
  input  logic [31:0] img_bytes,         // the image's size (reads past it are 0)
  input  logic        map_reset,         // clear the page table, the TLB, the lines (pulse)
  output logic        map_busy,
  output logic        mem_idle,          // no request in progress (every write has landed)
  output logic        fault,             // sticky: the COW pool ran out, or an address >= 512 MiB
  output logic [31:0] fault_addr,
  output logic [15:0] cow_used,
  output logic [31:0] line_fills,
  // the core
  input  logic        c_req, c_we,
  input  logic [31:0] c_addr, c_wd,
  input  logic [3:0]  c_be,
  output logic        c_rdy,
  output logic        c_rv,
  output logic [31:0] c_rd,
  // the host
  input  logic        h_req, h_we, h_raw,
  input  logic [31:0] h_addr, h_wd,
  input  logic [3:0]  h_be,
  output logic        h_rdy,
  output logic        h_rv,
  output logic [31:0] h_rd,
  // the SD card (tang_sd)
  input  logic        sd_ready,
  output logic        sd_req,
  output logic [31:0] sd_lba,
  output logic [15:0] sd_n,
  input  logic        sd_busy,
  input  logic        sd_dv,
  input  logic [31:0] sd_dw,
  // the SDRAM (tang_sdram)
  input  logic        m_ready,
  output logic        m_req, m_we,
  output logic [20:0] m_addr,
  output logic [8:0]  m_len,
  input  logic        m_ack,
  input  logic        m_wtake,
  output logic [31:0] m_wd,
  output logic [3:0]  m_wbe,
  input  logic        m_rv,
  input  logic [31:0] m_rd
);
  localparam logic [20:0] LINE_BASE = 21'h010000, COW_BASE = 21'h050000;
  localparam int LW = $clog2(NLINE);

  typedef enum logic [4:0] {
    S_INIT, S_CLR, S_IDLE, S_TLB, S_TLBCK, S_PT, S_PTW, S_ROUTE, S_SDLOOK, S_FILL, S_FILLW,
    S_RD, S_RDW, S_WR, S_COW, S_COWRD, S_COWRW, S_COWWR, S_COWPT, S_RESP, S_ZERO
  } st_t;
  st_t st;

  // ---- the request being served
  logic        rq_h, rq_we, rq_raw;
  logic [31:0] rq_addr, rq_wd;
  logic [3:0]  rq_be;
  wire  [16:0] page = rq_addr[28:12];

  // ---- the chunk buffer: 8 words of the virtual chunk cb_tag (not raw reads)
  logic [31:0] cb [8];
  logic [26:0] cb_tag;
  logic        cb_v;
  wire  cb_hit = cb_v && cb_tag == rq_addr[31:5];

  // ---- the TLB: entry {valid, tag page[16:8], pte[15:0]}
  logic [25:0] tlb [256];
  logic [25:0] tlb_q;
  logic        tlb_we;
  logic [7:0]  tlb_wa;
  logic [25:0] tlb_wd;
  always_ff @(posedge clk) begin
    if (tlb_we) tlb[tlb_wa] <= tlb_wd;
    tlb_q <= tlb[page[7:0]];
  end
  logic [15:0] pte;

  // ---- the SD lines, keyed {raw, line}: an image line is the image's 64 KiB at addr[28:16]
  // (blocks img_lba + 128 * line ..), a raw line the card's blocks 128 * line .. (the FAT)
  logic [25:0] ltag [NLINE];
  logic [NLINE-1:0] lval;
  logic [LW-1:0] lway, victim;
  logic        lhit;
  wire  [25:0] lkey = rq_raw ? {1'b1, 9'd0, rq_addr[31:16]} : {1'b0, 12'd0, rq_addr[28:16]};
  wire  [31:0] fill_lba = rq_raw ? {rq_addr[31:16], 7'd0} : img_lba + {12'd0, rq_addr[28:16], 7'd0};
  always_comb begin
    lhit = 1'b0; lway = '0;
    for (int w = 0; w < NLINE; w++)
      if (lval[w] && ltag[w] == lkey) begin lhit = 1'b1; lway = LW'(w); end
  end

  // ---- the block buffer: SD blocks on their way to a line, COW copies (512 words)
  logic [31:0] bbuf [512];
  logic        bb_we;
  logic [8:0]  bb_wa, bb_ra;
  logic [31:0] bb_wd, bb_q;
  always_ff @(posedge clk) begin
    if (bb_we) bbuf[bb_wa] <= bb_wd;
    bb_q <= bbuf[bb_ra];
  end

  logic [8:0]  bi;                         // the burst's word (writes from bbuf)
  logic [15:0] nblk_in, nblk_out;          // fill: blocks received / written
  logic [8:0]  win;                        // fill: words received
  logic [1:0]  part;                       // COW: quarter of the page (256 words)
  logic [20:0] sdr;                        // the SDRAM word address of the request
  logic [16:0] clr;
  logic        wsel;                       // burst write source: 0 zeros, 1 bbuf
  logic [7:0]  tclr;
  logic        cow_ret;                    // a COW waits for its line's fill

  assign c_rdy = (st == S_IDLE) && !h_req && !map_reset;
  assign h_rdy = (st == S_IDLE) && !map_reset;
  assign map_busy = (st == S_INIT) || (st == S_CLR);
  assign mem_idle = (st == S_IDLE) && !m_req;

  // SDRAM write data: the request's word, the page-table half word, zeros, or bbuf
  always_comb begin
    m_wd = rq_wd; m_wbe = rq_be;
    case (st)
      S_CLR: begin m_wd = '0; m_wbe = 4'hF; end
      S_COWPT: begin m_wd = {2{1'b1, 4'd0, 11'(cow_used)}}; m_wbe = page[0] ? 4'b1100 : 4'b0011; end
      S_FILLW, S_COWWR: begin m_wd = wsel ? bb_q : 32'd0; m_wbe = 4'hF; end
      default: ;
    endcase
    // the block buffer's read address runs a word ahead of the burst
    bb_ra = (m_wtake ? bi + 9'd1 : bi);
  end

  task automatic respond(input logic [31:0] v);
    if (rq_h) begin h_rv <= 1'b1; h_rd <= v; end
    else begin c_rv <= 1'b1; c_rd <= v; end
  endtask

  always_ff @(posedge clk) begin
    c_rv <= 1'b0; h_rv <= 1'b0;
    if (m_ack) m_req <= 1'b0;                // requests hold until the SDRAM takes them
    sd_req <= 1'b0;
    tlb_we <= 1'b0;
    bb_we <= 1'b0;
    if (rst) begin
      st <= S_INIT;
      fault <= 1'b0;
      cb_v <= 1'b0;
      lval <= '0;
      cow_used <= '0;
      line_fills <= '0;
      victim <= '0;
    end else begin
      if (m_wtake) bi <= bi + 9'd1;
      case (st)
        S_INIT: if (m_ready) begin clr <= '0; tclr <= '0; st <= S_CLR; end
        // ---- clear the page table (256 bursts of 256 words) and the TLB
        S_CLR: begin
          tlb_we <= 1'b1; tlb_wa <= tclr; tlb_wd <= '0; tclr <= tclr + 8'd1;
          if (!m_req && !m_ack && clr[16:8] != 9'h100) begin
            m_req <= 1'b1; m_we <= 1'b1; m_addr <= {5'd0, clr[15:8], 8'd0}; m_len <= 9'd256;
          end
          if (m_ack) clr <= clr + 17'd256;
          if (clr[16:8] == 9'h100 && !m_req && tclr == 8'hFF) begin
            cb_v <= 1'b0; lval <= '0; cow_used <= '0; st <= S_IDLE;
          end
        end
        S_IDLE: begin
          if (map_reset) begin
            st <= S_INIT;
          end else if (h_req || c_req) begin
            rq_h <= h_req;
            rq_we <= h_req ? h_we : c_we;
            rq_raw <= h_req && h_raw;
            rq_addr <= h_req ? h_addr : c_addr;
            rq_wd <= h_req ? h_wd : c_wd;
            rq_be <= h_req ? h_be : c_be;
            cow_ret <= 1'b0;
            st <= S_TLB;
          end
        end
        S_TLB: begin                          // tlb_q is read now (page settles this cycle)
          if (!rq_we && !rq_raw && cb_hit) begin
            respond(cb[rq_addr[4:2]]);
            st <= S_IDLE;
          end else if (rq_raw) begin
            st <= rq_we ? S_IDLE : S_SDLOOK;  // the card is never written
          end else if (rq_addr[31:29] != 0) begin
            fault <= 1'b1; fault_addr <= rq_addr;
            if (!rq_we) respond(32'd0);
            st <= S_IDLE;
          end else st <= S_TLBCK;
        end
        S_TLBCK: begin
          if (tlb_q[25] && tlb_q[24:16] == page[16:8]) begin
            pte <= tlb_q[15:0];
            st <= S_ROUTE;
          end else begin                      // the page-table word holding the entry
            m_req <= 1'b1; m_we <= 1'b0; m_addr <= {5'd0, page[16:1]}; m_len <= 9'd1;
            st <= S_PT;
          end
        end
        S_PT: if (m_ack) st <= S_PTW;
        S_PTW: if (m_rv) begin
          logic [15:0] e;
          e = page[0] ? m_rd[31:16] : m_rd[15:0];
          pte <= e;
          tlb_we <= 1'b1; tlb_wa <= page[7:0]; tlb_wd <= {1'b1, page[16:8], e};
          st <= S_ROUTE;
        end
        S_ROUTE: begin
          if (pte[15]) begin                  // the page's own copy
            sdr <= COW_BASE + {pte[10:0], rq_addr[11:2]};
            st <= rq_we ? S_WR : S_RD;
          end else if (rq_we) begin
            st <= S_COW;
          end else if (rq_addr >= img_bytes) begin
            respond(32'd0);
            st <= S_IDLE;
          end else begin
            st <= S_SDLOOK;
          end
        end
        // ---- the image: its line in the cache, from the card on a miss
        S_SDLOOK: begin
          if (lhit) begin
            sdr <= LINE_BASE + {lway, rq_addr[15:2]};
            st <= cow_ret ? S_COWRD : S_RD;
          end else if (sd_ready && !sd_busy) begin
            lval[victim] <= 1'b0;
            ltag[victim] <= lkey;
            sd_req <= 1'b1; sd_lba <= fill_lba; sd_n <= 16'd128;
            nblk_in <= '0; nblk_out <= '0; win <= '0;
            line_fills <= line_fills + 32'd1;
            st <= S_FILL;
          end
        end
        S_FILL: begin                         // SD words into bbuf (two halves, ping-pong)
          if (sd_dv) begin
            bb_we <= 1'b1;
            bb_wa <= {nblk_in[0], win[6:0]};
            bb_wd <= sd_dw;
            win <= win + 9'd1;
            if (win[6:0] == 7'd127) nblk_in <= nblk_in + 16'd1;
          end
          if (nblk_out != nblk_in && !m_req) begin
            m_req <= 1'b1; m_we <= 1'b1; m_len <= 9'd128;
            m_addr <= LINE_BASE + {victim, nblk_out[6:0], 7'd0};
            bi <= {1'b0, nblk_out[0], 7'd0};  // its half of bbuf
            wsel <= 1'b1;
            st <= S_FILLW;
          end
          if (nblk_out == 16'd128 && !sd_busy) begin
            lval[victim] <= 1'b1;
            victim <= victim + 1'b1;
            st <= S_SDLOOK;
          end
        end
        S_FILLW: begin                        // a block's burst; SD words keep arriving
          if (sd_dv) begin
            bb_we <= 1'b1;
            bb_wa <= {nblk_in[0], win[6:0]};
            bb_wd <= sd_dw;
            win <= win + 9'd1;
            if (win[6:0] == 7'd127) nblk_in <= nblk_in + 16'd1;
          end
          if (m_wtake && bi[6:0] == 7'd127) begin
            nblk_out <= nblk_out + 16'd1;
            st <= S_FILL;
          end
        end
        // ---- SDRAM: a chunk read into the chunk buffer, or a word write
        S_RD: begin
          m_req <= 1'b1; m_we <= 1'b0; m_len <= 9'd8;
          m_addr <= {sdr[20:3], 3'd0};
          bi <= '0;
          st <= S_RDW;
        end
        S_RDW: if (m_rv) begin
          cb[bi[2:0]] <= m_rd;
          bi <= bi + 9'd1;
          if (bi[2:0] == 3'd7) begin
            cb_v <= !rq_raw;
            cb_tag <= rq_addr[31:5];
            st <= S_RESP;
          end
        end
        S_RESP: begin respond(cb[rq_addr[4:2]]); st <= S_IDLE; end
        S_WR: begin
          if (!m_req) begin
            m_req <= 1'b1; m_we <= 1'b1; m_len <= 9'd1; m_addr <= sdr;
          end
          if (m_ack) begin
            m_req <= 1'b0;
            if (cb_hit) cb_v <= 1'b0;         // (the next read of the chunk reads it again)
            st <= S_IDLE;
          end
        end
        // ---- copy on write: the page's image contents (or zeros) to the next COW page
        S_COW: begin
          if (cow_used == 16'(NCOW)) begin
            fault <= 1'b1; fault_addr <= rq_addr;
            st <= S_IDLE;
          end else begin
            part <= '0;
            st <= ({rq_addr[31:12], 12'd0} >= img_bytes) ? S_ZERO : S_COWRD;
          end
        end
        S_COWRD: begin                        // the quarter's 256 words from the line
          if (!lhit) begin
            st <= S_SDLOOK;                   // fill the line, then back here
            cow_ret <= 1'b1;
          end else begin
            m_req <= 1'b1; m_we <= 1'b0; m_len <= 9'd256;
            m_addr <= LINE_BASE + {lway, rq_addr[15:12], part, 8'd0};
            bi <= '0;
            st <= S_COWRW;
          end
        end
        S_COWRW: if (m_rv) begin
          bb_we <= 1'b1; bb_wa <= bi; bb_wd <= m_rd;
          bi <= bi + 9'd1;
          if (bi == 9'd255) begin
            m_req <= 1'b1; m_we <= 1'b1; m_len <= 9'd256;
            m_addr <= COW_BASE + {11'(cow_used), part, 8'd0};
            bi <= '0;
            wsel <= 1'b1;
            st <= S_COWWR;
          end
        end
        S_ZERO: begin                         // past the image: a zero page
          m_req <= 1'b1; m_we <= 1'b1; m_len <= 9'd256;
          m_addr <= COW_BASE + {11'(cow_used), part, 8'd0};
          bi <= '0;
          wsel <= 1'b0;
          st <= S_COWWR;
        end
        S_COWWR: if (m_wtake && bi[7:0] == 8'd255) begin
          if (part == 2'd3) begin
            m_req <= 1'b1; m_we <= 1'b1; m_len <= 9'd1;
            m_addr <= {5'd0, page[16:1]};
            st <= S_COWPT;
          end else begin
            part <= part + 2'd1;
            st <= wsel ? S_COWRD : S_ZERO;
          end
        end
        S_COWPT: if (m_wtake) begin           // the page-table entry, then the TLB, then the write
          tlb_we <= 1'b1; tlb_wa <= page[7:0];
          tlb_wd <= {1'b1, page[16:8], 1'b1, 4'd0, 11'(cow_used)};
          pte <= {1'b1, 4'd0, 11'(cow_used)};
          cow_used <= cow_used + 16'd1;
          if (cb_v && cb_tag[26:7] == rq_addr[31:12]) cb_v <= 1'b0;
          st <= S_ROUTE;
        end
        default: st <= S_IDLE;
      endcase
    end
  end
endmodule
