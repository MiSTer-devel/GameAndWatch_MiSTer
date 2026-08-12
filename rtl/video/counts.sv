module counts (
    input wire clk,
    input wire ce_pix,
    input wire crt_video,

    output reg [10:0] x = 0,
    output reg [9:0] y = 0,

    output reg  hsync = 0,
    output reg  vsync = 0,
    output wire hblank,
    output wire vblank,

    output wire de
);
  localparam [10:0] NORMAL_WIDTH = 11'd720;
  localparam [9:0] NORMAL_HEIGHT = 10'd720;
  localparam [9:0] NORMAL_MAX_Y = 10'd730;
  localparam [10:0] NORMAL_MAX_X = 11'd756;
  localparam [10:0] NORMAL_HSYNC_X = 11'd725;
  localparam [9:0] NORMAL_VSYNC_Y = 10'd725;
  localparam [10:0] NORMAL_VSYNC_X = 11'd721;

  localparam [10:0] CRT_WIDTH = 11'd360;
  localparam [9:0] CRT_HEIGHT = 10'd240;
  localparam [9:0] CRT_MAX_Y = 10'd262;
  localparam [10:0] CRT_MAX_X = 11'd416;
  localparam [10:0] CRT_HSYNC_START = 11'd376;
  localparam [10:0] CRT_HSYNC_END = 11'd400;
  localparam [9:0] CRT_VSYNC_START = 10'd243;
  localparam [9:0] CRT_VSYNC_END = 10'd246;

  wire [10:0] width = crt_video ? CRT_WIDTH : NORMAL_WIDTH;
  wire [9:0] height = crt_video ? CRT_HEIGHT : NORMAL_HEIGHT;
  wire [9:0] max_y = crt_video ? CRT_MAX_Y : NORMAL_MAX_Y;
  wire [10:0] max_x = crt_video ? CRT_MAX_X : NORMAL_MAX_X;

  ////////////////////////////////////////////////////////////////////////////////////////
  // Generated

  initial begin
    $display("Normal video: 720x720 active, 756x730 total");
    $display("CRT video: 360x240 active, 416x262 total");
  end

  assign de = x < width && y < height;
  assign vblank = y >= height;
  assign hblank = x >= width;

  always @(posedge clk) begin
    if (ce_pix) begin
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
        hsync <= next_x == NORMAL_HSYNC_X;
        vsync <= next_y == NORMAL_VSYNC_Y && next_x == NORMAL_VSYNC_X;
      end

      x <= next_x;
      y <= next_y;
    end
  end

endmodule
