// 1024-entry asynchronous FIFO for complete video packets. Show-ahead mode
// keeps q on the current head so the 54 MHz bridge can present a packet and
// dequeue it on the same edge, including consecutive native CE pulses.
module video_packet_fifo (
    input wire aclr,

    input wire wrclk,
    input wire wrreq,
    input wire [29:0] data,
    output wire wrfull,
    output wire [9:0] wrusedw,

    input wire rdclk,
    input wire rdreq,
    output wire [29:0] q,
    output wire rdempty,
    output wire [9:0] rdusedw
);
  dcfifo dcfifo_component (
      .aclr(aclr),
      .data(data),
      .wrclk(wrclk),
      .wrreq(wrreq),
      .wrfull(wrfull),
      .wrusedw(wrusedw),
      .rdclk(rdclk),
      .rdreq(rdreq),
      .q(q),
      .rdempty(rdempty),
      .rdusedw(rdusedw),
      .rdfull(),
      .wrempty(),
      .eccstatus()
  );

  defparam
      dcfifo_component.add_ram_output_register = "OFF",
      dcfifo_component.add_usedw_msb_bit = "OFF",
      dcfifo_component.clocks_are_synchronized = "FALSE",
      dcfifo_component.intended_device_family = "Cyclone V",
      dcfifo_component.lpm_numwords = 1024,
      dcfifo_component.lpm_showahead = "ON",
      dcfifo_component.lpm_hint =
          "USE_EAB=ON,DISABLE_DCFIFO_EMBEDDED_TIMING_CONSTRAINT=TRUE",
      dcfifo_component.lpm_type = "dcfifo",
      dcfifo_component.lpm_width = 30,
      dcfifo_component.lpm_widthu = 10,
      dcfifo_component.overflow_checking = "ON",
      dcfifo_component.rdsync_delaypipe = 4,
      dcfifo_component.read_aclr_synch = "ON",
      dcfifo_component.underflow_checking = "ON",
      dcfifo_component.use_eab = "ON",
      dcfifo_component.write_aclr_synch = "ON",
      dcfifo_component.wrsync_delaypipe = 4;
endmodule
