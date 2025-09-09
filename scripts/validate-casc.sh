#!/usr/bin/env bash
# Validate JCasC configuration for Jenkins Migration Tool

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Load libraries
source "$PROJECT_DIR/lib/logging.sh"
source "$PROJECT_DIR/lib/validation.sh"

#######################################
# Show usage
#######################################
show_help() {
    cat << 'EOF'
JCasC Configuration Validator

USAGE:
    ./validate-casc.sh [CONFIG_FILE]

OPTIONS:
    CONFIG_FILE    Path to jenkins.yaml file (default: /var/lib/jenkins/casc_configs/jenkins.yaml)
    -h, --help     Show this help

EXAMPLES:
    ./validate-casc.sh
    ./validate-casc.sh /opt/jenkins-docker/jenkins.yaml
EOF
}

#######################################
# Main validation function
#######################################
main() {
    setup_logging
    
    local config_file="${1:-/var/lib/jenkins/casc_configs/jenkins.yaml}"
    
    if [[ "${1}" == "-h" || "${1}" == "--help" ]]; then
        show_help
        exit 0
    fi
    
    log_info "Validating JCasC configuration: ${config_file}"
    
    if validate_jcasc_config "${config_file}"; then
        log_success "JCasC configuration validation passed"
        exit 0
    else
        log_error "JCasC configuration validation failed"
        exit 1
    fi
}

# Load JCasC module for validation functions
source "$PROJECT_DIR/modules/jcasc.sh"

main "$@"