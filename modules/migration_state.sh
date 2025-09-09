#!/usr/bin/env bash
# Migration state management module

#######################################
# Create migration state directory and file with proper ownership
#######################################
create_migration_state() {
    local state_file="${MIGRATION_STATE_DIR}/state.json"
    
    mkdir -p "${MIGRATION_STATE_DIR}"
    
    log_info "Creating migration state: ${MIGRATION_ID:-unknown}"
    
    # Detect current service
    local current_service="unknown"
    if systemctl is-active --quiet jenkins; then
        current_service="systemd"
    elif docker ps --format '{{.Names}}' | grep -q "^jenkins$"; then
        current_service="docker"
    fi
    
    # Export variables for template processing
    export current_service
    
    local host_hostname host_os_release host_docker_version
    host_hostname="$(hostname)"
    host_os_release="$(lsb_release -ds 2>/dev/null || echo 'Unknown')"
    host_docker_version="$(docker --version 2>/dev/null || echo 'Not installed')"
    
    export HOST_HOSTNAME="${host_hostname}"
    export HOST_OS_RELEASE="${host_os_release}"
    export HOST_DOCKER_VERSION="${host_docker_version}"
    
    # Generate migration state JSON
    local template_file="${SCRIPT_DIR}/templates/migration-state.json.template"
    if [[ -f "${template_file}" ]]; then
        process_template "${template_file}" "${state_file}"
    else
        log_error "Migration state template not found: ${template_file}"
        return 1
    fi
    
    # Fix ownership to prevent permission issues
    if [[ -n "${SUDO_USER:-}" ]]; then
        chown -R "${SUDO_USER}:${SUDO_USER}" "${MIGRATION_STATE_DIR}" 2>/dev/null || true
    fi
    
    log_success "Migration state created: ${state_file} (current service: ${current_service})"
}

#######################################
# Update migration state with reality validation
#######################################
update_migration_state() {
    local new_status="$1"
    local additional_info="${2:-}"
    local state_file="${MIGRATION_STATE_DIR}/state.json"
    
    if [[ ! -f "${state_file}" ]]; then
        log_warning "Migration state file not found, creating new one"
        create_migration_state
    fi
    
    log_debug "Updating migration state to: $new_status"
    
    # Validate state matches reality
    local current_service="unknown"
    if systemctl is-active --quiet jenkins; then
        current_service="systemd"
    elif docker ps --format '{{.Names}}' | grep -q "^jenkins$"; then
        current_service="docker"
    fi
    
    # Use jq if available for safe JSON manipulation
    if command -v jq >/dev/null 2>&1; then
        local temp_file="${state_file}.tmp"
        jq --arg status "$new_status" \
           --arg timestamp "$(date -Iseconds)" \
           --arg info "$additional_info" \
           --arg service "$current_service" \
           '.status = $status | .last_updated = $timestamp | .current_service = $service | if $info != "" then .additional_info = $info else . end' \
           "$state_file" > "$temp_file" && mv "$temp_file" "$state_file"
    else
        # Fallback: simple sed replacement
        sed -i "s/\"status\": \"[^\"]*\"/\"status\": \"$new_status\"/" "$state_file"
        sed -i "/\"migration_id\"/a\\  \"last_updated\": \"$(date -Iseconds)\"," "$state_file"
        sed -i "/\"migration_id\"/a\\  \"current_service\": \"$current_service\"," "$state_file"
    fi
    
    # Fix ownership to prevent permission issues
    if [[ -n "${SUDO_USER:-}" ]]; then
        chown "$SUDO_USER:$SUDO_USER" "$state_file" 2>/dev/null || true
    fi
    
    log_debug "Migration state updated (current service: $current_service)"
}

#######################################
# Read migration state
#######################################
read_migration_state() {
    local state_file="${MIGRATION_STATE_DIR}/state.json"
    
    if [[ ! -f "${state_file}" ]]; then
        log_warning "No migration state file found"
        return 1
    fi
    
    cat "$state_file"
}
#######################################
# Get migration status
#######################################
get_migration_status() {
    local state_file="${MIGRATION_STATE_DIR}/state.json"
    
    if [[ ! -f "${state_file}" ]]; then
        echo "none"
        return 0
    fi
    
    if command -v jq >/dev/null 2>&1; then
        jq -r '.status' "$state_file" 2>/dev/null || echo "unknown"
    else
        grep -o '"status": "[^"]*"' "$state_file" | cut -d'"' -f4 || echo "unknown"
    fi
}
#######################################
# Show migration history
#######################################
show_migration_history() {
    local archive_dir="$MIGRATION_STATE_DIR/archive"
    
    if [[ ! -d "$archive_dir" ]]; then
        log_info "No migration history found"
        return 0
    fi
    
    log_info "Migration History:"
    log_info "=================="
    
    local count=0
    for state_file in "$archive_dir"/state_*.json; do
        [[ ! -f "$state_file" ]] && continue
        
        local migration_info
        if command -v jq >/dev/null 2>&1; then
            migration_info=$(jq -r '"\(.migration_id) | \(.start_time) | \(.status)"' "$state_file" 2>/dev/null)
        else
            local migration_id start_time status
            migration_id=$(grep -o '"migration_id": "[^"]*"' "$state_file" | cut -d'"' -f4)
            start_time=$(grep -o '"start_time": "[^"]*"' "$state_file" | cut -d'"' -f4)
            status=$(grep -o '"status": "[^"]*"' "$state_file" | cut -d'"' -f4)
            migration_info="$migration_id | $start_time | $status"
        fi
        
        echo "  $migration_info"
        count=$((count + 1))
    done
    
    if [[ $count -eq 0 ]]; then
        log_info "No migration history found"
    else
        log_info "Found $count migration record(s)"
    fi
}

#######################################
# Simplified rollback migration - basic stop Docker, start systemd
#######################################
rollback_migration() {
    log_info "↩️  Rolling back Jenkins migration..."
    
    
    # Stop Docker containers with proper path
    log_info "Stopping Docker containers..."
    if [[ -f "${DOCKER_DIR}/docker-compose.yml" ]]; then
        if cd "${DOCKER_DIR}"; then
            docker compose down 2>/dev/null || true
        fi
    else
        # Try to stop container directly if compose file not found
        docker stop jenkins 2>/dev/null || true
        docker rm jenkins 2>/dev/null || true
    fi
    
    # Clean up Docker directory and configurations
    log_info "Removing Docker-specific configurations..."
    if [[ -d "${DOCKER_DIR}" ]]; then
        log_info "Removing Docker directory: ${DOCKER_DIR}"
        rm -rf "${DOCKER_DIR}"
        log_debug "Removed Docker directory and all configurations"
    fi
    
    # Clean up ALL JCasC configs that interfere with systemd Jenkins
    local jenkins_home="${JENKINS_HOME:-/var/lib/jenkins}"
    local cleaned_configs=0
    
    # Remove root-level JCasC files
    for config_file in "${jenkins_home}/jenkins.yaml" "${jenkins_home}/jenkins.yml" "${jenkins_home}/casc.yaml"; do
        if [[ -f "${config_file}" ]]; then
            rm -f "${config_file}"
            log_debug "Removed JCasC config: $(basename "${config_file}")"
            cleaned_configs=$((cleaned_configs + 1))
        fi
    done
    
    # Remove entire casc_configs directory (both enabled and disabled)
    if [[ -d "${jenkins_home}/casc_configs" ]]; then
        rm -rf "${jenkins_home}/casc_configs"
        log_debug "Removed casc_configs directory"
        cleaned_configs=$((cleaned_configs + 1))
    fi
    
    # Clear failed boot attempts
    if [[ -f "${jenkins_home}/failed-boot-attempts.txt" ]]; then
        rm -f "${jenkins_home}/failed-boot-attempts.txt"
        log_debug "Cleared failed boot attempts"
    fi
    
    if [[ ${cleaned_configs} -gt 0 ]]; then
        log_info "Cleaned up ${cleaned_configs} JCasC configuration(s) for systemd compatibility"
    fi
    
    # Re-enable and start systemd Jenkins  
    log_info "Starting systemd Jenkins..."
    systemctl enable jenkins 2>/dev/null || true
    systemctl start jenkins
    
    # Check if Jenkins started successfully
    sleep 2
    if systemctl is-active --quiet jenkins; then
        log_success "✅ Jenkins systemd service started successfully"
    else
        log_error "Failed to start Jenkins systemd service"
        log_info "Check status with: systemctl status jenkins"
        log_info "Check logs with: journalctl -xeu jenkins.service"
        return 1
    fi
    
    # Update state to reflect reality if state file exists
    if [[ -d "$MIGRATION_STATE_DIR" ]]; then
        update_migration_state "rolled_back" "Rollback completed successfully"
    fi
    
    log_success "✅ Rollback complete - Jenkins restored to systemd"
    log_info "   URL: http://localhost:8080"
    
    return 0
}