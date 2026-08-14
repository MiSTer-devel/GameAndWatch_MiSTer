import types::*;

module input_config (
    input wire clk,

    input system_config sys_config,

    input wire [3:0] cpu_id,

    // Input selection
    input wire [7:0] output_shifter_s,
    input wire [3:0] output_r,

    // Input
    input wire button_a,
    input wire button_b,
    input wire button_x,
    input wire button_y,
    // Six stable auxiliary controls. Package action bytes select which
    // electrical input each control drives for the loaded handheld.
    //
    //   0: Time / Pause / Status (joystick bit 8)
    //   1: Alarm                (joystick bit 9)
    //   2: Game A / Power On    (joystick bit 10)
    //   3: Game B / Power Off   (joystick bit 11)
    //   4: Sound / Minute       (joystick bit 12)
    //   5: ACL                  (joystick bit 13)
    input wire [5:0] button_aux,
    input wire osd_status,
    input wire dpad_up,
    input wire dpad_down,
    input wire dpad_left,
    input wire dpad_right,

    input wire player_two_button_a,
    input wire player_two_button_b,
    input wire player_two_button_x,
    input wire player_two_button_y,
    input wire [5:0] player_two_button_aux,
    input wire player_two_dpad_up,
    input wire player_two_dpad_down,
    input wire player_two_dpad_left,
    input wire player_two_dpad_right,

    // MPU Input
    output reg [7:0] input_k = 0,
    output reg input_wake = 0,

    output reg input_beta = 0,
    output reg input_ba = 0,
    output reg input_acl = 0
);
  localparam INACTIVE_CONFIG_ROW = 32'h7F7F_7F7F;

  wire player_two_metadata_active =
      sys_config.format_version >= 8'd2 &&
      sys_config.feature_flags[2] && sys_config.feature_flags[7] &&
      sys_config.extension_directory_valid &&
      sys_config.player_two_metadata_valid;
  wire [39:0] player_two_mask = player_two_metadata_active ?
      sys_config.player_two_mask : 40'd0;

  function [31:0] s_config_by_index(reg [2:0] index);
    case (index)
      0: return sys_config.input_s0_config;
      1: return sys_config.input_s1_config;
      2: return sys_config.input_s2_config;
      3: return sys_config.input_s3_config;
      4: return sys_config.input_s4_config;
      5: return sys_config.input_s5_config;
      6: return sys_config.input_s6_config;
      7: return sys_config.input_s7_config;
    endcase
  endfunction

  function row_has_action([31:0] input_config, [6:0] action);
    return input_config[ 6: 0] == action ||
        input_config[14: 8] == action ||
        input_config[22:16] == action ||
        input_config[30:24] == action;
  endfunction

  function [3:0] player_two_mask_by_index(reg [2:0] index);
    case (index)
      0: return player_two_mask[3:0];
      1: return player_two_mask[7:4];
      2: return player_two_mask[11:8];
      3: return player_two_mask[15:12];
      4: return player_two_mask[19:16];
      5: return player_two_mask[23:20];
      6: return player_two_mask[27:24];
      7: return player_two_mask[31:28];
    endcase
  endfunction

  wire has_start2_config =
      row_has_action(sys_config.input_s0_config, 7'd14) ||
      row_has_action(sys_config.input_s1_config, 7'd14) ||
      row_has_action(sys_config.input_s2_config, 7'd14) ||
      row_has_action(sys_config.input_s3_config, 7'd14) ||
      row_has_action(sys_config.input_s4_config, 7'd14) ||
      row_has_action(sys_config.input_s5_config, 7'd14) ||
      row_has_action(sys_config.input_s6_config, 7'd14) ||
      row_has_action(sys_config.input_s7_config, 7'd14) ||
      sys_config.input_b_config[6:0] == 7'd14 ||
      sys_config.input_ba_config[6:0] == 7'd14 ||
      sys_config.input_acl_config[6:0] == 7'd14;

  wire has_power_off_config =
      row_has_action(sys_config.input_s0_config, 7'd27) ||
      row_has_action(sys_config.input_s1_config, 7'd27) ||
      row_has_action(sys_config.input_s2_config, 7'd27) ||
      row_has_action(sys_config.input_s3_config, 7'd27) ||
      row_has_action(sys_config.input_s4_config, 7'd27) ||
      row_has_action(sys_config.input_s5_config, 7'd27) ||
      row_has_action(sys_config.input_s6_config, 7'd27) ||
      row_has_action(sys_config.input_s7_config, 7'd27) ||
      sys_config.input_b_config[6:0] == 7'd27 ||
      sys_config.input_ba_config[6:0] == 7'd27 ||
      sys_config.input_acl_config[6:0] == 7'd27;

  // Map from config value to control
  function input_mux(
      [7:0] config_value,
      input player_two,
      input has_start2,
      input has_power_off
  );
    reg out;

    case (config_value[6:0])
      0: out = player_two ? player_two_dpad_up : dpad_up;
      1: out = player_two ? player_two_dpad_down : dpad_down;
      2: out = player_two ? player_two_dpad_left : dpad_left;
      3: out = player_two ? player_two_dpad_right : dpad_right;

      // Buttons 1-4
      4: out = player_two ? player_two_button_b : button_b;
      5: out = player_two ? player_two_button_a : button_a;
      6: out = player_two ? player_two_button_y : button_y;
      7: out = player_two ? player_two_button_x : button_x;

      // Buttons 5-8 unhandled.
      //
      // Auxiliary controls have stable physical positions while the package
      // action bytes select their electrical meaning. Keep the former
      // Game-B-to-Game-A convenience only when that physical control has no
      // declared Game B or Power Off function. In particular, Power Off must
      // never start or restart a single-start game.
      12: out = player_two ? player_two_button_aux[0] : button_aux[0];
      13: out = (player_two ? player_two_button_aux[2] : button_aux[2]) ||
          (!has_start2 && !has_power_off &&
              (player_two ? player_two_button_aux[3] : button_aux[3]));
      14: out = player_two ? player_two_button_aux[3] : button_aux[3];
      15: out = player_two ? player_two_button_aux[5] : button_aux[5];
      16: out = player_two ? player_two_button_aux[1] : button_aux[1];

      // Left joystick
      17: out = player_two ? player_two_dpad_up : dpad_up;
      18: out = player_two ? player_two_dpad_down : dpad_down;
      19: out = player_two ? player_two_dpad_left : dpad_left;
      20: out = player_two ? player_two_dpad_right : dpad_right;

      // Right joystick
      21: out = player_two ? player_two_button_x : button_x;
      22: out = player_two ? player_two_button_b : button_b;
      23: out = player_two ? player_two_button_y : button_y;
      24: out = player_two ? player_two_button_a : button_a;

      25: out = player_two ? player_two_button_aux[4] : button_aux[4];
      26: out = player_two ? player_two_button_aux[2] : button_aux[2];
      27: out = player_two ? player_two_button_aux[3] : button_aux[3];

      // Explicit MAME IPT_CUSTOM mappings that fit the existing controller
      // layout. Generic custom/keypad wiring remains unhandled.
      30: out = player_two ?
          (player_two_dpad_up || player_two_dpad_down) :
          (dpad_up || dpad_down);
      31: out = player_two ? player_two_button_b : button_b;

      // Dial/value 32 remains unhandled. Service4 has a distinct value
      // so its Minute function can share the Sound auxiliary control without
      // being mistaken for Alarm/Service2.
      33: out = player_two ? player_two_button_aux[4] : button_aux[4];

      // Unused. Polarity still applies: active-low unused is the established
      // representation for pulled-up B/BA pins.
      7'h7f: out = 0;

      // Other values unhandled.

      default: out = 0;
    endcase

    // The MiSTer framework continues to stream controller levels while its
    // OSD owns the controls. Suppress raw active-high presses first, then
    // apply the package's electrical active-low flag so inactive-low inputs
    // still idle at logic one.
    if (osd_status) out = 0;

    // High bit is active low flag.
    return config_value[7] ? ~out : out;
  endfunction

  function [3:0] build_k(
      [31:0] input_config,
      [3:0] player_two_cells,
      input has_start2,
      input has_power_off
  );
    return {
      input_mux(input_config[31:24], player_two_cells[3], has_start2, has_power_off),
      input_mux(input_config[23:16], player_two_cells[2], has_start2, has_power_off),
      input_mux(input_config[15:8], player_two_cells[1], has_start2, has_power_off),
      input_mux(input_config[7:0], player_two_cells[0], has_start2, has_power_off)
    };
  endfunction

  function wake_input_mux(
      [7:0] config_value,
      input player_two,
      input has_start2,
      input has_power_off
  );
    if (config_value[6:0] == 7'h7F) begin
      return 1'b0;
    end

    // input_mux returns the electrical pin level after applying package
    // polarity. Wake is a logical "control pressed" indication instead, so
    // remove that polarity again. This also keeps wake deasserted while the
    // OSD is open: input_mux idles active-high pins low and active-low pins
    // high before this conversion.
    return input_mux(config_value, player_two, has_start2, has_power_off) ^
        config_value[7];
  endfunction

  function [3:0] build_wake_k(
      [31:0] input_config,
      [3:0] player_two_cells,
      input has_start2,
      input has_power_off
  );
    return {
      wake_input_mux(input_config[31:24], player_two_cells[3], has_start2, has_power_off),
      wake_input_mux(input_config[23:16], player_two_cells[2], has_start2, has_power_off),
      wake_input_mux(input_config[15:8], player_two_cells[1], has_start2, has_power_off),
      wake_input_mux(input_config[7:0], player_two_cells[0], has_start2, has_power_off)
    };
  endfunction

  // Always active config
  reg [31:0] grounded_input_config = INACTIVE_CONFIG_ROW;
  reg [3:0] grounded_player_two_mask = 4'd0;

  reg [ 7:0] main_input_k = 0;

  always @(posedge clk) begin
    reg [7:0] temp_k;

    temp_k = 0;
    grounded_input_config <= INACTIVE_CONFIG_ROW;
    grounded_player_two_mask <= 4'd0;

    if (sys_config.grounded_port_config == 4'h0) begin
      // Disabled
      grounded_input_config <= INACTIVE_CONFIG_ROW;
      grounded_player_two_mask <= 4'd0;
    end else begin
      reg [3:0] temp;
      temp = sys_config.grounded_port_config - 4'h1;

      grounded_input_config <= s_config_by_index(temp[2:0]);
      grounded_player_two_mask <= player_two_mask_by_index(temp[2:0]);
    end

    case (cpu_id)
      4: begin
        // SM5a
        if (output_r[1]) temp_k = build_k(sys_config.input_s0_config,
            player_two_mask[3:0],
            has_start2_config, has_power_off_config);
        if (output_r[2]) temp_k = temp_k | build_k(sys_config.input_s1_config,
            player_two_mask[7:4],
            has_start2_config, has_power_off_config);
        if (output_r[3]) temp_k = temp_k | build_k(sys_config.input_s2_config,
            player_two_mask[11:8],
            has_start2_config, has_power_off_config);
      end
      3: begin
        // SM530 has an 8-bit K/KE input port. The generator stores the low
        // nibble in S0 and the high nibble in S1 for fixed-input Nelsonic games.
        temp_k = {
          build_k(sys_config.input_s1_config, player_two_mask[7:4],
              has_start2_config, has_power_off_config),
          build_k(sys_config.input_s0_config, player_two_mask[3:0],
              has_start2_config, has_power_off_config)
        };
      end
      default: begin
        // SM510/SM510 Tiger
        if (output_shifter_s[0]) temp_k = build_k(sys_config.input_s0_config,
            player_two_mask[3:0],
            has_start2_config, has_power_off_config);
        if (output_shifter_s[1]) temp_k = temp_k | build_k(sys_config.input_s1_config,
            player_two_mask[7:4],
            has_start2_config, has_power_off_config);
        if (output_shifter_s[2]) temp_k = temp_k | build_k(sys_config.input_s2_config,
            player_two_mask[11:8],
            has_start2_config, has_power_off_config);
        if (output_shifter_s[3]) temp_k = temp_k | build_k(sys_config.input_s3_config,
            player_two_mask[15:12],
            has_start2_config, has_power_off_config);
        if (output_shifter_s[4]) temp_k = temp_k | build_k(sys_config.input_s4_config,
            player_two_mask[19:16],
            has_start2_config, has_power_off_config);
        if (output_shifter_s[5]) temp_k = temp_k | build_k(sys_config.input_s5_config,
            player_two_mask[23:20],
            has_start2_config, has_power_off_config);
        if (output_shifter_s[6]) temp_k = temp_k | build_k(sys_config.input_s6_config,
            player_two_mask[27:24],
            has_start2_config, has_power_off_config);
        if (output_shifter_s[7]) temp_k = temp_k | build_k(sys_config.input_s7_config,
            player_two_mask[31:28],
            has_start2_config, has_power_off_config);
      end
    endcase

    main_input_k <= temp_k;

    input_wake <= (
        build_wake_k(sys_config.input_s0_config, player_two_mask[3:0],
            has_start2_config, has_power_off_config) |
        build_wake_k(sys_config.input_s1_config, player_two_mask[7:4],
            has_start2_config, has_power_off_config) |
        build_wake_k(sys_config.input_s2_config, player_two_mask[11:8],
            has_start2_config, has_power_off_config) |
        build_wake_k(sys_config.input_s3_config, player_two_mask[15:12],
            has_start2_config, has_power_off_config) |
        build_wake_k(sys_config.input_s4_config, player_two_mask[19:16],
            has_start2_config, has_power_off_config) |
        build_wake_k(sys_config.input_s5_config, player_two_mask[23:20],
            has_start2_config, has_power_off_config) |
        build_wake_k(sys_config.input_s6_config, player_two_mask[27:24],
            has_start2_config, has_power_off_config) |
        build_wake_k(sys_config.input_s7_config, player_two_mask[31:28],
            has_start2_config, has_power_off_config)
    ) != 4'd0;
  end

  always @(posedge clk) begin
    reg [7:0] grounded_input_k;

    grounded_input_k = {4'h0,
      input_mux(grounded_input_config[31:24], grounded_player_two_mask[3],
          has_start2_config, has_power_off_config),
      input_mux(grounded_input_config[23:16], grounded_player_two_mask[2],
          has_start2_config, has_power_off_config),
      input_mux(grounded_input_config[15:8], grounded_player_two_mask[1],
          has_start2_config, has_power_off_config),
      input_mux(grounded_input_config[7:0], grounded_player_two_mask[0],
          has_start2_config, has_power_off_config)
    };

    input_k <= main_input_k | (cpu_id == 4'd3 ? 8'h00 : grounded_input_k);

    input_beta <= input_mux(sys_config.input_b_config, player_two_mask[32],
        has_start2_config, has_power_off_config);
    input_ba <= input_mux(sys_config.input_ba_config, player_two_mask[33],
        has_start2_config, has_power_off_config);
    // Old packages sometimes encoded an absent ACL as 0xff by reusing the
    // pulled-up B/BA default. Treat either unused marker as no ACL, while B,
    // BA, and S entries retain their normal electrical polarity semantics.
    input_acl <= sys_config.input_acl_config[6:0] == 7'h7f ?
        1'b0 : input_mux(sys_config.input_acl_config, player_two_mask[34],
            has_start2_config, has_power_off_config);
  end

endmodule
