module ram (
    input wire clk,
    input wire reset,

    input wire [3:0] cpu_id,
    input wire       default_sound_on,

    input wire [6:0] addr,
    input wire wren,
    input wire [3:0] data,

    output reg [3:0] q = 0,

    input wire [1:0] lcd_h,

    // Comb
    output reg [15:0] segment_a = 0,
    output reg [15:0] segment_b = 0,
    output reg [15:0] segment_c = 0,

    output reg [3:0] sm530_segment_a[16],
    output reg [3:0] sm530_segment_b[16]
);

  // Entire RAM is represented here. We write through to registers for display RAM (segments)
  reg [3:0] ram[128];

  // Cached versions of all segments, with 4 H values
  reg [3:0] cached_segment_a[16];
  reg [3:0] cached_segment_b[16];
  reg [3:0] cached_segment_c[16];
  reg [3:0] cached_sm530_segment_a[16];
  reg [3:0] cached_sm530_segment_b[16];

  always_comb begin
    integer i;

    for (i = 0; i < 16; i += 1) begin
      segment_a[i] = cached_segment_a[i][lcd_h];
      segment_b[i] = cached_segment_b[i][lcd_h];
      segment_c[i] = cached_segment_c[i][lcd_h];

      if (cpu_id == 3 && i < 12) begin
        sm530_segment_a[i] = ram[7'h40 + i];
        sm530_segment_b[i] = ram[7'h50 + i];
      end else begin
        sm530_segment_a[i] = cached_sm530_segment_a[i];
        sm530_segment_b[i] = cached_sm530_segment_b[i];
      end
    end
  end

  // Comb
  reg [6:0] final_addr;

  // Function separated out so it can be used for testing
  function [6:0] computed_addr();
    case (cpu_id)
	      4: begin
        // SM5a
        reg [2:0] upper_addr;
        upper_addr = addr[6:4];

        if (upper_addr > 3'h4) begin
          // Wrap 0x50 and above to 0x40
          upper_addr = 3'h4;
        end

        computed_addr = {upper_addr, addr[3:0]};

        if (addr[3:0] > 4'hC) begin
          // Wrap 0xD-F to 0xC
          computed_addr[3:0] = 4'hC;
        end
	      end
	      3: begin
	        // SM530 mirrors LCD A/B RAM at 0x40/0x60 and 0x50/0x70.
	        if ((addr[6:4] == 3'h6 || addr[6:4] == 3'h7) && addr[3:0] < 4'd12) begin
	          computed_addr = {1'b0, addr[5:0]};
	        end else begin
	          computed_addr = addr;
	        end
	      end
	      default: begin
        // SM510/SM510 Tiger
        computed_addr = addr;
      end
    endcase
  endfunction

  always_comb begin
    final_addr = computed_addr();
  end

  always @(posedge clk) begin
    if (reset) begin
      integer i;

      q <= 0;

      for (i = 0; i < 128; i += 1) begin
        ram[i] <= 0;
      end

      for (i = 0; i < 16; i += 1) begin
        cached_segment_a[i] <= 0;
        cached_segment_b[i] <= 0;
        cached_segment_c[i] <= 0;
        cached_sm530_segment_a[i] <= 0;
        cached_sm530_segment_b[i] <= 0;
      end
    end else begin
      // TODO: Does this need to be comb?
      // Nelsonic SMB3 normally boots with its alarm/melody bit clear. A
      // package may request the compatibility default without modifying its
      // program ROM or stored RAM: only CPU reads of the exact SM530 flag see
      // bit 3 asserted. All writes and every other RAM bit remain authentic.
      q <= ram[final_addr] |
          ((cpu_id == 4'd3 && default_sound_on && final_addr == 7'h37) ? 4'h8 : 4'h0);

      if (wren) begin
        ram[final_addr] <= data;

        if (cpu_id == 3 && final_addr >= 7'h40 && final_addr < 7'h4C) begin
          cached_sm530_segment_a[final_addr[3:0]] <= data;
        end else if (cpu_id == 3 && final_addr >= 7'h50 && final_addr < 7'h5C) begin
          cached_sm530_segment_b[final_addr[3:0]] <= data;
        end else if (cpu_id == 2 && final_addr >= 7'h50 && final_addr < 7'h60) begin
          // SM512 display RAM segment C
          cached_segment_c[final_addr[3:0]] <= data;
        end else if (final_addr >= 7'h60) begin
          // Display RAM segment A/B
          if (final_addr[4]) begin
            // Segment B
            cached_segment_b[final_addr[3:0]] <= data;
          end else begin
            // Segment A
            cached_segment_a[final_addr[3:0]] <= data;
          end
        end
      end
    end
  end

endmodule
