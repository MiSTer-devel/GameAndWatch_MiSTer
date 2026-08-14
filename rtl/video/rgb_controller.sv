module rgb_controller (
    input wire clk_sys_99_287,
    input wire clk_vid_33_095,

    input wire reset,

    // Video
    input wire ce_pix,
    input wire crt_video,
    input wire use_crt_assets,
    input wire hblank_int,
    input wire [9:0] video_y,
    input wire de_int,

    // RGB
    output wire [23:0] background_rgb,
    output wire [23:0] mask_rgb,

    // SDRAM
    input wire sd_data_available,
    input wire [15:0] sd_out,
    output reg sd_rd = 0,
    output reg sd_end_burst = 0,
    output reg [24:0] sd_rd_addr
);
  // 1/3rd of each source pixel per 16 bit word (one byte to each FIFO).
  localparam [15:0] NATIVE_WORDS_PER_LINE = 16'd720 * 16'd3;
  localparam [15:0] CRT_WORDS_PER_LINE = 16'd360 * 16'd3;
  localparam [24:0] CRT_IMAGE_WORD_BASE = 25'h180000;

  reg prev_sd_data_available;
  reg prev_hblank = 0;
  reg prev_hblank2 = 0;
  reg prev_crt_video = 0;
  reg prev_use_crt_assets = 0;
  reg fifo_mode_clear = 0;
  reg fifo_line_clear = 0;
  reg read_line_zero = 0;
  reg mode_read_pending = 0;

  reg [23:0] background_buffer = 0;
  reg [23:0] mask_buffer = 0;

  reg [2:0] buffer_count = 0;
  reg [15:0] sd_read_count = 0;
  reg [9:0] source_pixel_x = 0;

  // hblank_int/video_y arrive as a coherent sys-domain pixel packet from
  // video.sv. Edge detection therefore produces a full-system-clock DCFIFO
  // clear pulse without independently synchronizing related raster fields.
  wire hblank_rise = hblank_int && ~prev_hblank;
  wire fifo_clear = reset || fifo_line_clear || fifo_mode_clear;
  wire completed_pixel = buffer_count == 3'h3;
  wire legacy_crt_bridge = crt_video && !use_crt_assets;
  // Native 360-wide CRT packages are already one source pixel per output
  // pixel. Old packages retain a 720-wide image, so preserve compatibility by
  // writing only source X=0,2,...718 into the 360-pixel FIFO line.
  wire fifo_write = completed_pixel &&
      (!legacy_crt_bridge || !source_pixel_x[0]);
  wire [15:0] source_words_per_line =
      crt_video && use_crt_assets ? CRT_WORDS_PER_LINE : NATIVE_WORDS_PER_LINE;

  image_fifo background_image_fifo (
      .wrclk(clk_sys_99_287),
      .rdclk(clk_vid_33_095),

      .wrreq(fifo_write),
      .data (background_buffer),

      .rdreq(de_int && ce_pix),
      // TODO: Can this be fixed somewhere?
      // .q({rgb[7:0], rgb[15:8], rgb[23:16]}),
      .q({background_rgb[7:0], background_rgb[15:8], background_rgb[23:16]}),

      .aclr(fifo_clear),
      .rdempty(),
      .rdusedw(),
      .wrfull(),
      .wrusedw()
  );

  image_fifo mask_image_fifo (
      .wrclk(clk_sys_99_287),
      .rdclk(clk_vid_33_095),

      .wrreq(fifo_write),
      .data (mask_buffer),

      .rdreq(de_int && ce_pix),
      .q({mask_rgb[7:0], mask_rgb[15:8], mask_rgb[23:16]}),

      .aclr(fifo_clear),
      .rdempty(),
      .rdusedw(),
      .wrfull(),
      .wrusedw()
  );

  always @(posedge clk_sys_99_287) begin
    if (reset) begin
      background_buffer <= 0;
      mask_buffer <= 0;

      buffer_count <= 0;
      sd_read_count <= 0;
      source_pixel_x <= 0;
      prev_sd_data_available <= 1'b0;
      prev_hblank <= hblank_int;
      prev_hblank2 <= hblank_int;
      prev_crt_video <= crt_video;
      prev_use_crt_assets <= use_crt_assets;
      fifo_mode_clear <= 1'b0;
      fifo_line_clear <= 1'b0;
      read_line_zero <= 1'b0;
      mode_read_pending <= 1'b0;
      sd_rd <= 1'b0;
      // Package download/content reset may begin while SDRAM is returning a
      // scanline. Terminate that burst immediately so loader backpressure is
      // released in a bounded number of clocks instead of at the page edge.
      sd_end_burst <= 1'b1;
    end else begin
      reg [2:0] new_buffer_count;

      prev_sd_data_available <= sd_data_available;
      prev_hblank <= hblank_int;
      prev_hblank2 <= prev_hblank;
      prev_crt_video <= crt_video;
      prev_use_crt_assets <= use_crt_assets;
      fifo_mode_clear <= 1'b0;
      fifo_line_clear <= hblank_rise;

      new_buffer_count = buffer_count;

      sd_rd <= 0;
      sd_end_burst <= 0;

      if (crt_video != prev_crt_video ||
          use_crt_assets != prev_use_crt_assets) begin
        // The timing controller keeps video blank while the new source line
        // is prefetched. Always begin with logical line zero; on CRT->native
        // transitions the held CRT counter is otherwise only 261 and could be
        // mistaken for native line 262 while a mode change is settling.
        sd_read_count <= 16'd0;
        source_pixel_x <= 10'd0;
        background_buffer <= 24'd0;
        mask_buffer <= 24'd0;
        buffer_count <= 3'd0;
        read_line_zero <= 1'b1;
        mode_read_pending <= 1'b1;
        fifo_mode_clear <= 1'b1;
        sd_end_burst <= 1'b1;
      end else if (mode_read_pending) begin
        // Drain/stop any request made for the previous mode. The registered
        // address has then had a full cycle to move to the new line-zero base
        // before its replacement read request is asserted.
        if (sd_data_available) begin
          sd_end_burst <= 1'b1;
        end else begin
          sd_rd <= 1'b1;
          mode_read_pending <= 1'b0;
        end
      end else begin
        if (completed_pixel) begin
          // The completed source pixel has now been consumed.
          new_buffer_count = 0;
          source_pixel_x <= source_pixel_x + 10'd1;
        end

        buffer_count <= new_buffer_count;

        if (sd_data_available) begin
          // Background is low byte
          background_buffer <= {sd_out[7:0], background_buffer[23:8]};
          mask_buffer <= {sd_out[15:8], mask_buffer[23:8]};

          buffer_count <= new_buffer_count + 3'h1;

          sd_read_count <= sd_read_count + 16'h1;

          if (sd_read_count >= source_words_per_line - 16'd2) begin
            // Don't need to read any more. Halt burst
            sd_end_burst <= 1;
          end
        end else if (~sd_data_available && prev_sd_data_available) begin
          // We stopped reading, check if we need to read more
          if (sd_read_count < source_words_per_line) begin
            // We haven't read enough, queue another read
            sd_rd <= 1;
          end
        end

        // Delay hblank trigger by one cycle so that sd_rd_addr can be set properly
        if (hblank_rise) begin
          sd_read_count <= 0;
          source_pixel_x <= 0;
          read_line_zero <= 1'b0;
        end else if (prev_hblank && ~prev_hblank2) begin
          sd_rd <= 1;

          // For easy debugging
          background_buffer <= 0;
          mask_buffer <= 0;
          buffer_count <= 0;
        end
      end
    end
  end

  // Address of the next line of the image in 16-bit SDRAM words. Native and
  // legacy packages use 720*3=2160 words; the native CRT bank uses
  // 360*3=1080 words.
  always @(posedge clk_sys_99_287) begin
    reg [ 9:0] target_y;
    reg [ 9:0] read_y;
    reg [24:0] line_word_addr;

    target_y = read_line_zero ? 10'd0 :
        hblank_int ? video_y + 10'd1 : video_y;

    if (crt_video) begin
      if (target_y >= 10'd240) begin
        target_y = 10'd0;
      end

      read_y = use_crt_assets ? target_y :
          ({target_y[7:0], 1'b0} + target_y);
    end else begin
      if (target_y >= 10'd720) begin
        target_y = 10'd0;
      end

      read_y = target_y;
    end

    if (crt_video && use_crt_assets) begin
      // 1080 = 1024 + 64 - 8.
      line_word_addr = {5'b0, read_y, 10'b0} +
          {9'b0, read_y, 6'b0} - {12'b0, read_y, 3'b0};
    end else begin
      // 2160 = 2048 + 128 - 16.
      line_word_addr = {4'b0, read_y, 11'b0} +
          {8'b0, read_y, 7'b0} - {11'b0, read_y, 4'b0};
    end

    sd_rd_addr <= line_word_addr + {9'b0, sd_read_count} +
        (use_crt_assets ? CRT_IMAGE_WORD_BASE : 25'd0);
  end

endmodule
