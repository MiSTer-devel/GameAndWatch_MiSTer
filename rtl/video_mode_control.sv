// Coordinates a live video-mode change in the stable mapped 98.3203125 MHz
// system/source-video
// domain. The raster acknowledges a blank/frozen state, the active asset bank
// changes, then SDRAM line buffers refill before release. No CPU/audio reset or
// clock switch is involved.
module video_mode_control #(
    parameter integer SETTLE_CYCLES = 64
) (
    input  wire clk_sys,
    input  wire reset,
    input  wire clocks_ready,
    input  wire request_crt,
    input  wire video_vblank,
    input  wire video_held,

    output reg  active_crt = 1'b0,
    output reg  hold_video = 1'b0,
    output reg  new_vmode = 1'b0
);
  localparam [1:0] IDLE = 2'd0;
  localparam [1:0] WAIT_HELD = 2'd1;
  localparam [1:0] SETTLE = 2'd2;
  localparam [1:0] WAIT_RELEASED = 2'd3;
  localparam integer SETTLE_WIDTH = SETTLE_CYCLES <= 1 ? 1 : $clog2(SETTLE_CYCLES);

  (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
  reg vblank_meta = 1'b0;
  reg vblank_sync = 1'b0;
  (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
  reg held_meta = 1'b0;
  reg held_sync = 1'b0;
  (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
  reg ready_meta = 1'b0;
  reg ready_sync = 1'b0;
  reg [1:0] state = IDLE;
  reg target_crt = 1'b0;
  reg [SETTLE_WIDTH-1:0] settle_count = {SETTLE_WIDTH{1'b0}};

  always @(posedge clk_sys) begin
    vblank_meta <= video_vblank;
    vblank_sync <= vblank_meta;
    held_meta <= video_held;
    held_sync <= held_meta;
    ready_meta <= clocks_ready;
    ready_sync <= ready_meta;
    if (reset) begin
      active_crt <= 1'b0;
      hold_video <= 1'b0;
      new_vmode <= 1'b0;
      target_crt <= 1'b0;
      settle_count <= {SETTLE_WIDTH{1'b0}};
      state <= IDLE;
    end else begin
      case (state)
        IDLE: begin
          if (ready_sync && request_crt != active_crt && vblank_sync) begin
            target_crt <= request_crt;
            hold_video <= 1'b1;
            state <= WAIT_HELD;
          end
        end

        WAIT_HELD: begin
          if (held_sync) begin
            // Mode remains frozen while the new image/mask banks prefill.
            active_crt <= target_crt;
            settle_count <= {SETTLE_WIDTH{1'b0}};
            state <= SETTLE;
          end
        end

        SETTLE: begin
          if (settle_count == SETTLE_WIDTH'(SETTLE_CYCLES - 1)) begin
            hold_video <= 1'b0;
            state <= WAIT_RELEASED;
          end else begin
            settle_count <= settle_count + {{(SETTLE_WIDTH-1){1'b0}}, 1'b1};
          end
        end

        default: begin  // WAIT_RELEASED
          if (!held_sync) begin
            new_vmode <= ~new_vmode;
            state <= IDLE;
          end
        end
      endcase
    end
  end
endmodule
