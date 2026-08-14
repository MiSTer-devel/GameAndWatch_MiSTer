// Dedicated fixed video transport clock. Use an integer Cyclone V PLL ratio
// instead of Quartus' fractional frequency fitter: 50 MHz * 108 / 5 / 20 is
// exactly 54 MHz, with a legal 1080 MHz VCO.
module video_pll_54 (
    input  wire refclk_50,
    input  wire reset,
    output wire clk_video_54,
    output wire locked
);
  wire [0:0] outclk;

  altera_pll #(
      .fractional_vco_multiplier("false"),
      .reference_clock_frequency("50.000000 MHz"),
      .operation_mode("direct"),
      .number_of_clocks(1),
      .output_clock_frequency0("54.000000 MHz"),
      .phase_shift0("0 ps"),
      .duty_cycle0(50),
      .m_cnt_hi_div(54),
      .m_cnt_lo_div(54),
      .n_cnt_hi_div(3),
      .n_cnt_lo_div(2),
      .n_cnt_odd_div_duty_en("true"),
      .c_cnt_hi_div0(10),
      .c_cnt_lo_div0(10),
      .pll_type("General"),
      .pll_subtype("General")
  ) video_pll_inst (
      .rst(reset),
      .outclk(outclk),
      .locked(locked),
      .fboutclk(),
      .fbclk(1'b0),
      .refclk(refclk_50)
  );

  assign clk_video_54 = outclk[0];
endmodule
