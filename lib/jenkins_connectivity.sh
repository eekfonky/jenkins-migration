#!/usr/bin/env bash
# Jenkins connectivity and validation library

#######################################
# Comprehensive Jenkins connectivity test
# Tests all required API endpoints once
#######################################
validate_jenkins_connectivity() {
    local jenkins_url="$1"
    local jenkins_user="$2"
    local jenkins_token="$3"
    
    if [[ -z "${jenkins_url}" || -z "${jenkins_user}" || -z "${jenkins_token}" ]]; then
        log_error "Jenkins API credentials required for connectivity validation"
        return 1
    fi
    
    log_info "Validating Jenkins connectivity and permissions..."
    
    local base_url="${jenkins_url%/}"  # Remove trailing slash
    local temp_results
    temp_results=$(mktemp -d)
    
    # Test all required endpoints in parallel
    local endpoints=(
        "api/json:Basic API access"
        "pluginManager/api/json?depth=2:Plugin management"
        "configuration-as-code/export:JCasC export"
    )
    
    local pids=()
    local failed=false
    
    for endpoint in "${endpoints[@]}"; do
        local path="${endpoint%%:*}"
        local description="${endpoint##*:}"
        local url="${base_url}/${path}"
        
        (
            local method="GET"
            [[ "${path}" == *"export" ]] && method="POST"
            
            if curl -sf -X "${method}" -u "${jenkins_user}:${jenkins_token}" "${url}" >/dev/null 2>&1; then
                echo "SUCCESS:${description}" > "${temp_results}/${path//\//_}"
            else
                echo "FAILED:${description}" > "${temp_results}/${path//\//_}"
                echo "URL: ${url}" >> "${temp_results}/${path//\//_}"
            fi
        ) &
        pids+=($!)
    done
    
    # Wait for all tests
    for pid in "${pids[@]}"; do
        wait "${pid}"
    done
    
    # Check results
    for endpoint in "${endpoints[@]}"; do
        local path="${endpoint%%:*}"
        local result_file="${temp_results}/${path//\//_}"
        
        if [[ -f "${result_file}" ]]; then
            local result
            result=$(head -n1 "${result_file}")
            local status="${result%%:*}"
            local description="${result##*:}"
            
            if [[ "${status}" == "SUCCESS" ]]; then
                log_success "✓ ${description}"
            else
                log_error "✗ ${description}"
                tail -n +2 "${result_file}" | while read -r line; do
                    log_error "  ${line}"
                done
                failed=true
            fi
        else
            log_error "✗ Test failed to complete for ${endpoint}"
            failed=true
        fi
    done
    
    # Clean up
    rm -rf "${temp_results}"
    
    if [[ "${failed}" == "true" ]]; then
        log_error ""
        log_error "Jenkins connectivity validation failed. Common solutions:"
        log_error "1. Ensure Jenkins is running and accessible at ${base_url}"
        log_error "2. Verify user '${jenkins_user}' has admin permissions"
        log_error "3. Check API token is valid (generate new one if needed)"
        log_error "4. Ensure Configuration as Code plugin is installed"
        return 1
    fi
    
    log_success "✅ All Jenkins API endpoints accessible and ready"
    return 0
}

#######################################  
# Cache Jenkins API data globally
#######################################
cache_jenkins_api_data() {
    local jenkins_url="$1"
    local jenkins_user="$2" 
    local jenkins_token="$3"
    local cache_dir="$4"
    
    mkdir -p "${cache_dir}"
    
    # Cache plugin data if not already cached
    local plugin_cache="${cache_dir}/plugin_api_data.json"
    local plugin_timestamp="${cache_dir}/plugin_api_data.timestamp"
    
    if [[ ! -f "${plugin_cache}" ]] || ! is_cache_valid "${plugin_timestamp}" 3600; then
        log_info "Caching Jenkins plugin data..."
        local api_url="${jenkins_url%/}/pluginManager/api/json?depth=2"
        if curl -sf -u "${jenkins_user}:${jenkins_token}" "${api_url}" > "${plugin_cache}"; then
            date +%s > "${plugin_timestamp}"
            log_success "✓ Plugin data cached"
        else
            log_warning "Failed to cache plugin data"
            rm -f "${plugin_cache}" "${plugin_timestamp}"
        fi
    fi
    
    return 0
}

#######################################
# Check if cache file is valid
#######################################
is_cache_valid() {
    local timestamp_file="$1"
    local max_age_seconds="$2"
    
    [[ -f "${timestamp_file}" ]] || return 1
    
    local cache_timestamp
    cache_timestamp=$(cat "${timestamp_file}" 2>/dev/null) || return 1
    
    local current_time
    current_time=$(date +%s)
    
    local age=$((current_time - cache_timestamp))
    
    [[ ${age} -lt ${max_age_seconds} ]]
}