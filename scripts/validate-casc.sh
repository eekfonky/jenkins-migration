#!/usr/bin/env bash
# Validate JCasC configuration for Jenkins Migration Tool

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Load libraries
source "$PROJECT_DIR/lib/logging.sh"
source "$PROJECT_DIR/lib/validation.sh"

# Default Docker deployment directory
DOCKER_DIR="${DOCKER_DIR:-/opt/jenkins-docker}"

#######################################
# Show usage
#######################################
show_help() {
    cat << 'EOF'
JCasC Configuration Validator

USAGE:
    ./validate-casc.sh [OPTIONS] [CONFIG_FILE]

OPTIONS:
    --docker       Validate configuration using a temporary Jenkins Docker container.
                   This provides a full, high-fidelity validation.
                   Requires Docker to be running.
    -h, --help     Show this help

ARGUMENTS:
    CONFIG_FILE    Path to jenkins.yaml file.
                   Default: ${DOCKER_DIR}/jenkins.yaml

EXAMPLES:
    ./validate-casc.sh
    ./validate-casc.sh --docker
    ./validate-casc.sh /path/to/my-jenkins.yaml
    ./validate-casc.sh --docker /path/to/my-jenkins.yaml
EOF
}

#######################################
# Detect Jenkins home directory (simplified version)
#######################################
detect_jenkins_home_for_validation() {
    # This is a simplified detection for validation purposes.
    # It checks common paths and the JENKINS_HOME env var.
    if [[ -n "${JENKINS_HOME:-}" && -d "${JENKINS_HOME}" ]]; then
        echo "${JENKINS_HOME}"
        return 0
    fi

    local common_paths=("/var/lib/jenkins" "/opt/jenkins-docker/jenkins_home")
    for path in "${common_paths[@]}"; do
        if [[ -d "${path}" && -f "${path}/config.xml" ]]; then
            echo "${path}"
            return 0
        fi
    done

    echo ""
}


#######################################
# Validate JCasC using a Docker container for high-fidelity checking
#######################################
validate_jcasc_docker() {
    local config_file="$1"

    log_info "Performing high-fidelity validation using Docker..."

    if ! command -v docker &> /dev/null; then
        log_error "Docker is not installed. Cannot perform Docker-based validation."
        return 1
    fi

    if ! docker info >/dev/null 2>&1; then
        log_error "Docker daemon is not running."
        return 1
    fi

    local jenkins_home
    jenkins_home=$(detect_jenkins_home_for_validation)
    if [[ -z "${jenkins_home}" ]]; then
        log_error "Could not detect JENKINS_HOME. Cannot mount plugins for validation."
        log_error "Set the JENKINS_HOME environment variable to the path of your Jenkins data."
        return 1
    fi
    log_info "Found JENKINS_HOME at ${jenkins_home} to mount for plugins."

    local container_name="jcasc-validator-$(date +%s)"
    log_info "Starting temporary container '${container_name}' for validation..."

    local validation_logs
    validation_logs=$(mktemp)

    local exit_code=0
    docker run --rm \
        --name "${container_name}" \
        -e CASC_JENKINS_CONFIG_CHECK=true \
        -e JENKINS_HOME=/var/jenkins_home \
        -v "${jenkins_home}:/var/jenkins_home" \
        -v "${config_file}:/tmp/jenkins.yaml:ro" \
        -e CASC_JENKINS_CONFIG=/tmp/jenkins.yaml \
        jenkins/jenkins:lts > "${validation_logs}" 2>&1 || exit_code=$?

    if [[ ${exit_code} -eq 0 ]]; then
        log_success "Docker-based validation successful."
        log_debug "Jenkins container exited cleanly (code 0)."
        rm -f "${validation_logs}"
        return 0
    else
        log_error "Docker-based validation FAILED (exit code: ${exit_code})."
        log_error "The configuration is invalid. See logs for details:"
        echo "--------------------------------- DOCKER LOGS ---------------------------------"
        cat "${validation_logs}"
        echo "------------------------------- END DOCKER LOGS -------------------------------"
        rm -f "${validation_logs}"
        return 1
    fi
}


#######################################
# Main validation function
#######################################
main() {
    setup_logging
    
    local use_docker=false
    local config_file=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case ${1} in
            --docker)
                use_docker=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                if [[ -z "${config_file}" ]]; then
                    config_file="${1}"
                else
                    log_error "Unknown option or multiple config files specified: ${1}"
                    show_help
                    exit 1
                fi
                shift
                ;;
        esac
    done

    # Set default config file if not provided
    if [[ -z "${config_file}" ]]; then
        config_file="${DOCKER_DIR}/jenkins.yaml"
    fi

    if [[ ! -f "${config_file}" ]]; then
        log_error "Configuration file not found: ${config_file}"
        show_help
        exit 1
    fi

    log_info "Validating JCasC configuration: ${config_file}"

    local result=0
    if [[ "${use_docker}" == "true" ]]; then
        validate_jcasc_docker "${config_file}"
        result=$?
    else
        # Load JCasC module for basic validation functions
        source "$PROJECT_DIR/modules/jcasc.sh"
        validate_jcasc_config "${config_file}"
        result=$?
    fi

    if [[ ${result} -eq 0 ]]; then
        log_success "JCasC configuration validation passed."
        exit 0
    else
        log_error "JCasC configuration validation failed."
        exit 1
    fi
}

main "$@"