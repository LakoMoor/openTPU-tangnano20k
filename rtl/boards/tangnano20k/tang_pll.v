// 27 MHz -> 48 MHz core clock (UART 2 Mbaud = 24 clocks a bit, SD 24 MHz), plus the same clock
// shifted by 180 degrees for the embedded SDRAM (gowin_pll; the phase as the board's GB port).
module tang_pll (
    input  clock_in,
    output clk,
    output clk_p,
    output locked
);
    rPLL #(
        .FCLKIN("27.0"),
        .IDIV_SEL(8),        // PFD = 3 MHz
        .FBDIV_SEL(15),      // CLKOUT = 48 MHz
        .ODIV_SEL(16),       // VCO = 768 MHz
        .PSDA_SEL("1000"),   // CLKOUTP = 180 deg
        .DUTYDA_SEL("1000"),
        .DEVICE("GW2A-18C")
    ) pll (.CLKOUTD(), .CLKOUTD3(), .RESET(1'b0), .RESET_P(1'b0), .CLKFB(1'b0), .FBDSEL(6'b0),
           .IDSEL(6'b0), .ODSEL(6'b0), .PSDA(4'b0), .DUTYDA(4'b0), .FDLY(4'b0),
           .CLKIN(clock_in), .CLKOUT(clk), .CLKOUTP(clk_p), .LOCK(locked));
endmodule
