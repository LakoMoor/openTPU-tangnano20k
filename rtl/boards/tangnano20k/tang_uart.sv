// 8N1 UART, DIV clocks per bit (50 MHz / 25 = 2 Mbaud), for the BL616 USB bridge.
module tang_uart_rx #(parameter int DIV = 25) (
  input  logic       clk,
  input  logic       rst,
  input  logic       rx,
  output logic       v,
  output logic [7:0] d
);
  logic [2:0] sync;
  logic [15:0] cnt;
  logic [3:0] bitn;
  logic       busy;
  logic [7:0] sh;
  always_ff @(posedge clk) begin
    sync <= {sync[1:0], rx};
    v <= 1'b0;
    if (rst) begin
      busy <= 1'b0; sync <= 3'b111;
    end else if (!busy) begin
      if (!sync[2]) begin busy <= 1'b1; cnt <= 16'(DIV / 2); bitn <= '0; end
    end else if (cnt == 0) begin
      cnt <= 16'(DIV - 1);
      bitn <= bitn + 4'd1;
      if (bitn == 0) begin
        if (sync[2]) busy <= 1'b0;            // a glitch, not a start bit
      end else if (bitn <= 4'd8) begin
        sh <= {sync[2], sh[7:1]};
      end else begin                          // the stop bit
        busy <= 1'b0;
        if (sync[2]) begin v <= 1'b1; d <= sh; end
      end
    end else cnt <= cnt - 16'd1;
  end
endmodule

module tang_uart_tx #(parameter int DIV = 25) (
  input  logic       clk,
  input  logic       rst,
  input  logic       v,                     // send d (when rdy)
  input  logic [7:0] d,
  output logic       rdy,
  output logic       tx
);
  logic [15:0] cnt;
  logic [3:0]  bitn;
  logic [9:0]  sh;
  assign rdy = (bitn == 0);
  always_ff @(posedge clk) begin
    if (rst) begin
      tx <= 1'b1; bitn <= '0;
    end else if (bitn == 0) begin
      if (v) begin sh <= {1'b1, d, 1'b0}; bitn <= 4'd11; cnt <= '0; end   // start, 8 data, a full stop bit
    end else if (cnt == 0) begin
      tx <= sh[0];
      sh <= {1'b1, sh[9:1]};
      cnt <= 16'(DIV - 1);
      bitn <= bitn - 4'd1;
    end else cnt <= cnt - 16'd1;
  end
endmodule
