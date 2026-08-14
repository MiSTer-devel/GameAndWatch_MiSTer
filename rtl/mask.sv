module mask (
    input wire clk,

    input wire reset,

    input wire        ioctl_wr,
    input wire        ioctl_crt,
    input wire        ioctl_start,
    input wire [15:0] ioctl_dout,

    input wire use_crt_assets,
    input wire pixel_tick,
    input wire [1:0] source_x_step,
    input wire vblank,
    input wire hblank,
    input wire [10:0] video_x,
    input wire [9:0] video_y,

    output reg [9:0] segment_id = 0,  // Cycle delayed to only update on video_clock cycles
    output reg has_segment = 0,
    output reg sample_ready = 0
);
  ////////////////////////////////////////////////////////////////////////////////////////
  // ROM management

  localparam [15:0] CRT_MASK_BASE = 16'h9240;

  reg [15:0] read_addr = 0;
  // mask_rom registers q. Whenever read_addr changes, the old q is still
  // visible to this process for the current edge and the newly addressed q is
  // not safe to inspect until two following system edges have elapsed.
  reg [1:0] read_wait = 2'd2;
  reg prev_vblank = 1'b0;
  reg prev_use_crt_assets = 1'b0;
  reg [1:0] prev_source_x_step = 2'd1;
  reg [15:0] write_addr = 0;

  reg wren = 0;

  wire [9:0] next_segment_id;
  wire [9:0] segment_start_x /* synthesis keep */;
  wire [9:0] segment_y /* synthesis keep */;
  wire [9:0] segment_length /* synthesis keep */;
  reg [39:0] buffer_40 = 0;

  mask_rom mask_rom (
      .clock(clk),

      .address(wren ? write_addr : read_addr),
      .wren(wren),
      .data(buffer_40),
      .q({segment_length, segment_y, segment_start_x, next_segment_id})
  );

  reg  [15:0] buffer_16 = 0;
  reg  [ 1:0] buffer_16_bytes = 0;

  always @(posedge clk) begin
    if (ioctl_start && ioctl_crt) begin
      buffer_16 <= 16'd0;
      buffer_16_bytes <= 2'd0;
    end

    if (ioctl_wr) begin
      buffer_16 <= ioctl_dout;
      buffer_16_bytes <= 2;
    end

    if (buffer_16_bytes > 0) begin
      buffer_16 <= {8'h0, buffer_16[15:8]};
      buffer_16_bytes <= buffer_16_bytes - 2'h1;
    end
  end

  reg [2:0] buffer_40_bytes = 0;
  reg prev_wren = 0;

  reg prev_reset = 0;

  always @(posedge clk) begin
    prev_reset <= reset;
    prev_wren  <= wren;

    if (reset && ~prev_reset) begin
      write_addr <= 0;
    end


    if (ioctl_start && ioctl_crt) begin
      write_addr <= CRT_MASK_BASE;
      buffer_40 <= 40'd0;
      buffer_40_bytes <= 3'd0;
    end

    wren <= 0;

    if (buffer_16_bytes > 0) begin
      // Write. Load next byte into buffer.
      buffer_40 <= {buffer_16[7:0], buffer_40[39:8]};
      buffer_40_bytes <= buffer_40_bytes + 3'h1;

      if (buffer_40_bytes + 3'h1 == 3'h5) begin
        // This was last byte, write.
        wren <= 1;
        buffer_40_bytes <= 3'h0;
      end
    end

    if (~wren && prev_wren) begin
      // Finished write, increment addr.
      write_addr <= write_addr + 16'h1;
    end
  end

  ////////////////////////////////////////////////////////////////////////////////////////
  // Mask pixel selection

  wire [10:0] current_x = video_x;
  // Legacy 720-wide assets are sampled at source X=0,2,...718 for the
  // 360-pixel CRT raster. Advance an entry when the next displayed source
  // coordinate reaches its end; using +1 here loses an immediately adjacent
  // run because the stale-entry recovery consumes that next pixel tick.
  wire [10:0] next_sample_x = current_x + {9'd0, source_x_step};
  wire [10:0] segment_end_x = {1'b0, segment_start_x} + {1'b0, segment_length};
  wire same_row = segment_y == video_y;
  wire valid_entry = segment_length != 10'd0;
  wire sampled_segment = valid_entry && same_row && current_x >= {1'b0, segment_start_x} &&
      current_x < segment_end_x;
  wire stale_segment = valid_entry && ((segment_y < video_y) ||
      (same_row && segment_end_x <= current_x));

  always @(posedge clk) begin
    // sample_ready is a one-cycle mailbox strobe. segment_id/has_segment stay
    // valid until the next sampled pixel; consumers capture the pair on the
    // following system edge, independent of native /3 or fractional CRT CE.
    sample_ready <= 1'b0;
    prev_vblank <= vblank;
    prev_use_crt_assets <= use_crt_assets;
    prev_source_x_step <= source_x_step;

    if (use_crt_assets != prev_use_crt_assets ||
        source_x_step != prev_source_x_step) begin
      // Active mode changes only while video is held. Rebase immediately so
      // the correct bank is primed during SETTLE even though the frozen
      // vblank packet may have asserted before the mode level changed.
      read_addr <= use_crt_assets ? CRT_MASK_BASE : 16'd0;
      read_wait <= 2'd2;
      has_segment <= 1'b0;
    end else if (vblank && !prev_vblank) begin
      read_addr <= use_crt_assets ? CRT_MASK_BASE : 16'd0;
      read_wait <= 2'd2;
      has_segment <= 1'b0;
    end else if (read_wait != 2'd0) begin
      read_wait <= read_wait - 2'd1;
      has_segment <= 1'b0;
    end else if (vblank) begin
      // The base entry is now primed while blank remains asserted. Do not
      // continually reload it or the first active x=0 packet will be lost to
      // read_wait at every frame boundary.
      has_segment <= 1'b0;
    end else if (stale_segment) begin
      read_addr   <= read_addr + 16'h1;
      read_wait   <= 2'd2;
    end else if (hblank) begin
      has_segment <= 1'b0;
    end else if (pixel_tick) begin
      segment_id <= next_segment_id;
      has_segment <= sampled_segment;
      sample_ready <= 1'b1;

      // Read ahead past every same-row run that is complete before the next
      // displayed source coordinate. In legacy x*2 mode this also consumes an
      // odd-only run such as [1,2) while sampling x=0; otherwise stale-entry
      // recovery at x=2 would spend that pixel tick and drop an adjacent
      // visible [2,4) run.
      if (valid_entry && same_row && next_sample_x >= segment_end_x) begin
        read_addr <= read_addr + 16'h1;
        read_wait <= 2'd2;
      end
    end
  end

endmodule
