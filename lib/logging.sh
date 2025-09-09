#!/usr/bin/env bash
# Logging utilities for Jenkins Migration Tool

# ANSI color codes
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly NC='\033[0m' # No Color

# Logging levels
readonly LOG_ERROR=1
readonly LOG_WARNING=2
readonly LOG_INFO=3
readonly LOG_DEBUG=4

# Default log level
LOG_LEVEL=${MIGRATION_LOG_LEVEL:-INFO}

#######################################
# Set up logging for the session
#######################################
setup_logging() {
    # Convert log level name to number
    case "${LOG_LEVEL,,}" in
        error) LOG_LEVEL_NUM=$LOG_ERROR ;;
        warning|warn) LOG_LEVEL_NUM=$LOG_WARNING ;;
        info) LOG_LEVEL_NUM=$LOG_INFO ;;
        debug) LOG_LEVEL_NUM=$LOG_DEBUG ;;
        *) LOG_LEVEL_NUM=$LOG_INFO ;;
    esac
    
    # Enable debug mode if requested
    if [[ "${DEBUG:-false}" == "true" ]]; then
        LOG_LEVEL_NUM=$LOG_DEBUG
        set -x
    fi
}

#######################################
# Log with timestamp and level
# Arguments:
#   $1 - Log level (ERROR, WARNING, INFO, DEBUG)
#   $2 - Color code
#   $3 - Message
#######################################
log_with_level() {
    local level=$1
    local color=$2
    local message=$3
    local level_num=$4
    
    # Check if we should log this level
    if [[ ${level_num} -le ${LOG_LEVEL_NUM:-${LOG_INFO}} ]]; then
        printf "${color}%s [%s] %s${NC}\n" "$(date '+%H:%M:%S')" "${level}" "${message}" >&2
    fi
}

#######################################
# Logging functions
#######################################
log_error() {
    log_with_level "ERROR" "${RED}" "${1}" ${LOG_ERROR}
}

log_warning() {
    log_with_level "WARNING" "${YELLOW}" "${1}" ${LOG_WARNING}
}

log_info() {
    log_with_level "INFO" "${BLUE}" "${1}" ${LOG_INFO}
}

log_debug() {
    log_with_level "DEBUG" "${PURPLE}" "${1}" ${LOG_DEBUG}
}

log_success() {
    printf "${GREEN}%s [SUCCESS] %s${NC}\n" "$(date '+%H:%M:%S')" "${1}" >&2
}

#######################################
# Fail with error message and exit
#######################################
fail() {
    log_error "${1}"
    exit 1
}

