#!/usr/bin/env bash
# Jenkins service management module for systemd and Docker

#######################################
# Detect Jenkins home directory
#######################################
detect_jenkins_home() {
    local jenkins_home=""
    
    # Try to get from systemd service first
    if systemctl is-active --quiet jenkins 2>/dev/null; then
        local env_file
        env_file=$(systemctl show jenkins --property=EnvironmentFiles | cut -d= -f2)
        if [[ -n "${env_file}" && -f "${env_file}" ]]; then
            jenkins_home=$(grep "^JENKINS_HOME=" "${env_file}" 2>/dev/null | cut -d= -f2 | tr -d '"')
        fi
        
        # Try environment from service
        if [[ -z "${jenkins_home}" ]]; then
            jenkins_home=$(systemctl show jenkins --property=Environment | grep -o 'JENKINS_HOME=[^[:space:]]*' | cut -d= -f2 | tr -d '"')
        fi
    fi
    
    # Fallback to common locations
    if [[ -z "${jenkins_home}" ]]; then
        local common_paths=("/var/lib/jenkins" "/home/jenkins" "/opt/jenkins")
        for path in "${common_paths[@]}"; do
            if [[ -d "${path}" && -f "${path}/config.xml" ]]; then
                jenkins_home="${path}"
                break
            fi
        done
    fi
    
    # Final fallback
    jenkins_home="${jenkins_home:-/var/lib/jenkins}"
    
    # Resolve any symlinks
    if [[ -L "${jenkins_home}" ]]; then
        jenkins_home=$(readlink -f "${jenkins_home}")
    fi
    
    echo "${jenkins_home}"
}

#######################################
# Detect Jenkins user UID and GID
#######################################
detect_jenkins_user() {
    local jenkins_home="${1}"
    
    if [[ ! -d "${jenkins_home}" ]]; then
        log_error "Jenkins home directory not found: ${jenkins_home}"
        return 1
    fi
    
    # Get ownership from Jenkins home
    if ! stat -c "%u:%g" "${jenkins_home}" 2>/dev/null; then
        log_error "Cannot determine Jenkins user ownership for: ${jenkins_home}"
        return 1
    fi
}

#######################################
# Detect Jenkins URL
#######################################
detect_jenkins_url() {
    local jenkins_home="${1:-/var/lib/jenkins}"
    local jenkins_url="${JENKINS_URL:-}"
    
    # If already configured, use it
    if [[ -n "${jenkins_url}" ]]; then
        echo "${jenkins_url}"
        return 0
    fi
    
    # Try to detect from config.xml
    local config_file="${jenkins_home}/config.xml"
    if [[ -f "${config_file}" ]]; then
        local url_from_config
        url_from_config=$(grep -o '<jenkinsUrl>[^<]*</jenkinsUrl>' "${config_file}" 2>/dev/null | sed 's/<[^>]*>//g')
        if [[ -n "${url_from_config}" ]]; then
            echo "${url_from_config}"
            return 0
        fi
    fi
    
    # Try to detect from systemd service
    if systemctl is-active --quiet jenkins; then
        local jenkins_args
        jenkins_args=$(systemctl show jenkins --property=ExecStart | cut -d= -f2-)
        if [[ "${jenkins_args}" =~ --httpPort=([0-9]+) ]]; then
            echo "http://localhost:${BASH_REMATCH[1]}"
            return 0
        fi
    fi
    
    # Default fallback
    echo "http://localhost:8080"
}

#######################################
# Detect Jenkins ports (web:agent)
#######################################
detect_jenkins_ports() {
    local web_port="8080"
    local agent_port="50000"  # Always use standard Docker Jenkins agent port
    
    # Try to get web port from systemd service
    if systemctl is-active --quiet jenkins; then
        local jenkins_args
        jenkins_args=$(systemctl show jenkins --property=ExecStart | cut -d= -f2-)
        if [[ "${jenkins_args}" =~ --httpPort=([0-9]+) ]]; then
            web_port="${BASH_REMATCH[1]}"
        fi
    fi
    
    # Use configured values if available
    web_port="${JENKINS_PORT:-$web_port}"
    # Note: Always use 50000 for Docker agent port regardless of systemd config
    # Docker Jenkins images expect standard port 50000, agents will connect correctly
    
    echo "${web_port}:${agent_port}"
}

#######################################
# Detect SSL configuration from systemd Jenkins
#######################################
detect_jenkins_ssl_config() {
    local ssl_enabled="false"
    local ssl_port=""
    local ssl_keystore=""
    local ssl_keystore_password=""
    
    # Check for systemd Jenkins configuration (whether running or not)
    if systemctl list-unit-files jenkins.service 2>/dev/null | grep -q jenkins.service; then
        # Get Jenkins arguments from systemd
        local jenkins_args=""
        
        # Try from /etc/default/jenkins first
        if [[ -f "/etc/default/jenkins" ]]; then
            jenkins_args=$(grep "^JENKINS_ARGS=" /etc/default/jenkins | cut -d= -f2- | tr -d '"')
        fi
        
        # If not found, try from ExecStart
        if [[ -z "${jenkins_args}" ]]; then
            jenkins_args=$(systemctl show jenkins --property=ExecStart | cut -d= -f2-)
        fi
        
        # Parse SSL configuration
        if [[ "${jenkins_args}" =~ --httpsPort=([0-9]+) ]]; then
            ssl_enabled="true"
            ssl_port="${BASH_REMATCH[1]}"
        fi
        
        if [[ "${jenkins_args}" =~ --httpsKeyStore=([^[:space:]]+) ]]; then
            ssl_keystore="${BASH_REMATCH[1]}"
        fi
        
        if [[ "${jenkins_args}" =~ --httpsKeyStorePassword=([^[:space:]]+) ]]; then
            ssl_keystore_password="${BASH_REMATCH[1]}"
        fi
        
        # Check if HTTP is disabled
        local http_disabled="false"
        if [[ "${jenkins_args}" =~ --httpPort=-1 ]]; then
            http_disabled="true"
        fi
        
        # Output the configuration as environment variables format
        if [[ "${ssl_enabled}" == "true" ]]; then
            echo "JENKINS_SSL_ENABLED=true"
            echo "JENKINS_HTTPS_PORT=${ssl_port}"
            [[ -n "${ssl_keystore}" ]] && echo "JENKINS_SSL_KEYSTORE=${ssl_keystore}"
            [[ -n "${ssl_keystore_password}" ]] && echo "JENKINS_SSL_KEYSTORE_PASSWORD=${ssl_keystore_password}"
            [[ "${http_disabled}" == "true" ]] && echo "JENKINS_HTTP_DISABLED=true"
        else
            echo "JENKINS_SSL_ENABLED=false"
        fi
    else
        echo "JENKINS_SSL_ENABLED=false"
    fi
}

#######################################
# Detect service type (systemd, docker, or unknown)
#######################################
detect_service_type() {
    if systemctl is-active --quiet jenkins 2>/dev/null; then
        echo "systemd"
    elif docker ps --format "table {{.Names}}" 2>/dev/null | grep -q "^jenkins$"; then
        echo "docker"
    else
        echo "unknown"
    fi
}

#######################################
# Count existing plugins
#######################################
count_existing_plugins() {
    local jenkins_home="${1}"
    local plugins_dir="${jenkins_home}/plugins"
    
    if [[ ! -d "${plugins_dir}" ]]; then
        echo "0"
        return 0
    fi
    
    # Count .jpi and .hpi files
    local count=0
    count=$(find "${plugins_dir}" -name "*.jpi" -o -name "*.hpi" | wc -l)
    echo "${count}"
}

#######################################
# Backup Jenkins service configuration
#######################################
backup_service_config() {
    local backup_dir="${MIGRATION_STATE_DIR}/service_backup"
    
    mkdir -p "${backup_dir}"
    log_info "Creating service configuration backup..."
    
    # Backup systemd service file
    if [[ -f /usr/lib/systemd/system/jenkins.service ]]; then
        cp /usr/lib/systemd/system/jenkins.service "${backup_dir}/"
        log_debug "Backed up main systemd service file"
    fi
    
    if [[ -f /etc/systemd/system/jenkins.service ]]; then
        cp /etc/systemd/system/jenkins.service "${backup_dir}/jenkins.service.custom"
        log_debug "Backed up custom systemd service file"
    fi
    
    # Backup any environment files
    local env_files
    env_files=$(systemctl show jenkins --property=EnvironmentFiles 2>/dev/null | cut -d= -f2)
    if [[ -n "${env_files}" && "${env_files}" != "(none)" ]]; then
        for env_file in ${env_files}; do
            if [[ -f "${env_file}" ]]; then
                cp "${env_file}" "${backup_dir}/$(basename "${env_file}")"
                log_debug "Backed up environment file: ${env_file}"
            fi
        done
    fi
    
    # Backup service overrides (this is where the HTTPS config is)
    if [[ -d /etc/systemd/system/jenkins.service.d ]]; then
        cp -r /etc/systemd/system/jenkins.service.d "${backup_dir}/"
        log_debug "Backed up service overrides"
    fi
    
    # Backup current service status and configuration
    systemctl show jenkins > "${backup_dir}/jenkins.service.show" 2>/dev/null || true
    systemctl status jenkins > "${backup_dir}/jenkins.service.status" 2>/dev/null || true
    
    log_info "Service configuration backed up to: ${backup_dir}"
}

#######################################
# Restore Jenkins service configuration
#######################################
restore_service_config() {
    local backup_dir="${MIGRATION_STATE_DIR}/service_backup"
    
    if [[ ! -d "${backup_dir}" ]]; then
        log_warning "No service backup found to restore"
        return 0
    fi
    
    log_info "Restoring Jenkins service configuration..."
    
    # Restore systemd service file
    if [[ -f "${backup_dir}/jenkins.service" ]]; then
        cp "${backup_dir}/jenkins.service" /etc/systemd/system/
        log_debug "Restored systemd service file"
    fi
    
    # Restore environment files
    for env_backup in "${backup_dir}"/*.env "${backup_dir}"/jenkins; do
        [[ ! -f "${env_backup}" ]] && continue
        local filename
        filename=$(basename "${env_backup}")
        if [[ "${filename}" != "jenkins.service" ]]; then
            cp "${env_backup}" "/etc/default/${filename}"
            log_debug "Restored environment file: ${filename}"
        fi
    done
    
    # Restore service overrides
    if [[ -d "${backup_dir}/jenkins.service.d" ]]; then
        cp -r "${backup_dir}/jenkins.service.d" /etc/systemd/system/
        log_debug "Restored service overrides"
    fi
    
    # Reload systemd
    systemctl daemon-reload
    
    log_success "Service configuration restored"
}

#######################################
# Get Jenkins service status information
#######################################
get_service_status() {
    local service_info=""
    
    # Check systemd service
    if systemctl list-units --type=service | grep -q jenkins; then
        local status
        status=$(systemctl is-active jenkins 2>/dev/null || echo "inactive")
        service_info="Systemd: ${status}"
    fi
    
    # Check Docker container
    if docker ps --format "table {{.Names}}\t{{.Status}}" 2>/dev/null | grep -q "^jenkins"; then
        local docker_status
        docker_status=$(docker ps --format "table {{.Status}}" --filter name=jenkins | tail -n +2)
        service_info="${service_info:+$service_info, }Docker: $docker_status"
    fi
    
    echo "${service_info:-No Jenkins service found}"
}