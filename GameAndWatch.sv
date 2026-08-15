//------------------------------------------------------------------------------
// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileType: SOURCE
// SPDX-FileCopyrightText: (c) 2022, OpenGateware authors and contributors
//------------------------------------------------------------------------------
//
// Copyright (c) 2022, OpenGateware authors and contributors
// Copyright (c) 2017, Alexey Melnikov <pour.garbage@gmail.com>
// Copyright (c) 2015, Till Harbaum <till@harbaum.org>
//
// This source file is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful, but
// WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
// General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <http://www.gnu.org/licenses/>.
//
//------------------------------------------------------------------------------
// MiSTer framework glue logic.
// Instantiated by the framework top-level: sys/sys_top.v
//------------------------------------------------------------------------------

module emu (
    `include "sys/emu_ports.vh"
);

  assign ADC_BUS = 'Z;
  assign USER_OUT = '1;
  assign {UART_RTS, UART_TXD, UART_DTR} = 0;
  assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
  assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = '0;

  assign VGA_F1 = 0;
  assign VGA_SCALER = 0;
  assign VGA_DISABLE = 0;
  assign HDMI_FREEZE = 0;
  assign HDMI_BLACKOUT = 0;
  assign HDMI_BOB_DEINT = 0;

`ifdef MISTER_FB
  assign FB_EN = 0;
  assign FB_FORMAT = 0;
  assign FB_WIDTH = 0;
  assign FB_HEIGHT = 0;
  assign FB_BASE = 0;
  assign FB_STRIDE = 0;
  assign FB_FORCE_BLANK = 0;

`ifdef MISTER_FB_PALETTE
  assign FB_PAL_CLK = 0;
  assign FB_PAL_ADDR = 0;
  assign FB_PAL_DOUT = 0;
  assign FB_PAL_WR = 0;
`endif
`endif

`ifdef MISTER_DUAL_SDRAM
  assign {SDRAM2_CLK, SDRAM2_A, SDRAM2_BA, SDRAM2_nCS, SDRAM2_nCAS, SDRAM2_nRAS, SDRAM2_nWE} = 'Z;
  assign SDRAM2_DQ = 'Z;
`endif

  assign AUDIO_MIX = 0;

  assign LED_DISK = 0;
  assign LED_POWER = 0;
  assign LED_USER = 0;
  assign BUTTONS[1] = 0;

  `include "build_id.v"

  localparam CONF_STR = {
    "Game and Watch;;",
    "FS0,gnw,Load ROM;",
    "-;",
    "O[10],Native Video,360x240 CRT,720x720;",
    "-;",
    "O[5:2],Inactive LCD Alpha,Off,5%,10%,20%,30%,40%,50%,60%,70%,80%,90%,100%;",
    "-;",
    "O[1],Accurate LCD Timing,Off,On;",
    "-;",
    "O[11],Audio,On,Mute;",
`ifdef CORE_ENABLE_DEBUG_OVERLAY
    "-;",
    "O[6],Debug Video,Off,On;",
    "O[8:7],Debug View,Events,CPU,Melody,Core;",
    "O[9],Debug Freeze,Off,On;",
    "-;",
`endif
    "-;",
    "R[0],Reset;",
    "J1,Btn 1/R Joy Down,Btn 2/R Joy Right,Btn 3/R Joy Left,Btn 4/R Joy Up,Time/Pause/Status,Alarm,Game A/Power On,Game B/Power Off,Sound/Minute,ACL;",
    "jn,B,A,Y,X,L,R,Select,Start;",
    "v,0;",
    "V,v",
    `BUILD_DATE
  };

  wire clk_sys_99_287;
  wire pll_core_locked;
  wire clk_video_54;
  wire pll_video_locked;

  pll pll (
      .refclk  (CLK_50M),
      .rst     (RESET),
      .outclk_0(clk_sys_99_287),
      .outclk_1(),
      .locked  (pll_core_locked)
  );

  // Direct Video transports the CRT raster on the canonical 54.000 MHz SD
  // clock. Rendering remains on the mapped 98.3203125 MHz core clock below; a
  // packet FIFO crosses only complete logical pixels into this output domain.
  // The video PLL is free-running. Its lock participates in the transport's
  // asynchronously asserted, synchronously released reset instead of being
  // restarted by the emulated machine reset.
  video_pll_54 video_pll (
      .refclk_50  (CLK_50M),
      .reset      (1'b0),
      .clk_video_54(clk_video_54),
      .locked     (pll_video_locked)
  );

  wire video_transport_async_reset = RESET || !pll_core_locked || !pll_video_locked;
  (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
  reg [2:0] video_transport_reset_pipe = 3'b111;
  always @(posedge clk_video_54 or posedge video_transport_async_reset) begin
    if (video_transport_async_reset) begin
      video_transport_reset_pipe <= 3'b111;
    end else begin
      video_transport_reset_pipe <= {video_transport_reset_pipe[1:0], 1'b0};
    end
  end
  wire video_transport_reset = video_transport_reset_pipe[2];

  wire active_crt_video;
  wire hold_video;
  wire new_vmode;
  wire transport_active_crt;

  // video_mode_control emits a toggle only after a mode switch has completed
  // in the source domain. Synchronize that notification before handing it to
  // hps_io's fixed-54 MHz video-domain mode calculator.
  (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
  reg [1:0] new_vmode_video_pipe = 2'b00;
  always @(posedge clk_video_54) begin
    new_vmode_video_pipe <= {new_vmode_video_pipe[0], new_vmode};
  end
  wire new_vmode_video = new_vmode_video_pipe[1];

  wire [127:0] status;
  wire [  1:0] hps_buttons;
  wire [ 21:0] gamma_bus;
  wire         forced_scandoubler;

  wire        ioctl_download;
  wire        ioctl_upload;
  wire        ioctl_upload_req = 0;
  wire [15:0] ioctl_index;
  wire        ioctl_wr;
  wire        ioctl_wait;
  wire [26:0] ioctl_addr;
  wire [15:0] ioctl_dout;
  wire [15:0] ioctl_din = 0;

  wire [10:0] ps2_key;
  wire [31:0] joystick_0;
  wire [31:0] joystick_1;

  hps_io #(
      .CONF_STR(CONF_STR),
      .WIDE(1)
  ) hps_io (
      .clk_sys(clk_sys_99_287),
      .HPS_BUS(HPS_BUS),
      .EXT_BUS(),
      .gamma_bus(gamma_bus),

      .buttons(hps_buttons),
      .forced_scandoubler(forced_scandoubler),
      .status(status),
      .status_in(128'd0),
      .status_set(1'b0),
      .status_menumask(16'd0),

      .video_rotated(1'b0),
      .new_vmode(new_vmode_video),

      .info_req(1'b0),
      .info(8'd0),

      .ioctl_upload      (ioctl_upload),
      .ioctl_upload_req  (ioctl_upload_req),
      .ioctl_upload_index(8'd0),
      .ioctl_download    (ioctl_download),
      .ioctl_wr          (ioctl_wr),
      .ioctl_addr        (ioctl_addr),
      .ioctl_dout        (ioctl_dout),
      .ioctl_din         (ioctl_din),
      .ioctl_index       (ioctl_index),
      .ioctl_wait        (ioctl_wait),

      .ps2_key(ps2_key),

      .joystick_0(joystick_0),
      .joystick_1(joystick_1)
  );

  wire external_reset = status[0];
  wire accurate_lcd_timing = status[1];
  wire [3:0] inactive_lcd_alpha_selection = status[5:2];
`ifdef CORE_ENABLE_DEBUG_OVERLAY
  wire debug_video = status[6];
  wire [1:0] debug_view = status[8:7];
  wire debug_freeze = status[9];
`else
  wire debug_video = 1'b0;
  wire [1:0] debug_view = 2'b00;
  wire debug_freeze = 1'b0;
`endif
  wire requested_crt_video = ~status[10];
  wire crt_video = active_crt_video;

  // Aspect ratio follows the mode actually committed by the output bridge,
  // not the independently clocked source-domain request.
  assign VIDEO_ARX = transport_active_crt ? 13'd4 : 13'd1;
  assign VIDEO_ARY = transport_active_crt ? 13'd3 : 13'd1;

  reg [7:0] lcd_off_alpha;

  always_comb begin
    lcd_off_alpha = 0;

    case (inactive_lcd_alpha_selection)
      0: lcd_off_alpha = 0;
      1: lcd_off_alpha = 13;
      2: lcd_off_alpha = 26;
      3: lcd_off_alpha = 51;
      4: lcd_off_alpha = 77;
      5: lcd_off_alpha = 102;
      6: lcd_off_alpha = 128;
      7: lcd_off_alpha = 153;
      8: lcd_off_alpha = 179;
      9: lcd_off_alpha = 204;
      10: lcd_off_alpha = 230;
      11: lcd_off_alpha = 255;
      default: lcd_off_alpha = 0;
    endcase
  end

  reg has_rom = 0;
  reg [25:0] open_osd_timeout = {26{1'b1}};
  reg did_reset = 0;
  reg open_osd = 0;
  reg prev_ioctl_download = 0;

  assign BUTTONS[0] = open_osd;

  always @(posedge clk_sys_99_287) begin
    prev_ioctl_download <= ioctl_download;

    if (~ioctl_download && prev_ioctl_download) begin
      has_rom <= 1;
    end

    if (RESET) begin
      did_reset <= 0;
    end else if (status[0]) begin
      did_reset <= 1;
    end

    if (did_reset && ~status[0]) begin
      open_osd <= 0;

      if (open_osd_timeout > 0) begin
        open_osd_timeout <= open_osd_timeout - 26'd1;

        if (~has_rom) begin
          open_osd <= 1;
        end
      end
    end
  end

  wire signed [15:0] core_audio;
  wire audio_muted = status[11];
  wire source_vsync;
  wire source_hsync;
  wire source_vblank;
  wire source_hblank;
  wire source_de;
  wire source_ce_pix;
  wire [23:0] source_rgb;
  wire source_packet_wr;
  wire [29:0] source_packet;
  wire crt_source_tick_toggle;
  wire native_source_pause;
  wire source_video_held;

  wire vsync;
  wire hsync;
  wire vblank;
  wire hblank;
  wire de;
  wire ce_pix;
  wire [23:0] rgb;

  // Keep the output blank long enough for the largest SDRAM line buffer to
  // refill after its base address changes (2160 16-bit words natively).
  video_mode_control #(
      .SETTLE_CYCLES(4096)
  ) video_mode_control (
      .clk_sys(clk_sys_99_287),
      .reset(RESET),
      .clocks_ready(pll_core_locked && pll_video_locked),
      .request_crt(requested_crt_video),
      .video_vblank(source_vblank),
      .video_held(source_video_held),
      .active_crt(active_crt_video),
      .hold_video(hold_video),
      .new_vmode(new_vmode)
  );

  gameandwatch gameandwatch (
      .clk_sys_99_287(clk_sys_99_287),
      .clk_vid_33_095(clk_sys_99_287),

      .reset(RESET || ioctl_download || ~has_rom || external_reset || hps_buttons[1]),
      .video_blank(RESET || ~has_rom || external_reset || hps_buttons[1]),
      .pll_core_locked(pll_core_locked),

      .button_a(joystick_0[5]),
      .button_b(joystick_0[4]),
      .button_x(joystick_0[7]),
      .button_y(joystick_0[6]),
      .button_aux(joystick_0[13:8]),
      .osd_status(OSD_STATUS),
      .dpad_up(joystick_0[3]),
      .dpad_down(joystick_0[2]),
      .dpad_left(joystick_0[1]),
      .dpad_right(joystick_0[0]),
      .player_two_button_a(joystick_1[5]),
      .player_two_button_b(joystick_1[4]),
      .player_two_button_x(joystick_1[7]),
      .player_two_button_y(joystick_1[6]),
      .player_two_button_aux(joystick_1[13:8]),
      .player_two_dpad_up(joystick_1[3]),
      .player_two_dpad_down(joystick_1[2]),
      .player_two_dpad_left(joystick_1[1]),
      .player_two_dpad_right(joystick_1[0]),

      .ioctl_download(ioctl_download),
      .ioctl_wr(ioctl_wr),
      .ioctl_addr({1'b0, ioctl_addr[24:1]}),
      .ioctl_dout(ioctl_dout),
      .ioctl_wait(ioctl_wait),

      .hsync(source_hsync),
      .vsync(source_vsync),
      .hblank(source_hblank),
      .vblank(source_vblank),
      .de(source_de),
      .ce_pix(source_ce_pix),
      .rgb(source_rgb),
      .source_packet_wr(source_packet_wr),
      .source_packet(source_packet),
      .video_held(source_video_held),

      .audio(core_audio),

      .accurate_lcd_timing(accurate_lcd_timing),
      .lcd_off_alpha(lcd_off_alpha),
      .crt_video(crt_video),
      .hold_video(hold_video),
      .crt_source_tick_async(crt_source_tick_toggle),
      .native_source_pause_async(native_source_pause),

      .debug_video(debug_video),
      .debug_view(debug_view),
      .debug_freeze(debug_freeze),
      .debug_clear(RESET || (ioctl_download && !prev_ioctl_download) || external_reset || hps_buttons[1]),

      .SDRAM_A(SDRAM_A),
      .SDRAM_BA(SDRAM_BA),
      .SDRAM_DQ(SDRAM_DQ),
      .SDRAM_DQM({SDRAM_DQMH, SDRAM_DQML}),
      .SDRAM_CLK(SDRAM_CLK),
      .SDRAM_CKE(SDRAM_CKE),
      .SDRAM_nCS(SDRAM_nCS),
      .SDRAM_nRAS(SDRAM_nRAS),
      .SDRAM_nCAS(SDRAM_nCAS),
      .SDRAM_nWE(SDRAM_nWE)
  );

  wire transport_packet_ready;
  wire [9:0] transport_packet_level_source;
  wire [9:0] transport_packet_level_video;
  wire transport_running;
  wire transport_fault;
  video_transport_54 #(
      .PREFILL_WORDS(512)
  ) video_transport (
      .clk_source(clk_sys_99_287),
      .clk_video_54(clk_video_54),
      .reset(video_transport_reset),
      .crt_mode_async(crt_video),
      .hold_async(hold_video),
      .packet_wr(source_packet_wr),
      .packet_data(source_packet),
      .packet_ready(transport_packet_ready),
      .packet_level_source(transport_packet_level_source),
      .packet_level_video(transport_packet_level_video),
      .crt_source_tick_toggle(crt_source_tick_toggle),
      .native_source_pause(native_source_pause),
      .ce_pixel(ce_pix),
      .hsync(hsync),
      .vsync(vsync),
      .hblank(hblank),
      .vblank(vblank),
      .de(de),
      .rgb(rgb),
      .active_crt_mode(transport_active_crt),
      .running(transport_running),
      .fault(transport_fault)
  );

  // CLK_VIDEO must be a direct PLL clock because the MiSTer framework places
  // its own clock selector after this boundary. CRT mode exposes an actual
  // 360-sample CE /8 transport, giving 2880 active and 3432 total raw clocks
  // at 54 MHz. Native mode remains
  // emitted using an exact-average 32.768 MHz CE, although Direct Video support
  // is intentionally only claimed for the CRT mode.
  assign CLK_VIDEO = clk_video_54;
  assign CE_PIXEL = ce_pix;

  assign VGA_R = rgb[23:16];
  assign VGA_G = rgb[15:8];
  assign VGA_B = rgb[7:0];
  assign VGA_HS = hsync;
  assign VGA_VS = vsync;
  assign VGA_DE = de;
  assign VGA_SL = 2'b00;

  assign AUDIO_S = 1;
  assign AUDIO_L = audio_muted ? 16'sd0 : core_audio;
  assign AUDIO_R = AUDIO_L;

endmodule
