// Behavioural model of the GW2AR's embedded SDRAM (2M x 32, CAS latency 2, burst length 1):
// commands sampled on the chip clock (the controller clock shifted 180 degrees), read data driven
// one chip clock after the READ's sampling edge and held for a clock (CL 2).
module sdram_model (
  input  logic        clk_p,
  input  logic        cke, cs_n, ras_n, cas_n, we_n,
  input  logic [3:0]  dqm,
  input  logic [10:0] addr,
  input  logic [1:0]  ba,
  inout  wire  [31:0] dq
);
  logic [31:0] mem [2097152];
  logic [10:0] row [4];
  logic        rd1, rd2;
  logic [20:0] ra1;
  logic [31:0] dqo;
  logic        drv;
  assign dq = drv ? dqo : 32'bz;
  always @(posedge clk_p) begin
    drv <= 1'b0;
    if (rd1) begin dqo <= mem[ra1]; drv <= 1'b1; end
    rd1 <= 1'b0;
    if (cke && !cs_n) begin
      case ({ras_n, cas_n, we_n})
        3'b011: row[ba] <= addr;                                          // ACTIVE
        3'b101: begin rd1 <= 1'b1; ra1 <= {ba, row[ba], addr[7:0]}; end  // READ
        3'b100: for (int b = 0; b < 4; b++)                                // WRITE
                  if (!dqm[b]) mem[{ba, row[ba], addr[7:0]}][8 * b +: 8] <= dq[8 * b +: 8];
        default: ;
      endcase
    end
  end
endmodule
