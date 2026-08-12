import types::*;

module gameandwatch (
    input wire clk_sys_99_287,
    input wire clk_vid_33_095,

    input wire reset,
    input wire pll_core_locked,

    // Inputs
    input wire button_a,
    input wire button_b,
    input wire button_x,
    input wire button_y,
    input wire button_trig_l,
    input wire button_trig_r,
    input wire button_start,
    input wire button_select,
    input wire dpad_up,
    input wire dpad_down,
    input wire dpad_left,
    input wire dpad_right,

    // Data in
    input wire        ioctl_download,
    input wire        ioctl_wr,
    input wire [24:0] ioctl_addr,
    input wire [15:0] ioctl_dout,

    // Video
    output wire hsync,
    output wire vsync,
    output wire hblank,
    output wire vblank,

    output wire de,
    output wire ce_pix,
    output wire [23:0] rgb,

    // Sound
    output wire sound,

    // Settings
    input wire accurate_lcd_timing, // Use precise timing to update the cached LCD segments based on H timing. This doesn't look good, hence the setting
    input wire [7:0] lcd_off_alpha, // The alpha value of all disabled/off LCD segments. This allows the LCD to stay visible at all times
    input wire crt_video,

    // Debug
    input wire debug_video,
    input wire [1:0] debug_view,
    input wire debug_freeze,
    input wire debug_clear,

    // SDRAM
    inout  wire [15:0] SDRAM_DQ,
    output wire [12:0] SDRAM_A,
    output wire [ 1:0] SDRAM_DQM,
    output wire [ 1:0] SDRAM_BA,
    output wire        SDRAM_nCS,
    output wire        SDRAM_nWE,
    output wire        SDRAM_nRAS,
    output wire        SDRAM_nCAS,
    output wire        SDRAM_CKE,
    output wire        SDRAM_CLK
);
  ////////////////////////////////////////////////////////////////////////////////////////
  // Loading and config

  system_config sys_config;

  wire [24:0] base_addr;
  wire image_download;
  wire mask_config_download;
  wire rom_download;

  wire wr_8bit;
  wire [25:0] addr_8bit;
  wire [7:0] data_8bit;

  wire [3:0] cpu_id = sys_config.mpu[3:0];

  rom_loader rom_loader (
      .clk(clk_sys_99_287),

      .ioctl_download(ioctl_download),
      .ioctl_wr(ioctl_wr),
      .ioctl_addr(ioctl_addr),
      .ioctl_dout(ioctl_dout),

      .sys_config(sys_config),

      // Data signals
      .base_addr(base_addr),
      .image_download(image_download),
      .mask_config_download(mask_config_download),
      .rom_download(rom_download),

      // 8 bit bus
      .wr_8bit  (wr_8bit),
      .addr_8bit(addr_8bit),
      .data_8bit(data_8bit)
  );

  ////////////////////////////////////////////////////////////////////////////////////////
  // ROM

  wire [11:0] rom_addr;
  wire        rom_rd_en;
  reg [7:0] rom_data = 0;
  wire [7:0] melody_addr;
  reg [7:0] melody_data = 0;

  reg [7:0] rom[4096];
  reg [7:0] melody_rom[256];

  always @(posedge clk_sys_99_287) begin
    if (rom_rd_en) begin
      rom_data <= rom[rom_addr];
    end

    if (clk_en) begin
      melody_data <= melody_rom[melody_addr];
    end
  end

  wire [25:0] rom_byte_addr = {addr_8bit[25:1], ~addr_8bit[0]};

  always @(posedge clk_sys_99_287) begin
    if (wr_8bit && rom_download) begin
	      // ioctl_dout has flipped bytes, flip back by modifying address. Melody-capable
      // packages append the 0x100-byte melody ROM at byte offset 0x1000.
      if (rom_byte_addr < 26'h001000) begin
        rom[rom_byte_addr[11:0]] <= data_8bit;
      end else if (rom_byte_addr >= 26'h001000 && rom_byte_addr < 26'h001100) begin
        melody_rom[rom_byte_addr[7:0]] <= data_8bit;
      end
    end
  end

  ////////////////////////////////////////////////////////////////////////////////////////
  // Input

  wire [7:0] output_shifter_s;
  wire [3:0] output_r;

  wire [7:0] input_k;
  wire input_wake;

  wire input_beta;
  wire input_ba;

  // TODO: Unused
  wire input_acl;

  input_config input_config (
      .clk(clk_sys_99_287),

      .sys_config(sys_config),

      .cpu_id(cpu_id),

      // Input selection
      .output_shifter_s(output_shifter_s),
      .output_r(output_r),

      // Input
      .button_a(button_a),
      .button_b(button_b),
      .button_x(button_x),
      .button_y(button_y),
      .button_trig_l(button_trig_l),
      .button_trig_r(button_trig_r),
      .button_start(button_start),
      .button_select(button_select),
      .dpad_up(dpad_up),
      .dpad_down(dpad_down),
      .dpad_left(dpad_left),
      .dpad_right(dpad_right),

      // MPU Input
      .input_k(input_k),
      .input_wake(input_wake),

      .input_beta(input_beta),
      .input_ba  (input_ba),
      .input_acl (input_acl)
  );

  ////////////////////////////////////////////////////////////////////////////////////////
  // Device/CPU

  // 98.304MHz / 3000 = the SM5xx 32.768kHz base clock.
  localparam [11:0] DIVIDER_RESET_VALUE = 12'd3000 - 12'd1;
  reg [11:0] clock_divider = DIVIDER_RESET_VALUE;

  wire clk_en = clock_divider == 0;

  always @(posedge clk_sys_99_287) begin
    clock_divider <= clock_divider - 12'h001;

    if (clock_divider == 0) begin
      clock_divider <= DIVIDER_RESET_VALUE;
    end
  end

  wire [1:0] output_lcd_h_index;

  wire [15:0] current_segment_a;
  wire [15:0] current_segment_b;
  wire [15:0] current_segment_c;
  wire [15:0] current_segment_bs;

  wire [3:0] current_w_prime[16];
  wire [3:0] current_w_main[16];

  wire divider_1khz;

  wire [63:0] cpu_debug_events;
  wire [63:0] debug_cpu_state;
  wire [63:0] debug_melody_state;

  sm510 sm510 (
      .clk(clk_sys_99_287),

      .clk_en(clk_en),

      .reset(reset),

      .cpu_id(cpu_id),

      .rom_data(rom_data),
      .rom_addr(rom_addr),
      .rom_rd_en(rom_rd_en),

      .melody_data(melody_data),
      .melody_addr(melody_addr),

      .input_k(input_k),
      .input_wake(input_wake),

      .input_ba  (input_ba),
      .input_beta(input_beta),

      .output_lcd_h_index(output_lcd_h_index),

      .output_shifter_s(output_shifter_s),

      .segment_a (current_segment_a),
      .segment_b (current_segment_b),
      .segment_c (current_segment_c),
      .segment_bs(current_segment_bs),

      .w_prime(current_w_prime),
      .w_main (current_w_main),

      .output_r(output_r),

      // Settings
      .accurate_lcd_timing(accurate_lcd_timing),

      // Utility
      .divider_1khz(divider_1khz),

      // Debug
      .debug_events(cpu_debug_events),
      .debug_cpu_state(debug_cpu_state),
      .debug_melody_state(debug_melody_state)
  );

  assign sound = output_r[0];

  ////////////////////////////////////////////////////////////////////////////////////////
  // Debug

  reg [15:0] debug_core_seen = 16'd0;
  reg [ 7:0] debug_last_melody_addr = 8'd0;
  reg [ 3:0] debug_last_output_r = 4'd0;

  always @(posedge clk_sys_99_287) begin
    if (debug_clear) begin
      debug_core_seen <= 16'd0;
      debug_last_melody_addr <= 8'd0;
      debug_last_output_r <= 4'd0;
    end else begin
      debug_last_melody_addr <= melody_addr;
      debug_last_output_r <= output_r;

      debug_core_seen[0]  <= debug_core_seen[0]  | 1'b1;
      debug_core_seen[1]  <= debug_core_seen[1]  | ioctl_download;
      debug_core_seen[2]  <= debug_core_seen[2]  | wr_8bit;
      debug_core_seen[3]  <= debug_core_seen[3]  | (ioctl_wr && image_download);
      debug_core_seen[4]  <= debug_core_seen[4]  | (ioctl_wr && mask_config_download);
      debug_core_seen[5]  <= debug_core_seen[5]  | (wr_8bit && rom_download);
      debug_core_seen[6]  <= debug_core_seen[6]  | (wr_8bit && rom_download && rom_byte_addr < 26'h001000);
      debug_core_seen[7]  <= debug_core_seen[7]  | (wr_8bit && rom_download && rom_byte_addr >= 26'h001000 && rom_byte_addr < 26'h001100);
      debug_core_seen[8]  <= debug_core_seen[8]  | (cpu_id == 4'd1);
      debug_core_seen[9]  <= debug_core_seen[9]  | (cpu_id == 4'd2);
	      debug_core_seen[10] <= debug_core_seen[10] | (cpu_id == 4'd3);
	      debug_core_seen[11] <= debug_core_seen[11] | (cpu_id == 4'd6 || cpu_id == 4'd7);
      debug_core_seen[12] <= debug_core_seen[12] | (rom_data != 8'd0);
      debug_core_seen[13] <= debug_core_seen[13] | (melody_data != 8'd0);
      debug_core_seen[14] <= debug_core_seen[14] | (melody_addr != debug_last_melody_addr);
      debug_core_seen[15] <= debug_core_seen[15] | (output_r[0] != debug_last_output_r[0]);
    end
  end

  wire [7:0] debug_core_row0 = {cpu_id, input_k[3:0]};
  wire [7:0] debug_core_row1 = cpu_id == 4'd3 ? input_k : output_shifter_s;
  wire [7:0] debug_core_row2 = {output_r, input_ba, input_beta, image_download, rom_download};
  wire [7:0] debug_core_row3 = cpu_id == 4'd3 ? {current_w_prime[0], current_w_main[0]} :
      rom_addr[11:4];
  wire [7:0] debug_core_row4 = cpu_id == 4'd3 ? {current_w_prime[1], current_w_main[1]} :
      {rom_addr[3:0], rom_data[7:4]};
  wire [7:0] debug_core_row5 = cpu_id == 4'd3 ? {current_w_prime[2], current_w_main[2]} :
      {rom_data[3:0], melody_addr[7:4]};
  wire [7:0] debug_core_row6 = cpu_id == 4'd3 ? {current_w_prime[3], current_w_main[3]} :
      {melody_addr[3:0], melody_data[7:4]};
  wire [7:0] debug_core_row7 = cpu_id == 4'd3 ? {current_w_prime[11], current_w_main[11]} :
      {melody_data[3:0], current_segment_a[3:0]};

  wire [63:0] debug_events = {cpu_debug_events[47:0], debug_core_seen};
  wire [63:0] debug_core_state = {debug_core_row7, debug_core_row6, debug_core_row5, debug_core_row4, debug_core_row3, debug_core_row2, debug_core_row1, debug_core_row0};

  reg [63:0] debug_events_frozen = 64'd0;
  reg [63:0] debug_cpu_state_frozen = 64'd0;
  reg [63:0] debug_melody_state_frozen = 64'd0;
  reg [63:0] debug_core_state_frozen = 64'd0;

  always @(posedge clk_sys_99_287) begin
    if (!debug_freeze) begin
      debug_events_frozen <= debug_events;
      debug_cpu_state_frozen <= debug_cpu_state;
      debug_melody_state_frozen <= debug_melody_state;
      debug_core_state_frozen <= debug_core_state;
    end
  end

  wire [63:0] video_debug_events = debug_freeze ? debug_events_frozen : debug_events;
  wire [63:0] video_debug_cpu_state = debug_freeze ? debug_cpu_state_frozen : debug_cpu_state;
  wire [63:0] video_debug_melody_state = debug_freeze ? debug_melody_state_frozen : debug_melody_state;
  wire [63:0] video_debug_core_state = debug_freeze ? debug_core_state_frozen : debug_core_state;

  ////////////////////////////////////////////////////////////////////////////////////////
  // Video

  wire        sd_data_available;
  wire [15:0] sd_out;
  wire        sd_end_burst;
  wire        sd_rd;
  wire [24:0] sd_rd_addr;

  video video (
      .clk_sys_99_287(clk_sys_99_287),
      .clk_vid_33_095(clk_vid_33_095),

      .reset(reset || ioctl_download),

      .cpu_id(cpu_id),
      .crt_video(crt_video),

      .mask_data_wr(mask_config_download && ioctl_wr),
      .mask_data(ioctl_dout),

      .divider_1khz(divider_1khz),

      // Segments
      .current_segment_a (current_segment_a),
      .current_segment_b (current_segment_b),
      .current_segment_c (current_segment_c),
      .current_segment_bs(current_segment_bs),

      .current_w_prime(current_w_prime),
      .current_w_main (current_w_main),

      .output_lcd_h_index(output_lcd_h_index),

      // Settings
      .lcd_off_alpha(lcd_off_alpha),

      // Debug
      .debug_video(debug_video),
      .debug_view(debug_view),
      .debug_events(video_debug_events),
      .debug_cpu_state(video_debug_cpu_state),
      .debug_melody_state(video_debug_melody_state),
      .debug_core_state(video_debug_core_state),

      // Video
      .hsync (hsync),
      .vsync (vsync),
      .hblank(hblank),
      .vblank(vblank),

      .de (de),
      .ce_pix(ce_pix),
      .rgb(rgb),

      // SDRAM
      .sd_data_available(sd_data_available),
      .sd_out(sd_out),
      .sd_end_burst(sd_end_burst),
      .sd_rd(sd_rd),
      .sd_rd_addr(sd_rd_addr)
  );

  ////////////////////////////////////////////////////////////////////////////////////////
  // SDRAM

  wire sdram_wr = ioctl_wr && image_download;

  sdram_burst #(
      .CLOCK_SPEED_MHZ(98.304),
      .CAS_LATENCY(2)
  ) sdram (
      .clk  (clk_sys_99_287),
      .reset(~pll_core_locked),

      // Port 0
      .p0_addr(sdram_wr ? base_addr : sd_rd_addr),
      .p0_data(ioctl_dout),
      .p0_byte_en(2'b11),
      .p0_q(sd_out),

      .p0_wr_req(sdram_wr),
      .p0_rd_req(sd_rd),
      .p0_end_burst_req(sd_end_burst),

      .p0_data_available(sd_data_available),

      .SDRAM_DQ(SDRAM_DQ),
      .SDRAM_A(SDRAM_A),
      .SDRAM_DQM(SDRAM_DQM),
      .SDRAM_BA(SDRAM_BA),
      .SDRAM_nCS(SDRAM_nCS),
      .SDRAM_nWE(SDRAM_nWE),
      .SDRAM_nRAS(SDRAM_nRAS),
      .SDRAM_nCAS(SDRAM_nCAS),
      .SDRAM_CLK(SDRAM_CLK),
      .SDRAM_CKE(SDRAM_CKE)
  );

endmodule
