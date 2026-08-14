module sm510 (
    input wire clk,

    // Clocked at 32.768kHz
    input wire clk_en,

    input wire reset,
    input wire acl,

    // The type of CPU being implemented
    input wire [3:0] cpu_id,

    // Data for external ROM
    // NOTE: rom_data is expected to be updated with clk_en, and not run at a higher clock
    // Doing so will break this CPU's operation
    input  wire [ 7:0] rom_data,
    output wire [11:0] rom_addr,
    output wire        rom_rd_en,

    // SM511/SM512 melody ROM
    input  wire [7:0] melody_data,
    output wire [7:0] melody_addr,

    // The K1-4 input pins
    input wire [7:0] input_k,
    input wire       input_wake,

    // The BA and Beta input pins
    input wire input_ba,
    input wire input_beta,

    // The H1-4 output pins, as an index
    output wire [1:0] output_lcd_h_index,

    // The S1-8 strobe output pins
    output wire [7:0] output_shifter_s,

    // LCD Segments
    output reg [15:0] segment_a,
    output reg [15:0] segment_b,
    output reg [15:0] segment_c,
    output reg [15:0] segment_bs,

    // LCD Segments SM5a
    output reg [3:0] w_prime[16],
    output reg [3:0] w_main [16],

    // Audio
    output wire [3:0] output_r,

    // Settings
    input wire accurate_lcd_timing,

    // Utility
    output wire divider_1khz,

    // Debug
    output wire [63:0] debug_events,
    output wire [63:0] debug_cpu_state,
    output wire [63:0] debug_melody_state
);
  ////////////////////////////////////////////////////////////////////////////////////////

  wire [7:0] opcode = rom_data;
  reg [7:0] last_opcode = 0;

  wire [3:0] ram_data;

  reg [5:0] last_Pl = 0;

	  wire divider_gamma;
	  wire [3:0] divider_gamma_flags;
	  reg sm5a_acl_gamma = 0;
	  wire gamma = divider_gamma | (cpu_id == 4'd4 && sm5a_acl_gamma);
	  wire [3:0] gamma_flags =
	      divider_gamma_flags | {3'b000, cpu_id == 4'd4 && sm5a_acl_gamma};
	  wire divider_1s_tick;

  wire divider_4hz;
  wire divider_32hz;
  wire divider_64hz;

	  wire [14:0] divider;
	  wire [3:0] divider_count_10ms;

  instructions inst (
      .cpu_id(cpu_id),

      // Data
      .opcode(opcode),
      .last_opcode(last_opcode),
      .melody_data(melody_data),
      .ram_data(ram_data),

	      // Internal
	      .gamma(gamma),
	      .gamma_flags(gamma_flags),
	      .divider(divider),
	      .divider_4hz(divider_4hz),
	      .divider_32hz(divider_32hz),
	      .divider_count_10ms(divider_count_10ms),
	      .last_Pl(last_Pl),

      // IO
      .input_k(input_k),
      .input_beta(input_beta),
      .input_ba(input_ba)
  );

  // CPU families and instruction-clock phases are declared before their first use so the
  // production RTL is accepted by both Quartus and standalone SystemVerilog simulators.
  wire is_sm510 = cpu_id == 0 || cpu_id == 5;
  wire is_sm511_family = cpu_id == 1 || cpu_id == 2 || cpu_id == 6 || cpu_id == 7;
  wire is_sm530 = cpu_id == 3;
  wire is_sm5a = cpu_id == 4;

  // ACL is a CPU reset pin, not a core reset. Its architectural reset work is
  // performed once per assertion while the level itself holds execution.
  reg acl_previous = 0;
  wire acl_assert = acl && !acl_previous;

  always @(posedge clk) begin
    if (reset) begin
      acl_previous <= 0;
    end else begin
      acl_previous <= acl;
    end
  end

  // SM500/SM5A ACL invokes IDIV, whose MAME 0.289 implementation preserves
  // divider bits 5:0. Queue it until the next 32.768kHz divider tick.
  reg sm5a_acl_idiv_pending = 0;
  wire sm5a_acl_idiv = is_sm5a && (acl_assert || sm5a_acl_idiv_pending);

  always @(posedge clk) begin
    if (reset || !is_sm5a) begin
      sm5a_acl_idiv_pending <= 0;
    end else if (clk_en) begin
      sm5a_acl_idiv_pending <= 0;
    end else if (acl_assert) begin
      sm5a_acl_idiv_pending <= 1;
    end
  end

  // SM500/SM5A ACL also sets gamma. Keep that state separate from the base
  // divider so an ordinary ACL never resets divider/gamma on other families.
  always @(posedge clk) begin
    if (reset || !is_sm5a) begin
      sm5a_acl_gamma <= 0;
    end else if (acl_assert) begin
      sm5a_acl_gamma <= 1;
    end else if (clk_en && inst.reset_gamma) begin
      sm5a_acl_gamma <= 0;
    end
  end

  reg sm511_clock_phase = 0;
  reg [1:0] sm530_clock_phase = 0;
  // A normal instruction uses two state-machine phases. SM530 completes those two phases
  // over three oscillator clocks; enabling only once per three clocks would halve the CPU
  // rate relative to its divider and gamma timers.
  wire instr_clk_en = clk_en && !acl &&
      (!is_sm511_family || !inst.sm511_slow_clock || sm511_clock_phase) &&
      (!is_sm530 || sm530_clock_phase != 2'd0);

  assign rom_addr = inst.rom_addr;
  assign rom_rd_en = instr_clk_en;
  assign melody_addr = inst.melody_address;
  assign output_shifter_s = inst.shifter_s;
  assign output_r = inst.output_r;

  ////////////////////////////////////////////////////////////////////////////////////////
  // Divider

  divider div (
      .clk(clk),
      .clk_en(clk_en),

      .reset(reset),

      .cpu_id(cpu_id),

	      .reset_gamma(inst.reset_gamma && !acl),
	      .reset_gamma_mask(acl ? 4'h0 : inst.reset_gamma_mask),
	      .reset_divider(inst.reset_divider && !acl),
	      .reset_divider_keep_6((inst.reset_divider_keep_6 && !acl) || sm5a_acl_idiv),
	      .reset_10ms_counter(inst.reset_10ms_counter && !acl),

	      .gamma(divider_gamma),
	      .gamma_flags(divider_gamma_flags),
	      .divider_1s_tick(divider_1s_tick),

      .divider_4hz(divider_4hz),
      .divider_32hz(divider_32hz),
	      .divider_64hz(divider_64hz),
	      .divider_1khz(divider_1khz),
	      .divider_count_10ms(divider_count_10ms),
	      .divider(divider)
	  );

  ////////////////////////////////////////////////////////////////////////////////////////
  // LCD Strobe

	  wire [15:0] ram_segment_a;
	  wire [15:0] ram_segment_b;
	  wire [15:0] ram_segment_c;
	  wire [ 3:0] ram_sm530_segment_a[16];
	  wire [ 3:0] ram_sm530_segment_b[16];

  // Select the active bit of display memory words in use
  // Comb
  reg  [ 3:0] lcd_h;
  reg  [ 1:0] lcd_h_index = 0;

  assign output_lcd_h_index = lcd_h_index;

  reg prev_strobe_divider = 0;

  always @(posedge clk) begin
    if (reset) begin
      lcd_h_index <= 0;
      prev_strobe_divider <= 0;
      segment_a <= 0;
      segment_b <= 0;
      segment_c <= 0;

      for (int i = 0; i < 16; i += 1) begin
        w_prime[i] <= 0;
        w_main[i]  <= 0;
      end
    end else if (clk_en) begin
      reg temp;
      temp = accurate_lcd_timing ? divider_64hz : divider_1khz;

      prev_strobe_divider <= temp;

      if (temp && ~prev_strobe_divider) begin
        // Strobe LCD
        lcd_h_index <= lcd_h_index + 2'b1;

	        // Copy over segments
	        segment_a <= ram_segment_a;
	        segment_b <= ram_segment_b;
	        segment_c <= ram_segment_c;

	        if (is_sm530) begin
	          integer i;
	          for (i = 0; i < 16; i += 1) begin
	            w_prime[i] <= inst.sm530_display_enabled ? ram_sm530_segment_a[i] : 4'h0;
	            w_main[i]  <= inst.sm530_display_enabled ? ram_sm530_segment_b[i] : 4'h0;
	          end
	        end else begin
	          w_prime <= inst.w_prime;
	          w_main  <= inst.w_main;
	        end
	      end
    end
  end

  always_comb begin
    integer i;
    reg [3:0] temp;
    reg [3:0] blink;
    // TODO: This should also use Y somehow
    for (i = 0; i < 4; i += 1) begin
      lcd_h[i] = lcd_h_index == i;
    end

    segment_bs = 16'h0;

    if (is_sm511_family) begin
      blink = divider_4hz ? inst.segment_y : 4'h0;
      segment_bs[0] = inst.segment_l[lcd_h_index] & ~blink[lcd_h_index];
      segment_bs[1] = inst.segment_x[lcd_h_index];
    end else begin
      // Preserve the existing SM510 behavior: the single BS line is available to
      // every mask column that references it.
      temp = lcd_h & inst.segment_l;
      segment_bs = {16{temp != 0}};
    end
  end

  ////////////////////////////////////////////////////////////////////////////////////////
  // RAM

  wire [6:0] ram_addr_with_masks =
      inst.ram_addr | (inst.temp_sbm ? 7'h40 : 7'h00) | (inst.temp_sabl ? 7'h08 : 7'h00);

  wire [6:0] debug_ram_addr =
      (cpu_id == 4'd3 &&
       (ram_addr_with_masks[6:4] == 3'h6 || ram_addr_with_masks[6:4] == 3'h7) &&
       ram_addr_with_masks[3:0] < 4'd12) ? {1'b0, ram_addr_with_masks[5:0]} :
      ram_addr_with_masks;

  ram ram (
      .clk(clk),
      .reset(reset),

      .cpu_id(cpu_id),

      // While temp_sbm is set, we operate as if the highest bit is high, rather than its current value
      .addr(ram_addr_with_masks),
      .wren(inst.ram_wr && !acl),
      .data(inst.ram_wr_data),
      .q(ram_data),

      .lcd_h(lcd_h_index + 2'h1),
      .segment_a(ram_segment_a),
      .segment_b(ram_segment_b),
      .segment_c(ram_segment_c),
      .sm530_segment_a(ram_sm530_segment_a),
      .sm530_segment_b(ram_sm530_segment_b)
  );

  ////////////////////////////////////////////////////////////////////////////////////////
  // Halt

  reg reset_halt = 0;

  always @(posedge clk) begin
    if (reset || acl) begin
      reset_halt <= 0;
    end else if (clk_en) begin
      reset_halt <= 0;

      if (divider_1s_tick ||
          (is_sm530 && gamma_flags != 4'h0) ||
          (is_sm511_family ? input_wake : (input_k != 8'd0))) begin
        // SM511/SM512 K inputs can wake halt before S has selected a row.
        // SM530 can wake on any pending gamma flag. Older cores keep the
        // existing row-scanned K wake behavior.
        reset_halt <= 1;
      end
    end
  end

  ////////////////////////////////////////////////////////////////////////////////////////
  // Stages

  // LBL xy | TL/TML xyz
  wire is_two_bytes_sm510 = opcode == 8'h5F || opcode[7:4] == 4'h7;

  // LBL xy | CEND/DTA
  wire is_two_bytes_sm5a = opcode == 8'h5F || opcode == 8'h5E;

	  // LBL xy | RME/SME/TMEL/etc. | PRE | TML xyz | TL xyz
	  wire is_two_bytes_sm511 = (opcode >= 8'h5F && opcode <= 8'h61) ||
	      (opcode[7:2] == 6'b011010) || opcode[7:4] == 4'h7;

	  // LBL xy | PRE x | TL xy
	  wire is_two_bytes_sm530 = opcode == 8'h6B || opcode == 8'h78 || (opcode & 8'hF8) == 8'h60;

	  wire is_two_bytes = is_sm5a ? is_two_bytes_sm5a :
	      is_sm530 ? is_two_bytes_sm530 :
	      is_sm511_family ? is_two_bytes_sm511 : is_two_bytes_sm510;
	  // TM x
	  wire is_tm = (is_sm510 || is_sm511_family) && opcode[7:6] == 2'b11;
	  wire is_sm530_trs = is_sm530 && opcode[7:6] == 2'b11;
  // LAX x
	  wire is_lax = is_sm530 ? opcode[7:4] == 4'h1 : opcode[7:4] == 4'h2;

  always @(posedge clk) begin
    if (reset || acl) begin
	      sm511_clock_phase <= 0;
	      sm530_clock_phase <= 0;
	    end else if (clk_en) begin
      if (is_sm511_family && inst.sm511_slow_clock) begin
        sm511_clock_phase <= ~sm511_clock_phase;
      end else begin
        sm511_clock_phase <= 1;
	      end

	      if (is_sm530) begin
	        sm530_clock_phase <= sm530_clock_phase == 2'd2 ? 2'd0 : sm530_clock_phase + 2'd1;
	      end else begin
	        sm530_clock_phase <= 0;
	      end
	    end
	  end

  localparam STAGE_LOAD_PC = 0;
  localparam STAGE_DECODE_PERF_1 = 1;
  localparam STAGE_LOAD_2 = 2;
  localparam STAGE_PERF_3 = 3;
  // TODO: Combine both sets of stages
  localparam STAGE_IDX_FETCH = 4;
  localparam STAGE_IDX_PERF = 5;
  localparam STAGE_HALT = 6;
  localparam STAGE_SKIP = 7;
  localparam STAGE_SKIP_2 = 8;
  localparam STAGE_SKIP_3 = 9;

  reg [3:0] stage = STAGE_LOAD_PC;

  always @(posedge clk) begin
    if (reset || acl) begin
      // rom_data <= 0;

      stage <= STAGE_LOAD_PC;
    end else if (instr_clk_en) begin
      case (stage)
        STAGE_LOAD_PC: begin
          if (inst.halt) begin
            stage <= STAGE_HALT;
          end else if (inst.skip_next_instr || inst.skip_next_if_lax && is_lax) begin
            // Skip
            stage <= STAGE_SKIP;
          end else begin
            stage <= STAGE_DECODE_PERF_1;
          end
        end
        STAGE_DECODE_PERF_1: begin
          stage <= STAGE_LOAD_PC;

	          if (is_tm || is_sm530_trs) begin
            // TMI x. Load IDX data
            stage <= STAGE_IDX_FETCH;
          end else if (is_two_bytes) begin
            // Instruction takes two bytes
            stage <= STAGE_LOAD_2;
          end
        end
        STAGE_LOAD_2: stage <= STAGE_PERF_3;
        STAGE_PERF_3: stage <= STAGE_LOAD_PC;
        STAGE_IDX_FETCH: stage <= STAGE_IDX_PERF;
        STAGE_IDX_PERF: stage <= STAGE_LOAD_PC;
        STAGE_HALT: begin
          if (reset_halt) begin
            stage <= STAGE_LOAD_PC;
          end
        end
        STAGE_SKIP: begin
          stage <= STAGE_LOAD_PC;

          if (is_two_bytes) begin
            // Evaluate for two byte. Since any instruction that sets PC won't leave enough
            // time for the read to occur, we wait until the skip cycle to check
            stage <= STAGE_SKIP_3;
          end
        end
        // Two cycles for the first byte of a two byte skip
        STAGE_SKIP_2: stage <= STAGE_LOAD_PC;
        STAGE_SKIP_3: stage <= STAGE_SKIP_2;
      endcase
    end
  end

  ////////////////////////////////////////////////////////////////////////////////////////
  // Debug

  reg [63:0] debug_seen = 64'd0;
  reg [11:0] debug_last_pc = 12'd0;
  reg [ 7:0] debug_last_opcode = 8'd0;
  reg [ 3:0] debug_last_stage = 4'd0;
  reg [ 7:0] debug_last_melody_address = 8'd0;
  reg [ 3:0] debug_last_output_r = 4'd0;
  reg [ 6:0] debug_last_ram_wr_addr = 7'd0;
  reg [ 3:0] debug_last_ram_wr_data = 4'd0;
  reg [ 3:0] debug_last_ram_rd_data = 4'd0;

  wire [7:0] debug_cpu_row0 = {cpu_id, stage};
  wire [7:0] debug_cpu_row1 = inst.pc[11:4];
  wire [7:0] debug_cpu_row2 = {inst.pc[3:0], opcode[7:4]};
  wire [7:0] debug_cpu_row3 = {opcode[3:0], inst.Acc};
  wire [7:0] debug_cpu_row4 = {inst.carry, inst.Bm, inst.Bl};
  wire [7:0] debug_cpu_row5 = is_sm530 ? input_k : {input_k[3:0], inst.output_r};
  wire [7:0] debug_cpu_row6 = is_sm530 ? {inst.ram_wr, debug_last_ram_wr_addr} : inst.shifter_s;
  wire [7:0] debug_cpu_row7 = is_sm530 ? {debug_last_ram_wr_data, debug_last_ram_rd_data} : {
    instr_clk_en,
    inst.halt,
    reset_halt,
    gamma,
    divider_4hz,
    divider_32hz,
    divider_64hz,
    divider_1s_tick
  };

  wire [7:0] debug_melody_row0 = inst.melody_address;
  wire [7:0] debug_melody_row1 = melody_data;
  wire [7:0] debug_melody_row2 = {inst.melody_rd, inst.melody_step_count, inst.melody_rd[0]};
  wire [7:0] debug_melody_row3 = {inst.melody_duty_index, inst.melody_duty_count, inst.sm511_slow_clock};
  wire [7:0] debug_melody_row4 = {inst.output_r, inst.stored_output_r};
  wire [7:0] debug_melody_row5 = {
    inst.melody_active_tone_next,
    inst.melody_target_cycles_next,
    inst.melody_rd[0],
    inst.output_r[0]
  };
  wire [7:0] debug_melody_row6 = divider[14:7];
  wire [7:0] debug_melody_row7 = {divider[6:0], gamma};

  assign debug_events = debug_seen;
  assign debug_cpu_state = {
    debug_cpu_row7,
    debug_cpu_row6,
    debug_cpu_row5,
    debug_cpu_row4,
    debug_cpu_row3,
    debug_cpu_row2,
    debug_cpu_row1,
    debug_cpu_row0
  };
  assign debug_melody_state = {
    debug_melody_row7,
    debug_melody_row6,
    debug_melody_row5,
    debug_melody_row4,
    debug_melody_row3,
    debug_melody_row2,
    debug_melody_row1,
    debug_melody_row0
  };

  always @(posedge clk) begin
    if (reset) begin
      debug_seen <= 64'd0;
      debug_last_pc <= 12'd0;
      debug_last_opcode <= 8'd0;
      debug_last_stage <= 4'd0;
      debug_last_melody_address <= 8'd0;
      debug_last_output_r <= 4'd0;
      debug_last_ram_wr_addr <= 7'd0;
      debug_last_ram_wr_data <= 4'd0;
      debug_last_ram_rd_data <= 4'd0;
    end else if (clk_en) begin
      debug_last_pc <= inst.pc;
      debug_last_opcode <= opcode;
      debug_last_stage <= stage;
      debug_last_melody_address <= inst.melody_address;
      debug_last_output_r <= inst.output_r;
      debug_last_ram_rd_data <= ram_data;

      if (inst.ram_wr) begin
        debug_last_ram_wr_addr <= debug_ram_addr;
        debug_last_ram_wr_data <= inst.ram_wr_data;
      end

      debug_seen[0]  <= debug_seen[0]  | 1'b1;
      debug_seen[1]  <= debug_seen[1]  | is_sm511_family;
      debug_seen[2]  <= debug_seen[2]  | (cpu_id == 4'd1);
      debug_seen[3]  <= debug_seen[3]  | (cpu_id == 4'd2);
      debug_seen[4]  <= debug_seen[4]  | (cpu_id == 4'd6);
      debug_seen[5]  <= debug_seen[5]  | (cpu_id == 4'd7);
      debug_seen[6]  <= debug_seen[6]  | instr_clk_en;
      debug_seen[7]  <= debug_seen[7]  | (inst.pc != debug_last_pc);

      debug_seen[8]  <= debug_seen[8]  | (stage == STAGE_LOAD_PC);
      debug_seen[9]  <= debug_seen[9]  | (stage == STAGE_DECODE_PERF_1);
      debug_seen[10] <= debug_seen[10] | (stage == STAGE_LOAD_2);
      debug_seen[11] <= debug_seen[11] | (stage == STAGE_PERF_3);
      debug_seen[12] <= debug_seen[12] | (stage == STAGE_IDX_FETCH);
      debug_seen[13] <= debug_seen[13] | (stage == STAGE_IDX_PERF);
      debug_seen[14] <= debug_seen[14] | (stage == STAGE_HALT);
      debug_seen[15] <= debug_seen[15] | reset_halt;

      debug_seen[16] <= debug_seen[16] | (opcode == 8'h60);
      debug_seen[17] <= debug_seen[17] | (opcode == 8'h61);
      debug_seen[18] <= debug_seen[18] | (stage == STAGE_PERF_3 && last_opcode == 8'h60);
      debug_seen[19] <= debug_seen[19] | (stage == STAGE_PERF_3 && last_opcode == 8'h61);
      debug_seen[20] <= debug_seen[20] | (stage == STAGE_PERF_3 && last_opcode == 8'h60 && opcode == 8'h31);
      debug_seen[21] <= debug_seen[21] | (stage == STAGE_PERF_3 && last_opcode == 8'h60 && opcode == 8'h30);
      debug_seen[22] <= debug_seen[22] | (stage == STAGE_PERF_3 && last_opcode == 8'h60 && opcode == 8'h32);
      debug_seen[23] <= debug_seen[23] | (stage == STAGE_PERF_3 && last_opcode == 8'h61);

      debug_seen[24] <= debug_seen[24] | inst.melody_rd[0];
      debug_seen[25] <= debug_seen[25] | inst.melody_rd[1];
      debug_seen[26] <= debug_seen[26] | (inst.melody_address != debug_last_melody_address);
      debug_seen[27] <= debug_seen[27] | (melody_data != 8'd0);
      debug_seen[28] <= debug_seen[28] | (inst.output_r != 4'd0);
      debug_seen[29] <= debug_seen[29] | (inst.output_r[0] != debug_last_output_r[0]);
      debug_seen[30] <= debug_seen[30] | (is_sm511_family && !inst.sm511_slow_clock);
      debug_seen[31] <= debug_seen[31] | (is_sm511_family && inst.sm511_slow_clock);

      debug_seen[32] <= debug_seen[32] | (input_k != 8'd0);
      debug_seen[33] <= debug_seen[33] | input_ba;
      debug_seen[34] <= debug_seen[34] | input_beta;
      debug_seen[35] <= debug_seen[35] | (inst.shifter_s != 8'd0);
      debug_seen[36] <= debug_seen[36] | (inst.segment_l != 4'd0);
      debug_seen[37] <= debug_seen[37] | (inst.segment_x != 4'd0);
      debug_seen[38] <= debug_seen[38] | (inst.segment_y != 4'd0);
      debug_seen[39] <= debug_seen[39] | inst.ram_wr;

      debug_seen[40] <= debug_seen[40] | (stage == STAGE_DECODE_PERF_1 && opcode == 8'h50);
      debug_seen[41] <= debug_seen[41] | (stage == STAGE_DECODE_PERF_1 && opcode == 8'h51);
      debug_seen[42] <= debug_seen[42] | (stage == STAGE_DECODE_PERF_1 && opcode == 8'h5E);
      debug_seen[43] <= debug_seen[43] | (stage == STAGE_DECODE_PERF_1 && opcode == 8'h58);
      debug_seen[44] <= debug_seen[44] | (stage == STAGE_DECODE_PERF_1 && opcode == 8'h62);
      debug_seen[45] <= debug_seen[45] | (stage == STAGE_DECODE_PERF_1 && opcode == 8'h63);
      debug_seen[46] <= debug_seen[46] | (stage == STAGE_DECODE_PERF_1 && is_sm511_family && opcode == 8'h6D);
      debug_seen[47] <= debug_seen[47] | (inst.shifter_w != 8'd0);

      debug_seen[48] <= debug_seen[48] | (inst.pc != 12'h370);
      debug_seen[49] <= debug_seen[49] | (opcode != debug_last_opcode);
      debug_seen[50] <= debug_seen[50] | (stage != debug_last_stage);
      debug_seen[51] <= debug_seen[51] | inst.skip_next_instr;
      debug_seen[52] <= debug_seen[52] | inst.skip_next_if_lax;
      debug_seen[53] <= debug_seen[53] | inst.temp_sbm;
      debug_seen[54] <= debug_seen[54] | inst.halt;
      debug_seen[55] <= debug_seen[55] | (inst.output_r[0] != debug_last_output_r[0]);
    end
  end

	  // Internal
	  reg last_temp_sbm = 0;
	  reg last_temp_sabl = 0;

  // Decoder

  task sm510_decode();
    casex (opcode)
      8'h00: begin
        // SKIP. NOP
      end
      8'h01: inst.atbp();  // ATBP. Set LCD BP to Acc
      8'h02: inst.sbm();  // SBM. Set high bit of Bm high for next instruction only
      8'h03: inst.atpl();  // ATPL. Load Pl with Acc
      8'b0000_01XX: inst.rm();  // 0x04-07: RM x. Zero RAM at bit indexed by immediate
      8'h08: inst.add();  // ADD. Add RAM to Acc
      8'h09: inst.add11();  // ADD11. Add RAM to Acc with carry. Skip next inst if carry
      8'h0A: inst.coma();  // COMA. NOT Acc (complement Acc)
      8'h0B: inst.exbla();  // EXBLA. Swap Acc and Bl
      8'b0000_11XX: inst.sm();  // 0x0C-0F: SM x. Set RAM at bit indexed by immediate
      8'b0001_00XX: begin
        // All opcodes that call a task must be replicated inline due to a Quartus bug that just silently drops
        // nested tasks inside of interfaces

        // inst.exc();  // 0x10-13: EXC x. Swap Acc and RAM. XOR Bm with immed
        inst.exc_x(1);
      end
      8'b0001_01XX: begin
        // inst.exci();  // 0x14-17: EXCI x. Swap Acc/RAM. XOR Bm with immed. Inc Bl
        inst.exc_x(1);
        inst.incb();
      end
      8'b0001_10XX: begin
        // inst.lda();  // 0x18-1B: LDA x. Load Acc with RAM value. XOR Bm with immed
        inst.exc_x(0);
      end
      8'b0001_11XX: begin
        // inst.excd();  // 0x1C-1F: EXCD x. Swap Acc/RAM. XOR Bm with immed. Dec Bl
        inst.exc_x(1);
        inst.decb();
      end
      8'h2X: inst.lax();  // LAX x. Load Acc with immed. If next instruction is LAX, skip it
      8'h3X: inst.adx();  // ADX x. Add immed to Acc. Skip next instruction if carry is set
      8'h4X: inst.lb();  // LB x. Low Bm to immed. Low Bl to immed. High Bl to OR immed
      // 0x50 unused
      8'h51: inst.tb();  // TB. Skip next instruction if Beta is 1
      8'h52: inst.tc();  // TC. Skip next instruction if C = 0
      8'h53: inst.tam();  // TAM. Skip next instruction if Acc = RAM value
      8'b0101_01XX: inst.tmi();  // TMI x. Skip next instruction if indexed memory bit is set
      8'h58: inst.tis();  // TIS. Skip next inst if 1sec divider signal is low. Zero gamma
      8'h59: inst.atl();  // ATL. Set segment output L to Acc
      8'h5A: inst.tao();  // TAO. Skip next instruction if Acc = 0
      8'h5B: inst.tabl();  // TABL. Skp next instruction if Acc = Bl
      // 0x5C unused
      8'h5D: inst.cend();  // CEND. Stop clock
      8'h5E: inst.tal();  // TAL. Skip next instruction if BA = 1
      8'h5F: begin
        // LBL xy (2 byte)
        // Do nothing here. Entirely done in second stage
      end
      8'h60: inst.atfc();  // ATFC. Set segment output Y to Acc
      8'h61: inst.atr();  // ATR. Set R buzzer control value to the bottom two bits of Acc
      8'h62: inst.wr();  // WR. Shift 0 into W
      8'h63: inst.ws();  // WS. Shift 1 into W
      8'h64: inst.incb();  // INCB. Increment Bl. If Bl was 0xF, skip next
      8'h65: inst.idiv();  // IDIV. Reset clock divider
      8'h66: inst.rc();  // RC. Clear carry
      8'h67: inst.sc();  // SC. Set carry
      8'h68: inst.tf1();  // TF1. Skip next instruction if F1 = 1 (clock divider 14th bit)
      8'h69: inst.tf4();  // TF4. Skip next instruction if F4 = 1 (clock divider 11th bit)
      8'h6A: inst.kta();  // KTA. Read K input bits into Acc
      8'h6B: inst.rot();  // ROT. Rotate right
      8'h6C: inst.decb();  // DECB. Decrement Bl. If Bl was 0x0, skip next
      8'h6D: inst.bdc();  // BDC. Set LCD power. Display is on when low
      8'h6E: begin
        // inst.rtn0();  // RTN0. Pop stack. Move S into PC, and R into S
        inst.pop_stack(1);
      end
      8'h6F: begin
        // inst.rtn1();  // RTN1. Pop stack. Move S into PC, and R into S. Skip next inst
        inst.pop_stack(1);

        inst.skip_next_instr <= 1;
      end
      8'h7X: begin
        // TL/TML xyz
        // Do nothing here. Entirely done in second stage
      end
      8'b10XX_XXXX: inst.t();  // T xy. Short jump, within page. Set Pl to immediate
      8'b11XX_XXXX: begin
        // inst.tm();  // TM x. JP to IDX table, and executes that inst. Push PC + 1
        inst.push_stack(inst.pc);

        {inst.Pu, inst.Pm, inst.Pl} <= {2'b0, 4'b0, opcode[5:0]};
      end
    endcase
  endtask

	  task sm511_decode();
    casex (opcode)
      8'h00: inst.rot();  // ROT. Rotate right
      // 0x01 is documented by MAME as DTA, with some uncertainty around exact divider bits
      8'h01: inst.dta();  // DTA. Copy high bits of clock divider to Acc
      8'h02: inst.sbm();  // SBM. Set high bit of Bm high for next instruction only
      8'h03: inst.atpl();  // ATPL. Load Pl with Acc
      8'b0000_01XX: inst.rm();  // 0x04-07: RM x. Zero RAM at bit indexed by immediate
      8'h08: inst.add();  // ADD. Add RAM to Acc
      8'h09: inst.add11();  // ADD11. Add RAM to Acc with carry. Skip next inst if carry
      8'h0A: inst.coma();  // COMA. NOT Acc (complement Acc)
      8'h0B: inst.exbla();  // EXBLA. Swap Acc and Bl
      8'b0000_11XX: inst.sm();  // 0x0C-0F: SM x. Set RAM at bit indexed by immediate
      8'b0001_00XX: begin
        inst.exc_x(1);
      end
      8'b0001_01XX: begin
        inst.exc_x(1);
        inst.incb();
      end
      8'b0001_10XX: begin
        inst.exc_x(0);
      end
      8'b0001_11XX: begin
        inst.exc_x(1);
        inst.decb();
      end
      8'h2X: inst.lax();  // LAX x. Load Acc with immed. If next instruction is LAX, skip it
      8'h3X: inst.adx();  // ADX x. Add immed to Acc. Skip next instruction if carry is set
      8'h4X: inst.lb();  // LB x. Low Bm to immed. Low Bl to immed. High Bl to OR immed
      8'h50: inst.kta();  // KTA. Read K input bits into Acc
      8'h51: inst.tb();  // TB. Skip next instruction if Beta is 1
      8'h52: inst.tc();  // TC. Skip next instruction if C = 0
      8'h53: inst.tam();  // TAM. Skip next instruction if Acc = RAM value
      8'b0101_01XX: inst.tmi();  // TMI x. Skip next instruction if indexed memory bit is set
      8'h58: inst.tis();  // TIS. Skip next inst if 1sec divider signal is low. Zero gamma
      8'h59: inst.atl();  // ATL. Set segment output L to Acc
      8'h5A: inst.tao();  // TAO. Skip next instruction if Acc = 0
      8'h5B: inst.tabl();  // TABL. Skp next instruction if Acc = Bl
      8'h5C: inst.atx();  // ATX. Set segment output X to Acc
      8'h5D: inst.cend();  // CEND. Stop clock
      8'h5E: inst.tal();  // TAL. Skip next instruction if BA = 1
      8'h5F: begin
        // LBL xy (2 byte). Entirely done in second stage.
      end
      8'h60: begin
        // Extended opcode prefix. Entirely done in second stage.
      end
      8'h61: begin
        // PRE x (2 byte). Entirely done in second stage.
      end
      8'h62: inst.wr();  // WR. Shift 0 into W
      8'h63: inst.ws();  // WS. Shift 1 into W
      8'h64: inst.incb();  // INCB. Increment Bl. If Bl was 0xF, skip next
      8'h65: inst.idiv();  // IDIV. Reset clock divider
      8'h66: inst.rc();  // RC. Clear carry
      8'h67: inst.sc();  // SC. Set carry
      8'b0110_10XX: begin
        // TML xyz (2 byte). Entirely done in second stage.
      end
      8'h6C: inst.decb();  // DECB. Decrement Bl. If Bl was 0x0, skip next
      8'h6D: inst.ptw_s();  // PTW. Latch W to S output
      8'h6E: begin
        inst.pop_stack(1);
      end
      8'h6F: begin
        inst.pop_stack(1);
        inst.skip_next_instr <= 1;
      end
      8'h7X: begin
        // TL xyz (2 byte). Entirely done in second stage.
      end
      8'b10XX_XXXX: inst.t();  // T xy. Short jump, within page. Set Pl to immediate
      8'b11XX_XXXX: begin
        // TM x. Jump to IDX table, then execute that instruction. Push PC + 1.
        inst.push_stack(inst.pc);

        {inst.Pu, inst.Pm, inst.Pl} <= {2'b0, 4'b0, opcode[5:0]};
      end
    endcase
	  endtask

	  task sm530_decode();
	    casex (opcode)
	      8'h0X: inst.adx_sm530();  // ADX x. Add immed to Acc. Skip next on carry
	      8'h1X: inst.lax();  // LAX x. Load Acc with immed. If next instruction is LAX, skip it
	      8'b0010_00XX: begin
	        inst.exc_x(0);  // LDA x. Load Acc with RAM value. XOR Bm with immed
	      end
	      8'b0010_01XX: begin
	        inst.exc_x(1);  // EXC x. Swap Acc and RAM. XOR Bm with immed
	      end
	      8'b0010_10XX: begin
	        inst.exc_x(1);  // EXCI x
	        inst.incb_sm530();
	      end
	      8'b0010_11XX: begin
	        inst.exc_x(1);  // EXCD x
	        inst.decb();
	      end
	      8'h3X: inst.lb_sm530();  // LB x
	      8'b0100_00XX: inst.rm();  // RM x. Zero RAM bit
	      8'b0100_01XX: inst.sm();  // SM x. Set RAM bit
	      8'b0100_10XX: inst.tmi();  // TM x. Skip if indexed memory bit is set
	      8'h4C: inst.incb_sm530();  // INCB. Increment Bl. Overflow on bit 3
	      8'h4D: inst.decb();  // DECB. Decrement Bl
	      8'h4E: inst.rds();  // RDS. Disable display
	      8'h4F: inst.sds();  // SDS. Enable display
	      8'h50: inst.kta();  // KTA. Read K low nibble into Acc
	      8'h51: inst.keta();  // KETA. Read K high nibble into Acc
	      8'h52: inst.dta_sm530();  // DTA. Copy 1/100s counter to Acc
	      8'h53: inst.coma();  // COMA. NOT Acc
	      8'h54: inst.add();  // ADD. Add RAM to Acc
	      8'h55: inst.add11();  // ADDC. Add RAM and carry to Acc
	      8'h56: inst.rc();  // RC. Clear carry
	      8'h57: inst.sc();  // SC. Set carry
	      8'h58: inst.tabl();  // TABL. Skip if Acc = Bl
	      8'h59: inst.tam();  // TAM. Skip if Acc = RAM
	      8'h5A: inst.exbla();  // EXBL. Swap Acc and Bl
	      8'h5B: inst.tc();  // TC. Skip if C = 0
	      8'h5C: inst.ats();  // ATS. Output Acc to S
	      8'h5D: inst.atf();  // ATF. Output Acc to F
	      8'h5E: inst.atbp();  // ATBP. Set BP to Acc
	      8'b0110_0XXX: begin
	        // TL xy (2 byte). Entirely done in second stage.
	      end
	      8'h68: begin
	        inst.pop_stack(1);  // RTN
	      end
	      8'h69: begin
	        inst.pop_stack(1);  // RTNS
	        inst.skip_next_instr <= 1;
	      end
	      8'h6A: inst.atpl();  // ATPL. Load Pl with Acc
	      8'h6B: begin
	        // LBL xy (2 byte). Entirely done in second stage.
	      end
	      8'b0110_11XX: inst.tg();  // TG x. Test/reset gamma flag
	      8'h70: inst.idiv();  // IDIV. Reset divider
	      8'h71: inst.inis();  // INIS. Reset 1/100s counter
	      8'h72: inst.sbm();  // SABM. Set high bit of Bm for next instruction
	      8'h73: inst.sabl();  // SABL. Set high bit of Bl for next instruction
	      8'h74: inst.cend();  // CEND. Stop clock
	      8'h75: inst.tmel();  // TMEL. Test melody stop flag
	      8'h76: inst.rme();  // RME. Disable melody
	      8'h77: inst.sme();  // SME. Enable melody
	      8'h78: begin
	        // PRE x (2 byte). Entirely done in second stage.
	      end
	      8'h79: inst.tal();  // TBA. Skip if BA = 1
	      8'b10XX_XXXX: inst.t();  // TR x. Short jump in current page
	      8'b11XX_XXXX: begin
	        // TRS x. Indirect subroutine call through page 14.
	        inst.push_stack(inst.pc);
	        {inst.Pu, inst.Pm, inst.Pl} <= {2'b00, 4'hE, opcode[5:0]};
	      end
	    endcase
	  endtask

	  task sm5a_decode();
    reg [3:0] w_length;
    reg trs_field;

    w_length  = 4'h9;
    trs_field = 1;

    casex (opcode)
      8'h00: begin
        // SKIP. NOP
      end
      8'h01: inst.atr();  // ATR. Set R buzzer control value to Acc
      8'h02: inst.sbm_sm500();  // SBM. Set high bit of Bm high
      8'h03: inst.atbp();  // ATBP. Set LCD BP to Acc
      8'b0000_01XX: inst.rm();  // 0x04-07: RM x. Zero RAM at bit indexed by immediate
      8'h08: inst.add();  // ADD. Add RAM to Acc
      8'h09: inst.add11();  // ADD11. Add RAM to Acc with carry. Skip next inst if carry
      8'h0A: inst.coma();  // COMA. NOT Acc (complement Acc)
      8'h0B: inst.exbla();  // EXBLA. Swap Acc and Bl
      8'b0000_11XX: inst.sm();  // 0x0C-0F: SM x. Set RAM at bit indexed by immediate
      8'b0001_00XX: begin
        // 0x10-13: EXC x. Swap Acc and RAM. XOR Bm with immed
        inst.exc_x(1);
      end
      8'b0001_01XX: begin
        // 0x14-17: EXCI x. Swap Acc/RAM. XOR Bm with immed. Inc Bl
        inst.exc_x(1);
        inst.incb_sm500();
      end
      8'b0001_10XX: begin
        // 0x18-1B: LDA x. Load Acc with RAM value. XOR Bm with immed
        inst.exc_x(0);
      end
      8'b0001_11XX: begin
        // 0x1C-1F: EXCD x. Swap Acc/RAM. XOR Bm with immed. Dec Bl
        inst.exc_x(1);
        inst.decb();
      end
      8'h2X: inst.lax();  // LAX x. Load Acc with immed. If next instruction is LAX, skip it
      8'h3X: inst.adx();  // ADX x. Add immed to Acc. Skip next instruction if carry is set
      8'h4X: inst.lb_sm500();  // LB x. Low Bm to immed. Low Bl to immed. High Bl to 2 if data
      8'h50: inst.tal();  // TAL. Skip next instruction if BA set
      8'h51: inst.tb();  // TB. Skip next instruction if Beta is 1
      8'h52: inst.tc();  // TC. Skip next instruction if C = 0
      8'h53: inst.tam();  // TAM. Skip next instruction if Acc = RAM value
      8'b0101_01XX: inst.tmi();  // TMI x. Skip next instruction if indexed memory bit is set
      8'h58: inst.tis();  // TIS. Skip next inst if 1sec divider signal is low. Zero gamma
      8'h59: inst.ptw(w_length);  // PTW. Copy last two values from W' to W
      8'h5A: inst.tao();  // TAO. Skip next instruction if Acc = 0
      8'h5B: inst.tabl();  // TABL. Skp next instruction if Acc = Bl
      8'h5C: inst.tw(w_length);  // TW. Copy W' to W
      8'h5D: begin
        // DTW. Shift PLA value into W'
        reg [3:0] digit;
        digit = inst.pla_digit();

        inst.shift_w_prime(w_length, digit);
      end
      // TODO: 0x5E
      8'h5F: begin
        // LBL xy (2 byte)
        // Do nothing here. Entirely done in second stage
      end
      8'h60: inst.comcn();  // COMCN. XOR (complement) LCD CN flag
      8'h61: begin
        // PDTW. Shift last two nibbles of W', moving one PLA value in
        reg [3:0] w_prime_temp[16];
        reg [3:0] digit;

        digit = inst.pla_digit();
        w_prime_temp = inst.w_prime;

        w_prime_temp[w_length-2] = w_prime_temp[w_length-1];
        w_prime_temp[w_length-1] = digit;

        inst.w_prime <= w_prime_temp;
      end
      8'h62: begin
        // WR. Shift Acc (0 high bit) into W'
        inst.shift_w_prime(w_length, inst.Acc & 4'h7);
      end
      8'h63: begin
        // WS. Shift Acc (1 high bit) into W'
        inst.shift_w_prime(w_length, inst.Acc | 4'h8);
      end
      8'h64: inst.incb_sm500();  // INCB. Increment Bl. If Bl was 0x7, skip next
      8'h65: inst.idiv_sm500();  // IDIV. Reset clock divider, keeping lower 6 bits
      8'h66: inst.rc();  // RC. Clear carry
      8'h67: inst.sc();  // SC. Set carry
      8'h68: inst.rmf();  // RMF. Clear m' and Acc
      8'h69: inst.smf();  // SMF. Set m'
      8'h6A: inst.kta();  // KTA. Read K input bits into Acc
      8'h6B: inst.rbm();  // RBM. Clear Bm high bit
      8'h6C: inst.decb();  // DECB. Decrement Bl. If Bl was 0x0, skip next
      8'h6D: inst.comcb();  // COMCB. XOR (complement) CB
      8'h6E: begin
        // inst.rtn0();  // RTN0. Pop stack. Move S into PC, and R into S
        inst.pop_stack(0);

        inst.within_subroutine <= 0;
      end
      8'h6F: begin
        // inst.rtn1();  // RTN1. Pop stack. Move S into PC, and R into S. Skip next inst
        inst.pop_stack(0);

        inst.skip_next_instr   <= 1;
        inst.within_subroutine <= 0;
      end
      8'h7X: inst.ssr();  // SSR. Set stack higher bits to immed. Set E for next inst
      8'b10XX_XXXX: inst.tr();  // TR. Long/short jump. Uses stack page value for distance
      8'b11XX_XXXX: begin
        // TRS. Call subroutine
        if (inst.within_subroutine) begin
          inst.Pl <= {2'b0, opcode[3:0]};
          inst.Pm[1:0] <= opcode[5:4];
          // pc[11:8] <= pc[11:8];
          // pc[7:6] <= opcode[5:4];
          // pc[5:4] <= 0;
          // pc[3:0] <= opcode[3:0];
        end else begin
          // Enter subroutine
          reg [3:0] temp_su;

          inst.within_subroutine <= 1;

          temp_su = inst.stack_s[9:6];

          inst.push_stack(inst.pc);

          if (last_opcode[7:4] == 4'h7) begin
            // Last instruction was SSR, and E flag would be set
            {inst.Pu, inst.Pm, inst.Pl} <= {1'b0, inst.cb_bank, temp_su, opcode[5:0]};
          end else begin
            {inst.Pu, inst.Pm, inst.Pl} <= {1'b0, trs_field, 4'b0, opcode[5:0]};
          end
        end
      end
    endcase
  endtask

  // PC increment only changes Pl
  // TODO: Is this correct, it doesn't match MAME?
  wire [11:0] pc_inc = {inst.Pu, inst.Pm, inst.Pl[0] == inst.Pl[1], inst.Pl[5:1]};

  always @(posedge clk) begin
    if (reset) begin
      // WARNING: Reset must be high for greater than one cycle so that data can cascade through
      // some registers initial states

      // Initial PC to 3_7_0
	      case (cpu_id)
	        3:       {inst.Pu, inst.Pm, inst.Pl} <= {2'h0, 4'hF, 6'b0};  // SM530
	        4:       {inst.Pu, inst.Pm, inst.Pl} <= {2'h0, 4'hF, 6'b0};  // SM5a
	        default: {inst.Pu, inst.Pm, inst.Pl} <= {2'h3, 4'h7, 6'b0};  // SM510
	      endcase

      inst.stack_s <= 0;
      inst.stack_r <= 0;

      inst.Acc <= 0;
      inst.carry <= 0;

      inst.lcd_bp <= 0;
      inst.lcd_bc <= 0;

      inst.segment_l <= 0;
      inst.segment_y <= 0;
      inst.segment_x <= 0;

      inst.shifter_w <= 0;
      inst.shifter_s <= 0;

      // Control
      inst.skip_next_instr <= 0;
      inst.skip_next_if_lax <= 0;

	      inst.temp_sbm  <= 0;
	      inst.temp_sabl <= 0;

      inst.next_ram_addr <= 0;
      inst.wr_next_ram_addr <= 0;

	      inst.reset_divider <= 0;
	      inst.reset_divider_keep_6 <= 0;
	      inst.reset_gamma <= 0;
	      inst.reset_gamma_mask <= 0;
	      inst.reset_10ms_counter <= 0;

      inst.halt <= 0;

      // RAM
      {inst.Bm, inst.Bl} <= 7'h0;

      inst.ram_wr <= 0;
      inst.ram_wr_data <= 0;

      // Internal
      last_Pl <= 0;

      last_opcode <= 0;
	      last_temp_sbm  <= 0;
	      last_temp_sabl <= 0;

	      inst.output_r <= 0;
	      inst.output_f <= 0;
      inst.sm511_slow_clock <= 1;
      inst.melody_rd <= 0;
      inst.melody_step_count <= 0;
      inst.melody_duty_count <= 0;
      inst.melody_duty_index <= 0;
      inst.melody_address <= 0;
      inst.melody_active_tone <= 0;
      inst.melody_target_cycles <= 0;

      case (cpu_id)
	        1, 2, 3, 6, 7: begin
	          // SM511/SM512/SM530
	          inst.stored_output_r <= 0;
	          inst.output_r_mask <= 3'h7;
        end
        4: begin
          // SM5a
          inst.stored_output_r <= 4'hF;

          inst.output_r_mask <= 3'h7;

          inst.stack_s <= inst.pc;
        end
        5: begin
          // SM510 Tiger
          inst.output_r_mask <= 3'h7;
        end
        default: begin
          // SM510
          inst.stored_output_r <= 0;

          // Use divider bit 3 for mask
          inst.output_r_mask <= 3'h2;
        end
      endcase

	      inst.output_r <= 0;
	      inst.sm530_display_enabled <= 1;

      // SM5a
      inst.cb_bank <= 0;

      inst.within_subroutine <= 0;

	      inst.lcd_cn <= 0;
      inst.m_prime <= 0;
      for (int i = 0; i < 16; i += 1) begin
        inst.w_prime[i] <= 0;
        inst.w_main[i]  <= 0;
      end

      inst.init_pla();
    end else if (acl_assert) begin
      // MAME's ACL reset is intentionally narrower than the MiSTer/system
      // reset above. Data RAM, divider state, general registers, stacks, W/S
      // outputs, and LCD data latches survive unless a CPU-family override
      // below explicitly changes them.
      case (cpu_id)
        3, 4:    {inst.Pu, inst.Pm, inst.Pl} <= {2'h0, 4'hF, 6'b0};
        default: {inst.Pu, inst.Pm, inst.Pl} <= {2'h3, 4'h7, 6'b0};
      endcase

      inst.skip_next_instr  <= 0;
      inst.skip_next_if_lax <= 0;
      inst.temp_sbm         <= 0;
      inst.temp_sabl        <= 0;
      inst.halt             <= 0;

      // Discard only the internal deferred-address transaction. Bm/Bl are
      // architectural registers and deliberately retain their current value.
      inst.next_ram_addr    <= {inst.Bm[1:0], inst.Bl};
      inst.wr_next_ram_addr <= 0;
      inst.ram_wr           <= 0;

      // These are one-cycle requests emitted by the interrupted instruction.
      // None may leak through after ACL; SM5A's required IDIV is generated by
      // the dedicated ACL request above.
      inst.reset_divider        <= 0;
      inst.reset_divider_keep_6 <= 0;
      inst.reset_gamma          <= 0;
      inst.reset_gamma_mask     <= 0;
      inst.reset_10ms_counter   <= 0;

      last_Pl        <= 0;
      last_opcode    <= 0;
      last_temp_sbm  <= 0;
      last_temp_sabl <= 0;

      // Base ACL state: LCD on, bleeder off, blink/Y off, and R pins low.
      // SM530 uses its separate display-enable latch and resets BP to zero.
      inst.lcd_bp    <= is_sm530 ? 1'b0 : 1'b1;
      inst.lcd_bc    <= 0;
      inst.segment_y <= 0;
      inst.output_r  <= 0;
      inst.stored_output_r <= is_sm5a ? 4'hF : 4'h0;

      if (is_sm511_family || is_sm530) begin
        // ACL disables melody without clearing the stop flag, address, or
        // phase counters, and restores the slow instruction clock.
        inst.melody_rd[0]   <= 0;
        inst.sm511_slow_clock <= 1;
      end

      if (is_sm530) begin
        inst.sm530_display_enabled <= 1;
      end

      if (is_sm5a) begin
        // SM500/SM5A push the reset-vector PC and reset their control-bank
        // state. Their R control latch becomes active-low 0xf.
        inst.stack_s          <= 12'h3C0;
        inst.cb_bank          <= 0;
        inst.within_subroutine <= 0;
        inst.lcd_cn           <= 0;
      end
    end else if (clk_en) begin
	      inst.reset_divider <= 0;
	      inst.reset_divider_keep_6 <= 0;
	      inst.reset_gamma <= 0;
	      inst.reset_gamma_mask <= 0;
	      inst.reset_10ms_counter <= 0;

      inst.ram_wr <= 0;

      inst.clock_melody();

      if (instr_clk_en) begin
        if (stage == STAGE_LOAD_PC || stage == STAGE_PERF_3 || stage == STAGE_SKIP_3) begin
          // Increment PC
          // For two byte instr (STAGE_PERF_3), PC needs to be incremented for the next instruction,
          // as we already consumed the incremented version, so we need to do it again
          inst.Pl <= pc_inc[5:0];

          // Backup Pl, so operations that change parts of it (ATPL) don't use the incremented version
          last_Pl <= inst.Pl;
        end

        case (stage)
        STAGE_LOAD_PC: begin
          inst.skip_next_instr  <= 0;
          // Continue skipping if previously skipped LAX, and still LAX
          inst.skip_next_if_lax <= inst.skip_next_if_lax && is_lax;
          inst.wr_next_ram_addr <= 0;

	          if (last_temp_sbm) inst.temp_sbm <= 0;
	          if (last_temp_sabl) inst.temp_sabl <= 0;

          if (inst.wr_next_ram_addr) begin
            {inst.Bm[1:0], inst.Bl} <= inst.next_ram_addr;
          end else begin
            // Update address for next time we write
            inst.next_ram_addr <= {inst.Bm[1:0], inst.Bl};
          end
        end
        STAGE_HALT: begin
          // Load PC at 1_0_00
          case (cpu_id)
	            3:       {inst.Pu, inst.Pm, inst.Pl} <= {2'b0, 4'b0, 6'b0};  // SM530
	            4:       {inst.Pu, inst.Pm, inst.Pl} <= {2'b0, 4'b0, 6'b0};  // SM5a
	            default: {inst.Pu, inst.Pm, inst.Pl} <= {2'b1, 4'b0, 6'b0};  // SM510/SM510 Tiger
          endcase

          inst.cb_bank <= 0;

          if (reset_halt) begin
            inst.halt <= 0;
          end
        end
        STAGE_DECODE_PERF_1: begin
	          last_opcode    <= opcode;
	          last_temp_sbm  <= inst.temp_sbm;
	          last_temp_sabl <= inst.temp_sabl;

	          case (cpu_id)
	            1, 2, 6, 7: sm511_decode();  // SM511/SM512
	            3: sm530_decode();
	            4: sm5a_decode();
            default: sm510_decode();  // SM510/SM510 Tiger
          endcase
        end
        STAGE_PERF_3: begin
          casex (last_opcode)
	            8'h60: begin
	              if (is_sm511_family) begin
                // SM511/SM512: Extended opcodes
                casex (opcode)
                  8'h30: inst.rme();  // RME. Disable melody
                  8'h31: inst.sme();  // SME. Enable melody
                  8'h32: inst.tmel();  // TMEL. Skip if melody stop flag is set
                  8'h33: inst.atfc();  // ATFC. Set segment output Y to Acc
                  8'h34: inst.bdc();  // BDC. Set LCD power
                  8'h35: inst.atbp();  // ATBP. Set LCD BP to Acc
                  8'h36: inst.clkhi();  // CLKHI. Select 16.384kHz instruction clock
                  8'h37: inst.clklo();  // CLKLO. Select 8.192kHz instruction clock
                  default: $display("Unknown SM511 extended instruction %h_%h", last_opcode, opcode);
                endcase
	              end else if (is_sm530) begin
	                {inst.Pu, inst.Pm, inst.Pl} <= {
	                  1'b0, last_opcode[2:0], opcode[7:6], opcode[5:0]
	                };
	              end
	            end
	            8'h61: begin
	              if (is_sm511_family) begin
	                inst.pre();  // PRE x. Preset melody ROM address
	              end else if (is_sm530) begin
	                {inst.Pu, inst.Pm, inst.Pl} <= {
	                  1'b0, last_opcode[2:0], opcode[7:6], opcode[5:0]
	                };
	              end
	            end
	            8'b0110_0XXX: begin
	              if (is_sm530) begin
	                // SM530: TL xy uses opcodes 0x60-0x67.
	                {inst.Pu, inst.Pm, inst.Pl} <= {
	                  1'b0, last_opcode[2:0], opcode[7:6], opcode[5:0]
	                };
	              end
	            end
            8'b0110_10XX: begin
              if (is_sm530) begin
                // Only 6B reaches this two-byte range on SM530: LBL xy.
                inst.Bm <= opcode[6:4];
                inst.Bl <= opcode[3:0];
              end else if (is_sm511_family) begin
                // TML xyz (2 byte). Long call. Push PC + 1 into stack registers. Load PC with immediates.
                inst.push_stack(pc_inc);

                {inst.Pu, inst.Pm, inst.Pl} <= {
                  opcode[7:6], {2'b0, last_opcode[1:0]}, opcode[5:0]
                };
              end
            end
            8'h5E: begin
              // SM5a: Extended opcodes
              casex (opcode)
                8'h00: inst.cend();  // CEND. Stop clock
                8'h04: inst.dta();  // DTA. Copy high bits of clock divider to Acc
              endcase
            end
	            8'h5F: begin
	              // LBL xy (2 byte). Immed is only second byte. Set Bm to high 3 bits of immed, and Bl to low 4 immed. Highest bit is unused
	              inst.Bm <= opcode[6:4];
	              inst.Bl <= opcode[3:0];
	            end
	            8'h7X: begin
              if (is_sm530) begin
                // SM530 0x78 is PRE. Keep it in the family-qualified 0x7X
                // arm so the same first byte remains TL on SM510/SM511.
                inst.pre();
              end else if (is_sm511_family) begin
                // SM511/SM512: TL xyz uses the full 0x70-0x7F opcode range.
                {inst.Pu, inst.Pm, inst.Pl} <= {opcode[7:6], last_opcode[3:0], opcode[5:0]};
              end else if (is_sm510) begin
                // Only is TL/TML if SM510
                // This is weird and goes up to 0xA for some reason, so we need the nested checks
                // Notice there is a gap where 0xB is not handled (in the actual CPU)
                if (last_opcode[3:0] < 4'hB) begin
                  // TL xyz (2 byte). Long jump. Load PC with immediates
                  {inst.Pu, inst.Pm, inst.Pl} <= {opcode[7:6], last_opcode[3:0], opcode[5:0]};
                end else if (last_opcode[3:0] >= 4'hC) begin
                  // TML xyz (2 byte). Long call. Push PC + 1 into stack registers. Load PC with immediates
                  // Need to push instruction after this one, so increment again
                  inst.push_stack(pc_inc);

                  {inst.Pu, inst.Pm, inst.Pl} <= {
                    opcode[7:6], {2'b0, last_opcode[1:0]}, opcode[5:0]
                  };
                end else begin
                  $display("Unexpected immediate in TL %h at %h", opcode, inst.pc);
                end
              end
            end
            default: begin
              $display("Unknown instruction in second stage %h_%h", last_opcode, opcode);
            end
          endcase
        end
	        STAGE_IDX_PERF: begin
	          // Prev cycle fetched IDX data. Now set PC
	          if (is_sm530) begin
	            // SM530 TRS vectors live on page 14 and encode page bits as 5,7,6.
	            {inst.Pu, inst.Pm, inst.Pl} <= {
	              1'b0, 2'b00, opcode[5], opcode[7], opcode[6], 1'b0, opcode[4:0]
	            };
	          end else begin
	            {inst.Pu, inst.Pm, inst.Pl} <= {opcode[7:6], 4'h4, opcode[5:0]};
	          end
	        end
        endcase
      end
    end
  end

endmodule
