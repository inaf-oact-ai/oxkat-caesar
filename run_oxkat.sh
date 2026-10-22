#!/usr/bin/env bash
# CAESAR-REST adapter for OXKAT.
# Supported stages:
#   GET_INFO: execute observation metadata extraction.
#   1GC: prepare and validate the calibration recipe (no execution yet).
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
  --stage=GET_INFO|1GC			First supported oxkat stage (future stages deliberately rejected).
  --jobdir=DIR							Private, writable, per-run workspace.
  --input-ms=PATH						Existing Measurement Set directory visible inside container.
	--project-info=PATH       Path to the project_info.json artifact produced by the upstream GET_INFO stage. Required for 1GC; supplies observation metadata and calibration configuration.
  --outdir=DIR							Directory for compact result manifest and diagnostic files.
  --oxkat-home=DIR					Location of cloned oxkat repo (default: /opt/oxkat).
  --run											Execute the generated script (otherwise prepare only).
  --waitcopy								Wait after copying output products (default: disabled).
  --copywaittime=N					Delay in seconds after copying (default: 30).
USAGE
}

# -----------------------------------------------------------------------------
# Parse inputs and establish defaults
# -----------------------------------------------------------------------------
# Use a case statement rather than evaluating caller-provided argument text.
# The cloned oxkat source is expected at /opt/oxkat in the final image,
# but can be supplied from a bind-mounted directory during development.
STAGE=""
JOB_DIR=""
INPUT_MS=""
PROJECT_INFO=""
OUT_DIR=""
OXKAT_HOME="${OXKAT_HOME:-/opt/oxkat}"
RUN=false

# - Output-copy synchronization options.
WAIT_COPY=false
COPY_WAIT_TIME=30

for arg in "$@"; do
	case "$arg" in
		--stage=*)
			STAGE="${arg#*=}"
		;;
		
		--jobdir=*)
			JOB_DIR="${arg#*=}"
		;;
		
		--input-ms=*)
			INPUT_MS="${arg#*=}"
		;;
		
		--project-info=*)
			PROJECT_INFO="${arg#*=}"
		;;
		
		--outdir=*)
			OUT_DIR="${arg#*=}"
		;;
		
		--oxkat-home=*)
			OXKAT_HOME="${arg#*=}"
		;;
		
		--run)
			RUN=true
		;;
		
		--waitcopy)
			WAIT_COPY=true
		;;
		
		--copywaittime=*)
			COPY_WAIT_TIME="${arg#*=}"
		;;
		
		--help|-h)
			usage
			exit 0
		;;
		
		*)
			printf 'ERROR: Unsupported option: %s\n' "$arg" >&2
			usage >&2
			exit 2
		;;
	esac
done

# -----------------------------------------------------------------------------
# Validate stage, required options, input MS and oxkat source tree
# -----------------------------------------------------------------------------
# Deliberately reject unsupported stages; new stages require their own
# validation, expected outputs and scientific parameters before enabling.
if [[ "$STAGE" != "GET_INFO" && "$STAGE" != "1GC" ]]; then
	echo 'ERROR: Unsupported oxkat stage.' >&2
	exit 2
fi

if [[ "$STAGE" == "1GC" ]]; then
	if [[ -z "$PROJECT_INFO" || ! -s "$PROJECT_INFO" ]]; then
		echo 'ERROR: 1GC requires a nonempty project_info.json.' >&2
		exit 2
	fi
fi

if [[ -z "$JOB_DIR" || -z "$INPUT_MS" ]]; then
	usage >&2
	exit 2
fi

if [[ ! -d "$INPUT_MS" ]]; then
	echo 'ERROR: --input-ms must point to an existing Measurement Set directory.' >&2
	exit 2
fi

# - V1 supplies the original *.ms directory.
# - V2 supplies the authorized read-only reference named measurement_set.
if [[ "$INPUT_MS" != *.ms && "$(basename "$INPUT_MS")" != "measurement_set" ]]; then
	echo 'ERROR: --input-ms must be a *.ms directory or the V2 measurement_set input.' >&2
	exit 2
fi

for required in oxkat/config.py setups/0_GET_INFO.py setups/1GC.py tools/ms_info.py data; do
	if [[ ! -e "$OXKAT_HOME/$required" ]]; then
		echo "ERROR: Missing $OXKAT_HOME/$required" >&2
		exit 2
	fi
done

if ! [[ "$COPY_WAIT_TIME" =~ ^[0-9]+$ ]]; then
	echo "ERROR: --copywaittime must be a non-negative integer" >&2
	exit 2
fi

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
if [[ -z "$OUT_DIR" ]]; then
	OUT_DIR="$JOB_DIR/caesar-results"
fi
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd -P)"

if [[ "$INPUT_MS" == "$JOB_DIR" || "$INPUT_MS" == "$JOB_DIR/"* ]]; then
	echo 'ERROR: Input MS must be outside job workspace.' >&2
	exit 2
fi

if [[ -e "$JOB_DIR/.oxkat-run-started" ]]; then
	echo 'ERROR: Job directory already used; specify a fresh --jobdir.' >&2
	exit 2
fi

if [[ -e "$JOB_DIR/project_info.json" ]]; then
	echo 'ERROR: Existing project_info.json; use a fresh workspace.' >&2
	exit 2
fi

if [[ -e "$JOB_DIR/oxkat" || -L "$JOB_DIR/oxkat" ]]; then
	echo 'ERROR: Workspace already contains oxkat/.' >&2
	exit 2
fi

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

# - Preserve the original Measurement Set name for V1.
# - Give the generic V2 input a conventional *.ms name so oxkat's
#   existing setup scripts can discover it without modification.
MS_NAME="$(basename "$INPUT_MS")"

if [[ "$MS_NAME" == "measurement_set" ]]; then
	MS_NAME="measurement_set.ms"
fi

ln -s "$INPUT_MS" "$JOB_DIR/$MS_NAME"

mkdir -p "$JOB_DIR"/{LOGS,SCRIPTS,GAINTABLES,GAINPLOTS,IMAGES,VISPLOTS}


# -----------------------------------------------------------------------------
# Restore and validate GET_INFO metadata for the 1GC stage
# -----------------------------------------------------------------------------
# project_info.json must exist before importing oxkat.config because
# the configuration reads the observing band from this file.
if [[ "$STAGE" == "1GC" ]]; then

	cp -- "$PROJECT_INFO" "$JOB_DIR/project_info.json"

	/usr/bin/python3 - "$JOB_DIR/project_info.json" "$MS_NAME" <<'PY'
import json
import sys

with open(sys.argv[1]) as stream:
	info = json.load(stream)

if not isinstance(info, dict):
	raise SystemExit('Invalid project_info.json')

if info.get('master_ms') != sys.argv[2]:
	raise SystemExit('GET_INFO master_ms does not match the staged MS')

if not info.get('band'):
	raise SystemExit('Missing observing band')
PY

fi

# -----------------------------------------------------------------------------
# Disable nested Singularity calls in this run-specific config
# -----------------------------------------------------------------------------
# All scientific executables already live in oxkat-0.41.sif, so oxkat should
# invoke them directly rather than trying to start another Singularity image.
# Change exactly one assignment; fail if upstream config.py has changed.
/usr/bin/python3 - "$JOB_DIR/oxkat/config.py" <<'PY'
import pathlib
import re
import sys
p = pathlib.Path(sys.argv[1])
content = p.read_text()
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
# Serialize a public, portable CAESAR-REST result manifest
# -----------------------------------------------------------------------------
# Expose only files delivered in OUT_DIR, using paths relative to that directory.
# Never publish host/container absolute paths, usernames, or mount locations.
# Diagnostics can still be inspected in the private job workspace when needed.
write_manifest() {
	local status="$1"
	local code="$2"

#	STATUS="$status" EXIT_CODE="$code" OUT_DIR="$OUT_DIR" INPUT_MS="$INPUT_MS" STAGE="$STAGE" \
	
	STATUS="$status" \
	EXIT_CODE="$code" \
	OUT_DIR="$OUT_DIR" \
	INPUT_MS="$INPUT_MS" \
	STAGE="$STAGE" \
	/usr/bin/python3 - <<'PYMANIFEST'
import json
import os
from pathlib import Path

out = Path(os.environ['OUT_DIR'])

def artifact(name):
	"""Return a relative filename only if present in the output directory."""
	path = out / name
	return name if path.is_file() else None

# Only list copied logs. Avoid exposing paths in the execution workspace.
logs = sorted(path.name for path in out.glob('*.log') if path.is_file())

manifest = {
	'stage': os.environ['STAGE'],
	'status': os.environ['STATUS'],
	'exit_code': int(os.environ['EXIT_CODE']),
	'input_ms_name': Path(os.environ['INPUT_MS']).name,
	'artifacts': {
		'project_info': artifact('project_info.json'),
		'execution_script': artifact(
			'submit_1GC_jobs.sh' if os.environ['STAGE'] == '1GC' else 'submit_info_job.sh'
		),
		'logs': logs,
	},
}

(out / 'oxkat_manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
PYMANIFEST
}


copy_outputs() {
	# The primary scientific result is already copied by the runner.
	# Copy additional diagnostic artifacts only when source and
	# destination are different.

	if [[ "$JOB_DIR" == "$OUT_DIR" ]]; then
		return 0
	fi

	echo "INFO: Collecting oxkat diagnostic outputs..."
	
	if [[ "$STAGE" == "1GC" ]]; then
		SCRIPT_NAME="submit_1GC_jobs.sh"
	else
		SCRIPT_NAME="submit_info_job.sh"
	fi

	if [[ -f "$JOB_DIR/$SCRIPT_NAME" ]]; then
		cp -f "$JOB_DIR/$SCRIPT_NAME" "$OUT_DIR/"
	fi	

	for logfile in "$JOB_DIR"/*.log "$JOB_DIR"/LOGS/*.log; do
		if [[ ! -f "$logfile" ]]; then
			continue
		fi
		cp -f "$logfile" "$OUT_DIR/"
	done
}

on_error() {
	local code=$?

	trap - ERR

	# Record the scientific or execution failure.
	write_manifest failed "$code" || true

	# Preserve diagnostic files even when scientific processing fails.
	copy_outputs || true

	# Give RCLONE additional time to transfer failed-job diagnostics.
	if [[ "$WAIT_COPY" == true ]]; then
		echo "INFO: Waiting $COPY_WAIT_TIME seconds after failure..."
		sleep "$COPY_WAIT_TIME"
	fi

	exit "$code"
}



# -----------------------------------------------------------------------------
# Mark execution and install error reporting
# -----------------------------------------------------------------------------
# A marker prevents a second invocation from accidentally reusing this job.
# On an ERR trap, record failure in the manifest without masking the original
# exit status. Earlier validation errors happen before the trap is installed.
touch "$JOB_DIR/.oxkat-run-started"
trap on_error ERR

# -----------------------------------------------------------------------------
# Prepare the 1GC stage without executing calibration
# -----------------------------------------------------------------------------
# The CAESAR-REST entrypoint always passes --run.
# For this integration milestone, 1GC must only generate its execution recipe.
if [[ "$STAGE" == "1GC" ]]; then

	echo "INFO: Preparing OXKAT 1GC stage..."

	/usr/bin/python3 "$JOB_DIR/setups/1GC.py" node 2>&1 | tee "$JOB_DIR/LOGS/caesar_setup_1GC.log"

	if [[ ! -s "$JOB_DIR/submit_1GC_jobs.sh" ]]; then
		echo "ERROR: OXKAT did not generate submit_1GC_jobs.sh" >&2
		false
	fi

	# Preserve upstream GET_INFO metadata as a registered output.
	if [[ "$OUT_DIR" != "$JOB_DIR" ]]; then
		cp "$JOB_DIR/project_info.json" "$OUT_DIR/project_info.json"
	fi

	# Copy generated script and diagnostic logs.
	copy_outputs

	# Record preparation, not scientific completion.
	write_manifest prepared 0

	if [[ "$WAIT_COPY" == true ]]; then
		echo "INFO: Waiting $COPY_WAIT_TIME seconds after output copying..."
		sleep "$COPY_WAIT_TIME"
	fi

	echo "INFO: OXKAT 1GC preparation completed."
	exit 0
fi

# -----------------------------------------------------------------------------
# Generate oxkat's GET_INFO local execution script
# -----------------------------------------------------------------------------
# oxkat creates submit_info_job.sh; on the "node" backend it contains shell
# commands executed sequentially (and commonly piped through tee).
# pipefail ensures generation errors are not hidden by our tee process.
/usr/bin/python3 "$JOB_DIR/setups/0_GET_INFO.py" node 2>&1 | tee "$JOB_DIR/LOGS/caesar_setup_GET_INFO.log"

if [[ ! -f "$JOB_DIR/submit_info_job.sh" ]]; then
	echo 'ERROR: oxkat did not generate submit_info_job.sh' >&2
	false  # Invoke ERR trap for a missing generated script.
fi

# -----------------------------------------------------------------------------
# Optionally execute GET_INFO and validate its primary output
# -----------------------------------------------------------------------------
# A dry preparation run leaves the generated script for inspection.
# The executed script runs under Bash with errexit+pipefail to propagate
# failures from oxkat-generated "command | tee logfile" pipelines.
# In execution mode, require nonempty, parseable project_info.json with band.
if [[ "$RUN" == true ]]; then
	bash -o errexit -o pipefail "$JOB_DIR/submit_info_job.sh" 2>&1 \
		| tee "$JOB_DIR/LOGS/caesar_run_GET_INFO.log"

	if [[ ! -s "$JOB_DIR/project_info.json" ]]; then
		echo 'ERROR: project_info.json missing or empty.' >&2
		false  # Invoke ERR trap for a missing scientific result.
	fi

	/usr/bin/python3 - "$JOB_DIR/project_info.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as stream:
	obj = json.load(stream)

if not isinstance(obj, dict) or not obj.get('band'):
	raise SystemExit('ERROR: Invalid project_info.json or missing band')
PY

	# Avoid copying a file onto itself when OUT_DIR is the workspace.
	if [[ "$OUT_DIR" != "$JOB_DIR" ]]; then
		cp "$JOB_DIR/project_info.json" "$OUT_DIR/project_info.json"
	fi

	STATUS=completed
else
	STATUS=prepared
fi

# -----------------------------------------------------------------------------
# Report successful preparation/execution to CAESAR-REST
# -----------------------------------------------------------------------------
# Collect diagnostic artifacts first.
copy_outputs

# The manifest is the stable contract for eventual pipeline graph integration.
# Write the final execution manifest.
write_manifest "$STATUS" 0

# Allow RCLONE time to flush its local VFS cache.
# This is required only when explicitly requested.
if [[ "$WAIT_COPY" == true ]]; then
	echo "INFO: Waiting $COPY_WAIT_TIME seconds after output copying..."
	sleep "$COPY_WAIT_TIME"
fi

printf 'oxkat GET_INFO %s: manifest at %s/oxkat_manifest.json\n' \
	"$STATUS" "$OUT_DIR"
