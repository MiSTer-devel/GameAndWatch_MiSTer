import types::*;

module rom_loader (
    input wire clk,

    input wire        ioctl_download,
    input wire        ioctl_wr,
    input wire [24:0] ioctl_addr,
    input wire [15:0] ioctl_dout,

    output system_config sys_config,

    // Data signals
    // Comb
    output reg [25:0] base_addr,
    output wire image_download,
    output wire mask_config_download,
    output wire rom_download,
    output wire rom_8bit_download,
    output wire crt_image_download,
    output wire crt_mask_download,

    // 8 bit bus
    output reg wr_8bit,
    output wire [25:0] addr_8bit,
    output wire [7:0] data_8bit
);
  // Package word addresses. The two image planes occupy separate SDRAM
  // ranges so loading a dual-resolution package never overwrites the legacy
  // 720x720 image used by native video mode.
  localparam [24:0] IMAGE_START_ADDR = 25'h000080;
  localparam [24:0] MASK_CONFIG_ADDR = 25'h17bb80;
  localparam [24:0] ROM_DATA_ADDR = 25'h192920;
  localparam [24:0] CRT_IMAGE_ADDR = 25'h19b280;  // byte 0x336500
  localparam [24:0] CRT_IMAGE_DATA_END_ADDR = 25'h1da700; // byte 0x3b4e00
  localparam [24:0] CRT_MASK_ADDR = 25'h219b80;   // byte 0x433700
  localparam [24:0] CRT_PACKAGE_END_ADDR = 25'h221560; // byte 0x442ac0
  localparam [24:0] CRT_IMAGE_SDRAM_BASE = 25'h180000;

  // wire config_data = ioctl_addr < IMAGE_START_ADDR;
  assign image_download = ioctl_addr >= IMAGE_START_ADDR && ioctl_addr < MASK_CONFIG_ADDR;
  assign mask_config_download = ioctl_addr >= MASK_CONFIG_ADDR && ioctl_addr < ROM_DATA_ADDR;
  assign rom_download = ioctl_addr >= ROM_DATA_ADDR && ioctl_addr < CRT_IMAGE_ADDR;
  assign crt_image_download = ioctl_addr >= CRT_IMAGE_ADDR && ioctl_addr < CRT_MASK_ADDR;
  assign crt_mask_download = ioctl_addr >= CRT_MASK_ADDR && ioctl_addr < CRT_PACKAGE_END_ADDR;

  always_comb begin
    base_addr = ioctl_addr;

    if (image_download) begin
      base_addr = ioctl_addr - IMAGE_START_ADDR;
    end else if (mask_config_download) begin
      base_addr = ioctl_addr - MASK_CONFIG_ADDR;
    end else if (rom_download) begin
      base_addr = ioctl_addr - ROM_DATA_ADDR;
    end else if (crt_image_download) begin
      base_addr = {1'b0, CRT_IMAGE_SDRAM_BASE + (ioctl_addr - CRT_IMAGE_ADDR)};
    end else if (crt_mask_download) begin
      base_addr = ioctl_addr - CRT_MASK_ADDR;
    end
  end

  reg [23:0] screen_size = 0;

  reg [15:0] buffer = 0;
  reg [ 1:0] read_count = 0;
  reg [25:0] buffer_base_addr = 0;
  reg buffer_rom_download = 1'b0;

  assign rom_8bit_download = buffer_rom_download;

  assign data_8bit = buffer[7:0];
  // Byte address
  assign addr_8bit = {buffer_base_addr[24:0], read_count == 2'h1};

  always @(posedge clk) begin
    wr_8bit <= 0;

    if (ioctl_wr) begin
      buffer <= ioctl_dout;
      // Keep the word address paired with its data while the two byte strobes
      // are emitted. The framework guarantees enough spacing between WIDE
      // writes, but it need not keep ioctl_addr live for our serializer.
      buffer_base_addr <= base_addr;
      buffer_rom_download <= rom_download;
      read_count <= 2'h2;
    end

    if (wr_8bit) begin
      buffer <= {8'h0, buffer[15:8]};
    end

    if (read_count > 0) begin
      wr_8bit <= 1;
      read_count <= read_count - 2'h1;
    end
  end

  ////////////////////////////////////////////////////////////////////////////////////////
  // State machine

  localparam VERSION = 0;
  localparam MPU = 1;
  localparam SCREEN_CONFIG = 2;
  localparam SCREEN_SIZE = 3;
  localparam SCREEN_RESERVED = 4;
  localparam INPUT_MAP = 5;
  localparam DONE = 6;

  localparam [7:0] FEATURE_HMC        = 8'h02;
  localparam [7:0] FEATURE_PLAYER_TWO = 8'h04;
  localparam [7:0] FEATURE_CRT_IMAGE  = 8'h08;
  localparam [7:0] FEATURE_CRT_MASK   = 8'h10;
  localparam [7:0] FEATURE_DIRECTORY  = 8'h80;
  localparam [7:0] MAX_DIRECTORY_DESCRIPTORS = 8'd11;

  reg [7:0] state = VERSION;
  reg [7:0] byte_count = 0;
  reg [7:0] directory_count = 0;
  reg [7:0] descriptor_bytes [0:15];
  reg hmc_descriptor_seen = 1'b0;
  reg crt_image_descriptor_seen = 1'b0;
  reg crt_mask_descriptor_seen = 1'b0;

  // Payload validation is deliberately independent of the SDRAM write path.
  // Data can be staged while downloading, but native CRT rendering is enabled
  // only after every canonical payload word and the fixed zero-padded mask
  // region have actually arrived in order.
  reg [24:0] crt_image_expected_addr = CRT_IMAGE_ADDR;
  reg [24:0] crt_mask_expected_addr = CRT_MASK_ADDR;
  reg crt_image_stream_good = 1'b0;
  reg crt_mask_stream_good = 1'b0;
  reg [2:0] crt_mask_byte_phase = 3'd0;
  reg [39:0] crt_mask_group = 40'd0;
  reg crt_mask_have_previous = 1'b0;
  reg [9:0] crt_mask_previous_y = 10'd0;
  reg [10:0] crt_mask_previous_end_x = 11'd0;

  // 16 is congruent to 1 modulo 5, so a 16-bit value is divisible by five
  // exactly when the sum of its four hexadecimal digits is. Keep this as a
  // small adder/LUT cone: a direct 32-bit `% 5` expression synthesized into
  // a 43-level combinational divider on the 98.304 MHz package-loader path.
  function automatic length_multiple_of_five;
    input [15:0] value;
    reg [5:0] digit_sum;
    begin
      digit_sum = {2'd0, value[3:0]} + {2'd0, value[7:4]} +
                  {2'd0, value[11:8]} + {2'd0, value[15:12]};
      case (digit_sum)
        6'd0, 6'd5, 6'd10, 6'd15, 6'd20, 6'd25, 6'd30,
        6'd35, 6'd40, 6'd45, 6'd50, 6'd55, 6'd60:
          length_multiple_of_five = 1'b1;
        default:
          length_multiple_of_five = 1'b0;
      endcase
    end
  endfunction

  // State is {stream_good, have_previous, previous_y, previous_end_x,
  // group[39:0], byte_phase[2:0]}. Each pre-terminator group must describe a
  // positive, in-bounds 360x240 run and groups must be sorted/non-overlapping.
  // The explicit final group and all fixed-capacity padding bytes are zero.
  function automatic [65:0] validate_crt_mask_byte;
    input [65:0] current_state;
    input [7:0] value;
    input before_terminator;
    reg good;
    reg have_previous;
    reg [9:0] previous_y;
    reg [10:0] previous_end_x;
    reg [39:0] group;
    reg [2:0] phase;
    reg [9:0] entry_start_x;
    reg [9:0] entry_y;
    reg [9:0] entry_length;
    reg [10:0] entry_end_x;
    begin
      good = current_state[65];
      have_previous = current_state[64];
      previous_y = current_state[63:54];
      previous_end_x = current_state[53:43];
      group = current_state[42:3];
      phase = current_state[2:0];

      if (before_terminator) begin
        group[phase * 8 +: 8] = value;

        if (phase == 3'd4) begin
          entry_start_x = group[19:10];
          entry_y = group[29:20];
          entry_length = group[39:30];
          entry_end_x = {1'b0, entry_start_x} + {1'b0, entry_length};

          if (entry_length == 10'd0 || entry_y >= 10'd240 ||
              entry_end_x > 11'd360 ||
              (have_previous &&
               !(entry_y > previous_y ||
                 (entry_y == previous_y &&
                  {1'b0, entry_start_x} >= previous_end_x)))) begin
            good = 1'b0;
          end

          have_previous = 1'b1;
          previous_y = entry_y;
          previous_end_x = entry_end_x;
          group = 40'd0;
          phase = 3'd0;
        end else begin
          phase = phase + 3'd1;
        end
      end else begin
        if (value != 8'd0 || phase != 3'd0) good = 1'b0;
      end

      validate_crt_mask_byte = {good, have_previous, previous_y,
                                previous_end_x, group, phase};
    end
  endfunction

  always @(posedge clk) begin
    if (state == DONE && ~ioctl_download) begin
      // Reset to load another ROM
      state <= VERSION;
      byte_count <= 8'h0;
    end

    if (wr_8bit) begin
      case (state)
        VERSION: begin
          sys_config.format_version <= data_8bit;
          sys_config.feature_flags <= 8'd0;
          sys_config.extension_directory_valid <= 1'b0;
          sys_config.hmc_descriptor_valid <= 1'b0;
          sys_config.crt_image_descriptor_valid <= 1'b0;
          sys_config.crt_mask_descriptor_valid <= 1'b0;
          sys_config.crt_mask_length <= 16'd0;
          sys_config.crt_image_payload_valid <= 1'b0;
          sys_config.crt_mask_payload_valid <= 1'b0;
          sys_config.player_two_metadata_valid <= 1'b0;
          sys_config.player_two_mask <= 40'd0;
          directory_count <= 8'd0;
          hmc_descriptor_seen <= 1'b0;
          crt_image_descriptor_seen <= 1'b0;
          crt_mask_descriptor_seen <= 1'b0;
          crt_image_expected_addr <= CRT_IMAGE_ADDR;
          crt_mask_expected_addr <= CRT_MASK_ADDR;
          crt_image_stream_good <= 1'b1;
          crt_mask_stream_good <= 1'b1;
          crt_mask_byte_phase <= 3'd0;
          crt_mask_group <= 40'd0;
          crt_mask_have_previous <= 1'b0;
          crt_mask_previous_y <= 10'd0;
          crt_mask_previous_end_x <= 11'd0;
          state <= MPU;
        end
        MPU: begin
          state <= SCREEN_CONFIG;
          sys_config.mpu <= data_8bit;
        end
        SCREEN_CONFIG: begin
          state <= SCREEN_SIZE;
          sys_config.screen_config <= data_8bit;
        end
        SCREEN_SIZE: begin
          byte_count  <= byte_count + 8'h1;
          screen_size <= {data_8bit, screen_size[23:8]};

          if (byte_count == 4'h2) begin
            state <= SCREEN_RESERVED;
            {sys_config.screen_height, sys_config.screen_width} <= {data_8bit, screen_size[23:8]};
            byte_count <= 0;
          end
        end
        SCREEN_RESERVED: begin
          // Reserved two bytes after screen size
          byte_count <= byte_count + 8'h1;

          if (byte_count == 6'h1) begin
            state <= INPUT_MAP;
            byte_count <= 0;
          end
        end
        INPUT_MAP: begin
          byte_count <= byte_count + 8'h1;

          if (byte_count >= 0 && byte_count < 4) begin
            // S0
            sys_config.input_s0_config <= {data_8bit, sys_config.input_s0_config[31:8]};
          end else if (byte_count >= 4 && byte_count < 8) begin
            // S1
            sys_config.input_s1_config <= {data_8bit, sys_config.input_s1_config[31:8]};
          end else if (byte_count >= 8 && byte_count < 12) begin
            // S2
            sys_config.input_s2_config <= {data_8bit, sys_config.input_s2_config[31:8]};
          end else if (byte_count >= 12 && byte_count < 16) begin
            // S3
            sys_config.input_s3_config <= {data_8bit, sys_config.input_s3_config[31:8]};
          end else if (byte_count >= 16 && byte_count < 20) begin
            // S4
            sys_config.input_s4_config <= {data_8bit, sys_config.input_s4_config[31:8]};
          end else if (byte_count >= 20 && byte_count < 24) begin
            // S5
            sys_config.input_s5_config <= {data_8bit, sys_config.input_s5_config[31:8]};
          end else if (byte_count >= 24 && byte_count < 28) begin
            // S6
            sys_config.input_s6_config <= {data_8bit, sys_config.input_s6_config[31:8]};
          end else if (byte_count >= 28 && byte_count < 32) begin
            // S7
            sys_config.input_s7_config <= {data_8bit, sys_config.input_s7_config[31:8]};
          end else if (byte_count == 32) begin
            // B
            sys_config.input_b_config <= data_8bit;
          end else if (byte_count == 33) begin
            // BA
            sys_config.input_ba_config <= data_8bit;
          end else if (byte_count == 34) begin
            // ACL
            sys_config.input_acl_config <= data_8bit;
          end else if (byte_count == 35) begin
            // Grounded port index
            sys_config.grounded_port_config <= data_8bit[3:0];
          end else if (byte_count == 40) begin
            // Config byte 0x30: optional V2 feature flags.
            sys_config.feature_flags <= data_8bit;
          end else if (byte_count == 41) begin
            // GNWX directory magic, revision, descriptor shape, and the
            // canonical HA1152 descriptor are accumulated fail-closed below.
            sys_config.extension_directory_valid <= data_8bit == 8'h47;
          end else if (byte_count == 42) begin
            sys_config.extension_directory_valid <=
                sys_config.extension_directory_valid && data_8bit == 8'h4e;
          end else if (byte_count == 43) begin
            sys_config.extension_directory_valid <=
                sys_config.extension_directory_valid && data_8bit == 8'h57;
          end else if (byte_count == 44) begin
            sys_config.extension_directory_valid <=
                sys_config.extension_directory_valid && data_8bit == 8'h58;
          end else if (byte_count == 45) begin
            sys_config.extension_directory_valid <=
                sys_config.extension_directory_valid && data_8bit == 8'h01;
          end else if (byte_count == 46) begin
            sys_config.extension_directory_valid <=
                sys_config.extension_directory_valid && data_8bit == 8'h10;
          end else if (byte_count == 47) begin
            sys_config.extension_directory_valid <=
                sys_config.extension_directory_valid &&
                data_8bit <= MAX_DIRECTORY_DESCRIPTORS &&
                sys_config.format_version >= 8'd2 &&
                sys_config.feature_flags[7];
            directory_count <= data_8bit;
          end else if (byte_count == 48) begin
            // Config 0x38..0x3c is a bit-per-electrical-cell ownership map:
            // S0.0..S7.3, B, BA, ACL, then five reserved bits. P2-only
            // packages intentionally have no payload descriptors, so a zero
            // directory count is legal while this feature is present.
            sys_config.player_two_mask[7:0] <= data_8bit;
          end else if (byte_count == 49) begin
            sys_config.player_two_mask[15:8] <= data_8bit;
          end else if (byte_count == 50) begin
            sys_config.player_two_mask[23:16] <= data_8bit;
          end else if (byte_count == 51) begin
            sys_config.player_two_mask[31:24] <= data_8bit;
          end else if (byte_count == 52) begin
            sys_config.player_two_mask[39:32] <= data_8bit;
            sys_config.player_two_metadata_valid <=
                sys_config.format_version >= 8'd2 &&
                (sys_config.feature_flags &
                    (FEATURE_PLAYER_TWO | FEATURE_DIRECTORY)) ==
                    (FEATURE_PLAYER_TWO | FEATURE_DIRECTORY) &&
                sys_config.extension_directory_valid &&
                data_8bit[7:3] == 5'd0 &&
                (|sys_config.player_two_mask[31:0] || |data_8bit[2:0]);
          end else if (byte_count >= 53 && byte_count <= 55) begin
            // Reserved bytes 0x3d..0x3f are part of the P2 metadata contract.
            sys_config.player_two_metadata_valid <=
                sys_config.player_two_metadata_valid && data_8bit == 8'h00;
          end else if (byte_count >= 56 && byte_count < 232) begin
            reg [7:0] descriptor_offset;
            reg [7:0] descriptor_index;
            reg [3:0] descriptor_byte;
            reg [31:0] descriptor_length;
            reg descriptor_common_valid;

            descriptor_offset = byte_count - 8'd56;
            descriptor_index = descriptor_offset >> 4;
            descriptor_byte = descriptor_offset[3:0];
            descriptor_bytes[descriptor_byte] <= data_8bit;

            if (descriptor_index < directory_count && descriptor_byte == 4'd15) begin
              descriptor_length = {
                descriptor_bytes[11], descriptor_bytes[10],
                descriptor_bytes[9], descriptor_bytes[8]
              };
              descriptor_common_valid = descriptor_bytes[3] == 8'h00;

              // Every descriptor has a reserved zero byte. Rejecting it at
              // directory scope also prevents a previously accepted payload
              // descriptor from surviving malformed trailing metadata.
              if (!descriptor_common_valid) begin
                sys_config.extension_directory_valid <= 1'b0;
              end

              case (descriptor_bytes[0])
                8'h02: begin
                  // HA1152: raw variant 1 at 0x336400, exactly 0x80 bytes.
                  sys_config.hmc_descriptor_valid <= !hmc_descriptor_seen &&
                      descriptor_common_valid && descriptor_bytes[1] == 8'h01 &&
                      descriptor_bytes[2] == 8'h01 &&
                      {descriptor_bytes[7], descriptor_bytes[6],
                       descriptor_bytes[5], descriptor_bytes[4]} == 32'h00336400 &&
                      descriptor_length == 32'h00000080 &&
                      {data_8bit, descriptor_bytes[14], descriptor_bytes[13],
                       descriptor_bytes[12]} == 32'h00000000 &&
                      sys_config.extension_directory_valid &&
                      sys_config.feature_flags[1] && sys_config.feature_flags[7];
                  hmc_descriptor_seen <= 1'b1;
                end

                8'h10: begin
                  // Native CRT image: paired background/mask RGB bytes.
                  sys_config.crt_image_descriptor_valid <=
                      !crt_image_descriptor_seen && descriptor_common_valid &&
                      descriptor_bytes[1] == 8'h01 && descriptor_bytes[2] == 8'h01 &&
                      {descriptor_bytes[7], descriptor_bytes[6],
                       descriptor_bytes[5], descriptor_bytes[4]} == 32'h00336500 &&
                      descriptor_length == 32'h0007e900 &&
                      {descriptor_bytes[13], descriptor_bytes[12]} == 16'd360 &&
                      {data_8bit, descriptor_bytes[14]} == 16'd240 &&
                      sys_config.extension_directory_valid &&
                      sys_config.feature_flags[3] && sys_config.feature_flags[7];
                  crt_image_descriptor_seen <= 1'b1;
                end

                8'h11: begin
                  // Native CRT mask: 40-bit RLE entries, followed by one
                  // explicit zero entry. Its descriptor length is the used
                  // bytes; the physical payload remains fixed and padded.
                  sys_config.crt_mask_descriptor_valid <=
                      !crt_mask_descriptor_seen && descriptor_common_valid &&
                      descriptor_bytes[1] == 8'h02 && descriptor_bytes[2] == 8'h01 &&
                      {descriptor_bytes[7], descriptor_bytes[6],
                       descriptor_bytes[5], descriptor_bytes[4]} == 32'h00433700 &&
                      descriptor_length >= 32'd5 && descriptor_length <= 32'h0000f3c0 &&
                      descriptor_length[31:16] == 16'd0 &&
                      length_multiple_of_five(descriptor_length[15:0]) &&
                      {descriptor_bytes[13], descriptor_bytes[12]} == 16'd360 &&
                      {data_8bit, descriptor_bytes[14]} == 16'd240 &&
                      sys_config.extension_directory_valid &&
                      sys_config.feature_flags[4] && sys_config.feature_flags[7];
                  sys_config.crt_mask_length <= descriptor_length[15:0];
                  crt_mask_descriptor_seen <= 1'b1;
                end

                default: begin
                  // Unknown future descriptor kinds do not enable any current
                  // payload. Their shared reserved byte is still enforced.
                end
              endcase
            end
          end

          // Consume the complete fixed 256-byte config so descriptors may
          // appear in any of the eleven ABI slots.
          if (byte_count == 8'hf7) begin
            state <= DONE;
          end
        end
      endcase
    end

    if (ioctl_download && ioctl_wr && crt_image_download) begin
      reg image_word_good;
      image_word_good = crt_image_stream_good &&
          ioctl_addr == crt_image_expected_addr &&
          (ioctl_addr < CRT_IMAGE_DATA_END_ADDR || ioctl_dout == 16'd0);
      crt_image_stream_good <= image_word_good;
      crt_image_expected_addr <= ioctl_addr + 25'd1;

      if (ioctl_addr == CRT_MASK_ADDR - 25'd1) begin
        sys_config.crt_image_payload_valid <= image_word_good &&
            sys_config.crt_image_descriptor_valid;
      end
    end

    if (ioctl_download && ioctl_wr && crt_mask_download) begin
      reg [15:0] mask_byte_offset;
      reg [15:0] terminator_start;
      reg [65:0] mask_state_low;
      reg [65:0] mask_state_high;

      mask_byte_offset = (ioctl_addr - CRT_MASK_ADDR) << 1;
      terminator_start = sys_config.crt_mask_length >= 16'd5 ?
          sys_config.crt_mask_length - 16'd5 : 16'd0;
      mask_state_low = validate_crt_mask_byte(
          {crt_mask_stream_good && ioctl_addr == crt_mask_expected_addr,
           crt_mask_have_previous, crt_mask_previous_y,
           crt_mask_previous_end_x, crt_mask_group, crt_mask_byte_phase},
          ioctl_dout[7:0], mask_byte_offset < terminator_start);
      mask_state_high = validate_crt_mask_byte(
          mask_state_low, ioctl_dout[15:8],
          mask_byte_offset + 16'd1 < terminator_start);

      crt_mask_stream_good <= mask_state_high[65];
      crt_mask_have_previous <= mask_state_high[64];
      crt_mask_previous_y <= mask_state_high[63:54];
      crt_mask_previous_end_x <= mask_state_high[53:43];
      crt_mask_group <= mask_state_high[42:3];
      crt_mask_byte_phase <= mask_state_high[2:0];
      crt_mask_expected_addr <= ioctl_addr + 25'd1;

      if (ioctl_addr == CRT_PACKAGE_END_ADDR - 25'd1) begin
        sys_config.crt_mask_payload_valid <= mask_state_high[65] &&
            mask_state_high[2:0] == 3'd0 &&
            sys_config.crt_mask_descriptor_valid;
      end
    end
  end

endmodule
