// Hitachi HA1152 custom sound-effect generator used by Star Fox.
//
// The external 128-byte mask ROM is streamed into this module by the .gnw
// loader.  Each ROM byte selects a divider terminal state in bits 6:0 and a
// tone/noise action in bit 7.  All sound state advances on a clock-enable;
// no fabric-derived clock is used.

`default_nettype none

module hmc_ha1152 #(
    // 312.5 kHz / 98.3203125 MHz = 8 / 2517 exactly.  The parameters are
    // exposed so the focused testbench can exercise the sequencer at one
    // oscillator tick per system clock without changing production timing.
    parameter logic [17:0] OSC_NUMERATOR   = 18'd8,
    parameter logic [17:0] OSC_DENOMINATOR = 18'd2517
) (
    input  wire                clk,
    input  wire                reset,

    input  wire                load_clear,
    input  wire                rom_wr,
    input  wire [6:0]          rom_addr,
    input  wire [7:0]          rom_data,

    input  wire                enable,
    input  wire [3:1]          s_out,

    output logic               rom_valid,
    output logic               busy,
    output logic               hmc_out,
    output logic signed [15:0] sample,

    // Debug taps.  Trigger encoding is 0=none, 1=S2, 2=S3, 3=S4.
    output logic               osc_ce,
    output logic [1:0]         latched_trigger,
    output logic [6:0]         current_address,
    output logic [7:0]         current_command,
    output logic [11:0]        dwell_remaining,
    output logic [8:0]         startup_remaining,
    output logic [6:0]         divider_state,
    output logic [8:0]         noise_state
);

  localparam logic [1:0] TRIGGER_NONE = 2'd0;
  localparam logic [1:0] TRIGGER_S2   = 2'd1;
  localparam logic [1:0] TRIGGER_S3   = 2'd2;
  localparam logic [1:0] TRIGGER_S4   = 2'd3;

  localparam logic [6:0] S2_START = 7'h00;
  localparam logic [6:0] S3_START = 7'h3c;
  localparam logic [6:0] S4_START = 7'h75;

  localparam logic [11:0] S2_DWELL = 12'd3840;
  localparam logic [11:0] S3_DWELL = 12'd2880;
  localparam logic [11:0] S4_DWELL = 12'd480;

  localparam logic [6:0] DIVIDER_SEED = 7'h40;

  // This memory is small enough for an MLAB.  Read-during-write behavior is
  // intentionally unspecified; package loading and playback do not overlap.
  (* ramstyle = "MLAB, no_rw_check" *) logic [7:0] effect_rom [0:127];
  logic [6:0] rom_read_address;

  always_ff @(posedge clk) begin
    if (rom_wr) begin
      effect_rom[rom_addr] <= rom_data;
    end
  end

  // The ROM is written at runtime, so Quartus must not discard bytes that the
  // current effect image does not happen to read in a particular synthesis.
  wire [7:0] rom_read_data = effect_rom[rom_read_address];

  // Validation is based on address coverage, not write count: duplicate or
  // out-of-order writes cannot make a partial ROM playable.  Playback reset is
  // deliberately absent here so a normal MiSTer reset retains the package.
  logic [127:0] rom_seen;
  logic [127:0] rom_seen_after;
  logic [7:0]   rom_bytes_loaded;

  always_comb begin
    rom_seen_after = load_clear ? 128'd0 : rom_seen;
    if (rom_wr) begin
      rom_seen_after[rom_addr] = 1'b1;
    end
  end

  initial begin
    rom_seen         = 128'd0;
    rom_bytes_loaded = 8'd0;
    rom_valid        = 1'b0;
  end

  always @(posedge clk) begin
    rom_seen <= rom_seen_after;

    if (load_clear) begin
      rom_bytes_loaded <= rom_wr ? 8'd1 : 8'd0;
      rom_valid        <= 1'b0;
    end else if (rom_wr && !rom_seen[rom_addr]) begin
      if (rom_bytes_loaded == 8'd127) begin
        rom_bytes_loaded <= 8'd128;
        rom_valid        <= 1'b1;
      end else begin
        rom_bytes_loaded <= rom_bytes_loaded + 8'd1;
      end
    end
  end

  // Exact rational clock enable.  The physical HA1152 has no reset pin, so
  // its RC oscillator remains free-running through game/core resets as well
  // as while the effect generator is idle or disabled.
  logic [17:0] oscillator_accumulator;
  logic [17:0] oscillator_threshold;
  logic        oscillator_tick_now;

  always_comb begin
    oscillator_threshold = OSC_DENOMINATOR - OSC_NUMERATOR;
    oscillator_tick_now  = oscillator_accumulator >= oscillator_threshold;
  end

  initial begin
    oscillator_accumulator = 18'd0;
    osc_ce                  = 1'b0;
  end

  always @(posedge clk) begin
    osc_ce <= oscillator_tick_now;
    if (oscillator_tick_now) begin
      oscillator_accumulator <= oscillator_accumulator +
                                OSC_NUMERATOR - OSC_DENOMINATOR;
    end else begin
      oscillator_accumulator <= oscillator_accumulator + OSC_NUMERATOR;
    end
  end

  function automatic logic [6:0] divider_advance(
      input logic [6:0] state
  );
    begin
      // Maximal x^7+x+1 sequence in the polarity/orientation used by the die.
      divider_advance = {state[5:0], state[6] ^ state[0]};
    end
  endfunction

  function automatic logic [8:0] noise_advance(
      input logic [8:0] state
  );
    begin
      // state[0] is the newest history bit.  This implements
      // q[n+1] = q[n-3] XOR q[n-8], equivalent to x^9+x^5+1.
      noise_advance = {state[7:0], state[8] ^ state[3]};
    end
  endfunction

  logic [3:1] previous_s_out;
  logic [6:0] start_address;
  logic [11:0] dwell_period;
  logic [7:0] first_command;

  logic falling_s2;
  logic falling_s3;
  logic falling_s4;
  logic any_falling;
  logic latched_trigger_low;

  logic [1:0] selected_trigger;
  logic [6:0] selected_start_address;
  logic [11:0] selected_dwell_period;

  logic [6:0] next_address;
  logic [7:0] next_command;
  logic [8:0] next_noise_state;

  always_comb begin
    falling_s2 = previous_s_out[1] && !s_out[1];
    falling_s3 = previous_s_out[2] && !s_out[2];
    falling_s4 = previous_s_out[3] && !s_out[3];
    any_falling = falling_s2 || falling_s3 || falling_s4;

    // S4 wins a simultaneous sample, followed by S2 and then S3.  This mux
    // also selects the sole asynchronous playback read port of effect_rom.
    if (falling_s4) begin
      selected_trigger       = TRIGGER_S4;
      selected_start_address = S4_START;
      selected_dwell_period  = S4_DWELL;
    end else if (falling_s2) begin
      selected_trigger       = TRIGGER_S2;
      selected_start_address = S2_START;
      selected_dwell_period  = S2_DWELL;
    end else begin
      selected_trigger       = TRIGGER_S3;
      selected_start_address = S3_START;
      selected_dwell_period  = S3_DWELL;
    end

    case (latched_trigger)
      TRIGGER_S2: latched_trigger_low = !s_out[1];
      TRIGGER_S3: latched_trigger_low = !s_out[2];
      TRIGGER_S4: latched_trigger_low = !s_out[3];
      default:    latched_trigger_low = 1'b0;
    endcase

    next_address     = current_address + 7'd1;
    rom_read_address = any_falling ? selected_start_address : next_address;
    next_command     = rom_read_data;
    next_noise_state = noise_advance(noise_state);

    if (!busy) begin
      sample = 16'sd0;
    end else if (hmc_out) begin
      sample = 16'sd8192;
    end else begin
      sample = -16'sd8192;
    end
  end

  // The noise generator is intentionally not reset by reset or load_clear.
  // Its phase persists across effects and idle time just as the physical
  // free-running storage does.  Any nonzero seed has the full 511-state period.
  initial noise_state = 9'b100000000;

  initial begin
    previous_s_out    = 3'b111;
    start_address     = S2_START;
    dwell_period      = S2_DWELL;
    first_command     = 8'd0;
    busy              = 1'b0;
    hmc_out           = 1'b0;
    latched_trigger   = TRIGGER_NONE;
    current_address   = 7'd0;
    current_command   = 8'd0;
    dwell_remaining   = 12'd0;
    startup_remaining = 9'd0;
    divider_state     = DIVIDER_SEED;
  end

  always @(posedge clk) begin
    previous_s_out <= s_out;

    if (reset) begin
      // Reset does not create an external HMC trigger edge.  The SM530 starts
      // with S low and firmware establishes the idle-high level with ATS; by
      // following the live pins during reset, each line arms independently
      // when firmware raises it and only a later real falling edge triggers.
      // ROM validity and noise phase are intentionally retained.
      previous_s_out    <= s_out;
      busy              <= 1'b0;
      hmc_out           <= 1'b0;
      latched_trigger   <= TRIGGER_NONE;
      current_address   <= 7'd0;
      current_command   <= 8'd0;
      dwell_remaining   <= 12'd0;
      startup_remaining <= 9'd0;
      divider_state     <= DIVIDER_SEED;
      first_command     <= 8'd0;
    end else if (load_clear || !enable || !rom_valid) begin
      busy              <= 1'b0;
      hmc_out           <= 1'b0;
      latched_trigger   <= TRIGGER_NONE;
      current_address   <= 7'd0;
      current_command   <= 8'd0;
      dwell_remaining   <= 12'd0;
      startup_remaining <= 9'd0;
      divider_state     <= DIVIDER_SEED;
    end else if (any_falling) begin
      // Every new falling edge preempts the current effect.  Priority applies
      // only when multiple lines fall on the same system-clock sample.
      busy              <= 1'b1;
      hmc_out           <= 1'b1;
      startup_remaining <= 9'd256;
      divider_state     <= DIVIDER_SEED;

      latched_trigger <= selected_trigger;
      start_address   <= selected_start_address;
      current_address <= selected_start_address;
      current_command <= rom_read_data;
      first_command   <= rom_read_data;
      dwell_period    <= selected_dwell_period;
      dwell_remaining <= selected_dwell_period;
    end else if (oscillator_tick_now && busy) begin
      if (startup_remaining != 9'd0) begin
        // The trigger level is asserted immediately, then held for 256 raw
        // oscillator ticks.  Normal divider sequencing begins on the next CE.
        startup_remaining <= startup_remaining - 9'd1;
      end else if (current_command == 8'd0) begin
        // A zero byte terminates a pass.  It repeats only while the trigger
        // that selected this pass remains asserted.
        if (latched_trigger_low) begin
          current_address <= start_address;
          current_command <= first_command;
          dwell_remaining <= dwell_period;
        end else begin
          busy              <= 1'b0;
          hmc_out           <= 1'b0;
          latched_trigger   <= TRIGGER_NONE;
          dwell_remaining   <= 12'd0;
          startup_remaining <= 9'd0;
          divider_state     <= DIVIDER_SEED;
        end
      end else begin
        // Divider terminal action occurs on the matching raw oscillator tick.
        if (divider_state == current_command[6:0]) begin
          divider_state <= DIVIDER_SEED;
          if (current_command[7]) begin
            noise_state <= next_noise_state;
            hmc_out     <= !next_noise_state[0];
          end else begin
            hmc_out <= !hmc_out;
          end
        end else begin
          divider_state <= divider_advance(divider_state);
        end

        if (dwell_remaining > 12'd1) begin
          dwell_remaining <= dwell_remaining - 12'd1;
        end else if (next_command == 8'd0) begin
          // The final dwell tick, including any terminal action above, belongs
          // to the old command.  The pitch divider is continuous across ROM
          // command and repeat boundaries; only a terminal match or a new
          // external trigger reloads it.
          if (latched_trigger_low) begin
            current_address <= start_address;
            current_command <= first_command;
            dwell_remaining <= dwell_period;
          end else begin
            current_address   <= next_address;
            current_command   <= 8'd0;
            busy              <= 1'b0;
            hmc_out           <= 1'b0;
            latched_trigger   <= TRIGGER_NONE;
            dwell_remaining   <= 12'd0;
            startup_remaining <= 9'd0;
            divider_state     <= DIVIDER_SEED;
          end
        end else begin
          current_address <= next_address;
          current_command <= next_command;
          dwell_remaining <= dwell_period;
        end
      end
    end
  end

endmodule

`default_nettype wire
