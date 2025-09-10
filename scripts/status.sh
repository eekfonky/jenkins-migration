#!/usr/bin/env bash
# Jenkins Migration Status Checker

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"

# Load libraries
# shellcheck source=../lib/logging.sh
source "${PROJECT_DIR}/lib/logging.sh"

# Load modules
# shellcheck source=../modules/jenkins_service.sh
source "${PROJECT_DIR}/modules/jenkins_service.sh"
# shellcheck source=../modules/migration_state.sh
source "${PROJECT_DIR}/modules/migration_state.sh"

#######################################
# Main status function
#######################################
main() {
    setup_logging
    
    log_info "🔍 Jenkins Migration Status"
    log_info "============================"
    
    # Check migration state
    local migration_status
    migration_status=$(get_migration_status)
    log_info "Migration Status: ${migration_status}"
    
    # Check service status
    local service_status
    service_status=$(get_service_status)
    log_info "Service Status: ${service_status}"
    
    # Check if containers are running
    if docker ps --format "table {{.Names}}\t{{.Status}}" 2>/dev/null | grep -q jenkins; then
        log_info "Docker Containers:"
        docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" --filter name=jenkins
        docker ps --format "table {{.Names}}\t{{.Status}}" --filter name=watchtower
    fi
    
    # Show Jenkins URL if available
    if [[ -f "${PROJECT_DIR}/jenkins-migrate.conf" ]]; then
        local jenkins_url
        jenkins_url=$(grep "^JENKINS_URL=" "${PROJECT_DIR}/jenkins-migrate.conf" 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "")
        if [[ -n "${jenkins_url}" ]]; then
            log_info "Jenkins URL: ${jenkins_url}"
            
            # Test if accessible
            if curl -sf --connect-timeout 5 "${jenkins_url}/login" >/dev/null 2>&1; then
                log_success "✅ Jenkins is accessible"
            else
                log_warning "⚠️  Jenkins is not accessible"
            fi
        fi
    fi
    
    # Show migration history if available
    echo
    show_migration_history
}

main "${@}"