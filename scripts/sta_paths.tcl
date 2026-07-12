# sta_paths.tcl — archive the real critical paths of the board top.
# Run by `make synth-sta` as: quartus_sta -t scripts/sta_paths.tcl rv32i_cpu
# (cwd = synth/). The default quartus_sta flow only writes summary tables;
# this dumps the top 20 setup paths with full detail so every board compile
# self-documents WHERE the critical path lives (audit 2026-07-11 — the
# board top's path had never been recorded, only bare-core ad-hoc runs).

project_open rv32i_cpu
create_timing_netlist -model slow
read_sdc
update_timing_netlist

report_timing -setup -npaths 20 -detail full_path \
    -file output_files/critical_paths.rpt
report_clock_fmax_summary -file output_files/fmax_summary.rpt

# Also echo the Fmax summary to stdout so the make log shows it inline.
report_clock_fmax_summary -stdout

delete_timing_netlist
project_close
