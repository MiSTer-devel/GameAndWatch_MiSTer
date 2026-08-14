# Fixed-54 transport clock-domain crossing constraints. The dedicated packet
# FIFO disables Intel's broad embedded false paths and replaces them with the
# bounded Gray-pointer constraints from Quartus Prime 17.0's dcfifo.sdc.

proc gw_need_exact {label collection expected} {
  set count [get_collection_size $collection]
  if {$count != $expected} {
    error "GameAndWatch: expected $expected $label nodes, matched $count"
  }
  post_message -type info "GameAndWatch: $label matched $count nodes"
}

proc gw_need_empty {label collection} {
  set count [get_collection_size $collection]
  if {$count != 0} {
    error "GameAndWatch: expected no $label nodes, matched $count"
  }
  post_message -type info "GameAndWatch: $label matched 0 nodes"
}

proc gw_need_clock {label pattern} {
  set clocks [get_clocks -nowarn $pattern]
  set count [get_collection_size $clocks]
  if {$count != 1} {
    error "GameAndWatch: expected one $label clock matching $pattern, got $count"
  }
  post_message -type info "GameAndWatch: $label clock matched $pattern"
  return $clocks
}

proc gw_need_period {label clock expected tolerance} {
  set actual [get_clock_info -period $clock]
  if {[expr {abs($actual - $expected)}] > $tolerance} {
    error "GameAndWatch: expected $label period $expected ns, got $actual ns"
  }
  post_message -type info \
      "GameAndWatch: $label period $actual ns matched expected $expected ns"
}

proc gw_gray_pointer {source destination} {
  set_max_skew -from $source -to $destination \
      -get_skew_value_from_clock_period src_clock_period \
      -skew_value_multiplier 0.8
  set_net_delay -from $source -to $destination -max \
      -get_value_from_clock_period dst_clock_period \
      -value_multiplier 0.8
  set_max_delay -from $source -to $destination 100
  set_min_delay -from $source -to $destination -100
}

proc gw_mstable_delay {source destination} {
  set_net_delay -from $source -to $destination -max \
      -get_value_from_clock_period dst_clock_period \
      -value_multiplier 0.8
}

# Fitter routing optimization may legally add `~DUPLICATE` keepers to a FIFO
# pointer or synchronizer stage. Validate the canonical bus width exactly, but
# return the complete collection so constraints also cover any such replicas.
proc gw_keeper_set {label pattern expected} {
  set all_nodes [get_keepers -nowarn $pattern]
  set canonical_nodes [get_keepers -no_duplicates -nowarn $pattern]
  set all_count [get_collection_size $all_nodes]
  set canonical_count [get_collection_size $canonical_nodes]
  set duplicate_count [expr {$all_count - $canonical_count}]
  if {$duplicate_count < 0} {
    error "GameAndWatch: invalid $label keeper counts ($all_count total, $canonical_count canonical)"
  }
  gw_need_exact $label $canonical_nodes $expected
  post_message -type info \
      "GameAndWatch: $label includes $duplicate_count fitted duplicate nodes"
  return $all_nodes
}

if {![info exists ::TimeQuestInfo(nameofexecutable)]} {
  error "GameAndWatch: TimeQuest executable identity unavailable"
}
set GW_EXECUTABLE $::TimeQuestInfo(nameofexecutable)

# quartus_map's pre-synthesis timing netlist cannot resolve generated PLL
# clocks or post-map keepers/pins from this core-owned SDC. The framework SDC
# still supplies its ordinary map-stage clocks and exceptions. Placement,
# routing, and final TimeQuest runs below apply the complete fail-closed clock,
# CDC, and reset constraint set.
if {$GW_EXECUTABLE eq "quartus_map"} {
  post_message -type info \
      "GameAndWatch: quartus_map defers transport clock and structural constraints to fit/STA"
  return
}

# sys_top.sdc already groups the mapped 98.3203125 MHz core clock away from
# framework domains. Extend those same cuts to the fixed 54 MHz clock while
# keeping the core and transport clocks together: never cut the FIFO domains
# apart.
set GW_CORE_CLOCK \
    [gw_need_clock core98 {*|pll|pll_inst|altera_pll_i|*|divclk}]
set GW_VIDEO_CLOCK \
    [gw_need_clock video54 {*|video_pll|video_pll_inst|*|divclk}]
# Quartus 17's get_clock_info interface quantizes periods to three decimal
# places. These values still distinguish the required mapped 98.3203125 MHz
# core (10.170) from the IP request's nominal 98.304 MHz (10.172).
gw_need_period core98  $GW_CORE_CLOCK  10.170 0.0001
gw_need_period video54 $GW_VIDEO_CLOCK 18.518 0.0001
set GW_SOURCE_CLOCKS [add_to_collection $GW_CORE_CLOCK $GW_VIDEO_CLOCK]

set_clock_groups -exclusive \
    -group $GW_SOURCE_CLOCKS \
    -group [get_clocks {pll_hdmi|pll_hdmi_inst|altera_pll_i|*[0].*|divclk}] \
    -group [get_clocks {pll_audio|pll_audio_inst|altera_pll_i|*[0].*|divclk}] \
    -group [get_clocks {spi_sck}] \
    -group [get_clocks {hdmi_sck}] \
    -group [get_clocks {*|h2f_user0_clk}] \
    -group [get_clocks {FPGA_CLK1_50}] \
    -group [get_clocks {FPGA_CLK2_50}] \
    -group [get_clocks {FPGA_CLK3_50}]

set GW_FIFO_INSTANCES [get_entity_instances video_packet_fifo]
set GW_FIFO_INSTANCE_COUNT [llength $GW_FIFO_INSTANCES]
if {$GW_FIFO_INSTANCE_COUNT != 1} {
  error "GameAndWatch: expected one packet FIFO instance, matched $GW_FIFO_INSTANCE_COUNT"
}
post_message -type info \
    "GameAndWatch: packet_fifo_instances matched $GW_FIFO_INSTANCE_COUNT instance"

foreach GW_FIFO_PATH $GW_FIFO_INSTANCES {
  set GW_READ_GRAY [gw_keeper_set fifo_read_gray_launch \
      [format {%s|dcfifo_component|auto_generated|rdptr_g[*]} \
          $GW_FIFO_PATH] 11]
  set GW_READ_SYNC_FIRST [gw_keeper_set fifo_read_gray_sync_first \
      [format {%s|dcfifo_component|auto_generated|*ws_dgrp|dffpipe*|dffe*2a[*]} \
          $GW_FIFO_PATH] 11]
  set GW_READ_SYNC_SECOND [gw_keeper_set fifo_read_gray_sync_second \
      [format {%s|dcfifo_component|auto_generated|*ws_dgrp|dffpipe*|dffe*3a[*]} \
          $GW_FIFO_PATH] 11]
  set GW_WRITE_GRAY [gw_keeper_set fifo_write_gray_launch \
      [format {%s|dcfifo_component|auto_generated|delayed_wrptr_g[*]} \
          $GW_FIFO_PATH] 11]
  set GW_WRITE_SYNC_FIRST [gw_keeper_set fifo_write_gray_sync_first \
      [format {%s|dcfifo_component|auto_generated|*rs_dgwp|dffpipe*|dffe*2a[*]} \
          $GW_FIFO_PATH] 11]
  set GW_WRITE_SYNC_SECOND [gw_keeper_set fifo_write_gray_sync_second \
      [format {%s|dcfifo_component|auto_generated|*rs_dgwp|dffpipe*|dffe*3a[*]} \
          $GW_FIFO_PATH] 11]

  # Bound the asynchronous Gray bus through the first destination stage, then
  # bound routing to the second destination stage so it retains almost a full
  # clock period for metastability resolution. Requested delaypipe=4 maps to
  # exactly these two physical dffpipe stages on Cyclone V in Quartus 17.
  gw_gray_pointer  $GW_READ_GRAY       $GW_READ_SYNC_FIRST
  gw_mstable_delay $GW_READ_SYNC_FIRST $GW_READ_SYNC_SECOND
  gw_gray_pointer  $GW_WRITE_GRAY       $GW_WRITE_SYNC_FIRST
  gw_mstable_delay $GW_WRITE_SYNC_FIRST $GW_WRITE_SYNC_SECOND
}

# Cut only the first stage of the bridge's explicit single-bit synchronizers.
set GW_CONTROL_META \
    [get_keepers -nowarn {*|video_transport_54:video_transport|*_meta}]
gw_need_exact bridge_control_first_stage $GW_CONTROL_META 3
set_false_path -to $GW_CONTROL_META

# CRT packet pacing originates in the 54 MHz bridge and crosses back as a
# toggle. Cut only the first source-domain synchronizer stage; the second
# stage and edge detector remain timed by the core clock.
set GW_CRT_TICK_META [gw_keeper_set crt_source_tick_first_stage \
    {*|video_timing:video_timing|crt_tick_meta} 1]
set_false_path -to $GW_CRT_TICK_META

# hps_io consumes new_vmode in the fixed-54 MHz domain. Cut only the first
# stage of the explicit two-register toggle synchronizer; the second-stage
# data path remains timed by the video clock.
set GW_NEW_VMODE_META [gw_keeper_set hps_new_vmode_first_stage \
    {*|new_vmode_video_pipe[0]} 1]
set_false_path -to $GW_NEW_VMODE_META

# The MiSTer framework contains a small set of intentional crossings that its
# usual shared video/core clock does not expose. Keep these exceptions narrow:
# slow configuration is cut only into the fixed video domain, video telemetry
# only into its HPS readback register, and frame status only into the first
# core-domain sampling registers. This leaves every transport FIFO endpoint
# fully timed by the bounded Gray-pointer constraints above.
set GW_FRAMEWORK_VIDEO_CONFIG [gw_keeper_set framework_video_config_sources {
  LFB_EN LFB_FLT FREESCALE HDMI_PR lowlat cfg_done subcarrier
  osd:vga_osd|osd_enable
  osd:vga_osd|info
  osd:vga_osd|infoh[*]
  osd:vga_osd|infow[*]
  osd:vga_osd|osd_h[*]
  osd:vga_osd|osd_w[*]
} 33]
set_false_path -from $GW_FRAMEWORK_VIDEO_CONFIG -to $GW_VIDEO_CLOCK

set GW_VIDEO_TELEMETRY [gw_keeper_set framework_video_telemetry_sources {
  *|hps_io:hps_io|video_calc:video_calc|vid_hcnt[*]
  *|hps_io:hps_io|video_calc:video_calc|vid_vcnt[*]
  *|hps_io:hps_io|video_calc:video_calc|vid_ccnt[*]
  *|hps_io:hps_io|video_calc:video_calc|vid_nres[*]
  *|hps_io:hps_io|video_calc:video_calc|vid_pixrep[*]
  *|hps_io:hps_io|video_calc:video_calc|vid_de_h[*]
  *|hps_io:hps_io|video_calc:video_calc|vid_de_v[*]
} 136]
set GW_VIDEO_TELEMETRY_DOUT [gw_keeper_set framework_video_telemetry_dout \
    {*|hps_io:hps_io|video_calc:video_calc|dout[*]} 16]
set_false_path -from $GW_VIDEO_TELEMETRY -to $GW_VIDEO_TELEMETRY_DOUT

set GW_VGA_FRAME_STATUS [gw_keeper_set framework_vga_frame_status \
    {vs_r vs_old} 2]
set_false_path -from $GW_VIDEO_CLOCK -to $GW_VGA_FRAME_STATUS

set GW_HDMI_FRAME_STATUS [gw_keeper_set framework_hdmi_frame_status \
    {vs_d0 vs_d1 vsd} 3]
set_false_path -from $GW_VIDEO_CLOCK -to $GW_HDMI_FRAME_STATUS

# The bridge's three explicit reset pipes and dcfifo's clock-local ACLR pipes
# asynchronously assert but synchronously release. Cut recovery/removal only
# at their asynchronous clear pins; data/clock paths through every keeper stay
# timed. Fail closed on both expected CLRN pins and the absence of PRN pins so
# a future synthesis-topology change cannot silently broaden this exception.
set GW_TOP_RESET_CLRN \
    [get_pins -compatibility_mode -nowarn \
        {*|video_transport_reset_pipe[*]|clrn}]
set GW_WRITE_RESET_CLRN \
    [get_pins -compatibility_mode -nowarn \
        {*|fifo_write_reset_pipe[*]|clrn}]
set GW_SOURCE_RESET_CLRN \
    [get_pins -compatibility_mode -nowarn \
        {*|source_global_reset_pipe[*]|clrn}]
set GW_FIFO_RDACLR_CLRN \
    [get_pins -compatibility_mode -nowarn \
        {*|transport_fifo|dcfifo_component|*rdaclr*|clrn}]
set GW_FIFO_WRACLR_CLRN \
    [get_pins -compatibility_mode -nowarn \
        {*|transport_fifo|dcfifo_component|*wraclr*|clrn}]

gw_need_exact bridge_top_reset_clrn    $GW_TOP_RESET_CLRN    3
gw_need_exact bridge_write_reset_clrn  $GW_WRITE_RESET_CLRN  3
gw_need_exact bridge_source_reset_clrn $GW_SOURCE_RESET_CLRN 3
gw_need_exact packet_fifo_rdaclr_clrn  $GW_FIFO_RDACLR_CLRN  2
gw_need_exact packet_fifo_wraclr_clrn  $GW_FIFO_WRACLR_CLRN  2

gw_need_empty bridge_top_reset_prn \
    [get_pins -compatibility_mode -nowarn \
        {*|video_transport_reset_pipe[*]|prn}]
gw_need_empty bridge_write_reset_prn \
    [get_pins -compatibility_mode -nowarn \
        {*|fifo_write_reset_pipe[*]|prn}]
gw_need_empty bridge_source_reset_prn \
    [get_pins -compatibility_mode -nowarn \
        {*|source_global_reset_pipe[*]|prn}]
gw_need_empty packet_fifo_rdaclr_prn \
    [get_pins -compatibility_mode -nowarn \
        {*|transport_fifo|dcfifo_component|*rdaclr*|prn}]
gw_need_empty packet_fifo_wraclr_prn \
    [get_pins -compatibility_mode -nowarn \
        {*|transport_fifo|dcfifo_component|*wraclr*|prn}]

set GW_ASYNC_CLEAR_PINS [add_to_collection $GW_TOP_RESET_CLRN \
    $GW_WRITE_RESET_CLRN]
set GW_ASYNC_CLEAR_PINS [add_to_collection $GW_ASYNC_CLEAR_PINS \
    $GW_SOURCE_RESET_CLRN]
set GW_ASYNC_CLEAR_PINS [add_to_collection $GW_ASYNC_CLEAR_PINS \
    $GW_FIFO_RDACLR_CLRN]
set GW_ASYNC_CLEAR_PINS [add_to_collection $GW_ASYNC_CLEAR_PINS \
    $GW_FIFO_WRACLR_CLRN]
set_false_path -to $GW_ASYNC_CLEAR_PINS
