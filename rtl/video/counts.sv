module counts (
    input wire clk,
    input wire reset,
    input wire hold,
    input wire ce_pix,
    input wire crt_video,

    output reg [10:0] x = 0,
    output reg [9:0] y = 0,

    output reg  hsync = 0,
    output reg  vsync = 0,
    output reg  hblank = 1,
    output reg  vblank = 1,

    output reg  de = 0
);
  localparam [10:0] NORMAL_WIDTH = 11'd720;
  localparam [9:0] NORMAL_HEIGHT = 10'd720;
  localparam [9:0] NORMAL_MAX_Y = 10'd730;
  localparam [10:0] NORMAL_MAX_X = 11'd756;
  // Native blanking is 36 pixels and 10 lines. Use conventional sync widths
  // inside those unchanged totals: horizontal front/sync/back = 5/8/23 and
  // vertical front/sync/back = 5/2/3. The former single-pixel VS pulse was
  // only 18.5 or 37 ns after the fixed-54 transport and could be missed by
  // the framework scaler's asynchronous frame-buffer rotation event.
  localparam [10:0] NORMAL_HSYNC_START = 11'd725;
  localparam [10:0] NORMAL_HSYNC_END = 11'd733;
  localparam [9:0] NORMAL_VSYNC_START = 10'd725;
  localparam [9:0] NORMAL_VSYNC_END = 10'd727;

  localparam [10:0] CRT_WIDTH = 11'd360;
  localparam [9:0] CRT_HEIGHT = 10'd240;
  localparam [9:0] CRT_MAX_Y = 10'd262;
  localparam [10:0] CRT_MAX_X = 11'd429;
  localparam [10:0] CRT_HSYNC_START = 11'd370;
  localparam [10:0] CRT_HSYNC_END = 11'd401;
  localparam [9:0] CRT_VSYNC_START = 10'd244;
  localparam [9:0] CRT_VSYNC_END = 10'd247;

  wire [10:0] width = crt_video ? CRT_WIDTH : NORMAL_WIDTH;
  wire [9:0] height = crt_video ? CRT_HEIGHT : NORMAL_HEIGHT;
  wire [9:0] max_y = crt_video ? CRT_MAX_Y : NORMAL_MAX_Y;
  wire [10:0] max_x = crt_video ? CRT_MAX_X : NORMAL_MAX_X;

  ////////////////////////////////////////////////////////////////////////////////////////
  // Generated

  initial begin
    $display("Normal video: 720x720 active, 756x730 total");
    $display("CRT video: 360x240 active, 429x262 total");
  end

  always @(posedge clk) begin
    if (reset || hold) begin
      // Seed the final count so the first CE after release begins at (0,0).
      x <= max_x - 11'd1;
      y <= max_y - 10'd1;
      hsync <= 1'b0;
      vsync <= 1'b0;
      hblank <= 1'b1;
      vblank <= 1'b1;
      de <= 1'b0;
    end else if (ce_pix) begin
      reg [10:0] next_x;
      reg [9:0] next_y;

      hsync <= 0;
      vsync <= 0;

      next_x = x + 11'd1;
      next_y = y;

      if (next_x >= max_x) begin
        next_x = 11'd0;
        next_y = y + 10'd1;

        if (next_y >= max_y) begin
          next_y = 10'd0;
        end
      end

      if (crt_video) begin
        hsync <= next_x >= CRT_HSYNC_START && next_x < CRT_HSYNC_END;
        vsync <= next_y >= CRT_VSYNC_START && next_y < CRT_VSYNC_END;
      end else begin
        hsync <= next_x >= NORMAL_HSYNC_START && next_x < NORMAL_HSYNC_END;
        vsync <= next_y >= NORMAL_VSYNC_START && next_y < NORMAL_VSYNC_END;
      end

      x <= next_x;
      y <= next_y;

      // Keep the blanking controls registered with the counters. These
      // signals cross into the faster image-reader clock domain, and a
      // combinational comparison can glitch when several binary counter bits
      // change together (notably x=511 -> 512). A false hblank pulse clears
      // both asynchronous image FIFOs and corrupts the rest of the scanline.
      hblank <= next_x >= width;
      vblank <= next_y >= height;
      de <= next_x < width && next_y < height;
    end
  end

endmodule
