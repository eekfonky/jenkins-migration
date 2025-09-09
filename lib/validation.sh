#!/usr/bin/env bash
# shellcheck disable=SC2034
# Validation utilities for Jenkins Migration Tool
#######################################
# Validate Docker group membership for key users
#######################################
validate_docker_group_membership() {
    log_info "🔐 Checking Docker group membership..."
    
    local users_added=false
    local logout_needed=false
    
    # Check jenkins user
    if id jenkins >/dev/null 2>&1; then
        if groups jenkins | grep -q docker; then
            log_success "✓ Jenkins user is in docker group"
        else
            log_info "Adding jenkins user to docker group..."
            if usermod -aG docker jenkins; then
                log_success "✓ Added jenkins user to docker group"
                users_added=true
            else
                log_error "Failed to add jenkins user to docker group"
                return 1
            fi
        fi
    fi
    
    # Check ubuntu user (common on Ubuntu systems)
    if id ubuntu >/dev/null 2>&1; then
        if groups ubuntu | grep -q docker; then
            log_success "✓ Ubuntu user is in docker group"
        else
            log_info "Adding ubuntu user to docker group..."
            if usermod -aG docker ubuntu; then
                log_success "✓ Added ubuntu user to docker group"
                users_added=true
                logout_needed=true
            else
                log_error "Failed to add ubuntu user to docker group"
                return 1
            fi
        fi
    fi
    
    # Check current user if different from ubuntu/jenkins
    local current_user="${SUDO_USER:-${USER}}"
    if [[ -n "${current_user}" && "${current_user}" != "ubuntu" && "${current_user}" != "jenkins" && "${current_user}" != "root" ]]; then
        if id "${current_user}" >/dev/null 2>&1; then
            if groups "${current_user}" | grep -q docker; then
                log_success "✓ User ${current_user} is in docker group"
            else
                log_info "Adding ${current_user} user to docker group..."
                if usermod -aG docker "${current_user}"; then
                    log_success "✓ Added ${current_user} user to docker group"
                    logout_needed=true
                else
                    log_error "Failed to add ${current_user} user to docker group"
                    return 1
                fi
            fi
        fi
    fi
    
    # Show logout notification if needed
    if [[ "${logout_needed}" == "true" ]]; then
        log_warning "⚠️  IMPORTANT: Users added to docker group must logout and login for changes to take effect"
        log_info "   After migration completes, run: 'docker ps' to test docker access"
        log_info "   If you get permission errors, logout and login again"
    fi
    
    return 0
}
#######################################
# Validate Jenkins ports are available or used by Jenkins
#######################################
validate_jenkins_ports() {
    local jenkins_port="${1}"
    local agent_port="${2}"
    
    log_info "🔌 Validating Jenkins port availability..."
    
    # Get process information for both ports
    local jenkins_port_info agent_port_info
    jenkins_port_info=$(ss -tulnp 2>/dev/null | grep ":${jenkins_port} " | head -1)
    agent_port_info=$(ss -tulnp 2>/dev/null | grep ":${agent_port} " | head -1)
    
    # Extract PIDs if ports are in use
    local jenkins_port_pid agent_port_pid
    if [[ -n "${jenkins_port_info}" ]]; then
        jenkins_port_pid=$(echo "${jenkins_port_info}" | grep -o 'pid=[0-9]*' | cut -d'=' -f2)
    fi
    if [[ -n "$agent_port_info" ]]; then
        agent_port_pid=$(echo "$agent_port_info" | grep -o 'pid=[0-9]*' | cut -d'=' -f2)
    fi
    
    # Check main Jenkins port
    if [[ -n "${jenkins_port_info}" ]]; then
        if echo "$jenkins_port_info" | grep -qi jenkins || echo "$jenkins_port_info" | grep -q java; then
            log_success "✓ Port ${jenkins_port} is used by Jenkins (PID: ${jenkins_port_pid})"
        else
            log_warning "⚠️  Port ${jenkins_port} is in use by non-Jenkins process:"
            echo "${jenkins_port_info}" | awk '{print "   " ${0}}'
            log_info "Migration will stop the current service and reuse this port"
        fi
    else
        log_success "✓ Port ${jenkins_port} is available"
    fi
    
    # Check Jenkins agent port (simplified for Docker)
    if [[ "${agent_port}" == "50000" ]]; then
        # Using standard Docker Jenkins port - just check if it's available
        if [[ -n "$agent_port_info" ]]; then
            log_info "Port ${agent_port} is in use - will be available after stopping systemd Jenkins"
        else
            log_success "✓ Port ${agent_port} is available for Docker Jenkins"
        fi
        log_info "📋 Using standard Docker Jenkins agent port (${agent_port}) for container"
    else
        # Custom port detection for validation only
        if [[ -n "$agent_port_info" ]]; then
            # Check if it's the same process as the main Jenkins port
            if [[ -n "${jenkins_port_pid}" && "${jenkins_port_pid}" == "${agent_port_pid}" ]]; then
                log_info "📋 Systemd Jenkins uses custom agent port ${agent_port} (PID: ${agent_port_pid})"
                log_info "   Docker migration will use standard port 50000 instead"
            else
                log_warning "⚠️  Port ${agent_port} is used by different process than Jenkins"
                log_info "   Docker migration will use standard port 50000 instead"
            fi
        else
            log_info "📋 Systemd Jenkins configured for port ${agent_port} (not in use)"
            log_info "   Docker migration will use standard port 50000 instead"
        fi
    fi
    
    return 0
}

#######################################
# Validate Docker socket accessibility
#######################################
validate_docker_socket_access() {
    log_info "🐳 Testing Docker socket access..."
    
    # Check if Docker socket exists
    if [[ ! -S /var/run/docker.sock ]]; then
        log_error "Docker socket not found at /var/run/docker.sock"
        return 1
    fi
    
    # Check socket permissions
    local socket_perms
    socket_perms=$(ls -l /var/run/docker.sock)
    log_debug "Docker socket permissions: ${socket_perms}"
    
    # Test Docker access with current effective permissions
    if docker info >/dev/null 2>&1; then
        log_success "✓ Docker socket access verified"
    else
        log_error "Cannot access Docker socket - this may indicate:"
        log_info "  1. Docker daemon is not running"
        log_info "  2. Current user lacks docker group permissions"
        log_info "  3. Recent group membership changes require logout/login"
        
        # Try to provide more specific error info
        if docker version --format '{{.Client.Version}}' >/dev/null 2>&1; then
            log_info "  → Docker client works, but daemon is inaccessible"
        else
            log_info "  → Docker client cannot connect at all"
        fi
        
        return 1
    fi
    
    # Test Docker operations
    if docker ps >/dev/null 2>&1; then
        log_success "✓ Docker operations verified"
    else
        log_error "Cannot list Docker containers - permission issue"
        return 1
    fi
    
    return 0
}

#######################################
# Validate AppArmor Docker profile compatibility  
#######################################
validate_apparmor_docker() {
    log_info "🛡️  Checking AppArmor Docker compatibility..."
    
    # Check if AppArmor is loaded
    if ! command -v aa-status >/dev/null 2>&1; then
        log_debug "AppArmor not installed - skipping checks"
        return 0
    fi
    
    if ! aa-status >/dev/null 2>&1; then
        log_debug "AppArmor not active - skipping checks"
        return 0
    fi
    
    # Check for Docker-related profiles
    local docker_profiles
    docker_profiles=$(aa-status 2>/dev/null | grep -i docker || true)
    
    if [[ -n "${docker_profiles}" ]]; then
        log_info "AppArmor Docker profiles detected:"
        echo "${docker_profiles//^/   }"
        
        # Check if Docker profile might block volume mounts
        if aa-status 2>/dev/null | grep -q "docker-default"; then
            log_success "✓ docker-default profile detected - standard Docker security"
            log_info "   This profile allows normal volume mounts and container operations"
        else
            # Only warn about custom/restrictive profiles
            log_warning "⚠️  Custom Docker AppArmor profiles detected - may restrict operations"
            log_info "   If migration fails with permission errors, consider reviewing profiles"
        fi
    else
        log_success "✓ No AppArmor Docker profiles found"
    fi
    
    # AppArmor compatibility will be tested when Jenkins container starts
    log_info "   AppArmor compatibility will be verified during container startup"
    
    return 0
}

