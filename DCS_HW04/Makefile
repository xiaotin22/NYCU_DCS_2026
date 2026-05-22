#===============================================================================
# ASIC Design Flow Makefile
# Supports: VCS, Cadence (irun/xrun), Verdi, Design Compiler
#===============================================================================

.PHONY: vcs_rtl vcs_gate \
				irun_rtl irun_gate \
				xrun_rtl xrun_gate \
				nWave verdi_rtl verdi_gate \
				setup_dc syn syn_gui check_rtl view_netlist clean

#-------------------------------------------------------------------------------
# 1. Project Configuration
#-------------------------------------------------------------------------------
TOP_DESIGN  = MHA
SRC_FILE    = "filelist.f"
OUTPUT_NAME = "simv"
LOG_VCS     = "vcs.log"
RC_FILE     = "signal.rc"

# Synthesis & Timing logs/scripts
SYN_TCL     = "syn.tcl"
SYN_LOG     = "syn.log"
PT_TCL      = "pt.tcl"
PT_LOG      = "pt.log"

# Hardware Resources
CPU_CORES   = 4

#-------------------------------------------------------------------------------
# 2. Tool Paths & Simulation Libraries
#-------------------------------------------------------------------------------
VERDI_HOME ?= /usr/cad/synopsys/verdi/cur2/
DW_SIM_LIB ?= /usr/cad/synopsys/synthesis/cur/dw/sim_ver/

# --- UMC 180nm Settings ---
UMC018_SIM    = /usr/cad/umc018/Verilog/umc18_neg.v
UMC018_SEARCH = ./ ../01_RTL \
                /usr/cad/umc018/Synthesis/ \
                /CAD/synopsys/synthesis/cur/libraries/syn/ \
                /CAD/synopsys/synthesis/cur/dw/
UMC018_TARGET = slow.db

# Simulation Settings
TIMESCALE     = -timescale=1ns/1fs
TIMESCALE_C   = -timescale 1ns/1fs # Cadence format

#-------------------------------------------------------------------------------
# 3. Tool Commands & Options
#-------------------------------------------------------------------------------

# Define handler
VCS_DEF = $(foreach d, $(define), +define+$(d))
CAD_DEF = $(foreach d, $(define), -define $(d))

# --- Synopsys VCS ---
VCS_COMMON_OPTS = vcs $(TIMESCALE) \
                      -j$(CPU_CORES) \
                      -sverilog +v2k -full64 \
                      -Mupdate -R \
                      -debug_access+all \
                      -f $(SRC_FILE) \
                      -o $(OUTPUT_NAME) \
                      -l $(LOG_VCS)

VCS_RTL_SIM  = $(VCS_COMMON_OPTS) -y $(DW_SIM_LIB) +define+RTL  $(VCS_DEF) +libext+.v +notimingchecks
VCS_GATE_SIM = $(VCS_COMMON_OPTS) -v $(UMC018_SIM) +define+GATE $(VCS_DEF) +neg_tchk +nowarnNTCDSN

# --- Cadence Irun / Xrun ---
CAD_COMMON      = -f $(SRC_FILE) -loadpli1 debpli:novas_pli_boot -debug $(CAD_DEF)

IRUN_COMMON_OPTS = irun $(CAD_COMMON) $(TIMESCALE_C) -override_precision -sdf_precision 1fs
IRUN_RTL_SIM     = $(IRUN_COMMON_OPTS) -incdir $(DW_SIM_LIB) -notimingchecks -define RTL
IRUN_GATE_SIM    = $(IRUN_COMMON_OPTS) -v $(UMC018_SIM) -define GATE

XRUN_COMMON_OPTS = xrun $(CAD_COMMON) -mcl $(CPU_CORES) $(TIMESCALE_C) -override_precision -sdf_precision 1fs
XRUN_RTL_SIM     = $(XRUN_COMMON_OPTS) -incdir $(DW_SIM_LIB) -notimingchecks -define RTL
XRUN_GATE_SIM    = $(XRUN_COMMON_OPTS) -v $(UMC018_SIM) -define GATE

# --- Debug Tools (Verdi / nWave) ---
VERDI_OPTS   = -ssf *.fsdb -sv -f $(SRC_FILE) -nologo +v2k -autoalias \
               $(shell [ -f $(RC_FILE) ] && echo "-sswr $(RC_FILE)")

#-------------------------------------------------------------------------------
# 4. Simulation Targets
#-------------------------------------------------------------------------------

# Run Synopsys VCS RTL simulation (behavioral level)
vcs_rtl:
	$(VCS_RTL_SIM)

# Run Synopsys VCS Gate-level simulation (after synthesis, with cell library)
vcs_gate:
	$(VCS_GATE_SIM)

# Run Cadence irun RTL simulation
irun_rtl:
	$(IRUN_RTL_SIM)

# Run Cadence irun Gate-level simulation
irun_gate:
	$(IRUN_GATE_SIM)

# Run Cadence xrun RTL simulation (multi-core supported)
xrun_rtl:
	$(XRUN_RTL_SIM)

# Run Cadence xrun Gate-level simulation
xrun_gate:
	$(XRUN_GATE_SIM)

#-------------------------------------------------------------------------------
# 5. Debugging & Visualization
#-------------------------------------------------------------------------------

# Open nWave waveform viewer and load FSDB files
nWave:
	nWave -ssf *.fsdb $(shell [ -f $(RC_FILE) ] && echo "-sswr $(RC_FILE)") &

# Open Verdi for RTL code debugging and waveform linkage
verdi_rtl:
	verdi $(VERDI_OPTS) +define+RTL &

# Open Verdi for Gate-level debugging (linked with tech library)
verdi_gate:
	verdi $(VERDI_OPTS) +define+GATE &

#-------------------------------------------------------------------------------
# 6. Synthesis, Timing & APR
#-------------------------------------------------------------------------------

# Generate the .synopsys_dc.setup file based on the selected PROCESS
setup_dc:
	@echo "set search_path \" $(UMC018_SEARCH) \"" > .synopsys_dc.setup
	@echo "set target_library \" $(UMC018_TARGET) \"" >> .synopsys_dc.setup
	@echo "set link_library \" * \$$target_library dw_foundation.sldb standard.sldb \"" >> .synopsys_dc.setup
	@echo "set symbol_library \" *.sdb \"" >> .synopsys_dc.setup
	@echo "set synthetic_library \" dw_foundation.sldb \"" >> .synopsys_dc.setup
	@echo "set verilogout_no_tri true" >> .synopsys_dc.setup
	@echo "set hdlin_enable_presto_for_vhdl TRUE" >> .synopsys_dc.setup
	@echo "set sh_enable_line_editing true" >> .synopsys_dc.setup
	@echo "history keep 100" >> .synopsys_dc.setup
	@echo "alias h history" >> .synopsys_dc.setup

# Run full synthesis flow in background (command line mode)
syn: setup_dc
	dcnxt_shell -f $(SYN_TCL) -x "set_host_options -max_cores $(CPU_CORES)" -output_log_file $(SYN_LOG)

# Run full synthesis flow and open Design Vision GUI upon completion
syn_gui: setup_dc
	dcnxt_shell -f $(SYN_TCL) -x "set_host_options -max_cores $(CPU_CORES)" -output_log_file $(SYN_LOG) -gui

# Quickly check RTL syntax and view GTECH schematic in Design Vision
check_rtl: setup_dc
	dcnxt_shell -x 'read_sverilog $(TOP_DESIGN).v' -gui

# Open Design Vision to view an existing synthesized .ddc netlist file
view_netlist: setup_dc
	dcnxt_shell -x "read_ddc $(TOP_DESIGN)_SYN.ddc" -gui

#-------------------------------------------------------------------------------
# 7. Cleanup
#-------------------------------------------------------------------------------

# Remove all temporary files generated by simulation, synthesis, and APR tools
clean:
	rm -rf *.fsdb ./csrc *.log $(OUTPUT_NAME)* *.sdf.X *.key ./verdiLog
	rm -rf ./INCA_libs ./xcelium.d *.history ./nWaveLog novas.rc
	rm -rf ./Netlist/* ./Report/* alib* *.svf dwsvf* *.ddc *.pvl *.syn *.mr *.conf .synopsys_dc.setup
	rm -rf vcd.out ./fsdb2vcdLog checkDesign *.rpt* *.CCOPT.spec *.checkPlace
	rm -rf ./StreamOut/* CHIP_SYN.v *.globals extLogDir ./log/* ./DBS/* ./timingReports/* *.bin