module counts_15k (
    input  wire clk,
    input  wire ce_pix,

    output reg  [9:0] x = 0,
    output reg  [9:0] y = 0,

    output reg  hsync = 0,
    output reg  vsync = 0,
    output wire hblank,
    output wire vblank,
    output wire de
);
  // 320x240 active in a ~15.7kHz / ~60Hz raster
  localparam WIDTH  = 10'd320;
  localparam HEIGHT = 10'd240;

  // Horizontal timing: 320 active + 6 fp + 4 sync + 21 bp = 351 total
  localparam H_FP   = 10'd5;
  localparam H_SYNC = 10'd24;
  localparam H_BP   = 10'd2;

  // Vertical timing: 240 active + 4 fp + 3 sync + 15 bp = 262 total
  localparam V_FP   = 10'd4;
  localparam V_SYNC = 10'd3;
  localparam V_BP   = 10'd15;

  localparam H_SYNC_START = WIDTH + H_FP;                 // 326
  localparam H_SYNC_END   = WIDTH + H_FP + H_SYNC;        // 330
  localparam H_TOTAL      = WIDTH + H_FP + H_SYNC + H_BP; // 351

  localparam V_SYNC_START = HEIGHT + V_FP;                // 244
  localparam V_SYNC_END   = HEIGHT + V_FP + V_SYNC;       // 247
  localparam V_TOTAL      = HEIGHT + V_FP + V_SYNC + V_BP;// 262

  assign de     = (x < WIDTH) && (y < HEIGHT);
  assign hblank = (x >= WIDTH);
  assign vblank = (y >= HEIGHT);

  always @(posedge clk) begin
    if (ce_pix) begin
      reg [9:0] next_x;
      reg [9:0] next_y;

      next_x = x + 10'd1;
      next_y = y;

      if (next_x == H_TOTAL) begin
        next_x = 10'd0;
        next_y = y + 10'd1;

        if (next_y == V_TOTAL) begin
          next_y = 10'd0;
        end
      end

      x <= next_x;
      y <= next_y;

      hsync <= (next_x >= H_SYNC_START) && (next_x < H_SYNC_END);
      vsync <= (next_y >= V_SYNC_START) && (next_y < V_SYNC_END);
    end
  end
endmodule