// Fixed-54 MHz MiSTer video transport bridge.
//
// The source writes one atomic packet per accepted source pixel:
//   {sof, hsync, vsync, hblank, vblank, de, rgb[23:0]}.
//
// Native mode preserves those timing fields and consumes packets with the
// exact rational cadence 54 MHz * 2048 / 3375 = 32.768 MHz. CRT mode consumes
// the 360x240 / 429x262 source one-for-one at exactly 54 MHz / 8 = 6.75 MHz.
// All externally visible signals change only on CE edges.
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

  // CRT CE is an exact /8. Native is the exact rational NCO 2048/3375.
  reg [2:0] crt_divider = 3'd0;
  reg [11:0] native_accumulator = 12'd0;
  wire [12:0] native_sum = {1'b0, native_accumulator} + 13'd2048;
  wire native_ce_raw = native_sum >= 13'd3375;
  wire [12:0] native_remainder = native_sum - 13'd3375;
  wire crt_ce_raw = crt_divider == 3'd7;
  wire selected_ce_raw = active_crt ? crt_ce_raw : native_ce_raw;
  // SEARCH and PREFILL need source pixels. ALIGN deliberately pauses the
  // source with SOF at the FIFO head until the free-running output reaches
  // its own frame boundary; RUN then requests and consumes one packet per CE.
  wire request_crt_source = active_crt && !hold_sync && !fifo_aclr &&
      state != STATE_ALIGN;
  reg blank_commit_pending = 1'b0;
  wire blank_transition_ce;
  // Once CRT mode is active, its externally visible cadence and raster never
  // stop for packet-FIFO search, prefill, hold, or recovery. A content fault
  // may black RGB, but it must not stretch a line/frame or suppress sync; the
  // framework and downstream Direct Video equipment measure those edges.
  // Native mode retains the packet-driven behavior because it is supported
  // through the normal MiSTer scaler rather than raw Direct Video.
  assign ce_pixel = active_crt ? crt_ce_raw :
      (!fifo_aclr &&
       ((running && !hold_sync && selected_ce_raw) || blank_transition_ce));

  reg [10:0] crt_x = 11'd0;
  reg [9:0] crt_y = 10'd0;
  wire mode_changed = crt_mode_sync != active_crt;
  wire hold_started = hold_sync && !hold_prev;
  wire overflow_event = overflow_sync != overflow_seen;
  wire prefill_ready = packet_level_video >= PREFILL_WORDS;
  wire control_event = mode_changed || hold_started || overflow_event;
  // A control event can arrive between normal pixel CEs. Export CE on the edge
  // that changes the registers to blank, then retain a pending CE through the
  // FIFO flush and emit it once more with blank already stable. The second CE
  // lets downstream CE-gated framework stages actually capture that blank
  // under nonblocking sequential semantics.
  assign blank_transition_ce =
      (state == STATE_RUN && control_event) || blank_commit_pending;

  // dcfifo samples rdreq on the same edge on which the bridge consumes the
  // show-ahead q word. Keeping this request combinational is required for
  // adjacent native CEs; registering it would repeat a packet in that case.
  wire search_discard = state == STATE_SEARCH && !fifo_aclr && !hold_sync &&
      !control_event && !fifo_empty && !fifo_q[PACKET_SOF];
  wire run_consume = state == STATE_RUN && selected_ce_raw && !fifo_aclr &&
      !hold_sync && !control_event && !fifo_empty;
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
      fault <= 1'b0;
      crt_divider <= 3'd0;
      native_accumulator <= 12'd0;
      crt_x <= 11'd0;
      crt_y <= 10'd0;
      blank_commit_pending <= 1'b0;
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

      if (request_crt_source && crt_ce_raw) begin
        crt_source_tick_toggle <= !crt_source_tick_toggle;
      end

      if (blank_commit_pending && !fifo_aclr) begin
        blank_commit_pending <= 1'b0;
      end

      if (active_crt) begin
        // CRT timing is output-owned and free-running. Packet availability
        // never resets this divider or the raster counters below.
        crt_divider <= crt_divider + 3'd1;
        native_accumulator <= 12'd0;
      end else if (state != STATE_RUN || hold_sync || fifo_aclr) begin
        crt_divider <= 3'd0;
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
        if (!active_crt) begin
          crt_x <= 11'd0;
          crt_y <= 10'd0;
        end
        if (state == STATE_RUN) begin
          blank_commit_pending <= 1'b1;
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
            if (!fifo_empty) begin
              if (fifo_q[PACKET_SOF]) begin
                state <= STATE_PREFILL;
              end else begin
              end
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
            end else if (!fifo_q[PACKET_SOF]) begin
              state <= STATE_SEARCH;
            end else if (prefill_ready) begin
              // Native timing comes from the packet and may start now. CRT
              // timing is output-owned, so hold the source SOF and wait for
              // the local frame boundary before revealing or consuming it.
              state <= active_crt ? STATE_ALIGN : STATE_RUN;
              if (!active_crt) fault <= 1'b0;
            end
          end

          STATE_ALIGN: begin
            // The CRT counters and sync continue in the unconditional block
            // below. RGB stays black and the FIFO head stays on source SOF.
            // Stopping source requests in this state prevents the FIFO from
            // filling while waiting up to one output frame for alignment.
            if (fifo_empty || !fifo_q[PACKET_SOF]) begin
              state <= STATE_SEARCH;
              fault <= 1'b1;
            end else if (crt_ce_raw &&
                         crt_x == CRT_TOTAL_X - 11'd1 &&
                         crt_y == CRT_TOTAL_Y - 10'd1) begin
              state <= STATE_RUN;
              fault <= 1'b0;
            end
          end

          STATE_RUN: begin
            if (selected_ce_raw) begin
              if (fifo_empty) begin
                state <= STATE_SEARCH;
                fault <= 1'b1;
                blank_commit_pending <= 1'b1;
                if (!active_crt) begin
                  crt_x <= 11'd0;
                  crt_y <= 10'd0;
                end
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
          end
        endcase
      end

      // Give the CRT raster final ownership of the externally visible video
      // registers and its counters. Earlier state-machine assignments may
      // blank/rearm native output, but they cannot alter CRT timing between
      // enables or reset the scan position during a FIFO recovery episode.
      if (active_crt) begin
        // Hold every CRT output stable between enables even when SEARCH,
        // PREFILL, or flush logic above requests a content blank.
        hsync <= hsync;
        vsync <= vsync;
        hblank <= hblank;
        vblank <= vblank;
        de <= de;
        rgb <= rgb;
        crt_x <= crt_x;
        crt_y <= crt_y;
        if (crt_ce_raw) begin
          hsync <= crt_x >= CRT_HSYNC_START && crt_x < CRT_HSYNC_END;
          vsync <= crt_y >= CRT_VSYNC_START && crt_y < CRT_VSYNC_END;
          hblank <= crt_x >= CRT_ACTIVE_X;
          vblank <= crt_y >= CRT_ACTIVE_Y;
          de <= crt_x < CRT_ACTIVE_X && crt_y < CRT_ACTIVE_Y;
          rgb <= state == STATE_RUN && !hold_sync && !fifo_aclr &&
                     !control_event && !fifo_empty &&
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
      end
    end
  end
endmodule
