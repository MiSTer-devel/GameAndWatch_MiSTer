module video #(
    parameter EXTERNAL_CRT_TICK = 1'b0
) (
    input wire clk_sys_99_287,
    input wire clk_vid_33_095,

    input wire reset,
    input wire content_reset,

    input wire [3:0] cpu_id,
    input wire crt_video,
    input wire hold_video,
    input wire crt_source_tick_async,
    input wire native_source_pause_async,
    input wire crt_assets_valid,

    // Data in
    input wire mask_data_wr,
    input wire crt_mask_data_wr,
    input wire crt_mask_data_start,
    input wire [15:0] mask_data,

    input wire divider_1khz,

    // Segments
    input wire [15:0] current_segment_a,
    input wire [15:0] current_segment_b,
    input wire [15:0] current_segment_c,
    input wire [15:0] current_segment_bs,

    input wire [3:0] current_w_prime[16],
    input wire [3:0] current_w_main [16],

    input wire [1:0] output_lcd_h_index,

    // Settings
    input wire [7:0] lcd_off_alpha,

    // Debug
    input wire debug_video,
    input wire [1:0] debug_view,
    input wire [63:0] debug_events,
    input wire [63:0] debug_cpu_state,
    input wire [63:0] debug_melody_state,
    input wire [63:0] debug_core_state,

    // Video
    output reg hsync,
    output reg vsync,
    output reg hblank,
    output reg vblank,

    output reg de,
    output wire ce_pix,
    output reg [23:0] rgb,
    // Coherent logical-pixel stream for the asynchronous 54 MHz output
    // transport. Bit layout is
    // {sof, hsync, vsync, hblank, vblank, de, rgb[23:0]}.
    output reg source_packet_wr = 1'b0,
    output reg [29:0] source_packet = 30'd0,
    output wire video_held,

    // SDRAM
    input wire sd_data_available,
    input wire [15:0] sd_out,
    output wire sd_end_burst,
    output wire sd_rd,
    output wire [24:0] sd_rd_addr
);
  wire [10:0] video_x;
  wire [9:0] video_y;
  wire crt_video_pixel;
  wire hsync_int;
  wire vsync_int;
  wire hblank_int;
  wire vblank_int;
  wire de_int;

  // The source compositor uses the mapped 98.3203125 MHz PLL net as clk_sys.
  // Register the next accepted raster coordinate as one atomic packet on every
  // CE. The LCD mask consumes it one clock later and resolves segment_en on the
  // following clock, leaving at least a third clock for the completed pixel.
  // The separate output transport crosses only those completed pixels to the
  // dedicated 54 MHz CLK_VIDEO domain.
  reg [10:0] pixel_x_sys = 11'd0;
  reg [9:0] pixel_y_sys = 10'd0;
  reg pixel_hblank_sys = 1'b1;
  reg pixel_vblank_sys = 1'b1;
  reg pixel_de_sys = 1'b0;
  reg pixel_crt_sys = 1'b0;
  reg pixel_packet_ready_sys = 1'b0;

  wire [10:0] packet_total_x = crt_video_pixel ? 11'd429 : 11'd756;
  wire [9:0] packet_total_y = crt_video_pixel ? 10'd262 : 10'd730;
  wire [10:0] packet_incremented_x = video_x + 11'd1;
  wire packet_wrap_x = packet_incremented_x >= packet_total_x;
  wire [10:0] packet_next_x = packet_wrap_x ? 11'd0 : packet_incremented_x;
  wire [9:0] packet_incremented_y = video_y + 10'd1;
  wire [9:0] packet_next_y = packet_wrap_x ?
      (packet_incremented_y >= packet_total_y ? 10'd0 : packet_incremented_y) :
      video_y;
  wire packet_next_hblank = packet_next_x >=
      (crt_video_pixel ? 11'd360 : 11'd720);
  wire packet_next_vblank = packet_next_y >=
      (crt_video_pixel ? 10'd240 : 10'd720);
  wire packet_next_de = !packet_next_hblank && !packet_next_vblank;

  wire legacy_crt_bridge_sys = pixel_crt_sys && !crt_assets_valid;
  wire [9:0] next_pixel_y_sys = pixel_y_sys >=
      (pixel_crt_sys ? 10'd239 : 10'd719) ? 10'd0 : pixel_y_sys + 10'd1;
  wire [9:0] source_y_sys = legacy_crt_bridge_sys ?
      ({pixel_y_sys[7:0], 1'b0} + pixel_y_sys) : pixel_y_sys;
  wire [9:0] next_source_y_sys = legacy_crt_bridge_sys ?
      ({next_pixel_y_sys[7:0], 1'b0} + next_pixel_y_sys) : next_pixel_y_sys;
  wire [10:0] source_x_sys = legacy_crt_bridge_sys ?
      {pixel_x_sys[9:0], 1'b0} : pixel_x_sys;
  wire [10:0] mask_x_sys = pixel_crt_sys && pixel_hblank_sys ?
      11'd0 : source_x_sys;
  wire [9:0] mask_y_sys = pixel_crt_sys && pixel_hblank_sys ?
      next_source_y_sys : source_y_sys;

  always @(posedge clk_sys_99_287) begin
    if (reset) begin
      pixel_packet_ready_sys <= 1'b0;
      pixel_x_sys <= 11'd0;
      pixel_y_sys <= 10'd0;
      pixel_hblank_sys <= 1'b1;
      pixel_vblank_sys <= 1'b1;
      pixel_de_sys <= 1'b0;
      pixel_crt_sys <= 1'b0;
    end else begin
      pixel_packet_ready_sys <= 1'b0;
      if (ce_pix) begin
        pixel_x_sys <= packet_next_x;
        pixel_y_sys <= packet_next_y;
        pixel_hblank_sys <= packet_next_hblank;
        pixel_vblank_sys <= packet_next_vblank;
        pixel_de_sys <= packet_next_de;
        pixel_crt_sys <= crt_video_pixel;
        pixel_packet_ready_sys <= 1'b1;
      end
    end
  end

  ////////////////////////////////////////////////////////////////////////////////////////
  // LCD

  wire segment_en;

  lcd lcd (
      .clk(clk_sys_99_287),

      .reset(content_reset),

      .cpu_id(cpu_id),

      .mask_data_wr(mask_data_wr),
      .crt_mask_data_wr(crt_mask_data_wr),
      .crt_mask_data_start(crt_mask_data_start),
      .mask_data(mask_data),

      // Segments
      .current_segment_a (current_segment_a),
      .current_segment_b (current_segment_b),
      .current_segment_c (current_segment_c),
      .current_segment_bs(current_segment_bs),

      .current_w_prime(current_w_prime),
      .current_w_main (current_w_main),

      .output_lcd_h_index(output_lcd_h_index),

      .divider_1khz(divider_1khz),

      // Video counters
      // crt_video is the stable, sys-controlled active mode and changes only
      // while raster is held. Use it for preload/bank selection so the 4096
      // settle interval actually refills the new source before release; packet
      // x/y/blanking remain atomic raster state.
      .use_crt_assets(crt_video && crt_assets_valid),
      .pixel_tick(pixel_packet_ready_sys),
      // Unlike x/y, this is a preload control. Derive it from the stable
      // active mode so the mask reader rebases to its legacy x*2 cadence
      // during HOLD/SETTLE, while pixel_crt_sys is deliberately frozen in the
      // previous mode until the raster is released.
      .source_x_step(crt_video && !crt_assets_valid ? 2'd2 : 2'd1),
      .vblank_int(pixel_vblank_sys),
      .hblank_int(pixel_hblank_sys),
      .video_x(mask_x_sys),
      .video_y(mask_y_sys),

      .segment_en(segment_en)
  );

  ////////////////////////////////////////////////////////////////////////////////////////
  // SDRAM and RGB

  wire [23:0] background_rgb;
  wire [23:0] mask_rgb;
  wire [23:0] processed_rgb;

  wire [7:0] alpha = content_reset ? 8'h00 : segment_en ? 8'hFF : lcd_off_alpha;

  alpha_blend alpha_blend (
      .background_pixel(background_rgb),
      .foreground_pixel({mask_rgb, alpha}),

      .output_pixel(processed_rgb)
  );

`ifdef CORE_ENABLE_DEBUG_OVERLAY
  wire [2:0] debug_col = crt_video_pixel ? video_x[7:5] : video_x[8:6];
  wire [2:0] debug_row = crt_video_pixel ? video_y[7:5] : video_y[8:6];
  wire [5:0] debug_idx = {debug_row, debug_col};
  wire debug_panel = video_x < (crt_video_pixel ? 11'd256 : 11'd512) &&
      video_y < (crt_video_pixel ? 10'd240 : 10'd512);
  wire debug_grid = crt_video_pixel ? ((video_x[4:0] == 5'd0) || (video_y[4:0] == 5'd0)) :
      ((video_x[5:0] == 6'd0) || (video_y[5:0] == 6'd0));

  reg [63:0] debug_bits;
  always_comb begin
    case (debug_view)
      2'd1: debug_bits = debug_cpu_state;
      2'd2: debug_bits = debug_melody_state;
      2'd3: debug_bits = debug_core_state;
      default: debug_bits = debug_events;
    endcase
  end

  reg [23:0] debug_row_rgb;
  always_comb begin
    case (debug_row)
      3'd0: debug_row_rgb = 24'hffffff;
      3'd1: debug_row_rgb = 24'h00ff00;
      3'd2: debug_row_rgb = 24'hffff00;
      3'd3: debug_row_rgb = 24'h00ffff;
      3'd4: debug_row_rgb = 24'hff80ff;
      3'd5: debug_row_rgb = 24'hff8000;
      3'd6: debug_row_rgb = 24'h80a0ff;
      default: debug_row_rgb = 24'hff4040;
    endcase
  end

  wire debug_cell_on = debug_panel && debug_bits[debug_idx];
  wire [23:0] debug_rgb =
      !de_int        ? 24'h000000 :
      !debug_panel   ? 24'h000010 :
      debug_grid     ? 24'h202020 :
      debug_cell_on  ? debug_row_rgb :
                       24'h080008;

  wire [23:0] final_rgb = debug_video ? debug_rgb : processed_rgb;
`else
  wire [23:0] final_rgb = processed_rgb;
`endif

  // Hardware A/B diagnostic for native artifacts. This preserves the source
  // raster, packet FIFO, fixed-54 transport, and MiSTer scaler while removing
  // only the near-saturating artwork SDRAM reads. Every active pixel encodes
  // its exact source coordinate so a repeated, skipped, or reordered region
  // remains visible and machine-checkable in captured screenshots.
`ifdef CORE_DIAGNOSTIC_VIDEO_PATTERN
  wire [23:0] transport_rgb = {video_x, video_y, 3'b101};
`else
  wire [23:0] transport_rgb = final_rgb;
`endif

  wire artwork_sd_end_burst;
  wire artwork_sd_rd;
  wire [24:0] artwork_sd_rd_addr;

  rgb_controller rgb_controller (
      .clk_sys_99_287(clk_sys_99_287),
      .clk_vid_33_095(clk_vid_33_095),

      .reset(content_reset),

      // Video
      .ce_pix(ce_pix),
      .crt_video(crt_video),
      .use_crt_assets(crt_video && crt_assets_valid),
      .hblank_int(pixel_hblank_sys),
      .video_y(pixel_y_sys),
      .de_int(de_int),

      // RGB
      .background_rgb(background_rgb),
      .mask_rgb(mask_rgb),

      // SDRAM
      .sd_data_available(sd_data_available),
      .sd_out(sd_out),
      .sd_end_burst(artwork_sd_end_burst),
      .sd_rd(artwork_sd_rd),
      .sd_rd_addr(artwork_sd_rd_addr)
  );

`ifdef CORE_DIAGNOSTIC_VIDEO_PATTERN
  assign sd_end_burst = 1'b0;
  assign sd_rd = 1'b0;
`else
  assign sd_end_burst = artwork_sd_end_burst;
  assign sd_rd = artwork_sd_rd;
`endif
  assign sd_rd_addr = artwork_sd_rd_addr;

  ////////////////////////////////////////////////////////////////////////////////////////
  // Sync counts

  // Retain the source values for the entire CE interval. Framework video
  // stages sample only on CE_PIXEL, so changing RGB or timing between enables
  // can otherwise produce scaler-only corruption.
  always @(posedge clk_vid_33_095) begin
    source_packet_wr <= 1'b0;

    if (ce_pix) begin
      if (hold_video || video_held) begin
        hsync <= 1'b0;
        vsync <= 1'b0;
        hblank <= 1'b1;
        vblank <= 1'b1;
        de <= 1'b0;
        rgb <= 24'd0;
      end else begin
        hsync <= hsync_int;
        vsync <= vsync_int;
        hblank <= hblank_int;
        vblank <= vblank_int;
        de <= de_int;
        // Content reset blanks only pixels. Raster/DE remain coherent so the
        // MiSTer framework can render its OSD before any package is loaded.
        // The synchronous next-pixel packet gives mask and segments two full
        // clocks to resolve final_rgb before the next native 3/4-gap CE edge.
        rgb <= content_reset ? 24'd0 : transport_rgb;

        // Register the complete pixel and its timing together. The FIFO sees
        // source_packet_wr on the following 98.3203125 MHz edge, after this bus
        // has settled, so no independently synchronized data bits cross to
        // the 54 MHz transport domain.
        source_packet <= {
          video_x == 11'd0 && video_y == 10'd0,
          hsync_int,
          vsync_int,
          hblank_int,
          vblank_int,
          de_int,
          content_reset ? 24'd0 : transport_rgb
        };
        source_packet_wr <= 1'b1;
      end
    end
  end

  video_timing #(
      .EXTERNAL_CRT_TICK(EXTERNAL_CRT_TICK)
  ) video_timing (
      .clk_video(clk_vid_33_095),
      .reset(reset),
      .crt_mode_async(crt_video),
      .hold_async(hold_video),
      .crt_tick_async(crt_source_tick_async),
      .native_pause_async(native_source_pause_async),
      .x(video_x),
      .y(video_y),
      .hsync (hsync_int),
      .vsync (vsync_int),
      .hblank(hblank_int),
      .vblank(vblank_int),
      .de(de_int),
      .ce_pix(ce_pix),
      .held(video_held),
      .crt_mode(crt_video_pixel)
  );

endmodule
