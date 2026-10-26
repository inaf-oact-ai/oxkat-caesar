#!/usr/bin/env bash
# =============================================================================
# oxkat pipeline — staged runner
# =============================================================================
#
# USAGE:
#   chmod +x oxkat_pipeline.sh
#
#   ./oxkat_pipeline.sh init      # Copy MS, clone oxkat, patch config
#   ./oxkat_pipeline.sh getinfo   # Inspect MS with ms_info.py (read-only)
#   ./oxkat_pipeline.sh 1gc       # Reference calibration
#   ./oxkat_pipeline.sh flag      # Target flagging + blind image + mask
#   ./oxkat_pipeline.sh 2gc       # Direction-independent self-calibration
#
# Run stages in order. Each stage is independent and can be re-run safely.
# =============================================================================

set -euo pipefail

# =============================================================================
# USER SETTINGS — edit these before first run
# =============================================================================

# - Path to original input MS (will be copied to WORKDIR in init stage)
ORIGINAL_MS="..."

# - Path to original oxkat container (e.g. oxkat-0.41.sif)
SIF=".../oxkat-0.41.sif" 

# - Working directory — all pipeline outputs go here; original MS is never touched
WORKDIR="..."

# - Infrastructure: 'node' = single machine (no SLURM/PBS)
INFRASTRUCTURE="node"

# - Container directory: oxkat will look for *.sif files here
CONTAINER_DIR="..."

# =============================================================================
# DERIVED — do not edit
# =============================================================================

MS_NAME=$(basename "$ORIGINAL_MS")
WORK_MS="$WORKDIR/$MS_NAME"
# oxkat config.py sets OXKAT=CWD+'/oxkat', TOOLS=CWD+'/tools', etc.
# so the repo must be cloned WITH '.' into WORKDIR, not into a subdirectory.
# After cloning: $WORKDIR/oxkat/ (python package), $WORKDIR/tools/, $WORKDIR/setups/, etc.
OXKAT_DIR="$WORKDIR"

# Singularity bind path — WORKDIR and HOME are sufficient after the MS is copied
export SINGULARITY_BINDPATH="$WORKDIR,$HOME"

# =============================================================================
# HELPERS
# =============================================================================

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

banner() { echo -e "\n${CYAN}======================================================================${NC}"; echo -e "${CYAN}  $1${NC}"; echo -e "${CYAN}======================================================================${NC}\n"; }
ok()     { echo -e "${GREEN}[OK]${NC} $1"; }
warn()   { echo -e "${YELLOW}[WARN]${NC} $1"; }
info()   { echo -e "     $1"; }
die()    { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

preflight() {
	[[ -f "$SIF" ]]           || die "Container not found: $SIF"
	command -v singularity >/dev/null 2>&1 || die "singularity not in PATH — try: module load singularity"
	[[ -d "$WORKDIR" ]]            || die "WORKDIR not found: $WORKDIR — run 'init' first"
	[[ -d "$WORK_MS" ]]            || die "Working MS not found: $WORK_MS — run 'init' first"
	[[ -d "$WORKDIR/setups" ]]     || die "oxkat not cloned correctly into $WORKDIR — run 'init' first"
	[[ -d "$WORKDIR/tools" ]]      || die "oxkat tools/ missing in $WORKDIR — run 'init' first"
	[[ -d "$WORKDIR/oxkat" ]]      || die "oxkat python package missing in $WORKDIR — run 'init' first"
}

run_singularity() {
	# run_singularity <python_script> [args...]
	singularity exec "$SIF" python3 "$@"
}


# =============================================================================
# HELPER: patch config.py with science-optimised wsclean parameters
# =============================================================================

patch_config_science() {
	local CONFIG="$WORKDIR/oxkat/config.py"

	sed -i "s|^WSC_PARALLELDECONVOLUTION.*|WSC_PARALLELDECONVOLUTION = 2560|"  "$CONFIG"
	sed -i "s|^WSC_MULTISCALE.*|WSC_MULTISCALE = True|"                         "$CONFIG"
	sed -i "s|^WSC_SCALES.*|WSC_SCALES = '0,3,9,27,81'|"                        "$CONFIG"
	sed -i "s|^WSC_NITER.*|WSC_NITER = 7500000|"                                "$CONFIG"
	sed -i "s|^WSC_GAIN.*|WSC_GAIN = 0.1|"                                      "$CONFIG"
	sed -i "s|^WSC_MGAIN.*|WSC_MGAIN = 0.4|"                                    "$CONFIG"
	sed -i "s|^WSC_NONEGATIVE.*|WSC_NONEGATIVE = False|"                        "$CONFIG"
	sed -i "s|^WSC_STOPNEGATIVE.*|WSC_STOPNEGATIVE = False|"                    "$CONFIG"
	sed -i "s|^WSC_CIRCULARBEAM.*|WSC_CIRCULARBEAM = True|"                     "$CONFIG"
	sed -i "s|^WSC_MASK.*|WSC_MASK = 'auto'|"                                   "$CONFIG"
	sed -i "s|^WSC_THRESHOLD.*|WSC_THRESHOLD = 1e-6|"                           "$CONFIG"
	sed -i "s|^WSC_AUTOMASK.*|WSC_AUTOMASK = 4.0|"                              "$CONFIG"
	sed -i "s|^WSC_AUTOTHRESHOLD.*|WSC_AUTOTHRESHOLD = 1.0|"                    "$CONFIG"
	sed -i "s|^WSC_LOCALRMS.*|WSC_LOCALRMS = False|"                            "$CONFIG"

	ok "config.py patched with science-optimised wsclean parameters."
	#warn "WSC_CIRCULARBEAM forced to False (wsclean 3.1.0 bug workaround)."
}

# =============================================================================
# STAGE: init
# =============================================================================

stage_init() {
	banner "INIT — copy MS, clone oxkat, patch config"

	# --- checks ---
	[[ -d "$ORIGINAL_MS" ]] || die "Original MS not found: $ORIGINAL_MS"
	[[ -f "$SIF" ]]         || die "Container not found: $SIF"
	command -v singularity >/dev/null 2>&1 || die "singularity not in PATH"
	command -v git         >/dev/null 2>&1 || die "git not in PATH"

	ok "Singularity: $(singularity --version)"
	ok "Container  : $SIF"

	# --- working directory ---
	mkdir -p "$WORKDIR"
	ok "Working directory: $WORKDIR"

	# --- copy MS ---
	if [[ -d "$WORK_MS" ]]; then
		warn "Working MS already exists, skipping copy: $WORK_MS"
		warn "Delete it manually if you want a clean copy."
	else
		info "Copying MS (may take several minutes for large files)..."
		cp -r "$ORIGINAL_MS" "$WORK_MS"
		ok "MS copied to: $WORK_MS"
	fi

	# --- clone oxkat ---
	# Must clone with '.' so repo contents land directly in WORKDIR:
	#   $WORKDIR/oxkat/   <- python package (OXKAT = CWD+'/oxkat')
	#   $WORKDIR/tools/   <- helper scripts (TOOLS = CWD+'/tools')
	#   $WORKDIR/setups/  <- pipeline setup scripts
	if [[ -d "$WORKDIR/setups" && -d "$WORKDIR/tools" && -d "$WORKDIR/oxkat" ]]; then
		warn "oxkat already cloned into $WORKDIR, skipping."
	else
		# WORKDIR may already exist (e.g. from MS copy) so use a temp
		# clone then move the repo contents in, rather than cloning into it directly.
		TMPCLONE=$(mktemp -d)
		git clone https://github.com/IanHeywood/oxkat.git "$TMPCLONE"
		# Move all repo contents (including hidden files) into WORKDIR
		mv "$TMPCLONE"/{.[!.],}* "$WORKDIR"/ 2>/dev/null || true
		rmdir "$TMPCLONE" 2>/dev/null || true
		ok "oxkat cloned into $WORKDIR"
	fi

	# --- patch config.py: point NODE_CONTAINER_PATH at the real .sif folder ---
	CONFIG="$WORKDIR/oxkat/config.py"
	if grep -q "$CONTAINER_DIR" "$CONFIG"; then
		warn "config.py already patched with CONTAINER_DIR, skipping."
	else
		# Replace the NODE_CONTAINER_PATH line in-place
		sed -i "s|NODE_CONTAINER_PATH = \[HOME+'/containers/'\]|NODE_CONTAINER_PATH = ['$CONTAINER_DIR/']|" "$CONFIG"
		ok "config.py patched: NODE_CONTAINER_PATH = ['$CONTAINER_DIR/']"
	fi

	# --- patch science parameters ---
	patch_config_science

	echo ""
	ok "Init complete. Next step:"
	info "./run_pipeline.sh getinfo"
}

# =============================================================================
# STAGE: getinfo
# =============================================================================

stage_getinfo() {
	banner "GETINFO — inspect MS and generate project_info.json"
	preflight

	# 0_GET_INFO.py expects to find the MS via glob('*.ms') in CWD,
	# and writes project_info.json there via oxkat/1GC_00_setup.py.
	# It also runs ms_info.py, scan_times.py and find_sun.py.
	cd "$WORKDIR"

	info "Generating submit_info_job.sh via 0_GET_INFO.py..."
	run_singularity "$OXKAT_DIR/setups/0_GET_INFO.py" "$INFRASTRUCTURE"

	SUBMIT="$WORKDIR/submit_info_job.sh"
	[[ -f "$SUBMIT" ]] || die "Submit script not generated: $SUBMIT"
	ok "Submit script generated: $SUBMIT"

	echo ""
	info "--- Contents of $SUBMIT ---"
	cat "$SUBMIT"
	echo ""

	info "Running info job (ms_info, scan_times, find_sun, 1GC_00_setup)..."
	bash "$SUBMIT"

	echo ""
	[[ -f "$WORKDIR/project_info.json" ]] \
		&& ok "project_info.json created successfully." \
		|| die "project_info.json was NOT created — check output above for errors."

	echo ""
	info "--- project_info.json contents ---"
	cat "$WORKDIR/project_info.json"
	echo ""

	warn "Review the field assignments above before running 1gc."
	warn "If primary/secondary/target IDs look wrong, edit $WORKDIR/oxkat/config.py"
	warn "  (CAL_1GC_PRIMARY, CAL_1GC_SECONDARIES, CAL_1GC_TARGETS)"
	warn "then re-run: ./oxkat_pipeline.sh getinfo"
	echo ""
	ok "Next step:"
	info "./oxkat_pipeline.sh 1gc"
}

# =============================================================================
# STAGE: 1gc
# =============================================================================

stage_1gc() {
	banner "1GC — reference calibration"
	preflight

	info "Steps that will run:"
	info "  [0] Split + average master MS to working MS"
	info "  [1] Basic flags on all fields"
	info "  [2] Auto-flaggers on calibrators"
	info "  [3] Reference calibration (K, B, G) + apply to targets"
	info "  [4] Plot gain tables"
	info "  [5] Split corrected target data"
	info "  [6] Plot calibrator visibilities"
	echo ""

	cd "$WORKDIR"

	info "Generating submit script..."
	run_singularity "$OXKAT_DIR/setups/1GC.py" "$INFRASTRUCTURE"

	SUBMIT="$WORKDIR/submit_1GC_jobs.sh"
	[[ -f "$SUBMIT" ]] || die "Submit script not generated: $SUBMIT"
	ok "Submit script generated: $SUBMIT"

	echo ""
	info "--- Contents of $SUBMIT ---"
	cat "$SUBMIT"
	echo ""

	info "Running 1GC pipeline..."
	bash "$SUBMIT"

	echo ""
	ok "1GC complete."
	warn "Check $WORKDIR/LOGS/ for per-step logs."
	warn "Check $WORKDIR/GAINPLOTS/ for calibration solution plots."
	warn "Inspect the split target MS(es) in $WORKDIR/ before continuing."
	echo ""
	ok "Next step:"
	info "./oxkat_pipeline.sh flag"
}

# =============================================================================
# STAGE: flag
# =============================================================================

stage_flag() {
	banner "FLAG — target flagging + blind imaging + initial mask"
	preflight

	info "Steps that will run (per target):"
	info "  [0] Tricolour flagging (polarisation strategy)"
	info "  [1] Blind wsclean image of DATA column"
	info "  [2] Make initial cleaning mask from blind image"
	info "  [3] Primary beam correction on blind image"
	echo ""

	cd "$WORKDIR"

	info "Generating submit script..."
	run_singularity "$OXKAT_DIR/setups/FLAG.py" "$INFRASTRUCTURE"

	SUBMIT="$WORKDIR/submit_flag_jobs.sh"
	[[ -f "$SUBMIT" ]] || die "Submit script not generated: $SUBMIT"
	ok "Submit script generated: $SUBMIT"

	echo ""
	info "--- Contents of $SUBMIT ---"
	cat "$SUBMIT"
	echo ""

	info "Running FLAG pipeline..."
	bash "$SUBMIT"

	echo ""
	ok "FLAG complete."
	warn "Check $WORKDIR/LOGS/ for logs."
	warn "Check $WORKDIR/IMAGES/ for the blind image and initial mask."
	warn "Inspect the image quality before continuing to 2gc."
	echo ""
	ok "Next step:"
	info "./oxkat_pipeline.sh 2gc"
}

# =============================================================================
# STAGE: 2gc
# =============================================================================

stage_2gc() {
	banner "2GC — direction-independent self-calibration"
	preflight

	info "Steps that will run (per target):"
	info "  [0] wsclean masked deconvolution of DATA column"
	info "  [1] Primary beam correction on 1GC image"
	info "  [2] CubiCal f-slope (delay) self-calibration"
	info "  [3] wsclean masked deconvolution of CORRECTED_DATA"
	info "  [4] Refine cleaning mask (cropped for DDFacet)"
	info "  [5] Primary beam correction on 2GC image"
	echo ""

	cd "$WORKDIR"

	info "Generating submit script..."
	run_singularity "$OXKAT_DIR/setups/2GC.py" "$INFRASTRUCTURE"

	SUBMIT="$WORKDIR/submit_2GC_jobs.sh"
	[[ -f "$SUBMIT" ]] || die "Submit script not generated: $SUBMIT"
	ok "Submit script generated: $SUBMIT"

	echo ""
	info "--- Contents of $SUBMIT ---"
	cat "$SUBMIT"
	echo ""

	info "Running 2GC pipeline..."
	bash "$SUBMIT"

	echo ""
	ok "2GC complete."
	warn "Check $WORKDIR/LOGS/ for logs."
	warn "Check $WORKDIR/IMAGES/ for self-calibrated images."
	echo ""
	ok "All pipeline stages complete."
	info "Working directory  : $WORKDIR"
	info "Gain tables        : $WORKDIR/GAINTABLES/"
	info "Gain plots         : $WORKDIR/GAINPLOTS/"
	info "Images             : $WORKDIR/IMAGES/"
	info "Logs               : $WORKDIR/LOGS/"
	info ""
	info "Original MS was NOT modified: $ORIGINAL_MS"
}

# =============================================================================
# STAGE: 3gc
# =============================================================================

stage_3gc() {
	banner "3GC — direction-dependent self-calibration (DDFacet + killMS)"
	preflight

	info "Steps that will run (per target):"
	info "  [0] wsclean masked deconvolution (for initial model)"
	info "  [1] killMS direction-dependent calibration"
	info "  [2] DDFacet imaging with DD corrections applied"
	info "  [3] Refine cleaning mask"
	info "  [4] Primary beam correction on 3GC image"
	echo ""

	# Check DDFacet and killMS are available in the container
	if ! singularity exec "$SIF" which goDDFacet >/dev/null 2>&1; then
		die "DDFacet not found in container $SIF — 3GC is not supported by this container."
	fi
	if ! singularity exec "$SIF" which goKillMS >/dev/null 2>&1; then
		die "killMS not found in container $SIF — 3GC is not supported by this container."
	fi

	cd "$WORKDIR"

	info "Generating submit script..."
	run_singularity "$OXKAT_DIR/setups/3GC.py" "$INFRASTRUCTURE"

	SUBMIT="$WORKDIR/submit_3GC_jobs.sh"
	[[ -f "$SUBMIT" ]] || die "Submit script not generated: $SUBMIT — check if setups/3GC.py exists in your oxkat clone."

	ok "Submit script generated: $SUBMIT"

	echo ""
	info "--- Contents of $SUBMIT ---"
	cat "$SUBMIT"
	echo ""

	info "Running 3GC pipeline..."
	bash "$SUBMIT"

	echo ""
	ok "3GC complete."
	warn "Check $WORKDIR/LOGS/ for logs."
	warn "Check $WORKDIR/IMAGES/ for DD-corrected images."
	echo ""
	ok "Next step: inspect the 3GC image for residual artefacts."
	info "Images : $WORKDIR/IMAGES/"
}

# =============================================================================
# ENTRYPOINT
# =============================================================================

STAGE="${1:-}"

case "$STAGE" in
	init)    stage_init    ;;
	getinfo) stage_getinfo ;;
	1gc)     stage_1gc     ;;
	flag)    stage_flag    ;;
	2gc)     stage_2gc     ;;
	3gc)     stage_3gc     ;;
	*)
		echo -e "${CYAN}oxkat pipeline runner${NC}"
		echo ""
		echo "Usage: $0 <stage>"
		echo ""
		echo "Stages (run in order):"
		echo "  init      Copy MS, clone oxkat, patch config"
		echo "  getinfo   Inspect MS — field/scan/SPW layout (read-only)"
		echo "  1gc       Reference calibration"
		echo "  flag      Target flagging + blind image + initial mask"
		echo "  2gc       Direction-independent self-calibration"
		echo "  3gc       Direction-dependent self-calibration (optional)"
		echo ""
		exit 1
		;;
esac
