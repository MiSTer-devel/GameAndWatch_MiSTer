module mask (
    input wire clk,

    input wire reset,

    input wire        ioctl_wr,
    input wire [15:0] ioctl_dout,

    input wire crt_video,
    input wire vblank,
    input wire hblank,
    input wire [10:0] video_x,
    input wire [9:0] video_y,
    input wire [1:0] source_x_step,

    output reg [9:0] segment_id = 0,  // Cycle delayed to only update on video_clock cycles
    output reg has_segment = 0 // Cycle delayed in_segment to properly track the cycles we should render segments
);
  ////////////////////////////////////////////////////////////////////////////////////////
  // ROM management

  reg [15:0] read_addr = 0;
  reg [15:0] write_addr = 0;

  reg wren = 0;

  wire [9:0] next_segment_id;

  mask_rom mask_rom (
      .clock(clk),

      .address(wren ? write_addr : read_addr),
      .wren(wren),
      .data(buffer_40),
      .q({segment_length, segment_y, segment_start_x, next_segment_id})
  );

  wire [ 9:0] segment_start_x  /* synthesis keep */;
  wire [ 9:0] segment_y  /* synthesis keep */;
  wire [ 9:0] segment_length  /* synthesis keep */;

  reg  [15:0] buffer_16 = 0;
  reg  [ 1:0] buffer_16_bytes = 0;

  always @(posedge clk) begin
    if (ioctl_wr) begin
      buffer_16 <= ioctl_dout;
      buffer_16_bytes <= 2;
    end

    if (buffer_16_bytes > 0) begin
      buffer_16 <= {8'h0, buffer_16[15:8]};
      buffer_16_bytes <= buffer_16_bytes - 2'h1;
    end
  end

  reg [39:0] buffer_40 = 0;
  reg [2:0] buffer_40_bytes = 0;
  reg prev_wren = 0;

  reg prev_reset = 0;

  always @(posedge clk) begin
    prev_reset <= reset;
    prev_wren  <= wren;

    if (reset && ~prev_reset) begin
      write_addr <= 0;
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

  reg [3:0] vid_counter = 0;

  wire [3:0] vid_counter_start = crt_video ? 4'd14 : 4'd2;
  wire sample_tick = vid_counter == 4'd0;
  wire [10:0] current_x = video_x;
  wire [10:0] next_sample_x = current_x + {9'd0, source_x_step};
  wire [10:0] segment_end_x = {1'b0, segment_start_x} + {1'b0, segment_length};
  wire same_row = segment_y == video_y;
  wire valid_entry = segment_length != 10'd0;
  wire sampled_segment = valid_entry && same_row && current_x >= {1'b0, segment_start_x} &&
      current_x < segment_end_x;
  wire stale_segment = valid_entry && ((segment_y < video_y) ||
      (same_row && segment_end_x <= current_x));

  always @(posedge clk) begin
    has_segment <= 0;

    if (vid_counter > 0) begin
      vid_counter <= vid_counter - 4'd1;
    end else begin
      vid_counter <= vid_counter_start;
    end

    if (vblank) begin
      read_addr  <= 0;
      vid_counter <= 0;
    end else if (stale_segment) begin
      read_addr   <= read_addr + 16'h1;
      has_segment <= 0;
    end else if (hblank) begin
      has_segment <= 0;
    end else if (sample_tick) begin
      segment_id <= next_segment_id;
      has_segment <= sampled_segment;

      if (sampled_segment && next_sample_x >= segment_end_x) begin
        read_addr <= read_addr + 16'h1;
      end
    end
  end

endmodule
