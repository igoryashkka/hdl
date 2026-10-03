# run after the build: reports from the routed checkpoint (kept next to the project)
open_checkpoint nano_sdr_pluto_ofdm_rx.runs/impl_1/system_top_routed.dcp
report_timing_summary -max_paths 600 -file reports_timing.rpt
report_utilization -file reports_util.rpt
report_utilization -hierarchical -file reports_util_hier.rpt
