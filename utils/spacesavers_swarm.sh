#!/usr/bin/env bash
set -euo pipefail

__VERSION__="1.0.0"

function usage() { cat << EOF
spacesavers_swarm.sh: a utility for creating spacesaver swarms jobs.

Usage:
  $ spacesavers_swarm.sh [-h] [-v] \\
      [--dependency] \\
      [--dry-run] \\
      --input DIRECTORY \\
      --output OUTPUT

Synopsis:
  This script provides a high level wrapper to run spacesavers
ls sub command in parallel. Given an --input DIRECTORY, it will 
run an instance of spacesaver in each of its child directories
using swarm. Job submission is automatically handled. Please use
the --dry-run option if you do not want to run anything.

Required Arguments:
  -i, --input DIRECTORY [Type: Str]  Parent input directory. 
                                      An instance of spacesavers will
                                      run against each child directory
                                      in the input parent directory.
  -o, --output OUTPUT  [Type: Path]  Path to an output directory.
                                      Local path where log files and
                                      swarm files will be generated.

Options:
  -e, --dependency    [Type: Int]    External Dependency Job ID.
                                       Any child jobs of generated by
                                       this script will not run until
                                       the provided dependency job has
                                       completed, either successfully 
                                       or un-successfully.
  -n, --dry-run       [Type: Bool]   Dryrun the script and do not submit
                                      any jobs to the cluster. This will
                                      create the swarms files, but will 
                                      not submit them to the cluster.
  -h, --help          [Type: Bool]   Displays usage and help information.
  -v, --version       [Type: Bool]   Displays version information.

Example:
  $ spacesavers_swarm.sh -i /data/CCBR/projects \\
      -o /data/$USER/logs/projects 

Version:
  ${__VERSION__}
EOF
}


# Functions
function err() { cat <<< "$@" 1>&2; }
function fatal() { cat <<< "$@" 1>&2; usage; exit 1; }
function version() { echo "${0##*/} v${__VERSION__}"; }
function timestamp() { date +"%Y-%m-%d_%H-%M-%S"; }
function abspath() { readlink -e "$1"; }
function parser() {
  # Adds parsed command-line args to GLOBAL $Arguments associative array
  # + KEYS = short_cli_flag ("j", "o", ...)
  # + VALUES = parsed_user_value ("MasterJobName" "/scratch/hg38", ...)
  # @INPUT "$@" = user command-line arguments
  # @CALLS check() to see if the user provided all the required arguments

  while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
      -h  | --help) usage && exit 0;;
      -v  | --verison) version && exit 0;;
      -i  | --input)  provided "$key" "${2:-}"; Arguments["i"]="$2"; shift; shift;;
      -o  | --output) provided "$key" "${2:-}"; Arguments["o"]="$2"; shift; shift;;
      -e  | --dependency) provided "$key" "${2:-}"; Arguments["e"]="$2"; shift; shift;;
      -n  | --dry-run) Arguments["n"]=true; shift;;
      -*  | --*) err "Error: Failed to parse unsupported argument: '${key}'."; usage && exit 1;;
      *) err "Error: Failed to parse unrecognized argument: '${key}'. Do any of your inputs have spaces?"; usage && exit 1;;
    esac
  done

  # check() for required args
  check
}


function provided() {
  # Checks to see if the argument's value exists
  # @INPUT $1 = name of user provided argument
  # @INPUT $2 = value of user provided argument
  # @CALLS fatal() if value is empty string or NULL

  if [[ -z "${2:-}" ]]; then
     fatal "Fatal: Failed to provide value to '${1}'!";
  fi
}


function check(){
  # Checks to see if user provided required arguments
  # @INPUTS $Arguments = Global Associative Array
  # @CALLS fatal() if user did NOT provide all the $required args

  # List of required arguments
  local required=("i" "o")
  for arg in "${required[@]}"; do
    value=${Arguments[${arg}]:-}
    if [[ -z "${value}" ]]; then
      fatal "Failed to provide all required args.. missing ${arg}"
    fi
  done
}


function require(){
  # Requires an executable is in $PATH
  # as a last resort it will attempt to load 
  # the executable as a module. If an exe is
  # not in $PATH raises fatal().
  # @INPUT $1 = executable to check
  # @INPUT $2 = optional module to load

  # Check if $1 in $PATH
  # If not, try to module load $2/$1 
  # as a last resort method.
  last_resort="${2:-"$1"}"
  command -V "$1" &> /dev/null || { 
    command -V module &> /dev/null && 
    module purge && module load "$last_resort"
  } || fatal "Error: failed to find or load '$1', not installed on target system."

}


function jobscript(){
    # Create swarm file for running spacesavers swarm
    # @INPUT $1 = Path to spacesavers installation
    # @INPUT $2 = Parent Input directory
    # @INPUT $3 = Ouput directory for logs and swarm files

    local gitdir="$1"
    local inputdir="$2"

    # Add she-bang to swarm file
    echo '#!/usr/bin/env bash' > "${outdir}/spacesavers.swarm"
    echo '#!/usr/bin/env bash' > "${outdir}/spacesavers.sh"
    # Create body of the job script
    # Add a line or entry for every 
    # child directory in the provided
    # input directory
    i=0  # add top-level parent directory to spacesavers.sh
    while read chdir; do
        local outscript="${outdir}/spacesavers.swarm";
        prefix=$(basename "$chdir")
        # Add the first line to batch job
        if [ $i -eq 0 ]; then 
            outscript="${outdir}/spacesavers.sh"
        fi
        # Output file prefix is child directory name
        echo "${gitdir}/spacesaver ls $chdir 1> ${outdir}/${prefix}.tsv 2> ${outdir}/${prefix}.err" \
            >> "${outscript}"
        i=$((i+1)) # increment counter, add to swarm file 
    done < <(find "${inputdir}" -maxdepth 1 -type d)

    chmod +x "${outdir}/spacesavers.swarm"
    chmod +x "${outdir}/spacesavers.sh"
}


function main(){
  # Parses args and pulls remote resources
  # @INPUT "$@" = command-line arguments
  # @CALLS pull()

  if [ $# -eq 0 ]; then usage; exit 1; fi

  # Spacesavers git installation
  home="$(dirname "$(abspath "$(dirname "${BASH_SOURCE[0]}")")")"

  # Check python3 is installed
  require "python3" "python/3.7"

  # Associative array to store parsed args
  declare -Ag Arguments

  # Parses user provided command-line arguments
  parser "${@}" # Remove first item of list

  # Required arguments
  inputdir="$(abspath "${Arguments[i]}")"

  # Optional Arguments
  outdir="${Arguments[o]}"
  [ ! -d "$outdir" ] && mkdir -p "$outdir"
  outdir="$(readlink -f "${Arguments[o]}")"
  dryrun="${Arguments[n]:-false}"
  ext_dep="${Arguments[e]:-}"
  if [[ -n "${ext_dep}" ]]; then 
    ext_dep="--dependency=afterany:${ext_dep}" 
  fi

  # Step 1. Create swarm file for spacesavers 
  jobscript "${home}" "${inputdir}" "${outdir}"

  # Step 2. Submit swarm job and top-level 
  # sbatch job as a dependency of swarm job.
  # -e option can set a dependency for the 
  # swarm job and subsequent batch job
  if [ "${dryrun}" = false ]; then
    # Swarm job for each child directory
    dependency=$(swarm ${ext_dep} -g 8 \
       -t 2 \
       --bundle 6 \
       --job-name "space_swarm" \
       --time 2:00:00 \
       --silent \
       --file "${outdir}/spacesavers.swarm")
    err "Submitting swarm: ${dependency}"
    # Top-level sbatch script that evalulates
    # everything together after the swarm job
    # finishes.
    last=$(sbatch --cpus-per-task=2 \
       --mem=32g \
       --time=10-00:00:00 \
       -J "space_batch" \
       --mail-type=BEGIN,END,FAIL \
       --dependency=afterany:${dependency} \
       "${outdir}/spacesavers.sh")
    echo "Submitting sbatch: ${last}"
  fi

}


# Main: check usage, parse args, and run pipeline
main "$@"
