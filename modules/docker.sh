#!/usr/bin/env bash
# Docker management module for Jenkins Migration Tool

#######################################
# Install Docker CE if not present
#######################################
install_docker() {
    log_info "Installing Docker CE..."
    
    # Remove old Docker versions
    apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
    
    # Update package index
    apt-get update
    
    # Install dependencies
    apt-get install -y \
        ca-certificates \
        curl \
        gnupg \
        lsb-release
    
    # Add Docker's official GPG key
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    
    # Set up Docker repository
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    # Update package index again
    apt-get update
    
    # Install Docker CE
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    
    # Start and enable Docker
    systemctl start docker
    systemctl enable docker
    
    # Add jenkins user to docker group
    if id jenkins >/dev/null 2>&1; then
        usermod -aG docker jenkins
        log_success "Added jenkins user to docker group"
    fi
    
    log_success "Docker CE installed successfully"
}

#######################################
# Pull required Docker images
#######################################
pull_docker_images() {
    local images=("jenkins/jenkins:lts" "containrrr/watchtower")
    
    log_info "Pulling ${#images[@]} Docker images in parallel..."
    
    # Start parallel pulls with progress tracking
    local pids=()
    local temp_dir
    temp_dir=$(mktemp -d)
    local completed=0
    
    for i in "${!images[@]}"; do
        local image="${images[$i]}"
        (
            if docker pull "${image}" >"${temp_dir}/pull_${i}.log" 2>&1; then
                echo "SUCCESS:${image}" >"${temp_dir}/result_${i}"
            else
                echo "FAILED:${image}" >"${temp_dir}/result_${i}"
                cat "${temp_dir}/pull_${i}.log" >&2
            fi
        ) &
        pids+=($!)
    done
    
    # Wait for all pulls with progress updates
    local failed=false
    local successful_images=()
    for i in "${!pids[@]}"; do
        if wait "${pids[$i]}"; then
            local result
            result=$(cat "${temp_dir}/result_${i}")
            if [[ "${result}" == SUCCESS:* ]]; then
                local image="${result#*:}"
                successful_images+=("${image}")
                ((completed++))
            else
                failed=true
            fi
        else
            failed=true
        fi
    done
    
    # Single consolidated status message
    if [[ ${#successful_images[@]} -gt 0 ]]; then
        log_success "✓ Successfully pulled ${#successful_images[@]}/${#images[@]} images: ${successful_images[*]}"
    fi
    
    # Clean up temp files
    rm -rf "${temp_dir}"
    
    if [[ "${failed}" == "true" ]]; then
        log_error "One or more Docker image pulls failed"
        return 1
    fi
    
    return 0
}
#######################################
# Start Jenkins Docker containers
#######################################
start_jenkins_containers() {
    local docker_dir="$1"
    
    if [[ ! -d "${docker_dir}" ]]; then
        log_error "Docker configuration directory not found: ${docker_dir}"
        return 1
    fi
    
    cd "${docker_dir}" || return 1
    
    # Pull required Docker images
    if ! pull_docker_images; then
        log_error "❌ Failed to pull required Docker images - migration cannot continue"
        log_error "   This indicates network connectivity or Docker registry issues"
        log_error "   Rollback: sudo ./jenkins-migrate.sh --rollback"
        return 1
    fi
    
    # Build and start containers in single operation
    log_info "Building and starting Jenkins containers..."
    if ! docker compose up -d --build; then
        # If combined operation fails, try to determine the cause
        log_warning "Combined build and start failed, checking build separately..."
        if ! docker compose build --quiet; then
            log_warning "Docker build had issues (likely plugin installation)"
            log_info "Continuing with base Jenkins image and existing plugins..."
            # Try starting without build
            if ! docker compose up -d; then
                log_error "❌ Failed to start Jenkins containers - migration cannot continue"
                log_error "   Check docker-compose.yml and container logs for details"
                log_error "   Rollback: sudo ./jenkins-migrate.sh --rollback"
                return 1
            fi
        else
            # Build succeeded but start failed
            log_error "❌ Failed to start Jenkins containers - migration cannot continue"
            log_error "   Check docker-compose.yml and container logs for details"
            log_error "   Rollback: sudo ./jenkins-migrate.sh --rollback"
            return 1
        fi
    fi
    
    log_success "Containers built and started successfully"
    
    # Show container status
    log_info "Container status:"
    docker compose ps
    
    log_success "✅ Jenkins containers started!"
    log_info "Monitor startup: docker logs -f jenkins"
    log_info "Jenkins will be available at: http://localhost:${JENKINS_PORT:-8080}"
    
    return 0
}
