# run after the build: reports from the routed checkpoint
open_checkpoint nano_sdr_pluto_ofdm_tx7020.runs/impl_1/system_top_routed.dcp
report_timing_summary -max_paths 100 -file reports_timing.rpt
report_utilization -file reports_util.rpt
report_utilization -hierarchical -file reports_util_hier.rpt
