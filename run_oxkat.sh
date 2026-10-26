#!/usr/bin/env bash
# CAESAR-REST adapter for OXKAT.
# Supported stages:
#   GET_INFO: execute observation metadata extraction.
#   1GC: generate and optionally execute first-generation calibration.
#        The original Measurement Set remains read-only; calibration
#        operates on private derived Measurement Sets.
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
Usage: run_oxkat.sh --stage=STAGE --jobdir=DIR --input-ms=PATH [--project-info=PATH] [--outdir=DIR] [--run]
Options:
  --stage=GET_INFO|1GC|FLAG
  --jobdir=DIR         Private per-run execution directory.
  --input-ms=PATH      Original MS for GET_INFO/1GC; private staged target MS for FLAG.
  --project-info=PATH  Retained project_info.json; required for 1GC and FLAG.
  --outdir=DIR         Directory for published scientific outputs.
  --oxkat-home=DIR     OXKAT checkout (default: /opt/oxkat).
  --run                Execute the generated scientific script.
  --waitcopy           Wait after output publication (default: disabled).
  --copywaittime=N     Optional output synchronization delay (default: 30).
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
OXKAT_CONFIG_TOKEN=""
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
				
		--oxkat-config=*)
			OXKAT_CONFIG_TOKEN="${arg#*=}"
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
if [[ "$STAGE" != "GET_INFO" && \
      "$STAGE" != "1GC" && \
      "$STAGE" != "FLAG" ]]; then      
	echo 'ERROR: Unsupported oxkat stage.' >&2
	exit 2
fi


if [[ "$STAGE" == "1GC" || "$STAGE" == "FLAG" ]]; then
	if [[ -z "$PROJECT_INFO" || ! -s "$PROJECT_INFO" ]]; then
		echo "ERROR: $STAGE requires nonempty project_info.json" >&2
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

if [[ "$STAGE" == "FLAG" ]]; then
	if [[ "$(basename "$INPUT_MS")" != "target_ms" ]]; then
		echo 'ERROR: FLAG requires the V2 target_ms input' >&2
		exit 2
	fi
else
	if [[ "$INPUT_MS" != *.ms && "$(basename "$INPUT_MS")" != "measurement_set" ]]; then
		echo 'ERROR: Invalid GET_INFO/1GC Measurement Set input' >&2
		exit 2
	fi
fi


for required in oxkat/config.py setups/0_GET_INFO.py setups/1GC.py setups/FLAG.py tools/ms_info.py data; do
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

if [[ "$STAGE" != "GET_INFO" && "$RUN" == true && "$OUT_DIR" == "$JOB_DIR" ]]; then
	echo "ERROR: $STAGE execution requires a separate output directory." >&2
	exit 2
fi


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

if [[ "$STAGE" == "FLAG" ]]; then
	# FLAG must use the private V2-staged target MS, never the
	# immutable retained upstream artifact.
	WORKSPACE_ROOT="$(dirname "$JOB_DIR")"
	EXPECTED_INPUT="$WORKSPACE_ROOT/input/target_ms"

	if [[ "$INPUT_MS" != "$EXPECTED_INPUT" ]]; then
		echo 'ERROR: FLAG input is not the private V2 target_ms' >&2
		exit 2
	fi

	if [[ ! -d "$INPUT_MS" || -L "$INPUT_MS" || ! -w "$INPUT_MS" ]]; then
		echo 'ERROR: FLAG target MS is not a writable private directory' >&2
		exit 2
	fi

	cp -- "$PROJECT_INFO" "$JOB_DIR/project_info.json"

	# Validate the upstream metadata and obtain the target MS name.
	# Initial FLAG implementation deliberately supports one target.
	MS_NAME=$(/usr/bin/python3 - "$JOB_DIR/project_info.json" <<'PY'
import json
import pathlib
import sys

with open(sys.argv[1]) as stream:
	info = json.load(stream)

if not isinstance(info, dict):
	raise SystemExit('Invalid project_info.json')

names = info.get('target_ms')
ids = info.get('target_ids')
targets = info.get('target_names')

if (
	not isinstance(names, list)
	or not isinstance(ids, list)
	or not isinstance(targets, list)
	or len(names) != 1
	or len(ids) != 1
	or len(targets) != 1
):
	raise SystemExit('FLAG currently requires exactly one target')

name = names[0]

if (
	not isinstance(name, str)
	or pathlib.PurePosixPath(name).name != name
	or not name.endswith('.ms')
	or name in ('.', '..')
	or not info.get('band')
):
	raise SystemExit('Invalid FLAG target metadata')

print(name)
PY
	)

	echo "INFO: FLAG target Measurement Set: $MS_NAME"

	# Upstream FLAG.py reads project_info.json and expects this
	# basename in its current execution directory.
	# The link targets only the private staged copy.
	if [[ -e "$JOB_DIR/$MS_NAME" || -L "$JOB_DIR/$MS_NAME" ]]; then
		echo 'ERROR: FLAG target name already exists in job directory' >&2
		exit 2
	fi

	ln -s "$INPUT_MS" "$JOB_DIR/$MS_NAME"

else
	if [[ "$MS_NAME" == "measurement_set" ]]; then
		MS_NAME="measurement_set.ms"
	fi

	ln -s "$INPUT_MS" "$JOB_DIR/$MS_NAME"

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
fi

mkdir -p "$JOB_DIR"/{LOGS,SCRIPTS,GAINTABLES,GAINPLOTS,IMAGES,VISPLOTS}


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
# Apply stage-specific scientific configuration overrides
# -----------------------------------------------------------------------------
# Only the private copy of oxkat/config.py may be modified.
# Input is an internally encoded JSON document, not Python source code.

if [[ -n "$OXKAT_CONFIG_TOKEN" ]]; then

	echo "INFO: Applying OXKAT scientific configuration overrides..."

	/usr/bin/python3 - \
		"$JOB_DIR/oxkat/config.py" \
		"$STAGE" \
		"$OXKAT_CONFIG_TOKEN" \
		"$JOB_DIR/oxkat_config_overrides.json" <<'PY'
import base64
import json
import pathlib
import re
import sys

config_path = pathlib.Path(sys.argv[1])
stage = sys.argv[2]
token = sys.argv[3]
record_path = pathlib.Path(sys.argv[4])

if not re.fullmatch(r'[A-Za-z0-9_-]{1,3000}', token):
	raise SystemExit('Invalid encoded OXKAT configuration')

try:
	padding = '=' * (-len(token) % 4)
	raw = base64.b64decode(
		(token + padding).encode('ascii'),
		altchars=b'-_',
		validate=True
	)
	document = json.loads(raw.decode('utf-8'))
except (ValueError, UnicodeError) as exc:
	raise SystemExit('Cannot decode OXKAT configuration: %s' % exc)

if not isinstance(document, dict) or set(document) != {'stage', 'overrides'}:
	raise SystemExit('Invalid OXKAT configuration document')

if document['stage'] != stage:
	raise SystemExit('OXKAT configuration stage mismatch')

# Validate independently using the same reviewed scientific schema.
# The schema is installed inside the Singularity image.
sys.path.insert(0, '/opt/caesar')

import oxkat_scientific_config

try:
	validated = oxkat_scientific_config.append_overrides(
		config_path,
		document['overrides'],
		stage
	)
except (ValueError, SyntaxError, OSError) as exc:
	raise SystemExit(
		'Invalid OXKAT scientific configuration: %s' % exc
	)

record = {
	'stage': stage,
	'overrides': validated,
}

record_path.write_text(
	json.dumps(record, sort_keys=True, indent=2) + '\n'
)

for name in sorted(validated):
	print('INFO: OXKAT override %s=%r' % (name, validated[name]))
PY

fi


# -----------------------------------------------------------------------------
# Activate and verify the run-specific oxkat Python package
# -----------------------------------------------------------------------------
# The setup scripts may be symlinked to the shared source checkout. Putting
# the job directory first on PYTHONPATH ensures imports use our copied config.
# Check this explicitly before generating any scientific command.
cd "$JOB_DIR"
export PYTHONPATH="$JOB_DIR${PYTHONPATH:+:$PYTHONPATH}"

/usr/bin/python3 - <<'PY'
import json
import os
from pathlib import Path

from oxkat import config

assert config.USE_SINGULARITY is False
assert config.CWD == os.getcwd()
assert config.__file__.startswith(config.CWD + '/oxkat/')

record_path = Path('oxkat_config_overrides.json')

if record_path.is_file():
	with record_path.open() as stream:
		record = json.load(stream)

	for name, expected in record['overrides'].items():
		actual = getattr(config, name)

		if actual != expected or type(actual) is not type(expected):
			raise SystemExit(
				'Applied OXKAT configuration mismatch: %s' % name
			)

	print('INFO: OXKAT scientific configuration verified.')
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
	MS_NAME="$MS_NAME" \
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
	'input_ms_name': os.environ['MS_NAME'],
	'artifacts': {
		'project_info': artifact('project_info.json'),
		'execution_script': artifact({
			'GET_INFO': 'submit_info_job.sh',
			'1GC': 'submit_1GC_jobs.sh',
			'FLAG': 'submit_flag_jobs.sh',
		}[os.environ['STAGE']]),
		'logs': logs,
		'oxkat_config_overrides': artifact('oxkat_config_overrides.json'),
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
	
	case "$STAGE" in
		GET_INFO)
			SCRIPT_NAME="submit_info_job.sh"
			;;
		1GC)
			SCRIPT_NAME="submit_1GC_jobs.sh"
			;;
		FLAG)
			SCRIPT_NAME="submit_flag_jobs.sh"
			;;
	esac

	if [[ -f "$JOB_DIR/$SCRIPT_NAME" ]]; then
		cp -f "$JOB_DIR/$SCRIPT_NAME" "$OUT_DIR/"
	fi	

	if [[ -f "$JOB_DIR/oxkat_config_overrides.json" ]]; then
		cp -f \
			"$JOB_DIR/oxkat_config_overrides.json" \
			"$OUT_DIR/oxkat_config_overrides.json"
	fi

	for logfile in "$JOB_DIR"/*.log "$JOB_DIR"/LOGS/*.log; do
		if [[ ! -f "$logfile" ]]; then
			continue
		fi
		cp -f "$logfile" "$OUT_DIR/"
	done
}

# -----------------------------------------------------------------------------
# Validate and publish the 1GC scientific products
# -----------------------------------------------------------------------------
publish_1gc_products() {

	local working_ms
	local ms_path
	local name

	# Read the expected working MS name from trusted GET_INFO metadata.
	working_ms=$(/usr/bin/python3 - "$JOB_DIR/project_info.json" <<'PY'
import json
import pathlib
import sys

with open(sys.argv[1]) as stream:
	info = json.load(stream)

name = info.get('working_ms')

if (
	not isinstance(name, str)
	or pathlib.PurePosixPath(name).name != name
	or not name.endswith('.ms')
	or name in ('.', '..')
):
	raise SystemExit('Invalid working_ms in project_info.json')

print(name)
PY
	)

	if [[ ! -d "$JOB_DIR/$working_ms" || -L "$JOB_DIR/$working_ms" ]]; then
		echo "ERROR: Missing private working MS: $working_ms" >&2
		return 1
	fi

	if [[ "$working_ms" == "$MS_NAME" ]]; then
		echo 'ERROR: Working MS must differ from the original MS' >&2
		return 1
	fi

	# Gain tables must have been produced by reference calibration.
	if ! compgen -G "$JOB_DIR/GAINTABLES/cal_1GC_*" > /dev/null; then
		echo 'ERROR: No 1GC gain tables were produced' >&2
		return 1
	fi

	# Publish only derived MS directories.
	# Never follow or move the original read-only MS symlink.
	for ms_path in "$JOB_DIR"/*.ms; do
		[[ -e "$ms_path" ]] || continue

		if [[ -L "$ms_path" ]]; then
			if [[ "$ms_path" != "$JOB_DIR/$MS_NAME" ]]; then
				echo "ERROR: Unexpected MS symlink: $ms_path" >&2
				return 1
			fi
			continue
		fi

		[[ -d "$ms_path" ]] || {
			echo "ERROR: Invalid MS product: $ms_path" >&2
			return 1
		}

		name="$(basename "$ms_path")"

		if [[ -e "$OUT_DIR/$name" ]]; then
			echo "ERROR: Output already exists: $name" >&2
			return 1
		fi

		mv -- "$ms_path" "$OUT_DIR/$name"
	done

	# Publish ancillary flag versions when CASA creates them.
	for ms_path in "$JOB_DIR"/*.ms.flagversions; do
		[[ -e "$ms_path" ]] || continue
		[[ -d "$ms_path" && ! -L "$ms_path" ]] || return 1
		mv -- "$ms_path" "$OUT_DIR/"
	done

	for name in GAINTABLES GAINPLOTS VISPLOTS; do
		if [[ -d "$JOB_DIR/$name" && ! -L "$JOB_DIR/$name" ]]; then
			mv -- "$JOB_DIR/$name" "$OUT_DIR/"
		fi
	done

	echo 'INFO: OXKAT 1GC scientific products published.'
}


# -----------------------------------------------------------------------------
# Validate and publish the FLAG scientific products
# -----------------------------------------------------------------------------
publish_flag_products() {

	local published_ms="$OUT_DIR/$MS_NAME"
	local source_ms="$INPUT_MS"
	local workspace_flags="$JOB_DIR/$MS_NAME.flagversions"
	local staged_flags="$(dirname "$INPUT_MS")/target_ms.flagversions"
	local source_flags=""
	local published_flags="$OUT_DIR/$MS_NAME.flagversions"

	echo "INFO: Validating OXKAT FLAG products..."

	# Require the expected private V2 staging location.
	if [[ "$source_ms" != "$(dirname "$JOB_DIR")/input/target_ms" ]]; then
		echo 'ERROR: FLAG source is not the private V2 target_ms' >&2
		return 1
	fi

	if [[ ! -d "$source_ms" || -L "$source_ms" ]]; then
		echo 'ERROR: Private FLAG target MS is missing or symlinked' >&2
		return 1
	fi

	if [[ ! -L "$JOB_DIR/$MS_NAME" ]]; then
		echo 'ERROR: FLAG workspace MS link is missing' >&2
		return 1
	fi

	if [[ "$(readlink -- "$JOB_DIR/$MS_NAME")" != "$source_ms" ]]; then
		echo 'ERROR: FLAG workspace link points to unexpected data' >&2
		return 1
	fi

	# Require scientific imaging and mask products.
	if [[ ! -d "$JOB_DIR/IMAGES" || -L "$JOB_DIR/IMAGES" ]]; then
		echo 'ERROR: FLAG IMAGES directory is invalid' >&2
		return 1
	fi

	if ! compgen -G "$JOB_DIR/IMAGES/*.mask0.fits" > /dev/null; then
		echo 'ERROR: FLAG initial cleaning mask not produced' >&2
		return 1
	fi

	if ! compgen -G "$JOB_DIR/IMAGES/*-MFS-image.fits" > /dev/null; then
		echo 'ERROR: FLAG initial WSClean image not produced' >&2
		return 1
	fi

	# Detect optional flag-version histories at either location.
	if [[ -e "$workspace_flags" || -L "$workspace_flags" ]]; then
		[[ -d "$workspace_flags" && ! -L "$workspace_flags" ]] || {
			echo 'ERROR: Invalid workspace flagversions' >&2
			return 1
		}
		source_flags="$workspace_flags"
	fi

	if [[ -e "$staged_flags" || -L "$staged_flags" ]]; then
		[[ -d "$staged_flags" && ! -L "$staged_flags" ]] || {
			echo 'ERROR: Invalid staged flagversions' >&2
			return 1
		}

		if [[ -n "$source_flags" ]]; then
			echo 'ERROR: Duplicate FLAG flag-version histories' >&2
			return 1
		fi

		source_flags="$staged_flags"
	fi

	# Validate all destinations before moving anything.
	for destination in \
		"$published_ms" \
		"$OUT_DIR/IMAGES" \
		"$published_flags"; do
		if [[ -e "$destination" || -L "$destination" ]]; then
			echo "ERROR: FLAG destination already exists: $destination" >&2
			return 1
		fi
	done

	# Avoid implicit cross-filesystem copy-and-delete behavior.
	if [[ "$(stat -c %d -- "$source_ms")" != \
	      "$(stat -c %d -- "$OUT_DIR")" ]]; then
		echo 'ERROR: FLAG MS publication crosses filesystems' >&2
		return 1
	fi

	if [[ "$(stat -c %d -- "$JOB_DIR/IMAGES")" != \
	      "$(stat -c %d -- "$OUT_DIR")" ]]; then
		echo 'ERROR: FLAG image publication crosses filesystems' >&2
		return 1
	fi

	if [[ -n "$source_flags" ]]; then
		if [[ "$(stat -c %d -- "$source_flags")" != \
		      "$(stat -c %d -- "$OUT_DIR")" ]]; then
			echo 'ERROR: FLAG flagversions publication crosses filesystems' >&2
			return 1
		fi
	fi

	# Publish actual directories, never the MS symlink.
	mv -T -- "$source_ms" "$published_ms"

	rm -- "$JOB_DIR/$MS_NAME"

	mv -T -- "$JOB_DIR/IMAGES" "$OUT_DIR/IMAGES"

	if [[ -n "$source_flags" ]]; then
		mv -T -- "$source_flags" "$published_flags"
	fi

	echo "INFO: Published flagged target MS: $MS_NAME"
	echo 'INFO: OXKAT FLAG scientific products published.'
}



on_error() {
	local code=$?

	trap - ERR

	# Preserve scientific diagnostics first.
	copy_outputs || true

	# Report the original failure without masking its exit code.
	write_manifest failed "$code" || true

	if [[ "$WAIT_COPY" == true ]]; then
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
# Generate and optionally execute first-generation calibration
# -----------------------------------------------------------------------------
if [[ "$STAGE" == "1GC" ]]; then

	echo "INFO: Preparing OXKAT 1GC stage..."

	/usr/bin/python3 "$JOB_DIR/setups/1GC.py" node 2>&1 | tee "$JOB_DIR/LOGS/caesar_setup_1GC.log"

	if [[ ! -s "$JOB_DIR/submit_1GC_jobs.sh" ]]; then
		echo 'ERROR: OXKAT did not generate submit_1GC_jobs.sh' >&2
		false
	fi

	if [[ "$RUN" == true ]]; then

		echo "INFO: Executing OXKAT 1GC calibration..."

		# Propagate failures from CASA and Python commands piped through tee.
		bash -o errexit -o pipefail \
			"$JOB_DIR/submit_1GC_jobs.sh" 2>&1 \
			| tee "$JOB_DIR/LOGS/caesar_run_1GC.log"

		# Validate and publish scientific products.
		publish_1gc_products

		STATUS=completed

	else

		echo 'INFO: OXKAT 1GC preparation only.'
		STATUS=prepared

	fi

	# Preserve the upstream observation metadata.
	if [[ "$OUT_DIR" != "$JOB_DIR" ]]; then
		cp "$JOB_DIR/project_info.json" "$OUT_DIR/project_info.json"
	fi

	copy_outputs
	write_manifest "$STATUS" 0

	if [[ "$WAIT_COPY" == true ]]; then
		echo "INFO: Waiting $COPY_WAIT_TIME seconds after copying..."
		sleep "$COPY_WAIT_TIME"
	fi

	echo "INFO: OXKAT 1GC $STATUS."
	exit 0
fi

# -----------------------------------------------------------------------------
# Generate and execute target flagging and initial mask-making
# -----------------------------------------------------------------------------
if [[ "$STAGE" == "FLAG" ]]; then

	echo "INFO: Preparing OXKAT FLAG stage..."

	/usr/bin/python3 "$JOB_DIR/setups/FLAG.py" node \
		2>&1 | tee "$JOB_DIR/LOGS/caesar_setup_FLAG.log"

	if [[ ! -s "$JOB_DIR/submit_flag_jobs.sh" ]]; then
		echo 'ERROR: OXKAT did not generate submit_flag_jobs.sh' >&2
		false
	fi

	# Ensure the setup script did not silently skip the target.
	if ! grep -q 'tricolour' "$JOB_DIR/submit_flag_jobs.sh"; then
		echo 'ERROR: FLAG recipe contains no Tricolour command' >&2
		false
	fi

	if [[ "$RUN" == true ]]; then
		echo "INFO: Executing OXKAT FLAG processing..."

		bash -o errexit -o pipefail \
			"$JOB_DIR/submit_flag_jobs.sh" \
			2>&1 | tee "$JOB_DIR/LOGS/caesar_run_FLAG.log"

		publish_flag_products

		STATUS=completed
	else
		echo 'INFO: OXKAT FLAG preparation only.'
		STATUS=prepared
	fi

	if [[ "$OUT_DIR" != "$JOB_DIR" ]]; then
		cp -- "$JOB_DIR/project_info.json" \
			"$OUT_DIR/project_info.json"
	fi

	copy_outputs
	write_manifest "$STATUS" 0

	if [[ "$WAIT_COPY" == true ]]; then
		echo "INFO: Waiting $COPY_WAIT_TIME seconds after output publication..."
		sleep "$COPY_WAIT_TIME"
	fi

	echo "INFO: OXKAT FLAG $STATUS."
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
