#!/usr/bin/env bash
# shellcheck disable=SC2155
# Templating utilities for Jenkins Migration Tool using envsubst

#######################################
# Process template with envsubst
# Arguments:
#   $1 - Template file path
#   $2 - Output file path (optional, defaults to stdout)
#   $3 - Environment variables to export (optional)
#######################################
process_template() {
    local template_file="${1}"
    local output_file="${2:-}"
    local env_vars="${3:-}"
    
    if [[ ! -f "${template_file}" ]]; then
        log_error "Template file not found: ${template_file}"
        return 1
    fi
    
    log_debug "Processing template: ${template_file}"
    
    # Export additional environment variables if provided
    if [[ -n "${env_vars}" ]]; then
        log_debug "Exporting variables: ${env_vars}"
        # Safely export each variable
        while IFS='=' read -r key value; do
            if [[ -n "${key}" ]]; then
                export "${key}=${value}"
            fi
        done <<< "${env_vars}"
    fi
    
    # Process template with envsubst
    if [[ -n "${output_file}" ]]; then
        envsubst < "${template_file}" > "${output_file}"
        log_debug "Template processed to: ${output_file}"
    else
        envsubst < "${template_file}"
    fi
    
    return 0
}

#######################################
# Generate environment file for Docker Compose
#######################################
generate_env_file() {
    local output_file="${1:-}"
    
    log_debug "Generating .env file with discovered variables"
    
    local env_content
    # Generate environment variables file
    local template_file="${SCRIPT_DIR}/templates/docker.env.template"
    if [[ -f "${template_file}" ]]; then
        env_content=$(process_template "${template_file}")
    else
        log_error "Environment template not found: ${template_file}"
        return 1
    fi
    
    if [[ -n "${output_file}" ]]; then
        echo "${env_content}" > "${output_file}"
        log_debug ".env file generated: ${output_file}"
    else
        echo "${env_content}"
    fi
}

#######################################
# Calculate memory limit based on system resources
#######################################
calculate_memory_limit() {
    local total_mem_kb
    total_mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local total_mem_gb=$((total_mem_kb / 1024 / 1024))
    
    if [[ ${total_mem_gb} -ge 16 ]]; then
        echo "4G"
    elif [[ ${total_mem_gb} -ge 8 ]]; then
        echo "3G"
    elif [[ ${total_mem_gb} -ge 4 ]]; then
        echo "2G"
    else
        echo "1G"
    fi
}

#######################################
# Calculate memory reservation based on system resources
#######################################
calculate_memory_reservation() {
    local total_mem_kb
    total_mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local total_mem_gb=$((total_mem_kb / 1024 / 1024))
    
    if [[ ${total_mem_gb} -ge 16 ]]; then
        echo "2G"
    elif [[ ${total_mem_gb} -ge 8 ]]; then
        echo "1G"
    elif [[ ${total_mem_gb} -ge 4 ]]; then
        echo "512M"
    else
        echo "256M"
    fi
}

#######################################
# Calculate CPU limit based on system resources
#######################################
calculate_cpu_limit() {
    local cpu_cores
    cpu_cores=$(nproc)
    
    if [[ ${cpu_cores} -ge 8 ]]; then
        echo "2.0"
    elif [[ ${cpu_cores} -ge 4 ]]; then
        echo "1.5"
    else
        echo "1.0"
    fi
}

#######################################
# Calculate CPU reservation based on system resources
#######################################
calculate_cpu_reservation() {
    local cpu_cores
    cpu_cores=$(nproc)
    
    if [[ ${cpu_cores} -ge 8 ]]; then
        echo "0.5"
    elif [[ ${cpu_cores} -ge 4 ]]; then
        echo "0.25"
    else
        echo "0.1"
    fi
}

#######################################
# Validate template file syntax
#######################################
validate_template() {
    local template_file="${1}"
    
    if [[ ! -f "${template_file}" ]]; then
        log_error "Template file not found: ${template_file}"
        return 1
    fi
    
    # Check for common envsubst issues
    local issues_found=false
    
    # Check for unescaped dollar signs that might not be variables
    if grep -q '\$[^{A-Z_]' "${template_file}"; then
        log_warning "Template may contain unescaped dollar signs: ${template_file}"
        issues_found=true
    fi
    
    # Check for unclosed variable references
    if grep -q "\${[^}]*\$" "${template_file}"; then
        log_warning "Template may contain unclosed variable references: ${template_file}"
        issues_found=true
    fi
    
    if [[ "${issues_found}" == "false" ]]; then
        log_debug "✓ Template validation passed: ${template_file}"
    fi
    
    return 0
}

#######################################
# Export all dynamic variables for template processing
#######################################
export_template_variables() {
    # Core Jenkins variables
    export JENKINS_UID
    export JENKINS_GID
    export JENKINS_HOME
    export JENKINS_PORT
    export JENKINS_AGENT_PORT
    export JENKINS_URL
    
    # Migration metadata
    export MIGRATION_ID
    local migration_timestamp
    migration_timestamp="$(date -Iseconds)"
    export MIGRATION_TIMESTAMP="${migration_timestamp}"
    
    # Docker configuration
    export DOCKER_DIR
    export DOCKER_NETWORK="${DOCKER_NETWORK:-jenkins-network}"
    export JENKINS_CONTAINER_NAME="${JENKINS_CONTAINER_NAME:-jenkins}"
    
    # Resource limits
    export JENKINS_MEMORY_LIMIT="${JENKINS_MEMORY_LIMIT:-$(calculate_memory_limit)}"
    export JENKINS_MEMORY_RESERVATION="${JENKINS_MEMORY_RESERVATION:-$(calculate_memory_reservation)}"
    export JENKINS_CPU_LIMIT="${JENKINS_CPU_LIMIT:-$(calculate_cpu_limit)}"
    export JENKINS_CPU_RESERVATION="${JENKINS_CPU_RESERVATION:-$(calculate_cpu_reservation)}"
    
    # Watchtower configuration
    export WATCHTOWER_SCHEDULE="${WATCHTOWER_SCHEDULE:-0 0 4 * * *}"
    
    # JCasC configuration
    export CASC_JENKINS_CONFIG="/usr/share/jenkins/ref/jenkins.yaml"
    export JCASC_CONFIG_FILE="${JCASC_CONFIG_FILE:-jenkins.yaml}"
    
    log_debug "Template variables exported"
}

#######################################
# Process all templates in a directory
#######################################
process_template_directory() {
    local template_dir="${1}"
    local output_dir="${2}"
    
    if [[ ! -d "${template_dir}" ]]; then
        log_error "Template directory not found: ${template_dir}"
        return 1
    fi
    
    mkdir -p "${output_dir}"
    
    # Export variables for template processing
    export_template_variables
    
    local processed_count=0
    
    for template_file in "${template_dir}"/*.template; do
        [[ ! -f "${template_file}" ]] && continue
        
        local basename
        basename=$(basename "${template_file}" .template)
        local output_file="${output_dir}/${basename}"
        
        log_debug "Processing template: ${basename}"
        
        if process_template "${template_file}" "${output_file}"; then
            processed_count=$((processed_count + 1))
        else
            log_error "Failed to process template: ${template_file}"
            return 1
        fi
    done
    
    log_info "Processed ${processed_count} template(s)"
    return 0
}