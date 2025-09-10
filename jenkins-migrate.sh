#!/usr/bin/env bash
# Jenkins Migration Tool - Lift & Shift systemd to Docker with JCasC
# Preserves all Jenkins data via ${JENKINS_HOME} volume mount

set -euo pipefail

# Script directory for relative paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# Migration state directory
MIGRATION_STATE_DIR="${SCRIPT_DIR}/.migration"
readonly MIGRATION_STATE_DIR
export MIGRATION_STATE_DIR  # Used by modules for state management

# Docker deployment directory
DOCKER_DIR="${DOCKER_DIR:-/opt/jenkins-docker}"
readonly DOCKER_DIR
export DOCKER_DIR

# Global variables (discovered dynamically)
JENKINS_HOME=""
JENKINS_UID=""
JENKINS_GID=""
JENKINS_URL=""
JENKINS_PORT=""
JENKINS_AGENT_PORT=""
DETECTED_SERVICE_TYPE=""
MIGRATION_ID=""
DRY_RUN=${DRY_RUN:-false}
DEBUG=${DEBUG:-false}
SKIP_PLUGIN_ANALYSIS=${SKIP_PLUGIN_ANALYSIS:-false}

# Load configuration if exists
CONFIG_FILE="${SCRIPT_DIR}/jenkins-migrate.conf"
if [[ -f "${CONFIG_FILE}" ]]; then
    # shellcheck source=jenkins-migrate.conf
    source "${CONFIG_FILE}"
    
    # Export Jenkins API variables for module access
    export JENKINS_URL
    export JENKINS_USER
    export JENKINS_API_TOKEN
    
fi

# Load library functions
# shellcheck source=lib/logging.sh
# shellcheck source=lib/validation.sh  
# shellcheck source=lib/templating.sh
# shellcheck source=lib/jenkins_connectivity.sh
for lib_file in "${SCRIPT_DIR}/lib"/*.sh; do
    [[ -f "${lib_file}" ]] && source "${lib_file}"
done

# Load module functions
# shellcheck source=modules/docker.sh
# shellcheck source=modules/jcasc.sh
# shellcheck source=modules/jenkins_service.sh
# shellcheck source=modules/migration_state.sh
# shellcheck source=modules/plugin_analysis.sh
for module_file in "${SCRIPT_DIR}/modules"/*.sh; do
    [[ -f "${module_file}" ]] && source "${module_file}"
done

# Set up logging to file (accessible to both jenkins and ubuntu users)
LOG_DIR="/var/log/jenkins-migration"
LOG_FILE="${LOG_DIR}/migration-$(date +%Y%m%d-%H%M%S).log"

# Create log directory with proper permissions if running as root
if [[ ${EUID} -eq 0 ]]; then
    mkdir -p "${LOG_DIR}"
    chmod 755 "${LOG_DIR}"  # Everyone can read and enter
    # Keep root as owner since script runs as root
fi

# Redirect all output to both console and log file if log directory exists
if [[ -d "${LOG_DIR}" ]] && [[ -w "${LOG_DIR}" ]]; then
    exec 2> >(tee -a "${LOG_FILE}" >&2)
    exec 1> >(tee -a "${LOG_FILE}")
    chmod 644 "${LOG_FILE}" 2>/dev/null || true  # Everyone can read log file
    echo "Migration log: ${LOG_FILE}"
fi

#######################################
# Display usage information
#######################################
show_help() {
    cat << 'EOF'
Jenkins Migration Tool - Systemd to Docker with JCasC

USAGE:
    sudo ./jenkins-migrate.sh [OPTIONS]

OPTIONS:
    --dry-run       Preview changes without executing
    --rollback      Rollback to systemd Jenkins service
    --skip-plugin-analysis  Skip the check for unused plugins
    --debug         Enable verbose debug output
    -y, --yes       Skip interactive confirmations
    -h, --help      Show this help message

EXAMPLES:
    sudo ./jenkins-migrate.sh                # Run migration
    sudo ./jenkins-migrate.sh --dry-run      # Preview migration
    sudo ./jenkins-migrate.sh --rollback     # Rollback to systemd
    sudo ./jenkins-migrate.sh --debug        # Debug mode

REQUIREMENTS:
    - Ubuntu 18.04+
    - sudo access
    - Existing Jenkins systemd service
    - 2GB+ RAM

Docker will be installed automatically if missing.
EOF
}

#######################################
# Parse command line arguments
#######################################
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case ${1} in
            --dry-run)
                DRY_RUN=true
                ;;
            --rollback)
                ROLLBACK=true
                ;;
            --skip-plugin-analysis)
                SKIP_PLUGIN_ANALYSIS=true
                ;;
            --debug)
                DEBUG=true
                ;;
            -y|--yes)
                export INTERACTIVE=false
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown option: ${1}"
                show_help
                exit 1
                ;;
        esac
        shift
    done
}

#######################################
# Validate environment and prerequisites
#######################################
validate_environment() {
    log_info "🔍 Phase 1: Environment Validation"
    
    # Check if running as root
    if [[ ${EUID} -ne 0 ]]; then
        log_error "This script requires root privileges"
        log_info "Please run with sudo: sudo ${0} ${*}"
        return 1
    fi
    log_success "Running as root (sudo detected)"
    
    # Check if Docker is available or can be installed
    if ! command -v docker &>/dev/null; then
        if [[ "${AUTO_INSTALL_DOCKER:-true}" == "true" ]]; then
            log_info "Docker not found - auto-installing..."
            install_docker || return 1
        else
            log_error "Docker is required but not installed"
            return 1
        fi
    else
        if ! docker info >/dev/null 2>&1; then
            log_error "Docker daemon is not running"
            return 1
        fi
        log_success "Docker daemon running ($(docker --version | cut -d' ' -f3 | tr -d ','))"
    fi
    
    # Check Docker Compose
    if docker compose version >/dev/null 2>&1; then
        log_success "Docker Compose available ($(docker compose version --short))"
    else
        log_error "Docker Compose v2 is required"
        return 1
    fi
    
    # Validate Docker group membership (must be done before detection phase)
    validate_docker_group_membership || return 1
    
    # Validate Docker socket access
    validate_docker_socket_access || return 1
    
    # Validate AppArmor compatibility
    validate_apparmor_docker || return 1
    
    log_success "All prerequisites met"
    return 0
}

#######################################
# Detect Jenkins setup and configuration
#######################################
detect_jenkins_setup() {
    log_info "🔍 Phase 2: Discovery & Detection"
    
    # Generate migration ID
    local migration_timestamp
    migration_timestamp="$(date +%Y%m%d_%H%M%S)"
    export MIGRATION_ID="mig_${migration_timestamp}"
    
    # Detect Jenkins home
    JENKINS_HOME=$(detect_jenkins_home)
    log_info "🏠 Jenkins Home: ${JENKINS_HOME} ($(du -sh "${JENKINS_HOME}" 2>/dev/null | cut -f1 || echo "size unknown"))"
    
    # Detect Jenkins UID/GID
    local jenkins_stat
    jenkins_stat=$(detect_jenkins_user "${JENKINS_HOME}")
    JENKINS_UID="${jenkins_stat%:*}"
    JENKINS_GID="${jenkins_stat#*:}"
    
    # Convert UID/GID to names if possible
    local jenkins_user_name jenkins_group_name
    jenkins_user_name=$(id -nu "${JENKINS_UID}" 2>/dev/null || echo "${JENKINS_UID}")
    jenkins_group_name=$(id -ng "${JENKINS_GID}" 2>/dev/null || echo "${JENKINS_GID}")
    log_info "👤 Jenkins User: ${JENKINS_UID}:${JENKINS_GID} (${jenkins_user_name}:${jenkins_group_name})"
    
    # Detect Jenkins URL and ports
    JENKINS_URL=$(detect_jenkins_url "${JENKINS_HOME}")
    local ports
    ports=$(detect_jenkins_ports)
    JENKINS_PORT="${ports%:*}"
    JENKINS_AGENT_PORT="${ports#*:}"
    log_info "🌐 Jenkins URL: ${JENKINS_URL}"
    log_info "🔌 Agent Port: ${JENKINS_AGENT_PORT}"
    
    # Detect SSL configuration  
    local ssl_config
    ssl_config=$(detect_jenkins_ssl_config)
    if [[ -n "${ssl_config}" ]]; then
        # Export SSL configuration as environment variables
        while IFS= read -r line; do
            if [[ -n "${line}" ]]; then
                eval "export ${line}"
            fi
        done <<< "${ssl_config}"
        
        # Update JENKINS_PORT if SSL is enabled
        if [[ "${JENKINS_SSL_ENABLED:-false}" == "true" ]]; then
            JENKINS_PORT="${JENKINS_HTTPS_PORT}"
            log_info "🔐 SSL Enabled: HTTPS on port ${JENKINS_PORT}"
        else
            log_info "🔓 SSL Disabled: HTTP on port ${JENKINS_PORT}"
        fi
    fi
    
    # Detect service status
    DETECTED_SERVICE_TYPE=$(detect_service_type)
    local service_status
    service_status=$(systemctl is-active jenkins 2>/dev/null || echo "inactive")
    log_info "⚙️  Service Status: ${service_status} (${DETECTED_SERVICE_TYPE})"
    
    # Count plugins if possible
    local plugin_count
    plugin_count=$(count_existing_plugins "${JENKINS_HOME}")
    log_info "📦 Plugins Found: ${plugin_count} plugins detected"
    
    # Validate port availability
    validate_jenkins_ports "${JENKINS_PORT}" "${JENKINS_AGENT_PORT}" || return 1
    
    return 0
}

#######################################
# Generate Docker configuration files
#######################################
generate_docker_config() {
    log_info "⚙️  Phase 3: Generating Docker Configuration"
    
    local docker_dir="${DOCKER_DIR}"
    
    
    # Create Docker management directory
    mkdir -p "${docker_dir}"
    log_info "📁 Creating ${docker_dir} (owned by ${JENKINS_UID}:${JENKINS_GID})"
    
    # Generate .env file
    generate_env_file > "${docker_dir}/.env"
    log_success "Generated .env with discovered variables"
    
    # Extract plugins first (required by Dockerfile)
    if extract_plugins_to_file "${docker_dir}/plugins.txt" "${JENKINS_HOME}"; then
        local plugin_count
        plugin_count=$(wc -l < "${docker_dir}/plugins.txt" 2>/dev/null || echo "0")
        log_success "🔌 Extracted ${plugin_count} plugins to plugins.txt"

        # Analyze and clean up unused plugins
        if [[ "${SKIP_PLUGIN_ANALYSIS}" == "false" ]]; then
            run_plugin_analysis || log_warning "Plugin analysis step encountered an issue. Continuing with the original plugin list."
        else
            log_info "Skipping plugin analysis as requested."
        fi
    fi
    
    # Generate JCasC configuration (required by Dockerfile)
    if ! generate_jcasc_config "${docker_dir}/jenkins.yaml"; then
        log_error "Failed to generate JCasC configuration - migration aborted"
        return 1
    fi
    log_success "⚙️  Generated jenkins.yaml (JCasC) configuration"

    # High-fidelity validation of the generated JCasC file
    log_info "Performing high-fidelity validation of JCasC configuration..."
    if ! "${SCRIPT_DIR}/scripts/validate-casc.sh" --docker "${docker_dir}/jenkins.yaml"; then
        log_error "Generated JCasC configuration failed validation."
        log_error "Aborting migration to prevent deployment of a broken configuration."
        return 1
    fi
    log_success "JCasC configuration passed high-fidelity validation"
    
    # Export all variables for template processing
    export JENKINS_UID JENKINS_GID JENKINS_HOME JENKINS_PORT JENKINS_AGENT_PORT
    export JENKINS_MEMORY_LIMIT JENKINS_MEMORY_RESERVATION JENKINS_CPU_LIMIT JENKINS_CPU_RESERVATION
    export MIGRATION_TIMESTAMP MIGRATION_ID DOCKER_DIR
    
    # Generate docker-compose.yml and Dockerfile from templates
    process_template_directory "${SCRIPT_DIR}/templates" "${docker_dir}"
    log_success "🐳 Generated Docker configuration from templates"
    
    # Set proper ownership
    chown -R "${JENKINS_UID}:${JENKINS_GID}" "${docker_dir}"
    
    log_success "All configuration files generated"
    return 0
}

#######################################
# Perform the actual migration
#######################################
perform_migration() {
    log_info "🔄 Phase 4: Service Migration"
    
    
    # Create migration state
    create_migration_state
    
    # Backup service configuration before making changes
    backup_service_config
    
    # Stop systemd Jenkins
    if systemctl is-active --quiet jenkins; then
        log_info "⏹️  Stopping systemd Jenkins service..."
        systemctl stop jenkins
        systemctl disable jenkins
        log_success "Jenkins systemd service stopped and disabled"
    else
        log_info "ℹ️  Jenkins systemd service is not running"
    fi
    
    # Start Docker containers using the improved function
    start_jenkins_containers "${DOCKER_DIR}" || return 1
    
    # Update migration state
    update_migration_state "completed"
    
    return 0
}

#######################################
# Verify migration health
#######################################
verify_migration() {
    log_info "🏥 Phase 5: Health Check & Verification"
    
    
    # Jenkins startup verification
    log_info "🌐 Jenkins URL: ${JENKINS_URL}"
    log_info "📋 Note: Jenkins may take 30-60 seconds to fully start up"
    
    # Quick log check for startup issues
    log_info "🔍 Checking Jenkins startup logs for errors..."
    local startup_logs
    startup_logs=$(docker logs jenkins --tail 50 2>&1 || echo "")
    
    if echo "${startup_logs}" | grep -q "ConfiguratorException\|BootFailure\|Failed to initialize Jenkins"; then
        log_error "❌ Jenkins startup failed - check logs:"
        log_error "   docker logs jenkins"
        echo "${startup_logs}" | grep -A 3 -B 3 "ConfiguratorException\|BootFailure\|Failed to initialize Jenkins" | head -10
        return 1
    elif echo "${startup_logs}" | grep -q "Jenkins is fully up and running"; then
        log_success "✅ Jenkins started successfully"
        log_warning "📋 View logs: docker logs -f jenkins"
    else
        log_info "📋 Jenkins is starting up - monitor logs for completion"
        log_warning "📋 Copy/paste: docker logs -f jenkins"
        log_info "📋 Verify accessibility at ${JENKINS_URL} once startup completes"
    fi
    
    # Verify Jenkins home mount
    log_info "🔍 Verifying Jenkins home mount..."
    if docker exec jenkins test -d /var/jenkins_home; then
        log_success "Jenkins home mounted successfully"
    else
        log_error "Jenkins home mount verification failed"
        return 1
    fi
    
    # Verify user data preserved (check if users directory exists)
    log_info "👥 Verifying user data preserved..."
    if docker exec jenkins test -d /var/jenkins_home/users; then
        log_success "User data preserved"
    else
        log_warning "User data directory not found (might be first run)"
    fi
    
    log_success "Migration verification complete"
    return 0
}

#######################################
# Show simplified dry-run preview
#######################################
show_dry_run_preview() {
    echo
    log_info "🔍 DRY RUN: Migration Preview"
    echo "=====================================" 
    log_info "This would:"
    log_info "  1. Stop systemd Jenkins service"
    log_info "  2. Create Docker configuration in /opt/jenkins-docker/"
    log_info "  3. Pull jenkins/jenkins:lts and watchtower images"
    log_info "  4. Start Jenkins in Docker container"
    log_info "  5. Preserve all Jenkins data via volume mount"
    echo
    log_info "To run actual migration: sudo ${0}"
    log_info "Jenkins would be accessible at: http://localhost:8080"
    echo
}

#######################################
# Show migration completion summary
#######################################
show_completion_summary() {
    echo
    log_success "🎉 SUCCESS! Jenkins Migration Complete!"
    echo "------------------------------------"
    echo "Jenkins URL:       ${JENKINS_URL}"
    echo "Container logs:    docker logs -f jenkins"
    echo "Plugin management: Edit ${DOCKER_DIR}/plugins.txt, then:"
    echo "                   cd ${DOCKER_DIR} && docker compose build && docker compose up -d"
    echo "JCasC config:      ${DOCKER_DIR}/jenkins.yaml"
    echo "Watchtower:        Auto-updates Jenkins LTS at ${WATCHTOWER_SCHEDULE:-4 AM daily}"
    echo "Migration log:     ${LOG_FILE:-Not logged to file}"
    echo "Rollback:          sudo ${0} --rollback"
    echo
}

#######################################
# Main function - orchestrate migration
#######################################
main() {
    # Set up logging
    setup_logging
    
    log_info "🔍 Jenkins Migration Tool v1.0"
    log_info "=========================================="
    echo
    
    # Parse arguments first
    parse_arguments "${@}"
    
    # Handle rollback
    if [[ "${ROLLBACK:-false}" == "true" ]]; then
        rollback_migration
        exit ${?}
    fi
    
    # Handle dry run with simplified preview
    if [[ "${DRY_RUN}" == "true" ]]; then
        show_dry_run_preview
        exit 0
    fi
    
    # Run migration phases
    validate_environment "${@}" || exit 1
    detect_jenkins_setup || exit 1
    generate_docker_config || exit 1
    perform_migration || exit 1
    verify_migration || exit 1
    
    # Show completion summary
    show_completion_summary
}

# Execute main with all arguments
main "${@}"