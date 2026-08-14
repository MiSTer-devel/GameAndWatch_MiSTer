// Sample-backed approximation of the MSM6373 used by a small number of
// SM511 games. The sample bank is downloaded into a private 64 KiB RAM.
//
// Bank layout:
//   0000-000f  "GWAU", version 1, codec 1, 8000 Hz LE, 32 slots,
//              reserved byte, payload size LE, then reserved bytes
//   0010-008f  32 entries: start byte LE (relative to 0100),
//              nibble count LE
//   0100-ffff  high-nibble-first OKI ADPCM payload

// The read and write processes intentionally use the same clock and separate
// ports so Quartus can infer a simple dual-port M10K implementation.
module msm6373_sample (
    input  wire               clk,
    input  wire               reset,

    input  wire               load_clear,
    input  wire               voice_wr,
    input  wire [15:0]        voice_addr,
    input  wire [7:0]         voice_data,

    input  wire               voice_enable,
    input  wire [7:0]         s_out,

    output reg                bank_valid,
    output reg                busy,
    output reg signed [15:0]  sample,

    output reg [4:0]          current_command,
    output reg [15:0]         nibbles_remaining,
    output reg [15:0]         sample_address
);

  localparam [13:0] SAMPLE_DIVIDER_LAST = 14'd12287;

  localparam [3:0] STATE_IDLE            = 4'd0;
  localparam [3:0] STATE_DIR_WAIT        = 4'd1;
  localparam [3:0] STATE_DIR_START_LO    = 4'd2;
  localparam [3:0] STATE_DIR_START_HI    = 4'd3;
  localparam [3:0] STATE_DIR_COUNT_LO    = 4'd4;
  localparam [3:0] STATE_DIR_COUNT_HI    = 4'd5;
  localparam [3:0] STATE_PAYLOAD_WAIT    = 4'd6;
  localparam [3:0] STATE_PAYLOAD_CAPTURE = 4'd7;
  localparam [3:0] STATE_PLAY            = 4'd8;
  localparam [3:0] STATE_TAIL            = 4'd9;
  localparam [3:0] STATE_DIR_VALIDATE    = 4'd10;

  // Quartus recognizes this as a 65536 x 8 simple dual-port RAM. No behavior
  // is required for simultaneous reads and writes to the same location.
  (* ramstyle = "M10K, no_rw_check" *) reg [7:0] voice_ram [0:65535];

  reg [15:0] ram_read_addr;
  reg [7:0]  ram_read_data;

  always @(posedge clk) begin
    if (voice_wr) begin
      voice_ram[voice_addr] <= voice_data;
    end
  end

  always @(posedge clk) begin
    ram_read_data <= voice_ram[ram_read_addr];
  end

  // Header validation is performed as bytes arrive. Payload size is variable,
  // but it may not extend beyond the end of the fixed 64 KiB address space.
  // Package metadata is deliberately independent of playback reset: MiSTer
  // holds playback reset asserted throughout ioctl_download. load_clear marks
  // the start of each new package, while an ordinary core reset must retain
  // the already-downloaded bank.
  reg [15:0] header_seen = 16'd0;
  reg [15:0] header_good = 16'd0;
  reg [15:0] payload_size = 16'd0;
  reg [1:0]  bank_tail_seen = 2'b00;
  initial bank_valid = 1'b0;

  wire header_complete = (&header_seen) && (&header_good) &&
                         (payload_size <= 16'hff00) && (&bank_tail_seen);

  always @(posedge clk) begin
    if (load_clear) begin
      header_seen  <= 16'd0;
      header_good  <= 16'd0;
      payload_size <= 16'd0;
      bank_tail_seen <= 2'b00;
      bank_valid   <= 1'b0;
    end else if (voice_wr && voice_addr <= 16'd15) begin
      // Invalidate immediately while any validated header byte is replaced.
      // It becomes valid again on the following clock if the complete header
      // is present and correct.
      bank_valid <= 1'b0;
    end else begin
      bank_valid <= header_complete;
    end

    // A first header write concurrent with load_clear belongs to the new bank
    // and therefore wins over the cleared metadata at its byte position.
    if (voice_wr) begin
      if (voice_addr == 16'hfffe) bank_tail_seen[0] <= 1'b1;
      if (voice_addr == 16'hffff) bank_tail_seen[1] <= 1'b1;

      case (voice_addr)
        16'd0: begin
          header_seen[0] <= 1'b1;
          header_good[0] <= voice_data == 8'h47; // G
        end
        16'd1: begin
          header_seen[1] <= 1'b1;
          header_good[1] <= voice_data == 8'h57; // W
        end
        16'd2: begin
          header_seen[2] <= 1'b1;
          header_good[2] <= voice_data == 8'h41; // A
        end
        16'd3: begin
          header_seen[3] <= 1'b1;
          header_good[3] <= voice_data == 8'h55; // U
        end
        16'd4: begin
          header_seen[4] <= 1'b1;
          header_good[4] <= voice_data == 8'd1;  // bank version
        end
        16'd5: begin
          header_seen[5] <= 1'b1;
          header_good[5] <= voice_data == 8'd1;  // OKI ADPCM4
        end
        16'd6: begin
          header_seen[6] <= 1'b1;
          header_good[6] <= voice_data == 8'h40; // 8000 LE
        end
        16'd7: begin
          header_seen[7] <= 1'b1;
          header_good[7] <= voice_data == 8'h1f;
        end
        16'd8: begin
          header_seen[8] <= 1'b1;
          header_good[8] <= voice_data == 8'd32;
        end
        16'd9: begin
          header_seen[9] <= 1'b1;
          header_good[9] <= voice_data == 8'd0;
        end
        16'd10: begin
          header_seen[10]    <= 1'b1;
          header_good[10]    <= 1'b1;
          payload_size[7:0]  <= voice_data;
        end
        16'd11: begin
          header_seen[11]    <= 1'b1;
          header_good[11]    <= 1'b1;
          payload_size[15:8] <= voice_data;
        end
        16'd12: begin
          header_seen[12] <= 1'b1;
          header_good[12] <= voice_data == 8'd0;
        end
        16'd13: begin
          header_seen[13] <= 1'b1;
          header_good[13] <= voice_data == 8'd0;
        end
        16'd14: begin
          header_seen[14] <= 1'b1;
          header_good[14] <= voice_data == 8'd0;
        end
        16'd15: begin
          header_seen[15] <= 1'b1;
          header_good[15] <= voice_data == 8'd0;
        end
        default: begin
        end
      endcase
    end
  end

  reg [3:0] state;
  reg       previous_s7;
  reg [7:0] byte_buffer;
  reg       low_nibble;
  reg [13:0] sample_divider;

  reg [7:0] directory_start_lo;
  reg [7:0] directory_start_hi;
  reg [7:0] directory_count_lo;
  reg [7:0] directory_count_hi;

  reg signed [11:0] adpcm_signal;
  reg [5:0]         adpcm_step;
  reg [11:0]        adpcm_step_value;

  wire command_edge = previous_s7 && !s_out[6];

  wire [15:0] directory_start   = {directory_start_hi, directory_start_lo};
  wire [15:0] directory_nibbles = {directory_count_hi, directory_count_lo};
  wire [16:0] directory_bytes   = ({1'b0, directory_nibbles} + 17'd1) >> 1;
  wire [16:0] directory_end     = {1'b0, directory_start} + directory_bytes;
  wire directory_entry_valid = (directory_nibbles != 16'd0) &&
                               (directory_end <= {1'b0, payload_size});

  wire [3:0] decode_nibble = low_nibble ? byte_buffer[3:0] : byte_buffer[7:4];

  function automatic [11:0] oki_step_value(input [5:0] index);
    begin
      case (index)
        6'd0:  oki_step_value = 12'd16;
        6'd1:  oki_step_value = 12'd17;
        6'd2:  oki_step_value = 12'd19;
        6'd3:  oki_step_value = 12'd21;
        6'd4:  oki_step_value = 12'd23;
        6'd5:  oki_step_value = 12'd25;
        6'd6:  oki_step_value = 12'd28;
        6'd7:  oki_step_value = 12'd31;
        6'd8:  oki_step_value = 12'd34;
        6'd9:  oki_step_value = 12'd37;
        6'd10: oki_step_value = 12'd41;
        6'd11: oki_step_value = 12'd45;
        6'd12: oki_step_value = 12'd50;
        6'd13: oki_step_value = 12'd55;
        6'd14: oki_step_value = 12'd60;
        6'd15: oki_step_value = 12'd66;
        6'd16: oki_step_value = 12'd73;
        6'd17: oki_step_value = 12'd80;
        6'd18: oki_step_value = 12'd88;
        6'd19: oki_step_value = 12'd97;
        6'd20: oki_step_value = 12'd107;
        6'd21: oki_step_value = 12'd118;
        6'd22: oki_step_value = 12'd130;
        6'd23: oki_step_value = 12'd143;
        6'd24: oki_step_value = 12'd157;
        6'd25: oki_step_value = 12'd173;
        6'd26: oki_step_value = 12'd190;
        6'd27: oki_step_value = 12'd209;
        6'd28: oki_step_value = 12'd230;
        6'd29: oki_step_value = 12'd253;
        6'd30: oki_step_value = 12'd279;
        6'd31: oki_step_value = 12'd307;
        6'd32: oki_step_value = 12'd337;
        6'd33: oki_step_value = 12'd371;
        6'd34: oki_step_value = 12'd408;
        6'd35: oki_step_value = 12'd449;
        6'd36: oki_step_value = 12'd494;
        6'd37: oki_step_value = 12'd544;
        6'd38: oki_step_value = 12'd598;
        6'd39: oki_step_value = 12'd658;
        6'd40: oki_step_value = 12'd724;
        6'd41: oki_step_value = 12'd796;
        6'd42: oki_step_value = 12'd876;
        6'd43: oki_step_value = 12'd963;
        6'd44: oki_step_value = 12'd1060;
        6'd45: oki_step_value = 12'd1166;
        6'd46: oki_step_value = 12'd1282;
        6'd47: oki_step_value = 12'd1411;
        default: oki_step_value = 12'd1552;
      endcase
    end
  endfunction

  function automatic [5:0] oki_next_step(
      input [5:0] index,
      input [2:0] code
  );
    reg [6:0] increased;
    begin
      if (code < 3'd4) begin
        if (index == 6'd0) begin
          oki_next_step = 6'd0;
        end else begin
          oki_next_step = index - 6'd1;
        end
      end else begin
        case (code)
          3'd4: increased = {1'b0, index} + 7'd2;
          3'd5: increased = {1'b0, index} + 7'd4;
          3'd6: increased = {1'b0, index} + 7'd6;
          default: increased = {1'b0, index} + 7'd8;
        endcase

        if (increased > 7'd48) begin
          oki_next_step = 6'd48;
        end else begin
          oki_next_step = increased[5:0];
        end
      end
    end
  endfunction

  reg signed [13:0] difference;
  reg signed [13:0] signal_sum;
  reg signed [11:0] decoded_signal;
  wire [5:0] decoded_step = oki_next_step(adpcm_step, decode_nibble[2:0]);

  always @* begin
    difference = $signed({2'b00, (adpcm_step_value >> 3)});
    if (decode_nibble[0]) begin
      difference = difference + $signed({2'b00, (adpcm_step_value >> 2)});
    end
    if (decode_nibble[1]) begin
      difference = difference + $signed({2'b00, (adpcm_step_value >> 1)});
    end
    if (decode_nibble[2]) begin
      difference = difference + $signed({2'b00, adpcm_step_value});
    end
    if (decode_nibble[3]) difference = -difference;

    signal_sum = $signed({{2{adpcm_signal[11]}}, adpcm_signal}) + difference;
    if (signal_sum > 14'sd2047) begin
      decoded_signal = 12'sd2047;
    end else if (signal_sum < -14'sd2048) begin
      decoded_signal = 12'sh800;
    end else begin
      decoded_signal = signal_sum[11:0];
    end
  end

  always @(posedge clk) begin
    previous_s7 <= s_out[6];

    if (reset) begin
      state               <= STATE_IDLE;
      ram_read_addr       <= 16'd0;
      busy                <= 1'b0;
      sample              <= 16'sd0;
      current_command     <= 5'd0;
      nibbles_remaining   <= 16'd0;
      sample_address      <= 16'd0;
      byte_buffer         <= 8'd0;
      low_nibble          <= 1'b0;
      sample_divider      <= 14'd0;
      directory_start_lo  <= 8'd0;
      directory_start_hi  <= 8'd0;
      directory_count_lo  <= 8'd0;
      directory_count_hi  <= 8'd0;
      adpcm_signal        <= -12'sd2;
      adpcm_step          <= 6'd0;
      adpcm_step_value    <= 12'd16;
    end else if (load_clear || !voice_enable || !bank_valid || !s_out[7]) begin
      // S8 low is the hardware reset/stop signal and takes priority over a
      // simultaneous S7 command edge.
      state               <= STATE_IDLE;
      busy                <= 1'b0;
      sample              <= 16'sd0;
      current_command     <= 5'd0;
      nibbles_remaining   <= 16'd0;
      sample_address      <= 16'd0;
      low_nibble          <= 1'b0;
      sample_divider      <= 14'd0;
      adpcm_signal        <= -12'sd2;
      adpcm_step          <= 6'd0;
      adpcm_step_value    <= 12'd16;
    end else begin
      if (command_edge) begin
        current_command <= s_out[4:0];
      end

      if (command_edge && busy && (s_out[4:0] == 5'd0)) begin
        // MAME's driver stops a playing sample only for command zero.
        state               <= STATE_IDLE;
        busy                <= 1'b0;
        sample              <= 16'sd0;
        nibbles_remaining   <= 16'd0;
        sample_address      <= 16'd0;
        low_nibble          <= 1'b0;
        sample_divider      <= 14'd0;
        adpcm_signal        <= -12'sd2;
        adpcm_step          <= 6'd0;
        adpcm_step_value    <= 12'd16;
      end else if (command_edge && !busy && (s_out[4:0] != 5'd0)) begin
        // Entry zero is reserved for stop. Commands are direct directory
        // indices, so command one begins at 0x14.
        state               <= STATE_DIR_WAIT;
        ram_read_addr       <= 16'h0010 + {9'd0, s_out[4:0], 2'b00};
        busy                <= 1'b1;
        sample              <= 16'sd0;
        nibbles_remaining   <= 16'd0;
        sample_address      <= 16'd0;
        low_nibble          <= 1'b0;
        sample_divider      <= 14'd0;
        adpcm_signal        <= -12'sd2;
        adpcm_step          <= 6'd0;
        adpcm_step_value    <= 12'd16;
      end else begin
        // Nonzero commands received while busy are deliberately ignored, but
        // the decoder continues advancing on that clock.
        case (state)
          STATE_DIR_WAIT: begin
            ram_read_addr <= ram_read_addr + 16'd1;
            state <= STATE_DIR_START_LO;
          end

          STATE_DIR_START_LO: begin
            directory_start_lo <= ram_read_data;
            ram_read_addr <= ram_read_addr + 16'd1;
            state <= STATE_DIR_START_HI;
          end

          STATE_DIR_START_HI: begin
            directory_start_hi <= ram_read_data;
            ram_read_addr <= ram_read_addr + 16'd1;
            state <= STATE_DIR_COUNT_LO;
          end

          STATE_DIR_COUNT_LO: begin
            directory_count_lo <= ram_read_data;
            state <= STATE_DIR_COUNT_HI;
          end

          STATE_DIR_COUNT_HI: begin
            // Register the final directory byte before doing the bounds
            // arithmetic. This keeps the M10K output out of the compare and
            // nibbles_remaining load path at the mapped 98.3203125 MHz.
            directory_count_hi <= ram_read_data;
            state <= STATE_DIR_VALIDATE;
          end

          STATE_DIR_VALIDATE: begin
            if (directory_entry_valid) begin
              nibbles_remaining <= directory_nibbles;
              sample_address <= 16'h0100 + directory_start;
              ram_read_addr <= 16'h0100 + directory_start;
              low_nibble <= 1'b0;
              sample_divider <= 14'd0;
              adpcm_signal <= -12'sd2;
              adpcm_step <= 6'd0;
              adpcm_step_value <= 12'd16;
              state <= STATE_PAYLOAD_WAIT;
            end else begin
              busy <= 1'b0;
              sample <= 16'sd0;
              nibbles_remaining <= 16'd0;
              sample_address <= 16'd0;
              state <= STATE_IDLE;
            end
          end

          STATE_PAYLOAD_WAIT: begin
            state <= STATE_PAYLOAD_CAPTURE;
          end

          STATE_PAYLOAD_CAPTURE: begin
            byte_buffer <= ram_read_data;
            state <= STATE_PLAY;
          end

          STATE_PLAY: begin
            if (sample_divider == SAMPLE_DIVIDER_LAST) begin
              sample_divider <= 14'd0;
              adpcm_signal <= decoded_signal;
              adpcm_step <= decoded_step;
              adpcm_step_value <= oki_step_value(decoded_step);
              sample <= {decoded_signal[11], decoded_signal, 3'b000};

              if (nibbles_remaining == 16'd1) begin
                // Hold the final decoded sample for one complete 8 kHz period,
                // while releasing busy immediately at the end of the phrase.
                nibbles_remaining <= 16'd0;
                busy <= 1'b0;
                state <= STATE_TAIL;
              end else begin
                nibbles_remaining <= nibbles_remaining - 16'd1;

                if (!low_nibble) begin
                  low_nibble <= 1'b1;
                  if (nibbles_remaining > 16'd2) begin
                    ram_read_addr <= sample_address + 16'd1;
                  end
                end else begin
                  low_nibble <= 1'b0;
                  byte_buffer <= ram_read_data;
                  sample_address <= sample_address + 16'd1;
                end
              end
            end else begin
              sample_divider <= sample_divider + 14'd1;
            end
          end

          STATE_TAIL: begin
            if (sample_divider == SAMPLE_DIVIDER_LAST) begin
              sample_divider <= 14'd0;
              sample <= 16'sd0;
              state <= STATE_IDLE;
            end else begin
              sample_divider <= sample_divider + 14'd1;
            end
          end

          default: begin
            state <= STATE_IDLE;
          end
        endcase
      end
    end
  end

endmodule
