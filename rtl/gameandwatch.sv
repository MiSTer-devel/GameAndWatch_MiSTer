import types::*;

module gameandwatch (
    input wire clk_sys_99_287,
    input wire clk_vid_33_095,

    input wire reset,
    input wire video_blank,
    input wire pll_core_locked,

    // Inputs
    input wire button_a,
    input wire button_b,
    input wire button_x,
    input wire button_y,
    input wire [5:0] button_aux,
    input wire osd_status,
    input wire dpad_up,
    input wire dpad_down,
    input wire dpad_left,
    input wire dpad_right,

    input wire player_two_button_a,
    input wire player_two_button_b,
    input wire player_two_button_x,
    input wire player_two_button_y,
    input wire [5:0] player_two_button_aux,
    input wire player_two_dpad_up,
    input wire player_two_dpad_down,
    input wire player_two_dpad_left,
    input wire player_two_dpad_right,

    // Data in
    input wire        ioctl_download,
    input wire        ioctl_wr,
    input wire [24:0] ioctl_addr,
    input wire [15:0] ioctl_dout,
    output wire ioctl_wait,

    // Video
    output wire hsync,
    output wire vsync,
    output wire hblank,
    output wire vblank,

    output wire de,
    output wire ce_pix,
    output wire [23:0] rgb,
    output wire source_packet_wr,
    output wire [29:0] source_packet,
    output wire video_held,

    // Sound
    output wire signed [15:0] audio,

    // Settings
    input wire accurate_lcd_timing, // Use precise timing to update the cached LCD segments based on H timing. This doesn't look good, hence the setting
    input wire [7:0] lcd_off_alpha, // The alpha value of all disabled/off LCD segments. This allows the LCD to stay visible at all times
    input wire crt_video,
    input wire hold_video,
    input wire crt_source_tick_async,

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

  wire [25:0] base_addr;
  wire image_download;
  wire mask_config_download;
  wire rom_download;
  wire rom_8bit_download;
  wire crt_image_download;
  wire crt_mask_download;
  wire sdram_p0_available;
  reg image_write_pending = 1'b0;
  reg [24:0] image_write_addr = 25'd0;
  reg [15:0] image_write_data = 16'd0;

  // hps_io observes this combinationally before issuing its next WIDE word.
  // Keep it stalled while the registered image-write slot is occupied or the
  // controller is busy. This breaks the live HPS-address -> SDRAM-pin path
  // without allowing the next package word to overwrite the pending request.
  assign ioctl_wait = ioctl_download &&
      (image_write_pending || !sdram_p0_available);

  wire wr_8bit;
  wire [25:0] addr_8bit;
  wire [7:0] data_8bit;

  wire [3:0] cpu_id = sys_config.mpu[3:0];
  wire crt_assets_valid = sys_config.format_version >= 8'd2 &&
      (sys_config.feature_flags & 8'h98) == 8'h98 &&
      sys_config.extension_directory_valid &&
      sys_config.crt_image_descriptor_valid &&
      sys_config.crt_mask_descriptor_valid &&
      sys_config.crt_image_payload_valid &&
      sys_config.crt_mask_payload_valid;

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
      .rom_8bit_download(rom_8bit_download),
      .crt_image_download(crt_image_download),
      .crt_mask_download(crt_mask_download),

      // 8 bit bus
      .wr_8bit  (wr_8bit),
      .addr_8bit(addr_8bit),
      .data_8bit(data_8bit)
  );

  ////////////////////////////////////////////////////////////////////////////////////////
  // ROM

  // The SM5xx base enable retains the established /3000 divider. Quartus 17
  // realizes the requested 98.304MHz PLL as 98.3203125MHz, so this pre-existing
  // CPU cadence is approximately 32.7734kHz. Declare it before the ROM read
  // process that consumes it (strict SystemVerilog tools reject a forward
  // reference here).
  localparam [11:0] DIVIDER_RESET_VALUE = 12'd3000 - 12'd1;
  reg [11:0] clock_divider = DIVIDER_RESET_VALUE;
  wire clk_en = clock_divider == 0;

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
    if (wr_8bit && rom_8bit_download) begin
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

  wire input_beta_controls;
  wire input_ba;

  wire voice_feature = sys_config.format_version >= 8'd2 && sys_config.feature_flags[0];
  wire voice_bank_valid;
  wire voice_busy;
  wire signed [15:0] voice_sample;
  wire [4:0] voice_current_command;
  wire [15:0] voice_nibbles_remaining;
  wire [15:0] voice_sample_address;
  wire voice_load_clear = ioctl_download && (addr_8bit < 26'h000002);
  wire voice_wr = wr_8bit && rom_8bit_download &&
      rom_byte_addr >= 26'h001100 && rom_byte_addr < 26'h011100;
  wire [15:0] voice_wr_addr = rom_byte_addr[15:0] - 16'h1100;

  msm6373_sample msm6373_sample (
      .clk(clk_sys_99_287),
      .reset(reset),
      .load_clear(voice_load_clear),
      .voice_wr(voice_wr),
      .voice_addr(voice_wr_addr),
      .voice_data(data_8bit),
      .voice_enable(voice_feature),
      .s_out(output_shifter_s),
      .bank_valid(voice_bank_valid),
      .busy(voice_busy),
      .sample(voice_sample),
      .current_command(voice_current_command),
      .nibbles_remaining(voice_nibbles_remaining),
      .sample_address(voice_sample_address)
  );

  wire hmc_feature = sys_config.format_version >= 8'd2 &&
      sys_config.feature_flags[1] && sys_config.feature_flags[7] &&
      sys_config.extension_directory_valid && sys_config.hmc_descriptor_valid;
  wire hmc_wr = wr_8bit && rom_8bit_download &&
      rom_byte_addr >= 26'h0111c0 && rom_byte_addr < 26'h011240;
  wire [6:0] hmc_wr_addr = rom_byte_addr - 26'h0111c0;
  wire hmc_rom_valid;
  wire hmc_busy;
  wire hmc_out;
  wire signed [15:0] hmc_sample;
  wire hmc_osc_ce;
  wire [1:0] hmc_trigger;
  wire [6:0] hmc_address;
  wire [7:0] hmc_command;
  wire [11:0] hmc_dwell_remaining;
  wire [8:0] hmc_startup_remaining;
  wire [6:0] hmc_divider_state;
  wire [8:0] hmc_noise_state;

  hmc_ha1152 hmc_ha1152 (
      .clk(clk_sys_99_287),
      .reset(reset),
      .load_clear(voice_load_clear),
      .rom_wr(hmc_wr),
      .rom_addr(hmc_wr_addr),
      .rom_data(data_8bit),
      .enable(hmc_feature),
      .s_out(output_shifter_s[3:1]),
      .rom_valid(hmc_rom_valid),
      .busy(hmc_busy),
      .hmc_out(hmc_out),
      .sample(hmc_sample),
      .osc_ce(hmc_osc_ce),
      .latched_trigger(hmc_trigger),
      .current_address(hmc_address),
      .current_command(hmc_command),
      .dwell_remaining(hmc_dwell_remaining),
      .startup_remaining(hmc_startup_remaining),
      .divider_state(hmc_divider_state),
      .noise_state(hmc_noise_state)
  );

  wire input_beta = voice_feature && voice_bank_valid ? ~voice_busy : input_beta_controls;

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
      .button_aux(button_aux),
      .osd_status(osd_status),
      .dpad_up(dpad_up),
      .dpad_down(dpad_down),
      .dpad_left(dpad_left),
      .dpad_right(dpad_right),
      .player_two_button_a(player_two_button_a),
      .player_two_button_b(player_two_button_b),
      .player_two_button_x(player_two_button_x),
      .player_two_button_y(player_two_button_y),
      .player_two_button_aux(player_two_button_aux),
      .player_two_dpad_up(player_two_dpad_up),
      .player_two_dpad_down(player_two_dpad_down),
      .player_two_dpad_left(player_two_dpad_left),
      .player_two_dpad_right(player_two_dpad_right),

      // MPU Input
      .input_k(input_k),
      .input_wake(input_wake),

      .input_beta(input_beta_controls),
      .input_ba  (input_ba),
      .input_acl (input_acl)
  );

  ////////////////////////////////////////////////////////////////////////////////////////
  // Device/CPU

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
      .acl(input_acl),

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

  localparam signed [15:0] PIEZO_LEVEL = 16'sh2000;
  reg signed [15:0] piezo_sample;
  reg signed [17:0] audio_sum;
  reg signed [15:0] mixed_audio;

  always_comb begin
    case (cpu_id)
      4'd7: begin
        // Tiger SM511 boards use R1 through 120K and S1 through 39K.
        // Preserve MAME's four evenly spaced output levels around zero.
        case ({output_shifter_s[0], output_r[0]})
          2'b00: piezo_sample = -16'sh2000;
          2'b01: piezo_sample = -16'sh0aab;
          2'b10: piezo_sample =  16'sh0aab;
          default: piezo_sample = 16'sh2000;
        endcase
      end
      default: piezo_sample = output_r[0] ? PIEZO_LEVEL : -PIEZO_LEVEL;
    endcase

    audio_sum = $signed({{2{piezo_sample[15]}}, piezo_sample}) +
        $signed({{2{voice_sample[15]}}, voice_sample}) +
        $signed({{2{hmc_sample[15]}}, hmc_sample});
    if (audio_sum > 18'sd32767) begin
      mixed_audio = 16'sh7fff;
    end else if (audio_sum < -18'sd32768) begin
      mixed_audio = 16'sh8000;
    end else begin
      mixed_audio = audio_sum[15:0];
    end
  end

  assign audio = mixed_audio;

  ////////////////////////////////////////////////////////////////////////////////////////
  // Debug

`ifdef CORE_ENABLE_DEBUG_OVERLAY
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
      debug_core_seen[5]  <= debug_core_seen[5]  | (wr_8bit && rom_8bit_download);
      debug_core_seen[6]  <= debug_core_seen[6]  | (wr_8bit && rom_8bit_download && rom_byte_addr < 26'h001000);
      debug_core_seen[7]  <= debug_core_seen[7]  | (wr_8bit && rom_8bit_download && rom_byte_addr >= 26'h001000 && rom_byte_addr < 26'h001100);
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
  wire [7:0] debug_core_row2 = hmc_feature ?
      {hmc_rom_valid, hmc_busy, hmc_trigger, hmc_osc_ce, hmc_out, output_shifter_s[1]} :
      voice_feature ?
      {voice_bank_valid, voice_busy, voice_current_command, input_beta} :
      {output_r, input_ba, input_beta, image_download, rom_download};
  wire [7:0] debug_core_row3 = hmc_feature ? {hmc_address, hmc_command[7]} :
      voice_feature ? voice_sample_address[15:8] :
      cpu_id == 4'd3 ? {current_w_prime[4], current_w_main[4]} :
      rom_addr[11:4];
  wire [7:0] debug_core_row4 = hmc_feature ? hmc_command :
      voice_feature ? voice_sample_address[7:0] :
      cpu_id == 4'd3 ? {current_w_prime[5], current_w_main[5]} :
      {rom_addr[3:0], rom_data[7:4]};
  wire [7:0] debug_core_row5 = hmc_feature ? hmc_dwell_remaining[11:4] :
      voice_feature ? voice_sample[15:8] :
      cpu_id == 4'd3 ? {current_w_prime[6], current_w_main[6]} :
      {rom_data[3:0], melody_addr[7:4]};
  wire [7:0] debug_core_row6 = hmc_feature ?
      {hmc_dwell_remaining[3:0], hmc_startup_remaining[8:5]} :
      voice_feature ? voice_nibbles_remaining[15:8] :
      cpu_id == 4'd3 ? {current_w_prime[7], current_w_main[7]} :
      {melody_addr[3:0], melody_data[7:4]};
  wire [7:0] debug_core_row7 = hmc_feature ?
      {hmc_divider_state, hmc_noise_state[0]} :
      voice_feature ? voice_nibbles_remaining[7:0] :
      cpu_id == 4'd3 ? {current_w_prime[8], current_w_main[8]} :
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
`else
  wire [63:0] video_debug_events = 64'd0;
  wire [63:0] video_debug_cpu_state = 64'd0;
  wire [63:0] video_debug_melody_state = 64'd0;
  wire [63:0] video_debug_core_state = 64'd0;
`endif

  ////////////////////////////////////////////////////////////////////////////////////////
  // Video

  wire        sd_data_available;
  wire [15:0] sd_out;
  wire        sd_end_burst;
  wire        sd_rd;
  wire [24:0] sd_rd_addr;

  video #(
      .EXTERNAL_CRT_TICK(1'b1)
  ) video (
      .clk_sys_99_287(clk_sys_99_287),
      .clk_vid_33_095(clk_vid_33_095),

      // Raster timing must free-run before/while package data is available so
      // MiSTer can display its OSD and commit the default video mode. Core and
      // loader reset only blank content; they never park CE/sync counters.
      .reset(1'b0),
      .content_reset(video_blank || ioctl_download),

      .cpu_id(cpu_id),
      .crt_video(crt_video),
      .hold_video(hold_video),
      .crt_source_tick_async(crt_source_tick_async),
      .crt_assets_valid(crt_assets_valid),

      .mask_data_wr(mask_config_download && ioctl_wr),
      .crt_mask_data_wr(crt_mask_download && ioctl_wr),
      .crt_mask_data_start(crt_mask_download && ioctl_wr && base_addr == 26'd0),
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
      .source_packet_wr(source_packet_wr),
      .source_packet(source_packet),
      .video_held(video_held),

      // SDRAM
      .sd_data_available(sd_data_available),
      .sd_out(sd_out),
      .sd_end_burst(sd_end_burst),
      .sd_rd(sd_rd),
      .sd_rd_addr(sd_rd_addr)
  );

  ////////////////////////////////////////////////////////////////////////////////////////
  // SDRAM

  // The package stream is already backpressured by ioctl_wait. Capture one
  // accepted image word, then present a one-cycle registered request to p0 on
  // the following clock. Non-image package words continue through rom_loader
  // at their original cadence.
  always @(posedge clk_sys_99_287) begin
    if (!pll_core_locked) begin
      image_write_pending <= 1'b0;
      image_write_addr <= 25'd0;
      image_write_data <= 16'd0;
    end else begin
      image_write_pending <= 1'b0;
      if (ioctl_wr && (image_download || crt_image_download)) begin
        image_write_pending <= 1'b1;
        image_write_addr <= base_addr[24:0];
        image_write_data <= ioctl_dout;
      end
    end
  end

  wire sdram_wr = image_write_pending;

  sdram_burst #(
      .CLOCK_SPEED_MHZ(98.3203125),
      .CAS_LATENCY(2)
  ) sdram (
      .clk  (clk_sys_99_287),
      .reset(~pll_core_locked),

      // Port 0
      .p0_addr(sdram_wr ? image_write_addr : sd_rd_addr),
      .p0_data(image_write_data),
      .p0_byte_en(2'b11),
      .p0_q(sd_out),

      .p0_wr_req(sdram_wr),
      .p0_rd_req(sd_rd),
      .p0_end_burst_req(sd_end_burst),

      .p0_available(sdram_p0_available),
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
