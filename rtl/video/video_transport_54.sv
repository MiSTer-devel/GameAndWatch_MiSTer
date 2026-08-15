// Fixed-54 MHz MiSTer video transport bridge.
//
// The source writes one atomic packet per accepted source pixel:
//   {sof, hsync, vsync, hblank, vblank, de, rgb[23:0]}.
//
// Both modes own their raster controls in this 54 MHz domain. Native consumes
// RGB packets at the exact rational cadence 54 MHz * 2048 / 3375 = 32.768 MHz;
// CRT consumes the 360x240 source at exactly 54 MHz / 8 = 6.75 MHz. Packet
// timing bits are acquisition evidence only, so a FIFO recovery can black RGB
// without stretching or reordering the framework-visible raster.
module video_transport_54 #(
    parameter integer PREFILL_WORDS = 512,
    parameter integer FLUSH_CYCLES = 8
) (
    input wire clk_source,
    input wire clk_video_54,
    input wire reset,

    // These controls are synchronous to clk_source and asynchronous to
    // clk_video_54. The integration contract keeps crt_mode_async stable
    // while hold_async is asserted.
    input wire crt_mode_async,
    input wire hold_async,

    input wire packet_wr,
    input wire [29:0] packet_data,
    output wire packet_ready,
    output wire [9:0] packet_level_source,
    output wire [9:0] packet_level_video,
    // CRT source pacing request. This toggle crosses back to clk_source and
    // advances the compositor exactly once per fixed /8 output pixel.
    output reg crt_source_tick_toggle = 1'b0,
    // Native source pause is a level CDC. The source synchronizes it and
    // freezes its slightly leading NCO while this bridge waits in ALIGN or
    // trims FIFO occupancy during RUN. It never changes the output raster.
    output wire native_source_pause,

    output wire ce_pixel,
    output reg hsync = 1'b0,
    output reg vsync = 1'b0,
    output reg hblank = 1'b1,
    output reg vblank = 1'b1,
    output reg de = 1'b0,
    output reg [23:0] rgb = 24'd0,

    output wire active_crt_mode,
    output wire running,
    output reg fault = 1'b0
);
  localparam integer PACKET_SOF = 29;
  localparam integer PACKET_HSYNC = 28;
  localparam integer PACKET_VSYNC = 27;
  localparam integer PACKET_HBLANK = 26;
  localparam integer PACKET_VBLANK = 25;
  localparam integer PACKET_DE = 24;

  localparam [10:0] CRT_ACTIVE_X = 11'd360;
  localparam [10:0] CRT_TOTAL_X = 11'd429;
  localparam [10:0] CRT_HSYNC_START = 11'd370;
  localparam [10:0] CRT_HSYNC_END = 11'd401;
  localparam [9:0] CRT_ACTIVE_Y = 10'd240;
  localparam [9:0] CRT_TOTAL_Y = 10'd262;
  localparam [9:0] CRT_VSYNC_START = 10'd244;
  localparam [9:0] CRT_VSYNC_END = 10'd247;

  localparam [10:0] NATIVE_ACTIVE_X = 11'd720;
  localparam [10:0] NATIVE_TOTAL_X = 11'd756;
  localparam [10:0] NATIVE_HSYNC_START = 11'd725;
  localparam [10:0] NATIVE_HSYNC_END = 11'd733;
  localparam [9:0] NATIVE_ACTIVE_Y = 10'd720;
  localparam [9:0] NATIVE_TOTAL_Y = 10'd730;
  localparam [9:0] NATIVE_VSYNC_START = 10'd725;
  localparam [9:0] NATIVE_VSYNC_END = 10'd727;

  localparam [1:0] STATE_SEARCH = 2'd0;
  localparam [1:0] STATE_PREFILL = 2'd1;
  localparam [1:0] STATE_RUN = 2'd2;
  localparam [1:0] STATE_ALIGN = 2'd3;
  localparam [3:0] FLUSH_RELOAD = FLUSH_CYCLES[3:0];

  wire [29:0] fifo_q;
  wire fifo_empty;
  wire fifo_full;
  wire fifo_rdreq;
  reg [3:0] flush_count = FLUSH_RELOAD;
  wire fifo_aclr = reset || flush_count != 4'd0;

  // fifo_aclr is authored in the 54 MHz domain and intentionally asserts the
  // dual-clock FIFO asynchronously. Give the write side its own synchronous
  // release before advertising readiness; otherwise a source pixel could be
  // accepted while the FIFO's internal write-side reset pipeline is still
  // clearing.
  (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
  reg [2:0] fifo_write_reset_pipe = 3'b111;
  always @(posedge clk_source or posedge fifo_aclr) begin
    if (fifo_aclr) begin
      fifo_write_reset_pipe <= 3'b111;
    end else begin
      fifo_write_reset_pipe <= {fifo_write_reset_pipe[1:0], 1'b0};
    end
  end
  wire fifo_write_reset = fifo_write_reset_pipe[2];

  // Keep the overflow event toggle stable across an ordinary FIFO flush. A
  // 1->0 transition caused by that same flush would otherwise look like a
  // second overflow in the read domain. Only the bridge's global reset
  // initializes the toggle; this source-local pipe provides synchronous
  // release for that reset as well.
  (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
  reg [2:0] source_global_reset_pipe = 3'b111;
  always @(posedge clk_source or posedge reset) begin
    if (reset) begin
      source_global_reset_pipe <= 3'b111;
    end else begin
      source_global_reset_pipe <= {source_global_reset_pipe[1:0], 1'b0};
    end
  end
  wire source_global_reset = source_global_reset_pipe[2];

  // hold_async originates with the source-domain mode controller, so it is
  // also the source-side write inhibit while the read domain flushes/rearms.
  // Keep a small recovery margin instead of waiting for the physical full
  // flag. Besides avoiding an edge-case write at full, this makes occupancy a
  // functional part of overflow recovery, so Quartus must retain the FIFO's
  // complete read-pointer-to-write-domain synchronizer.
  wire fifo_high_water = packet_level_source >= 10'd1000;
  assign packet_ready = !fifo_full && !fifo_high_water &&
      !fifo_write_reset && !hold_async;
  wire fifo_wrreq = packet_wr && packet_ready;

  video_packet_fifo transport_fifo (
      .aclr(fifo_aclr),
      .wrclk(clk_source),
      .wrreq(fifo_wrreq),
      .data(packet_data),
      .wrfull(fifo_full),
      .wrusedw(packet_level_source),
      .rdclk(clk_video_54),
      .rdreq(fifo_rdreq),
      .q(fifo_q),
      .rdempty(fifo_empty),
      .rdusedw(packet_level_video)
  );

  // A lost source packet cannot be repaired by backpressure because the
  // source raster must keep moving. Cross an overflow event as a toggle and
  // force the read side to discard/reacquire at the next SOF.
  reg overflow_toggle = 1'b0;
  reg overflow_latched = 1'b0;
  always @(posedge clk_source) begin
    if (source_global_reset) begin
      overflow_toggle <= 1'b0;
      overflow_latched <= 1'b0;
      end else if (packet_ready) begin
      // Rearm only after the write port is observably usable again. The
      // FIFO's synchronized reset can leave wrfull asserted briefly after
      // fifo_write_reset drops; rearming on the reset edge would turn that
      // settling interval into a second, artificial overflow event.
      overflow_latched <= 1'b0;
    end else if (packet_wr && !fifo_write_reset && !hold_async &&
                 !overflow_latched) begin
      overflow_toggle <= !overflow_toggle;
      overflow_latched <= 1'b1;
    end
  end

  (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
  reg crt_mode_meta = 1'b0;
  reg crt_mode_sync = 1'b0;
  (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
  reg hold_meta = 1'b0;
  reg hold_sync = 1'b0;
  (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
  reg overflow_meta = 1'b0;
  reg overflow_sync = 1'b0;
  reg overflow_seen = 1'b0;
  reg hold_prev = 1'b0;
  reg active_crt = 1'b0;

  assign active_crt_mode = active_crt;

  reg [1:0] state = STATE_SEARCH;
  assign running = state == STATE_RUN;
  // The native producer runs exactly 5,437.5 packets/s faster than the fixed
  // 32.768 MHz consumer. Pause it with wide hysteresis so sparse hardware
  // write/service gaps cannot drain the FIFO, while the framework-visible
  // raster remains free-running and exact. The read-domain count is already
  // synchronized by dcfifo; the 128-word band easily covers pause CDC delay.
  reg native_run_pause = 1'b0;
`ifdef CORE_DIAGNOSTIC_TRANSPORT_STATE
  // Latched hardware-only recovery cause. This remains visible throughout
  // SEARCH/PREFILL/ALIGN so a scaler screenshot can identify a one-cycle
  // trigger long after the offending edge.
  reg [2:0] diagnostic_fault_reason = 3'd0;
`endif

  // CRT CE is an exact /8. Native is the exact rational NCO 2048/3375.
  reg [2:0] crt_divider = 3'd0;
  reg [11:0] native_accumulator = 12'd0;
  wire [12:0] native_sum = {1'b0, native_accumulator} + 13'd2048;
  wire native_ce_raw = native_sum >= 13'd3375;
  wire [12:0] native_remainder = native_sum - 13'd3375;
  wire crt_ce_raw = crt_divider == 3'd7;
  wire selected_ce_raw = active_crt ? crt_ce_raw : native_ce_raw;
  // SEARCH and PREFILL need source pixels. ALIGN holds the FIFO head on SOF;
  // RUN uses occupancy hysteresis to absorb rare source-side service gaps.
  // CRT already stops receiving returned output ticks.
  wire request_crt_source = active_crt && !hold_sync && !fifo_aclr &&
      state != STATE_ALIGN;
  assign native_source_pause = !active_crt &&
      (state == STATE_ALIGN || native_run_pause);

  // Raster cadence is never gated by packet availability, hold, or recovery.
  // This is the central invariant that keeps MiSTer's scaler line and frame
  // accounting stable even if RGB must be black until the next clean SOF.
  assign ce_pixel = selected_ce_raw;

  reg [10:0] crt_x = 11'd0;
  reg [9:0] crt_y = 10'd0;
  reg [10:0] native_x = 11'd0;
  reg [9:0] native_y = 10'd0;
  wire mode_changed = crt_mode_sync != active_crt;
  wire hold_started = hold_sync && !hold_prev;
  wire overflow_event = overflow_sync != overflow_seen;
  wire prefill_ready = packet_level_video >= PREFILL_WORDS;
  wire control_event = mode_changed || hold_started || overflow_event;
  wire local_sof = active_crt ?
      (crt_x == 11'd0 && crt_y == 10'd0) :
      (native_x == 11'd0 && native_y == 10'd0);
  wire packet_phase_good = fifo_q[PACKET_SOF] == local_sof;

  // dcfifo samples rdreq on the same edge on which the bridge consumes the
  // show-ahead q word. Keep this request combinational so the consumed packet
  // and the exported CE refer to the same edge.
  // Both modes acquire a complete source frame. Discard until SOF, hold that
  // word through PREFILL, then align it to the output-owned frame boundary.
  wire search_discard = state == STATE_SEARCH && !fifo_aclr && !hold_sync &&
      !control_event && !fifo_empty && !fifo_q[PACKET_SOF];
  wire run_consume = state == STATE_RUN && selected_ce_raw && !fifo_aclr &&
      !hold_sync && !control_event && !fifo_empty && packet_phase_good;
  assign fifo_rdreq = search_discard || run_consume;

  always @(posedge clk_video_54 or posedge reset) begin
    if (reset) begin
      crt_mode_meta <= 1'b0;
      crt_mode_sync <= 1'b0;
      hold_meta <= 1'b0;
      hold_sync <= 1'b0;
      overflow_meta <= 1'b0;
      overflow_sync <= 1'b0;
      overflow_seen <= 1'b0;
      hold_prev <= 1'b0;
      active_crt <= 1'b0;
      crt_source_tick_toggle <= 1'b0;
      flush_count <= FLUSH_RELOAD;
      state <= STATE_SEARCH;
      native_run_pause <= 1'b0;
      fault <= 1'b0;
`ifdef CORE_DIAGNOSTIC_TRANSPORT_STATE
      diagnostic_fault_reason <= 3'd0;
`endif
      crt_divider <= 3'd0;
      native_accumulator <= 12'd0;
      crt_x <= 11'd0;
      crt_y <= 10'd0;
      native_x <= 11'd0;
      native_y <= 10'd0;
      hsync <= 1'b0;
      vsync <= 1'b0;
      hblank <= 1'b1;
      vblank <= 1'b1;
      de <= 1'b0;
      rgb <= 24'd0;
    end else begin
      crt_mode_meta <= crt_mode_async;
      crt_mode_sync <= crt_mode_meta;
      hold_meta <= hold_async;
      hold_sync <= hold_meta;
      overflow_meta <= overflow_toggle;
      overflow_sync <= overflow_meta;
      hold_prev <= hold_sync;

      if (active_crt || state != STATE_RUN || fifo_aclr || control_event ||
          fifo_empty) begin
        native_run_pause <= 1'b0;
      end else if (!native_run_pause && packet_level_video >= 10'd768) begin
        native_run_pause <= 1'b1;
      end else if (native_run_pause && packet_level_video <= 10'd640) begin
        native_run_pause <= 1'b0;
      end

      if (request_crt_source && crt_ce_raw) begin
        crt_source_tick_toggle <= !crt_source_tick_toggle;
      end

      if (active_crt) begin
        // Packet availability never resets either output pacing phase.
        crt_divider <= crt_divider + 3'd1;
        native_accumulator <= 12'd0;
      end else begin
        crt_divider <= 3'd0;
        if (native_ce_raw) begin
          native_accumulator <= native_remainder[11:0];
        end else begin
          native_accumulator <= native_sum[11:0];
        end
      end

      if (mode_changed || hold_started || overflow_event) begin
        active_crt <= crt_mode_sync;
        overflow_seen <= overflow_sync;
        flush_count <= FLUSH_RELOAD;
        state <= STATE_SEARCH;
        fault <= overflow_event;
`ifdef CORE_DIAGNOSTIC_TRANSPORT_STATE
        if (overflow_event) begin
          diagnostic_fault_reason <= 3'd3;
        end else if (hold_started) begin
          diagnostic_fault_reason <= 3'd2;
        end else begin
          diagnostic_fault_reason <= 3'd1;
        end
`endif
        if (mode_changed) begin
          if (crt_mode_sync) begin
            crt_x <= 11'd0;
            crt_y <= 10'd0;
          end else begin
            native_x <= 11'd0;
            native_y <= 10'd0;
          end
        end
        hsync <= 1'b0;
        vsync <= 1'b0;
        hblank <= 1'b1;
        vblank <= 1'b1;
        de <= 1'b0;
        rgb <= 24'd0;
      end else if (flush_count != 4'd0) begin
        flush_count <= flush_count - 4'd1;
        state <= STATE_SEARCH;
        hsync <= 1'b0;
        vsync <= 1'b0;
        hblank <= 1'b1;
        vblank <= 1'b1;
        de <= 1'b0;
        rgb <= 24'd0;
      end else if (hold_sync) begin
        state <= STATE_SEARCH;
        hsync <= 1'b0;
        vsync <= 1'b0;
        hblank <= 1'b1;
        vblank <= 1'b1;
        de <= 1'b0;
        rgb <= 24'd0;
      end else begin
        case (state)
          STATE_SEARCH: begin
            hsync <= 1'b0;
            vsync <= 1'b0;
            hblank <= 1'b1;
            vblank <= 1'b1;
            de <= 1'b0;
            rgb <= 24'd0;
            if (!fifo_empty && fifo_q[PACKET_SOF]) begin
              state <= STATE_PREFILL;
            end
          end

          STATE_PREFILL: begin
            hsync <= 1'b0;
            vsync <= 1'b0;
            hblank <= 1'b1;
            vblank <= 1'b1;
            de <= 1'b0;
            rgb <= 24'd0;
            if (fifo_empty) begin
              state <= STATE_SEARCH;
`ifdef CORE_DIAGNOSTIC_TRANSPORT_STATE
              diagnostic_fault_reason <= 3'd4;
`endif
            end else if (!fifo_q[PACKET_SOF]) begin
              state <= STATE_SEARCH;
`ifdef CORE_DIAGNOSTIC_TRANSPORT_STATE
              diagnostic_fault_reason <= 3'd5;
`endif
            end else if (prefill_ready) begin
              // Hold source SOF while the local raster completes its current
              // black frame. Both modes enter RUN only at their own origin.
              state <= STATE_ALIGN;
            end
          end

          STATE_ALIGN: begin
            // The local counters and sync continue in the unconditional block
            // below. RGB stays black and the FIFO head stays on source SOF.
            // Pausing source progress in this state prevents the FIFO from
            // filling while waiting up to one output frame for alignment.
            if (fifo_empty || !fifo_q[PACKET_SOF]) begin
              state <= STATE_SEARCH;
              fault <= 1'b1;
`ifdef CORE_DIAGNOSTIC_TRANSPORT_STATE
              diagnostic_fault_reason <= fifo_empty ? 3'd4 : 3'd5;
`endif
            end else if (selected_ce_raw &&
                         ((active_crt &&
                           crt_x == CRT_TOTAL_X - 11'd1 &&
                           crt_y == CRT_TOTAL_Y - 10'd1) ||
                          (!active_crt &&
                           native_x == NATIVE_TOTAL_X - 11'd1 &&
                           native_y == NATIVE_TOTAL_Y - 10'd1))) begin
              state <= STATE_RUN;
              fault <= 1'b0;
            end
          end

          STATE_RUN: begin
            if (selected_ce_raw) begin
              if (fifo_empty || !packet_phase_good) begin
                state <= STATE_SEARCH;
                fault <= 1'b1;
`ifdef CORE_DIAGNOSTIC_TRANSPORT_STATE
                diagnostic_fault_reason <= fifo_empty ? 3'd4 : 3'd5;
`endif
                hsync <= 1'b0;
                vsync <= 1'b0;
                hblank <= 1'b1;
                vblank <= 1'b1;
                de <= 1'b0;
                rgb <= 24'd0;
              end else if (active_crt) begin
                // CRT timing/RGB are authored by the unconditional raster
                // block below so recovery cannot perturb sync or CE cadence.
              end else begin
                hsync <= fifo_q[PACKET_HSYNC];
                vsync <= fifo_q[PACKET_VSYNC];
                hblank <= fifo_q[PACKET_HBLANK];
                vblank <= fifo_q[PACKET_VBLANK];
                de <= fifo_q[PACKET_DE];
                rgb <= fifo_q[PACKET_DE] ? fifo_q[23:0] : 24'd0;
              end
            end
          end

          default: begin
            state <= STATE_SEARCH;
            fault <= 1'b1;
`ifdef CORE_DIAGNOSTIC_TRANSPORT_STATE
            diagnostic_fault_reason <= 3'd7;
`endif
          end
        endcase
      end

      // Give the output-owned raster final priority over every state-machine
      // blank/recovery assignment above. Controls and counters never jump on
      // packet loss; only RGB changes to black until aligned RUN resumes.
      hsync <= hsync;
      vsync <= vsync;
      hblank <= hblank;
      vblank <= vblank;
      de <= de;
      rgb <= rgb;
      crt_x <= crt_x;
      crt_y <= crt_y;
      native_x <= native_x;
      native_y <= native_y;

      if (state != STATE_RUN || hold_sync || fifo_aclr || control_event) begin
        rgb <= 24'd0;
      end

      if (active_crt) begin
        native_x <= 11'd0;
        native_y <= 10'd0;
        if (crt_ce_raw) begin
          hsync <= crt_x >= CRT_HSYNC_START && crt_x < CRT_HSYNC_END;
          vsync <= crt_y >= CRT_VSYNC_START && crt_y < CRT_VSYNC_END;
          hblank <= crt_x >= CRT_ACTIVE_X;
          vblank <= crt_y >= CRT_ACTIVE_Y;
          de <= crt_x < CRT_ACTIVE_X && crt_y < CRT_ACTIVE_Y;
          rgb <= state == STATE_RUN && !hold_sync && !fifo_aclr &&
                     !control_event && !fifo_empty && packet_phase_good &&
                     crt_x < CRT_ACTIVE_X && crt_y < CRT_ACTIVE_Y ?
                 fifo_q[23:0] : 24'd0;

          if (crt_x == CRT_TOTAL_X - 11'd1) begin
            crt_x <= 11'd0;
            if (crt_y == CRT_TOTAL_Y - 10'd1) begin
              crt_y <= 10'd0;
            end else begin
              crt_y <= crt_y + 10'd1;
            end
          end else begin
            crt_x <= crt_x + 11'd1;
          end
        end
      end else begin
        crt_x <= 11'd0;
        crt_y <= 10'd0;
        if (native_ce_raw) begin
          hsync <= native_x >= NATIVE_HSYNC_START &&
              native_x < NATIVE_HSYNC_END;
          vsync <= native_y >= NATIVE_VSYNC_START &&
              native_y < NATIVE_VSYNC_END;
          hblank <= native_x >= NATIVE_ACTIVE_X;
          vblank <= native_y >= NATIVE_ACTIVE_Y;
          de <= native_x < NATIVE_ACTIVE_X && native_y < NATIVE_ACTIVE_Y;
`ifdef CORE_DIAGNOSTIC_TRANSPORT_STATE
          // Hardware-only state probe for intermittent native blanking. The
          // normal RUN path remains unmodified, while recovery states replace
          // black active pixels with unmistakable solid colors:
          // SEARCH=red, PREFILL=green, ALIGN=blue, invalid RUN=magenta.
          // Keep this macro disabled in every release build.
          if (native_x < NATIVE_ACTIVE_X && native_y < NATIVE_ACTIVE_Y) begin
            if (state == STATE_RUN) begin
              rgb <= !hold_sync && !fifo_aclr && !control_event &&
                             !fifo_empty && packet_phase_good ?
                         (native_x < 11'd8 ? 24'h00ffff : fifo_q[23:0]) :
                         (fifo_empty ? 24'hffff00 : 24'hff00ff);
            end else if (diagnostic_fault_reason != 3'd0) begin
              case (diagnostic_fault_reason)
                3'd1: rgb <= 24'hffffff;  // Mode change.
                3'd2: rgb <= 24'h808080;  // Hold started.
                3'd3: rgb <= 24'hff8000;  // FIFO overflow/high water.
                3'd4: rgb <= 24'hffff00;  // FIFO empty.
                3'd5: rgb <= 24'hff00ff;  // SOF phase mismatch.
                default: rgb <= 24'h8000ff;
              endcase
            end else begin
              case (state)
                STATE_SEARCH: rgb <= 24'hff0000;
                STATE_PREFILL: rgb <= 24'h00ff00;
                STATE_ALIGN: rgb <= 24'h0000ff;
                default: rgb <= 24'h8000ff;
              endcase
            end
          end else begin
            rgb <= 24'd0;
          end
`else
          rgb <= state == STATE_RUN && !hold_sync && !fifo_aclr &&
                     !control_event && !fifo_empty && packet_phase_good &&
                     native_x < NATIVE_ACTIVE_X &&
                     native_y < NATIVE_ACTIVE_Y ? fifo_q[23:0] : 24'd0;
`endif

          if (native_x == NATIVE_TOTAL_X - 11'd1) begin
            native_x <= 11'd0;
            if (native_y == NATIVE_TOTAL_Y - 10'd1) begin
              native_y <= 10'd0;
            end else begin
              native_y <= native_y + 10'd1;
            end
          end else begin
            native_x <= native_x + 11'd1;
          end
        end
      end
    end
  end
endmodule
