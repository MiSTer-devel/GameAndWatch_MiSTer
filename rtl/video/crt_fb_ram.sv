module crt_fb_ram #(
    parameter integer ADDR_WIDTH = 16,
    parameter integer DEPTH = 57600
) (
    input  wire                   clk,
    input  wire                   we,
    input  wire [ADDR_WIDTH-1:0]  wr_addr,
    input  wire [7:0]             din,
    input  wire [ADDR_WIDTH-1:0]  rd_addr,
    output reg  [7:0]             dout
);

  // Force Quartus toward block RAM instead of registers
  (* ramstyle = "M10K, no_rw_check" *) reg [7:0] mem [0:DEPTH-1];

  always @(posedge clk) begin
    if (we) begin
      mem[wr_addr] <= din;
    end

    // synchronous read
    dout <= mem[rd_addr];
  end

endmodule