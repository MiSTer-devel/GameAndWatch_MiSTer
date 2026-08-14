module segments #(
    parameter MAX_X_SEGMENT = 9,
    parameter MAX_Y_SEGMENT = 16,
    parameter MAX_Z_SEGMENT = 4
) (
    input wire clk,

    input wire reset,

    input wire [3:0] cpu_id,

    input wire mask_data_wr,
    input wire crt_mask_data_wr,
    input wire crt_mask_data_start,
    input wire [15:0] mask_data,

    input wire [MAX_Z_SEGMENT-1:0] segments[MAX_X_SEGMENT][MAX_Y_SEGMENT],

    // Video counters
    input wire use_crt_assets,
    input wire pixel_tick,
    input wire [1:0] source_x_step,
    input wire vblank_int,
    input wire hblank_int,
    input wire [10:0] video_x,
    input wire [9:0] video_y,

    // Comb
    output reg segment_en = 0
);
  // The line select of the segment, choosing which seg_a/b/bs is used. First value x in x.y.z
  wire [3:0] segment_line_select  /* synthesis keep */;

  // The column of the segment, corresponding to bit in the seg_a/b/bs line. Second value y in x.y.z
  wire [3:0] segment_column  /* synthesis keep */;

  // The row of the segment, corresponding to which H bit is high. Third value z in x.y.z
  wire [1:0] segment_row  /* synthesis keep */;

  wire has_segment;
  wire sample_ready;

  mask mask (
      .clk(clk),

      .reset(reset),

      .ioctl_wr  (mask_data_wr || crt_mask_data_wr),
      .ioctl_crt (crt_mask_data_wr),
      .ioctl_start(crt_mask_data_start),
      .ioctl_dout(mask_data),

      .use_crt_assets(use_crt_assets),
      .pixel_tick(pixel_tick),
      .source_x_step(source_x_step),
      .vblank (vblank_int),
      .hblank (hblank_int),
      .video_x(video_x),
      .video_y(video_y),

      .segment_id ({segment_line_select, segment_column, segment_row}),
      .has_segment(has_segment),
      .sample_ready(sample_ready)
  );

  always @(posedge clk) begin
    if (reset || vblank_int || hblank_int) begin
      segment_en <= 1'b0;
    end else if (sample_ready) begin
      // Capture validity and the normalized LCD bit atomically, then hold the
      // resolved pixel until the next mailbox sample. This survives the three
      // or four video-clock CE interval and removes phase-dependent pulses.
      segment_en <= has_segment &&
          segments[segment_line_select][segment_column][segment_row];
    end
  end
endmodule
