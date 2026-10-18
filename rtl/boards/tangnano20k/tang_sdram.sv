// The GW2AR-18's embedded SDRAM (64 Mbit: 2M x 32, 4 banks x 2048 rows x 256 columns), the
// Tang Nano 20K's only DRAM. The chip clock is the controller clock shifted by 180 degrees
// (clk_sdram_p), so a command launched on a rising edge is sampled half a cycle later (as in
// the board's proven Game Boy port, tangnano20k_gbc_native/rtl/sys/sdram_ctrl.sv).
//
// One request is a run of len words (1..256) inside one row: ACTIVE, then a READ or WRITE per
// cycle (burst length 1, CAS latency 2; the last with auto-precharge). Writes take their data
// from the client the cycle wtake is high (wd / wbe: the run's current word, the client
// advances on wtake); reads return rv / rd in order, RD_CAPTURE cycles after each READ.
// Refresh runs between requests every REFRESH cycles.
module tang_sdram #(
  parameter int RD_CAPTURE = 2,         // cycles from a READ to its data (CL 2 + the clock shift)
  parameter int INIT_WAIT  = 10000,     // > 200 us
  parameter int REFRESH    = 380        // < 7.8 us
) (
  input  logic        clk,
  input  logic        rst,
  output logic        ready,
  input  logic        req,
  input  logic        we,
  input  logic [20:0] addr,             // word address: bank [20:19], row [18:8], column [7:0]
  input  logic [8:0]  len,              // 1..256, column + len <= 256
  output logic        ack,              // the request is taken
  output logic        wtake,            // the current write word is taken
  input  logic [31:0] wd,
  input  logic [3:0]  wbe,
  output logic        rv,
  output logic [31:0] rd,
  // SDRAM pins
  output logic        O_sdram_clk,
  output logic        O_sdram_cke,
  output logic        O_sdram_cs_n,
  output logic        O_sdram_ras_n,
  output logic        O_sdram_cas_n,
  output logic        O_sdram_wen_n,
  output logic [3:0]  O_sdram_dqm,
  output logic [10:0] O_sdram_addr,
  output logic [1:0]  O_sdram_ba,
  inout  wire  [31:0] IO_sdram_dq,
  input  logic        clk_sdram_p
);
  localparam logic [2:0] C_NOP = 3'b111, C_ACT = 3'b011, C_RD = 3'b101, C_WR = 3'b100,
                         C_PRE = 3'b010, C_REF = 3'b001, C_MRS = 3'b000;
  // CAS latency 2, burst length 1, sequential, burst write off (single location writes)
  localparam logic [10:0] MODE = 11'b000_0_00_010_0_000;

  assign O_sdram_clk = clk_sdram_p;
  logic [31:0] dq_out;
  logic        dq_oe;
  assign IO_sdram_dq = dq_oe ? dq_out : 32'bz;

  typedef enum logic [2:0] { S_INIT, S_IDLE, S_ACT, S_RUN, S_WAIT, S_REF } st_t;
  st_t st;
  logic [15:0] icnt;
  logic [9:0]  rcnt;
  logic        rpend;
  logic [2:0]  cmd;
  logic [8:0]  left;
  logic [7:0]  col;
  logic        rwe;
  logic [3:0]  wcnt;
  logic [RD_CAPTURE:0] cap;

  assign {O_sdram_ras_n, O_sdram_cas_n, O_sdram_wen_n} = cmd;
  assign wtake = (st == S_RUN) && rwe;

  always_ff @(posedge clk) begin
    ack <= 1'b0;
    cmd <= C_NOP;
    dq_oe <= 1'b0;
    O_sdram_dqm <= 4'h0;
    cap <= {cap[RD_CAPTURE-1:0], 1'b0};
    if (rcnt == 10'(REFRESH - 1)) begin rcnt <= '0; rpend <= 1'b1; end
    else rcnt <= rcnt + 10'd1;
    if (rst) begin
      st <= S_INIT;
      icnt <= '0;
      ready <= 1'b0;
      O_sdram_cke <= 1'b0;
      O_sdram_cs_n <= 1'b1;
      O_sdram_dqm <= 4'hF;
      O_sdram_addr <= '0;
      O_sdram_ba <= '0;
      rpend <= 1'b0;
      rcnt <= '0;
      cap <= '0;
    end else begin
      case (st)
        S_INIT: begin
          icnt <= icnt + 16'd1;
          O_sdram_cke <= 1'b1;
          O_sdram_cs_n <= 1'b0;
          O_sdram_dqm <= 4'hF;
          case (icnt)
            16'(INIT_WAIT):      begin cmd <= C_PRE; O_sdram_addr <= 11'b100_0000_0000; end
            16'(INIT_WAIT + 4), 16'(INIT_WAIT + 12), 16'(INIT_WAIT + 20), 16'(INIT_WAIT + 28),
            16'(INIT_WAIT + 36), 16'(INIT_WAIT + 44), 16'(INIT_WAIT + 52), 16'(INIT_WAIT + 60):
              cmd <= C_REF;
            16'(INIT_WAIT + 68): begin cmd <= C_MRS; O_sdram_addr <= MODE; O_sdram_ba <= '0; end
            16'(INIT_WAIT + 72): begin st <= S_IDLE; ready <= 1'b1; end
            default: ;
          endcase
        end
        S_IDLE: begin
          if (rpend) begin
            rpend <= 1'b0;
            cmd <= C_REF;
            wcnt <= 4'd7;                    // tRFC
            st <= S_REF;
          end else if (req) begin
            ack <= 1'b1;
            cmd <= C_ACT;
            O_sdram_ba <= addr[20:19];
            O_sdram_addr <= addr[18:8];
            col <= addr[7:0];
            left <= len;
            rwe <= we;
            st <= S_ACT;                     // tRCD: one NOP cycle
          end
        end
        S_ACT: st <= S_RUN;
        S_RUN: begin                          // a column command per cycle
          cmd <= rwe ? C_WR : C_RD;
          O_sdram_addr <= {(left == 9'd1), 2'b00, col};   // A10: auto-precharge on the last
          if (rwe) begin
            dq_out <= wd;
            dq_oe <= 1'b1;
            O_sdram_dqm <= ~wbe;
          end else begin
            cap[0] <= 1'b1;
          end
          col <= col + 8'd1;
          left <= left - 9'd1;
          if (left == 9'd1) begin
            wcnt <= rwe ? 4'd4 : 4'd3;        // tWR + tRP / tRP before the next ACTIVE
            st <= S_WAIT;
          end
        end
        S_WAIT, S_REF: begin
          if (wcnt == 0) st <= S_IDLE;
          else wcnt <= wcnt - 4'd1;
        end
        default: st <= S_INIT;
      endcase
    end
  end

  always_ff @(posedge clk) begin
    rv <= cap[RD_CAPTURE - 1];          // the data of the READ issued RD_CAPTURE edges ago
    rd <= IO_sdram_dq;
  end
endmodule
