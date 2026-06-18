module video #(
    parameter CLOCK_RATIO = 3
) (
    input wire clk_sys_99_287,
    input wire clk_vid_33_095,

    input wire reset,

    input wire [3:0] cpu_id,

    // Data in
    input wire mask_data_wr,
    input wire [15:0] mask_data,

    input wire divider_1khz,

    // Segments
    input wire [15:0] current_segment_a,
    input wire [15:0] current_segment_b,
    input wire [15:0] current_segment_c,
    input wire [15:0] current_segment_bs,

    input wire [3:0] current_w_prime[9],
    input wire [3:0] current_w_main [9],

    input wire [1:0] output_lcd_h_index,

    // Settings
    input wire [7:0] lcd_off_alpha,
    input wire [1:0] crt_size,
    input wire [1:0] rotate_sel,
    input wire output_crt_15k,

    // Debug
    input wire debug_video,
    input wire [1:0] debug_view,
    input wire [63:0] debug_events,
    input wire [63:0] debug_cpu_state,
    input wire [63:0] debug_melody_state,
    input wire [63:0] debug_core_state,

    // Video
    output reg hsync,
    output reg vsync,
    output reg hblank,
    output reg vblank,

    output reg de,
    output wire ce_pix,
    output reg [23:0] rgb,

    // SDRAM
    input wire sd_data_available,
    input wire [15:0] sd_out,
    output wire sd_end_burst,
    output wire sd_rd,
    output wire [24:0] sd_rd_addr
);

  wire [9:0] video_x;
  wire [9:0] video_y;
  wire [9:0] out_x;
  wire [9:0] out_y;

  wire hsync_src;
  wire vsync_src;
  wire hblank_src;
  wire vblank_src;

  wire hsync_out;
  wire vsync_out;
  wire hblank_out;
  wire vblank_out;

  wire de_src;
  wire de_out;
  
  reg output_crt_15k_s1 = 1'b0;
  reg output_crt_15k_s2 = 1'b0;
  wire mode_crt = output_crt_15k_s2;

  wire ce_pix_src = 1'b1;
  
  always @(posedge clk_vid_33_095) begin
    if (reset) begin
      output_crt_15k_s1 <= 1'b0;
      output_crt_15k_s2 <= 1'b0;
    end else begin
      output_crt_15k_s1 <= output_crt_15k;
      output_crt_15k_s2 <= output_crt_15k_s1;
    end
  end

  reg ce_pix_crt = 1'b0;
  reg [2:0] ce_div = 3'd0;

  always @(posedge clk_vid_33_095) begin
    if (reset) begin
      ce_div <= 3'd0;
      ce_pix_crt <= 1'b0;
    end else begin
      ce_pix_crt <= 1'b0;
      if (ce_div == 3'd5) begin
        ce_div <= 3'd0;
        ce_pix_crt <= 1'b1;
      end else begin
        ce_div <= ce_div + 3'd1;
      end
    end
  end

  assign ce_pix = mode_crt ? ce_pix_crt : 1'b1;

  ////////////////////////////////////////////////////////////////////////////////////////
  // LCD

  wire segment_en;

  lcd #(
      .CLOCK_RATIO(CLOCK_RATIO)
  ) lcd (
      .clk(clk_sys_99_287),

      .reset(reset),

      .cpu_id(cpu_id),

      .mask_data_wr(mask_data_wr),
      .mask_data(mask_data),

      // Segments
      .current_segment_a (current_segment_a),
      .current_segment_b (current_segment_b),
      .current_segment_c (current_segment_c),
      .current_segment_bs(current_segment_bs),

      .current_w_prime(current_w_prime),
      .current_w_main (current_w_main),

      .output_lcd_h_index(output_lcd_h_index),

      .divider_1khz(divider_1khz),

      // Video counters
      .vblank_int(vblank_src),
      .hblank_int(hblank_src),
      .video_x(video_x),
      .video_y(video_y),

      .segment_en(segment_en)
  );

  ////////////////////////////////////////////////////////////////////////////////////////
  // SDRAM and RGB

  wire [23:0] background_rgb;
  wire [23:0] mask_rgb;
  wire [23:0] processed_rgb;

  wire [7:0] alpha = reset ? 8'h00 : segment_en ? 8'hFF : lcd_off_alpha;

  localparam integer CRT_W = 240;
  localparam integer CRT_H = 240;
  localparam integer CRT_FB_SIZE = CRT_W * CRT_H;
 
  wire [1:0] crt_size_eff   = mode_crt ? crt_size   : 2'd0;
  wire [1:0] rotate_sel_eff = mode_crt ? rotate_sel : 2'd0;

  wire [9:0] crt_img_w =
      (crt_size_eff == 2'd0) ? 10'd240 :   // 100%
      (crt_size_eff == 2'd1) ? 10'd180 :   // 75%
      (crt_size_eff == 2'd2) ? 10'd120 :   // 50%
                                 10'd240;  // fallback

  wire [9:0] crt_img_h = crt_img_w;
  wire [9:0] crt_x_off = (10'd320 - crt_img_w) >> 1;
  wire [9:0] crt_y_off = (10'd240 - crt_img_h) >> 1;

  reg        crt_wr_en = 1'b0;
  reg [15:0] crt_wr_addr = 16'd0;
  reg [23:0] crt_wr_data = 24'h000000;

  reg [15:0] crt_rd_addr = 16'd0;
  reg        crt_rd_active = 1'b0;
  reg [23:0] crt_pixel = 24'h000000;

  wire [7:0] crt_r_q;
  wire [7:0] crt_g_q;
  wire [7:0] crt_b_q;
  
  integer wr_addr_calc;
  integer rd_addr_calc;
  reg [9:0] disp_x;
  reg [9:0] disp_y;
  reg [9:0] fb_x;
  reg [9:0] fb_y;

  alpha_blend alpha_blend (
      .background_pixel(background_rgb),
      .foreground_pixel({mask_rgb, alpha}),

      .output_pixel(processed_rgb)
  );

  crt_fb_ram #(
      .ADDR_WIDTH(16),
      .DEPTH(CRT_FB_SIZE)
  ) crt_fb_r (
      .clk(clk_vid_33_095),
      .we(crt_wr_en),
      .wr_addr(crt_wr_addr),
      .din(crt_wr_data[23:16]),
      .rd_addr(crt_rd_addr),
      .dout(crt_r_q)
  );

  crt_fb_ram #(
      .ADDR_WIDTH(16),
      .DEPTH(CRT_FB_SIZE)
  ) crt_fb_g (
      .clk(clk_vid_33_095),
      .we(crt_wr_en),
      .wr_addr(crt_wr_addr),
      .din(crt_wr_data[15:8]),
      .rd_addr(crt_rd_addr),
      .dout(crt_g_q)
  );

  crt_fb_ram #(
      .ADDR_WIDTH(16),
      .DEPTH(CRT_FB_SIZE)
  ) crt_fb_b (
      .clk(clk_vid_33_095),
      .we(crt_wr_en),
      .wr_addr(crt_wr_addr),
      .din(crt_wr_data[7:0]),
      .rd_addr(crt_rd_addr),
      .dout(crt_b_q)
  );

  wire [2:0] debug_col = video_x[8:6];
  wire [2:0] debug_row = video_y[8:6];
  wire [5:0] debug_idx = {debug_row, debug_col};
  wire debug_panel = video_x < 10'd512 && video_y < 10'd512;
  wire debug_grid = (video_x[5:0] == 6'd0) || (video_y[5:0] == 6'd0);

  reg [63:0] debug_bits;
  always_comb begin
    case (debug_view)
      2'd1: debug_bits = debug_cpu_state;
      2'd2: debug_bits = debug_melody_state;
      2'd3: debug_bits = debug_core_state;
      default: debug_bits = debug_events;
    endcase
  end

  reg [23:0] debug_row_rgb;
  always_comb begin
    case (debug_row)
      3'd0: debug_row_rgb = 24'hffffff;
      3'd1: debug_row_rgb = 24'h00ff00;
      3'd2: debug_row_rgb = 24'hffff00;
      3'd3: debug_row_rgb = 24'h00ffff;
      3'd4: debug_row_rgb = 24'hff80ff;
      3'd5: debug_row_rgb = 24'hff8000;
      3'd6: debug_row_rgb = 24'h80a0ff;
      default: debug_row_rgb = 24'hff4040;
    endcase
  end

  wire debug_cell_on = debug_panel && debug_bits[debug_idx];
  wire [23:0] debug_rgb =
      !de_src        ? 24'h000000 :
      !debug_panel   ? 24'h000010 :
      debug_grid     ? 24'h202020 :
      debug_cell_on  ? debug_row_rgb :
                       24'h080008;

  wire [23:0] final_rgb = debug_video ? debug_rgb : processed_rgb;

  always @(posedge clk_vid_33_095) begin
 
    crt_wr_en <= 1'b0;
    crt_wr_addr <= 16'd0;
    crt_wr_data <= 24'h000000;

    if (de_src && (video_x < 10'd720) && (video_y < 10'd720)) begin
      if ((video_x % 3 == 0) && (video_y % 3 == 0)) begin
        wr_addr_calc = (video_y / 3) * CRT_W + (video_x / 3);
        if (wr_addr_calc >= 0 && wr_addr_calc < CRT_FB_SIZE) begin
          crt_wr_en   <= 1'b1;
          crt_wr_addr <= wr_addr_calc[15:0];
          crt_wr_data <= final_rgb;
        end
      end
    end

    if (de_out &&
        out_x >= crt_x_off && out_x < (crt_x_off + crt_img_w) &&
        out_y >= crt_y_off && out_y < (crt_y_off + crt_img_h)) begin

      disp_x = out_x - crt_x_off;
      disp_y = out_y - crt_y_off;

      case (rotate_sel_eff)
        2'd0: begin
          // 0 degrees
          fb_x = (disp_x * CRT_W) / crt_img_w;
          fb_y = (disp_y * CRT_H) / crt_img_h;
        end

        2'd1: begin
          // 90 degrees clockwise
          fb_x = (disp_y * CRT_W) / crt_img_h;
          fb_y = (CRT_H - 1) - ((disp_x * CRT_H) / crt_img_w);
        end

        2'd2: begin
          // 180 degrees
          fb_x = (CRT_W - 1) - ((disp_x * CRT_W) / crt_img_w);
          fb_y = (CRT_H - 1) - ((disp_y * CRT_H) / crt_img_h);
        end

        default: begin
          // 270 degrees clockwise
          fb_x = (CRT_W - 1) - ((disp_y * CRT_W) / crt_img_h);
          fb_y = (disp_x * CRT_H) / crt_img_w;
        end
      endcase

      rd_addr_calc = fb_y * CRT_W + fb_x;

      if (rd_addr_calc >= 0 && rd_addr_calc < CRT_FB_SIZE) begin
        crt_rd_addr   <= rd_addr_calc[15:0];
        crt_rd_active <= 1'b1;
      end else begin
        crt_rd_addr   <= 16'd0;
        crt_rd_active <= 1'b0;
      end
    end else begin
      crt_rd_addr   <= 16'd0;
      crt_rd_active <= 1'b0;
    end

	 crt_pixel <= crt_rd_active ? {crt_r_q, crt_g_q, crt_b_q} : 24'h000000;
  end

  rgb_controller rgb_controller (
      .clk_sys_99_287(clk_sys_99_287),
      .clk_vid_33_095(clk_vid_33_095),

      .reset(reset),

      // Video
      .hblank_int(hblank_src),
      .video_y(video_y),
      .de_int(de_src),

      // RGB
      .background_rgb(background_rgb),
      .mask_rgb(mask_rgb),

      // SDRAM
      .sd_data_available(sd_data_available),
      .sd_out(sd_out),
      .sd_end_burst(sd_end_burst),
      .sd_rd(sd_rd),
      .sd_rd_addr(sd_rd_addr)
  );

  ////////////////////////////////////////////////////////////////////////////////////////
  // Sync counts

  // Delay all signals by 1 cycle so that RGB is caught up
  always @(posedge clk_vid_33_095) begin
    if (mode_crt) begin
      hsync  <= hsync_out;
      vsync  <= vsync_out;
      hblank <= hblank_out;
      vblank <= vblank_out;
      de     <= de_out;
      rgb    <= crt_pixel;
    end else begin
      hsync  <= hsync_src;
      vsync  <= vsync_src;
      hblank <= hblank_src;
      vblank <= vblank_src;
      de     <= de_src;
      rgb    <= final_rgb;
    end
  end

  counts counts (
      .clk(clk_vid_33_095),
      .ce_pix(ce_pix_src),

      .x(video_x),
      .y(video_y),

      .hsync (hsync_src),
      .vsync (vsync_src),
      .hblank(hblank_src),
      .vblank(vblank_src),

      .de(de_src)
  );

  counts_15k counts_15k (
      .clk(clk_vid_33_095),
      .ce_pix(ce_pix_crt),

      .x(out_x),
      .y(out_y),

      .hsync (hsync_out),
      .vsync (vsync_out),
      .hblank(hblank_out),
      .vblank(vblank_out),

      .de(de_out)
  );

endmodule
