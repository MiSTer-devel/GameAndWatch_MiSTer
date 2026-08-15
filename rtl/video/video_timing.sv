// Exact-average pixel pacing on the Quartus 17 mapped 98.3203125 MHz PLL
// clock. Native uses 524375/1573125 (exactly /3) for 32.7734375 MHz and is
// hysteretically paused by the transport so its long-term delivered rate
// matches the exact 32.768 MHz output. CRT uses 288/4195 for exactly
// 6.750 MHz. Their CE gaps are bounded to 3/4 and 14/15 source clocks
// respectively. These ratios deliberately use the implemented PLL rate
// (12585/128 MHz), not the rounded frequency requested from the IP.
module video_timing #(
    parameter EXTERNAL_CRT_TICK = 1'b0
) (
    input wire clk_video,
    input wire reset,
    input wire crt_mode_async,
    input wire hold_async,
    input wire crt_tick_async,
    input wire native_pause_async,

    output wire [10:0] x,
    output wire [9:0] y,
    output wire hsync,
    output wire vsync,
    output wire hblank,
    output wire vblank,
    output wire de,
    output wire ce_pix,
    output reg held = 1'b0,
    output wire crt_mode
);
  (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
  reg crt_mode_meta = 1'b0;
  reg crt_mode_sync = 1'b0;
  (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
  reg hold_meta = 1'b0;
  reg hold_sync = 1'b0;
  (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
  reg native_pause_meta = 1'b0;
  reg native_pause_sync = 1'b0;
  (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
  reg crt_tick_meta = 1'b0;
  reg crt_tick_sync = 1'b0;
  reg crt_tick_seen = 1'b0;

  localparam [20:0] NATIVE_INCREMENT = 21'd524375;
  localparam [20:0] NATIVE_MODULUS = 21'd1573125;
  localparam [20:0] NATIVE_WRAP_THRESHOLD =
      NATIVE_MODULUS - NATIVE_INCREMENT;
  localparam [12:0] CRT_INCREMENT = 13'd288;
  localparam [12:0] CRT_MODULUS = 13'd4195;
  localparam [12:0] CRT_WRAP_THRESHOLD = CRT_MODULUS - CRT_INCREMENT;

  reg [20:0] native_ce_accumulator = 21'd0;
  reg [12:0] crt_ce_accumulator = 13'd0;
  wire native_ce = native_ce_accumulator >= NATIVE_WRAP_THRESHOLD;
  wire crt_ce = crt_ce_accumulator >= CRT_WRAP_THRESHOLD;
  // Threshold-form modulo updates keep every intermediate within the
  // accumulator width. A conventional native accumulator+increment sum can
  // reach 2,097,412 and would therefore require an otherwise unnecessary
  // 22nd bit.
  wire [20:0] native_ce_next = native_ce ?
      native_ce_accumulator - NATIVE_WRAP_THRESHOLD :
      native_ce_accumulator + NATIVE_INCREMENT;
  wire [12:0] crt_ce_next = crt_ce ?
      crt_ce_accumulator - CRT_WRAP_THRESHOLD :
      crt_ce_accumulator + CRT_INCREMENT;
  wire crt_tick_event = crt_tick_sync != crt_tick_seen;
  wire selected_crt_ce = EXTERNAL_CRT_TICK ? crt_tick_event : crt_ce;
  wire ce_raw = crt_mode_sync ? selected_crt_ce : native_ce;
  // video_mode_control asserts hold only after observing this source raster
  // in vertical blank. A further CE requirement is both redundant and, for
  // externally paced CRT video, unsafe: the output bridge may already have
  // stopped requesting pixels while it waits for this acknowledgement. The
  // counters and packet bus are stable between CEs, so freezing on the next
  // source clock preserves an exact pixel boundary without another tick.
  wire enter_hold = !held && hold_sync && vblank;
  // ALIGN pauses only the native compositor while the independent 54 MHz
  // raster reaches its next SOF. It must not alter the mode-control `held`
  // acknowledgement, which remains owned exclusively by hold_async.
  wire native_pause = !crt_mode_sync && native_pause_sync;
  wire mode_freeze = held || enter_hold;

  assign crt_mode = crt_mode_sync;
  assign ce_pix = ce_raw && !held && !native_pause;

  always @(posedge clk_video) begin
    crt_mode_meta <= crt_mode_async;
    crt_mode_sync <= crt_mode_meta;
    hold_meta <= hold_async;
    hold_sync <= hold_meta;
    native_pause_meta <= native_pause_async;
    native_pause_sync <= native_pause_meta;
    crt_tick_meta <= crt_tick_async;
    crt_tick_sync <= crt_tick_meta;
    crt_tick_seen <= crt_tick_sync;

    if (reset) begin
      held <= 1'b0;
      crt_tick_meta <= 1'b0;
      crt_tick_sync <= 1'b0;
      crt_tick_seen <= 1'b0;
      native_pause_meta <= 1'b0;
      native_pause_sync <= 1'b0;
      native_ce_accumulator <= 21'd0;
      crt_ce_accumulator <= 13'd0;
    end else begin
      if (enter_hold) begin
        held <= 1'b1;
      end else if (held && !hold_sync) begin
        held <= 1'b0;
      end

      if (mode_freeze) begin
        // Restart both pacing phases deterministically after a held mode
        // change. The CRT accumulator is not reset at line/frame boundaries,
        // so its one-source-clock duration dither cannot accumulate drift.
        native_ce_accumulator <= 21'd0;
        crt_ce_accumulator <= 13'd0;
      end else if (!native_pause) begin
        // ALIGN holds the native source exactly where it is; unlike a mode
        // hold, it must not reseed either the NCO or raster to SOF.
        native_ce_accumulator <= native_ce_next;
        crt_ce_accumulator <= crt_ce_next;
      end
    end
  end

  counts counts (
      .clk(clk_video),
      .reset(reset),
      .hold(mode_freeze),
      .ce_pix(ce_raw && !native_pause),
      .crt_video(crt_mode_sync),
      .x(x),
      .y(y),
      .hsync(hsync),
      .vsync(vsync),
      .hblank(hblank),
      .vblank(vblank),
      .de(de)
  );
endmodule
