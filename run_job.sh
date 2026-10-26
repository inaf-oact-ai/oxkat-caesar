#!/bin/bash

##########################
##    PARSE ARGS
##########################
# - Read CAESAR-REST environment variables (Slurm convention).
#   Command-line arguments below take precedence when explicitly supplied.
RUNUSER="${RUNUSER:-caesar}"
CHANGE_RUNUSER_FLAG="${CHANGE_RUNUSER:-1}"
if [ "$CHANGE_RUNUSER_FLAG" = "0" ]; then
	CHANGE_USER=false
else
	CHANGE_USER=true
fi

# - CAESAR OPTIONS
#   JOB_DIR is the per-job execution directory (not a fixed /workspace path).
JOB_DIR="${JOB_DIR:-}"
JOB_OUTDIR="${JOB_OUTDIR:-}"
JOB_ARGS="${JOB_OPTIONS:-}"
##INPUTFILE=""

# - RCLONE OPTIONS
MOUNT_RCLONE_VOLUME=0
MOUNT_VOLUME_PATH="/mnt/storage"
RCLONE_REMOTE_STORAGE="neanias-nextcloud"
RCLONE_REMOTE_STORAGE_PATH="."
RCLONE_MOUNT_WAIT_TIME=10
RCLONE_COPY_WAIT_TIME=30

printf "ARGS:"; printf " %q" "$@"; printf "\n"

for item in "$@"
do
	case $item in
		--runuser=*)
			RUNUSER="${item#*=}"
		;;
		--change-runuser=*)
			CHANGE_USER_FLAG="${item#*=}"
			if [ "$CHANGE_USER_FLAG" = "1" ] ; then
				CHANGE_USER=true
			else
				CHANGE_USER=false
			fi
		;;
		--jobdir=*)
			JOB_DIR="${item#*=}"
		;;
		--joboutdir=*)
			JOB_OUTDIR="${item#*=}"
		;;
		--jobargs=*)
			JOB_ARGS="${item#*=}"
		;;
##		--inputfile=*)
##    	INPUTFILE=`echo $item | /bin/sed 's/[-a-zA-Z0-9]*=//'`
##		;;
		--mount-rclone-volume=*)
			MOUNT_RCLONE_VOLUME="${item#*=}"
		;;
		--mount-volume-path=*)
			MOUNT_VOLUME_PATH="${item#*=}"
		;;
		--rclone-remote-storage=*)
			RCLONE_REMOTE_STORAGE="${item#*=}"
		;;
		--rclone-remote-storage-path=*)
			RCLONE_REMOTE_STORAGE_PATH="${item#*=}"
		;;
		--rclone-mount-wait=*)
			RCLONE_MOUNT_WAIT_TIME="${item#*=}"
		;;
		--rclone-copy-wait=*)
			RCLONE_COPY_WAIT_TIME="${item#*=}"
		;;

		*)
			# - Unknown option
			echo "ERROR: Unknown option ($item)...exit!"
			exit 1
		;;
	esac
done


# - Check options
#   JOB_OPTIONS is supplied by CAESAR-REST through Singularity --env.
#   Manual invocations may override it with --jobargs.
if [ "$JOB_ARGS" = "" ]; then
	echo "ERROR: Empty JOB_ARGS argument!"
	exit 1
fi

if ! [[ "$RCLONE_COPY_WAIT_TIME" =~ ^[0-9]+$ ]]; then
	echo "ERROR: Invalid RCLONE_COPY_WAIT_TIME" >&2
	exit 2
fi

###############################
##    MOUNT VOLUMES
###############################
if [ "$MOUNT_RCLONE_VOLUME" = "1" ] ; then

	# - Create mount directory if not existing
	echo "INFO: Creating mount directory $MOUNT_VOLUME_PATH ..."
	mkdir -p "$MOUNT_VOLUME_PATH"	

	# - Get device ID of standard dir, for example $HOME
	#   To be compared with mount point to check if mount is ready
	DEVICE_ID=`stat "$HOME" -c %d`
	echo "INFO: Standard device id @ $HOME: $DEVICE_ID"

	# - Mount rclone volume in background
	uid=$(id -u "$RUNUSER")

	echo "INFO: Mounting rclone volume at path $MOUNT_VOLUME_PATH for uid/gid=$uid ..."
	/usr/bin/rclone mount --daemon --uid="$uid" --gid="$uid" --umask 000 --allow-other --file-perms 0777 --dir-cache-time 0m5s --vfs-cache-mode full "${RCLONE_REMOTE_STORAGE}:${RCLONE_REMOTE_STORAGE_PATH}" "$MOUNT_VOLUME_PATH" -vvv

	# - Wait until filesystem is ready
	echo "INFO: Sleeping $RCLONE_MOUNT_WAIT_TIME seconds and then check if mount is ready..."
	sleep $RCLONE_MOUNT_WAIT_TIME

	# - Get device ID of mount point
	MOUNT_DEVICE_ID=`stat "$MOUNT_VOLUME_PATH" -c %d`
	echo "INFO: MOUNT_DEVICE_ID=$MOUNT_DEVICE_ID"
	if [ "$MOUNT_DEVICE_ID" = "$DEVICE_ID" ] ; then
 		echo "ERROR: Failed to mount rclone storage at $MOUNT_VOLUME_PATH within $RCLONE_MOUNT_WAIT_TIME seconds, exit!"
		exit 1
	fi

	# - Print mount dir content
	echo "INFO: Mounted rclone storage at $MOUNT_VOLUME_PATH with success (MOUNT_DEVICE_ID: $MOUNT_DEVICE_ID)..."
	ls -ltr "$MOUNT_VOLUME_PATH"

	# - Create job & data directories
	echo "INFO: Creating job & data directories ..."
	mkdir -p "$MOUNT_VOLUME_PATH"/jobs
	mkdir -p "$MOUNT_VOLUME_PATH"/data

	# - Create job output directory
	#echo "INFO: Creating job output directory $JOB_OUTDIR ..."
	#mkdir -p $JOB_OUTDIR

fi


###############################
##    SET OPTIONS
###############################
# - Set job dir
if [ "$JOB_DIR" == "" ]; then
	if [ "$CHANGE_USER" = true ]; then
		JOB_DIR="/home/$RUNUSER/caesar-job"
	else
		JOB_DIR="$HOME/caesar-job"
	fi
fi

###############################
##    SET ASTROPY DIRS
###############################

# - Use the writable per-job directory as HOME.
#   Older Astropy versions may use ~/.astropy instead of XDG paths.
#   Slurm runs with --containall --no-home, so /home/caesar
#   inside the container may be read-only.

export HOME="$JOB_DIR"

# - Set XDG configuration and cache directories
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_CACHE_HOME="$HOME/.cache"

# - Create directories if not existing
echo "INFO: Creating Astropy config/cache directories ..."
mkdir -p \
    "$HOME/.astropy/config" \
    "$HOME/.astropy/cache" \
    "$XDG_CONFIG_HOME" \
    "$XDG_CACHE_HOME"

# - Print directory paths
echo "INFO: HOME=$HOME"
echo "INFO: XDG_CONFIG_HOME=$XDG_CONFIG_HOME"
echo "INFO: XDG_CACHE_HOME=$XDG_CACHE_HOME"

###############################
##    RUN OXKAT JOB
###############################
# - Parse job arguments into a Bash array.
#   JOB_OPTIONS / --jobargs is a whitespace-delimited list of --option=value
#   arguments. Do not evaluate it as shell code. Paths with spaces are not
#   supported by the current CAESAR-REST job argument contract.
read -r -a OXKAT_ARGS <<< "$JOB_ARGS"

# - Check the supported scientific options
HAS_STAGE=false
HAS_MS=false
HAS_PROJECT_INFO=false
OXKAT_STAGE=""

for arg in "${OXKAT_ARGS[@]}"; do
	case "$arg" in
		--stage=GET_INFO|--stage=1GC|--stage=FLAG)
			if [ "$HAS_STAGE" = true ]; then
				echo 'ERROR: Duplicate OXKAT stage option' >&2
				exit 2
			fi
			HAS_STAGE=true
			OXKAT_STAGE="${arg#*=}"
		;;
		
		--input-ms=/*)
			if [ "$HAS_MS" = true ]; then
				echo 'ERROR: Duplicate --input-ms option' >&2
				exit 2
			fi
			HAS_MS=true
		;;
		--project-info=/*)
			if [ "$HAS_PROJECT_INFO" = true ]; then
				echo 'ERROR: Duplicate --project-info option' >&2
				exit 2
			fi
			HAS_PROJECT_INFO=true
		;;

		--oxkat-config=*)
			# - Encoded scientific options produced by CAESAR-REST.
			# - The scientific content is validated by run_oxkat.sh.
			CONFIG_TOKEN="${arg#*=}"

			if [[ ! "$CONFIG_TOKEN" =~ ^[A-Za-z0-9_-]{1,3000}$ ]]; then
				echo 'ERROR: Invalid OXKAT configuration token' >&2
				exit 2
			fi
		;;
		--oxkat-home=/*)
			# - Optional override of the oxkat source directory
		;;
		*)
			echo "ERROR: Unsupported oxkat argument: $arg" >&2
			exit 2
		;;
	esac
done

if [ "$HAS_STAGE" != true ] || [ "$HAS_MS" != true ]; then
	echo 'ERROR: oxkat requires --stage and --input-ms' >&2
	exit 2
fi


if [[ "$OXKAT_STAGE" == "1GC" || "$OXKAT_STAGE" == "FLAG" ]]; then
	if [ "$HAS_PROJECT_INFO" != true ]; then
		echo "ERROR: $OXKAT_STAGE requires --project-info" >&2
		exit 2
	fi
fi

# - Select the oxkat runner included in the container
OXKAT_EXE="${OXKAT_RUNNER_PATH:-/opt/caesar/run_oxkat.sh}"
if [ ! -f "$OXKAT_EXE" ]; then
	echo "ERROR: Missing oxkat runner at $OXKAT_EXE" >&2
	exit 1
fi

# - Set runner arguments.
#   JOB_DIR is the execution directory; JOB_OUTDIR contains collected outputs.
#   --waitcopy retains the previous RCLONE VFS cache delay for Kubernetes.
OXKAT_CMD=(bash "$OXKAT_EXE" --run "--jobdir=$JOB_DIR")
if [ -n "$JOB_OUTDIR" ]; then
	OXKAT_CMD+=("--outdir=$JOB_OUTDIR")
	if [ "$MOUNT_RCLONE_VOLUME" = "1" ]; then
		OXKAT_CMD+=(--waitcopy "--copywaittime=$RCLONE_COPY_WAIT_TIME")
	fi
fi
OXKAT_CMD+=("${OXKAT_ARGS[@]}")


# - Check Astropy cache dir
#echo "INFO: Checking Astropy directories ..."
#python3 -c '
#import os
#from astropy.config import get_config_dir, get_cache_dir

#print("HOME:", os.environ.get("HOME"))
#print("Astropy config:", get_config_dir())
#print("Astropy cache:", get_cache_dir())
#'

# - Use a locale available in the container.
# - Avoid unsupported en_US.UTF-8 settings inherited from the host.
export LANG=C
export LANGUAGE=C
export LC_ALL=C
export LC_NUMERIC=C

# - Execute oxkat.
#   Kubernetes may start this entrypoint as root and switch to RUNUSER.
#   Slurm already runs as the submitting user (CHANGE_RUNUSER=0).

printf 'INFO: Running oxkat command:'
printf ' %q' "${OXKAT_CMD[@]}"
printf '\n'

if [ "$CHANGE_USER" = true ]; then
	if [ "$(id -u)" -ne 0 ]; then
		echo 'ERROR: --change-runuser=1 requires root; use 0 inside Slurm.' >&2
		exit 1
	fi
	exec runuser -u "$RUNUSER" -- "${OXKAT_CMD[@]}"
else
	exec "${OXKAT_CMD[@]}"
fi
