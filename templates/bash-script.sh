#!/usr/bin/env bash
#
# ---
# bash-script.sh
#
# Description:
#   A bash script starter template.
#
# Requirements:
#
# Usage:
#
# Exit Codes:
#   0: Success
# ---

set -euo pipefail # Enable strict mode: exit on error, unset variable, pipe failure

# --- Configuration ---

# The script's log file.
# The filename is made unique for each run by including the script's base name,
# a timestamp, and the script's Process ID ($$).
# e.g., /tmp/bash-script_20250719_154830_12345.log
LOG_FILE="/tmp/$(basename "${BASH_SOURCE[0]%.*}")_$(date +'%Y%m%d_%H%M%S')_$$.log"

# --- Logging Functions ---

# Function to print info messages to stderr and a log file.
log_info() {
  echo "INFO[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*" | tee -a "${LOG_FILE}" >&2
}

# Function to print error messages to stderr and a log file.
log_error() {
  echo "❌ ERROR[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*" | tee -a "${LOG_FILE}" >&2
}

# --- Core Functions ---

main() {
  # --- Main Script ---
  log_info "Script started, logging output to: ${LOG_FILE}"

  log_info "✅ ✅ ✅"
  log_info "------------------------------------------------------------------"
  log_info "Script completed, output logged to: ${LOG_FILE}"
  log_info "------------------------------------------------------------------"

  exit 0
}

main "$@"
