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
    "O[6],Debug Video,Off,On;",
    "O[8:7],Debug View,Events,CPU,Melody,Core;",
    "O[9],Debug Freeze,Off,On;",
    "-;",
    "-;",
    "R[0],Reset;",
    "J1,Btn 1/R Joy Down,Btn 2/R Joy Right,Btn 3/R Joy Left,Btn 4/R Joy Up,Time,Alarm,Game A,Game B;",
    "jn,B,A,Y,X,L,R,Select,Start;",
    "v,0;",
    "V,v",
    `BUILD_DATE
  };

  wire clk_sys_99_287;
  wire clk_vid_33_095;
  wire pll_core_locked;
  wire clk_video = clk_vid_33_095;

  pll pll (
      .refclk  (CLK_50M),
      .rst     (RESET),
      .outclk_0(clk_sys_99_287),
      .outclk_1(clk_vid_33_095),
      .locked  (pll_core_locked)
  );

  wire [127:0] status;
  wire [  1:0] hps_buttons;
  wire [ 21:0] gamma_bus;
  wire         forced_scandoubler;

  wire        ioctl_download;
  wire        ioctl_upload;
  wire        ioctl_upload_req = 0;
  wire [15:0] ioctl_index;
  wire        ioctl_wr;
  wire [26:0] ioctl_addr;
  wire [15:0] ioctl_dout;
  wire [15:0] ioctl_din = 0;

  wire [10:0] ps2_key;
  wire [31:0] joystick_0;

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
      .new_vmode(1'b0),

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
      .ioctl_wait        (1'b0),

      .ps2_key(ps2_key),

      .joystick_0(joystick_0)
  );

  wire external_reset = status[0];
  wire accurate_lcd_timing = status[1];
  wire [3:0] inactive_lcd_alpha_selection = status[5:2];
  wire debug_video = status[6];
  wire [1:0] debug_view = status[8:7];
  wire debug_freeze = status[9];
  wire crt_video = ~status[10];

  assign VIDEO_ARX = crt_video ? 13'd4 : 13'd1;
  assign VIDEO_ARY = crt_video ? 13'd3 : 13'd1;

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

  wire sound;
  wire vsync;
  wire hsync;
  wire vblank;
  wire hblank;
  wire de;
  wire ce_pix;
  wire [23:0] rgb;

  gameandwatch gameandwatch (
      .clk_sys_99_287(clk_sys_99_287),
      .clk_vid_33_095(clk_video),

      .reset(RESET || ioctl_download || ~has_rom || external_reset || hps_buttons[1]),
      .pll_core_locked(pll_core_locked),

      .button_a(joystick_0[5]),
      .button_b(joystick_0[4]),
      .button_x(joystick_0[7]),
      .button_y(joystick_0[6]),
      .button_trig_l(joystick_0[8]),
      .button_trig_r(joystick_0[9]),
      .button_start(joystick_0[11]),
      .button_select(joystick_0[10]),
      .dpad_up(joystick_0[3]),
      .dpad_down(joystick_0[2]),
      .dpad_left(joystick_0[1]),
      .dpad_right(joystick_0[0]),

      .ioctl_download(ioctl_download),
      .ioctl_wr(ioctl_wr),
      .ioctl_addr({1'b0, ioctl_addr[24:1]}),
      .ioctl_dout(ioctl_dout),

      .hsync(hsync),
      .vsync(vsync),
      .hblank(hblank),
      .vblank(vblank),
      .de(de),
      .ce_pix(ce_pix),
      .rgb(rgb),

      .sound(sound),

      .accurate_lcd_timing(accurate_lcd_timing),
      .lcd_off_alpha(lcd_off_alpha),
      .crt_video(crt_video),

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

  assign CLK_VIDEO = clk_video;
  assign CE_PIXEL = ce_pix;

  assign VGA_R = rgb[23:16];
  assign VGA_G = rgb[15:8];
  assign VGA_B = rgb[7:0];
  assign VGA_HS = hsync;
  assign VGA_VS = vsync;
  assign VGA_DE = de;
  assign VGA_SL = 2'b00;

  localparam signed [15:0] AUDIO_PIEZO_LEVEL = 16'sh2000;

  assign AUDIO_S = 1;
  assign AUDIO_L = sound ? AUDIO_PIEZO_LEVEL : -AUDIO_PIEZO_LEVEL;
  assign AUDIO_R = AUDIO_L;

endmodule
