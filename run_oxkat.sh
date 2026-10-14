#!/usr/bin/env bash
# CAESAR-REST adapter for oxkat.
# Version 0: support the GET_INFO stage using oxkat's local "node" backend.
#
# Intended invocation: run_job.sh -> run_oxkat.sh -> oxkat generated job script.
# The input Measurement Set remains in its original storage location; this
# wrapper creates a private workspace and a lightweight output manifest.
# MPI execution and later oxkat stages are deliberately out of scope.
#
# Abort on errors (-e), unset variables (-u), pipeline failures (pipefail),
# and propagate ERR traps through functions/subshells (-E).
set -Eeuo pipefail

# -----------------------------------------------------------------------------
# Help / command-line contract
# -----------------------------------------------------------------------------
# Keep these options consistent with CAESAR-REST run_job.sh: it forwards
# --run, --jobdir, --outdir and optional copy-wait flags to the app runner.
usage() {
  cat <<'USAGE'
Usage: run_oxkat.sh --stage=GET_INFO --jobdir=DIR --input-ms=PATH [--outdir=DIR] [--run]
Options:
  --stage=GET_INFO      First supported oxkat stage (future stages deliberately rejected).
  --jobdir=DIR          Private, writable, per-run workspace.
  --input-ms=PATH       Existing Measurement Set directory visible inside container.
  --outdir=DIR          Directory for compact result manifest and diagnostic files.
  --oxkat-home=DIR      Location of cloned oxkat repo (default: /opt/oxkat).
  --run                 Execute the generated script (otherwise prepare only).
  --waitcopy            Accepted for compatibility with CAESAR-REST run_job.sh.
  --copywaittime=N      Accepted for compatibility (no artificial sleep).
USAGE
}

# -----------------------------------------------------------------------------
# Parse inputs and establish defaults
# -----------------------------------------------------------------------------
# Use a case statement rather than evaluating caller-provided argument text.
# The cloned oxkat source is expected at /opt/oxkat in the final image,
# but can be supplied from a bind-mounted directory during development.
STAGE=""; JOB_DIR=""; INPUT_MS=""; OUT_DIR=""; OXKAT_HOME="${OXKAT_HOME:-/opt/oxkat}"; RUN=false
for arg in "$@"; do
  case "$arg" in
    --stage=*) STAGE="${arg#*=}" ;;
    --jobdir=*) JOB_DIR="${arg#*=}" ;;
    --input-ms=*) INPUT_MS="${arg#*=}" ;;
    --outdir=*) OUT_DIR="${arg#*=}" ;;
    --oxkat-home=*) OXKAT_HOME="${arg#*=}" ;;
    --run) RUN=true ;;
    --waitcopy) : ;;
    --copywaittime=*) : ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'ERROR: Unsupported option: %s\n' "$arg" >&2; usage >&2; exit 2 ;;
  esac
done

# -----------------------------------------------------------------------------
# Validate stage, required options, input MS and oxkat source tree
# -----------------------------------------------------------------------------
# Deliberately reject unsupported stages; new stages require their own
# validation, expected outputs and scientific parameters before enabling.
[[ "$STAGE" == "GET_INFO" ]] || { echo 'ERROR: Only GET_INFO is supported in v0.' >&2; exit 2; }
[[ -n "$JOB_DIR" && -n "$INPUT_MS" ]] || { usage >&2; exit 2; }
[[ -d "$INPUT_MS" && "$INPUT_MS" == *.ms ]] || { echo 'ERROR: --input-ms must point to an existing *.ms directory.' >&2; exit 2; }
for required in oxkat/config.py setups/0_GET_INFO.py tools/ms_info.py data; do
  [[ -e "$OXKAT_HOME/$required" ]] || { echo "ERROR: Missing $OXKAT_HOME/$required" >&2; exit 2; }
done

# -----------------------------------------------------------------------------
# Normalize paths and protect existing workspaces
# -----------------------------------------------------------------------------
# Resolve all paths before changing directories; host bind mounts must expose
# these same paths within Singularity. Refuse a previously used workspace to
# avoid reusing old calibration products or silently overwriting results.
INPUT_MS="$(cd "$INPUT_MS" && pwd -P)"
OXKAT_HOME="$(cd "$OXKAT_HOME" && pwd -P)"
mkdir -p "$JOB_DIR"
JOB_DIR="$(cd "$JOB_DIR" && pwd -P)"
[[ -n "$OUT_DIR" ]] || OUT_DIR="$JOB_DIR/caesar-results"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd -P)"
[[ "$INPUT_MS" != "$JOB_DIR"* ]] || { echo 'ERROR: Input MS must be outside job workspace.' >&2; exit 2; }
[[ ! -e "$JOB_DIR/.oxkat-run-started" ]] || { echo 'ERROR: Job directory already used; specify a fresh --jobdir.' >&2; exit 2; }
[[ ! -e "$JOB_DIR/project_info.json" ]] || { echo 'ERROR: Existing project_info.json; use a fresh workspace.' >&2; exit 2; }
[[ ! -e "$JOB_DIR/oxkat" && ! -L "$JOB_DIR/oxkat" ]] || { echo 'ERROR: Workspace already contains oxkat/.' >&2; exit 2; }

# -----------------------------------------------------------------------------
# Assemble the oxkat workspace
# -----------------------------------------------------------------------------
# oxkat config.py derives its paths from os.getcwd(), so the job directory
# must contain oxkat/, setups/, tools/ and data/ as expected by its scripts.
#
# Copy only oxkat/ (containing config.py) so each run can safely override
# configuration values. Link unchanged repository resources and the input MS.
# The input MS is used only for GET_INFO here; later stages that modify MS
# data will require isolated writable snapshots/copies.
# Keep per-run configuration separate from the shared, immutable repository.
cp -a "$OXKAT_HOME/oxkat" "$JOB_DIR/oxkat"
ln -s "$OXKAT_HOME/setups" "$JOB_DIR/setups"
ln -s "$OXKAT_HOME/tools" "$JOB_DIR/tools"
ln -s "$OXKAT_HOME/data" "$JOB_DIR/data"
ln -s "$INPUT_MS" "$JOB_DIR/$(basename "$INPUT_MS")"
mkdir -p "$JOB_DIR"/{LOGS,SCRIPTS,GAINTABLES,GAINPLOTS,IMAGES,VISPLOTS}

# -----------------------------------------------------------------------------
# Disable nested Singularity calls in this run-specific config
# -----------------------------------------------------------------------------
# All scientific executables already live in oxkat-0.41.sif, so oxkat should
# invoke them directly rather than trying to start another Singularity image.
# Change exactly one assignment; fail if upstream config.py has changed.
/usr/bin/python3 - "$JOB_DIR/oxkat/config.py" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1]); content = p.read_text()
content, n = re.subn(r'(?m)^USE_SINGULARITY\s*=\s*True\s*$', 'USE_SINGULARITY = False', content)
if n != 1:
    raise SystemExit('Expected exactly one USE_SINGULARITY = True assignment')
p.write_text(content)
PY

# -----------------------------------------------------------------------------
# Activate and verify the run-specific oxkat Python package
# -----------------------------------------------------------------------------
# The setup scripts may be symlinked to the shared source checkout. Putting
# the job directory first on PYTHONPATH ensures imports use our copied config.
# Check this explicitly before generating any scientific command.
cd "$JOB_DIR"
export PYTHONPATH="$JOB_DIR${PYTHONPATH:+:$PYTHONPATH}"
/usr/bin/python3 - <<'PY'
from oxkat import config
assert config.USE_SINGULARITY is False
assert config.CWD == __import__('os').getcwd()
assert config.__file__.startswith(config.CWD + '/oxkat/')
PY

# -----------------------------------------------------------------------------
# Serialize a compact, machine-readable CAESAR-REST result manifest
# -----------------------------------------------------------------------------
# Store paths/references rather than copying large Measurement Sets or logs.
# The outdir is distinct from the oxkat workspace when supplied.
# Status is either prepared, completed or failed; exit_code is preserved.
write_manifest() {
  local status="$1" code="$2"
  STATUS="$status" EXIT_CODE="$code" OUT_DIR="$OUT_DIR" JOB_DIR="$JOB_DIR" INPUT_MS="$INPUT_MS" \
  /usr/bin/python3 - <<'PY'
import json, os, pathlib
out = pathlib.Path(os.environ['OUT_DIR'])
job = pathlib.Path(os.environ['JOB_DIR'])
info = job / 'project_info.json'
data = {
    'stage': 'GET_INFO', 'status': os.environ['STATUS'],
    'exit_code': int(os.environ['EXIT_CODE']),
    'input_ms': os.environ['INPUT_MS'],
    'job_dir': str(job),
    'project_info': str(info) if info.is_file() else None,
    'logs_dir': str(job / 'LOGS'),
    'generated_script': str(job / 'submit_info_job.sh') if (job / 'submit_info_job.sh').is_file() else None,
}
(out / 'oxkat_manifest.json').write_text(json.dumps(data, indent=2) + '\n')
PY
}

# -----------------------------------------------------------------------------
# Mark execution and install error reporting
# -----------------------------------------------------------------------------
# A marker prevents a second invocation from accidentally reusing this job.
# On an ERR trap, record failure in the manifest without masking the original
# exit status. Earlier validation errors happen before the trap is installed.
touch "$JOB_DIR/.oxkat-run-started"
trap 'code=$?; trap - ERR; write_manifest failed "$code" || true; exit "$code"' ERR

# -----------------------------------------------------------------------------
# Generate oxkat's GET_INFO local execution script
# -----------------------------------------------------------------------------
# oxkat creates submit_info_job.sh; on the "node" backend it contains shell
# commands executed sequentially (and commonly piped through tee).
# pipefail ensures generation errors are not hidden by our tee process.
/usr/bin/python3 "$JOB_DIR/setups/0_GET_INFO.py" node 2>&1 | tee "$JOB_DIR/LOGS/caesar_setup_GET_INFO.log"
[[ -f "$JOB_DIR/submit_info_job.sh" ]] || { echo 'ERROR: oxkat did not generate submit_info_job.sh' >&2; exit 1; }

# -----------------------------------------------------------------------------
# Optionally execute GET_INFO and validate its primary output
# -----------------------------------------------------------------------------
# A dry preparation run leaves the generated script for inspection.
# The executed script runs under Bash with errexit+pipefail to propagate
# failures from oxkat-generated "command | tee logfile" pipelines.
# In execution mode, require nonempty, parseable project_info.json with band.
if [[ "$RUN" == true ]]; then
  bash -o errexit -o pipefail "$JOB_DIR/submit_info_job.sh" 2>&1 | tee "$JOB_DIR/LOGS/caesar_run_GET_INFO.log"
  [[ -s "$JOB_DIR/project_info.json" ]] || { echo 'ERROR: project_info.json missing or empty.' >&2; exit 1; }
  /usr/bin/python3 - "$JOB_DIR/project_info.json" <<'PY'
import json, sys
with open(sys.argv[1]) as stream:
    obj = json.load(stream)
if not isinstance(obj, dict) or not obj.get('band'):
    raise SystemExit('ERROR: Invalid project_info.json or missing band')
PY
  cp "$JOB_DIR/project_info.json" "$OUT_DIR/project_info.json"
  STATUS=completed
else
  STATUS=prepared
fi

# -----------------------------------------------------------------------------
# Report successful preparation/execution to CAESAR-REST
# -----------------------------------------------------------------------------
# The manifest is the stable contract for eventual pipeline graph integration.
write_manifest "$STATUS" 0
printf 'oxkat GET_INFO %s: manifest at %s/oxkat_manifest.json\n' "$STATUS" "$OUT_DIR"
