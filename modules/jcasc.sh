#!/usr/bin/env bash
# Jenkins Configuration as Code (JCasC) module

#######################################
# Generate JCasC configuration file using live schema
#######################################
generate_jcasc_config() {
    local output_file="${1}"
    
    log_info "Generating JCasC configuration..."
    
    # CONFIGURATION ISOLATION: Only create JCasC configs in Docker output location
    # Never modify systemd Jenkins environment - strict "lift & shift" principle
    if [[ -z "${output_file}" ]]; then
        log_error "Output file required for configuration isolation"
        return 1
    fi
    
    local jenkins_casc_dir
    jenkins_casc_dir="$(dirname "${output_file}")"
    mkdir -p "${jenkins_casc_dir}"
    
    # Generate JCasC from live schema - fail fast if not available
    if ! generate_jcasc_from_schema "${output_file}"; then
        log_error "Schema-based generation failed - migration requires API access"
        log_error "Please configure JENKINS_USER and JENKINS_API_TOKEN in jenkins-migrate.conf"
        log_error "Migration cannot proceed without valid JCasC configuration"
        return 1
    fi

    # Set proper ownership for Docker environment
    if [[ -n "${SUDO_USER:-}" ]]; then
        chown "${SUDO_USER}:${SUDO_USER}" "${output_file}" 2>/dev/null || true
    fi
    
    log_success "Generated JCasC configuration: ${output_file} (Docker only - systemd environment untouched)"
}

#######################################
# Generate JCasC from live Jenkins schema
#######################################
generate_jcasc_from_schema() {
    local output_file="$1"
    
    
    # Check if we can access Jenkins API for schema
    if [[ -z "${JENKINS_URL:-}" || -z "${JENKINS_USER:-}" || -z "${JENKINS_API_TOKEN:-}" ]]; then
        log_debug "No Jenkins API credentials available for schema-based generation"
        return 1
    fi
    
    # Use centralized connectivity validation (skip if already validated)
    if [[ ! -f "${MIGRATION_STATE_DIR}/jenkins_validated" ]]; then
        if ! validate_jenkins_connectivity "${JENKINS_URL}" "${JENKINS_USER}" "${JENKINS_API_TOKEN}"; then
            return 1
        fi
        touch "${MIGRATION_STATE_DIR}/jenkins_validated"
    fi
    
    log_info "Generating JCasC configuration from live Jenkins schema..."
    
    # Check for cached JCasC export first
    local cache_dir="${MIGRATION_STATE_DIR}/cache"
    local cache_file="${cache_dir}/jcasc_export.yaml"
    local cache_timestamp="${cache_dir}/jcasc_export.timestamp"
    local cache_valid=false
    
    # Create cache directory if it doesn't exist
    mkdir -p "${cache_dir}"
    
    # Check if cache is valid (less than 1 hour old)
    if [[ -f "${cache_file}" && -f "${cache_timestamp}" ]]; then
        local cache_age
        cache_age=$(( $(date +%s) - $(cat "${cache_timestamp}") ))
        if [[ ${cache_age} -lt 3600 ]]; then
            log_info "Using cached JCasC export (${cache_age}s old)"
            cache_valid=true
        fi
    fi
    
    local temp_export
    if [[ "${cache_valid}" == "true" ]]; then
        temp_export="${cache_file}"
    else
        # Get current Jenkins configuration via JCasC export
        local export_url="${JENKINS_URL}/configuration-as-code/export"
        temp_export=$(mktemp)
        
        log_info "Attempting JCasC export from ${export_url}..."
        if curl -sf -X POST -u "${JENKINS_USER}:${JENKINS_API_TOKEN}" "${export_url}" > "${temp_export}"; then
            log_success "Retrieved current JCasC configuration from ${export_url}"
            
            # Cache the successful export
            cp "${temp_export}" "${cache_file}"
            date +%s > "${cache_timestamp}"
        else
            rm -f "${temp_export}"
            log_error "Could not export JCasC configuration from Jenkins"
            log_error "URL: ${export_url}"
            log_error ""
            log_error "SOLUTION: The Jenkins user '${JENKINS_USER}' needs admin permissions."
            log_error "Please ensure this user has 'Administer' permission in Jenkins."
            return 1
        fi
    fi
    
    # Enhance exported config with migration-specific settings
    enhance_exported_jcasc "${temp_export}" "${output_file}"
    local enhance_status=$?
    
    # Clean up temp file if it's not the cache
    if [[ "${temp_export}" != "${cache_file}" ]]; then
        rm -f "${temp_export}"
    fi
    
    return ${enhance_status}
}

#######################################
# Enhance exported JCasC with migration settings
#######################################
enhance_exported_jcasc() {
    local exported_file="$1"
    local output_file="$2"
    
    if ! command -v python3 >/dev/null 2>&1; then
        log_debug "Python3 not available for JCasC enhancement"
        return 1
    fi
    
    # Ensure migration variables are available
    export MIGRATION_TIMESTAMP="${MIGRATION_TIMESTAMP:-$(date -Iseconds)}"
    export MIGRATION_ID="${MIGRATION_ID:-mig_$(date +%Y%m%d_%H%M%S)}"
    
    # Use Python to merge exported config with migration settings
    local script_path
    script_path=$(dirname "${BASH_SOURCE[0]}")
    python3 "${script_path}/enhance_jcasc.py" "${exported_file}" > "${output_file}"
    local python_exit_code=$?
    if [[ ${python_exit_code} -eq 0 ]]; then
        log_success "Enhanced exported JCasC configuration with migration settings"
        return 0
    else
        log_error "Failed to enhance JCasC configuration"
        return 1
    fi
}
#######################################
# Extract plugins from existing Jenkins installation via API
#######################################
extract_plugins_to_file() {
    local output_file="${1}"
    local jenkins_home="${2}"
    
    # Input validation
    if [[ -z "${output_file}" ]]; then
        log_error "Output file parameter required"
        return 1
    fi
    
    if [[ -z "${jenkins_home}" ]]; then
        log_error "Jenkins home parameter required"  
        return 1
    fi
    
    log_info "Extracting plugins to plugins.txt..."
    
    # Try API-first approach if credentials are available
    if [[ -n "${JENKINS_URL:-}" && -n "${JENKINS_USER:-}" && -n "${JENKINS_API_TOKEN:-}" ]]; then
        log_info "Using API-based extraction (credentials detected)"
        extract_plugins_via_api "${output_file}" || return 1
    else
        log_info "Using filesystem-based extraction (no API credentials)"
        extract_plugins_via_filesystem "${output_file}" "${jenkins_home}" || return 1
    fi
}

#######################################
# Extract plugins via Jenkins REST API
#######################################
extract_plugins_via_api() {
    local output_file="${1}"
    
    log_info "🌐 Extracting plugins via Jenkins API..."
    
    local api_url="${JENKINS_URL}/pluginManager/api/json?depth=1"
    local temp_file
    temp_file=$(mktemp)
    
    # Make API call with authentication
    if curl -sf -u "${JENKINS_USER}:${JENKINS_API_TOKEN}" "${api_url}" > "${temp_file}"; then
        # Generate plugins header
        {
            echo "# Jenkins plugins extracted from systemd installation"
            echo "# Edit versions for controlled updates"
            echo "# Format: plugin-name:version"
            echo "# Use 'latest' for most recent version"
            echo
        } >> "${output_file}"
        
        # Parse JSON and extract plugin:version pairs
        local plugin_count=0
        while read -r line; do
            if [[ -n "${line}" ]]; then
                echo "${line}" >> "${output_file}"
                plugin_count=$((plugin_count + 1))
            fi
        done < <(jq -r '.plugins[] | select(.enabled == true) | "\(.shortName):\(.version)"' "${temp_file}" 2>/dev/null)
        
        rm -f "${temp_file}"
        
        if [[ ${plugin_count} -gt 0 ]]; then
            log_success "✅ Extracted ${plugin_count} plugins via API"
            return 0
        else
            log_error "No enabled plugins found via API"
            return 1
        fi
    else
        rm -f "${temp_file}"
        log_error "Failed to connect to Jenkins API"
        return 1
    fi
}

#######################################
# Extract plugins via filesystem (fallback)
#######################################
extract_plugins_via_filesystem() {
    local output_file="${1}"
    local jenkins_home="${2}"
    local plugins_dir="${jenkins_home}/plugins"
    
    log_info "📁 Extracting plugins via filesystem scan..."
    
    if [[ ! -d "${plugins_dir}" ]]; then
        log_error "No plugins directory found: ${plugins_dir}"
        return 1
    fi
    
    # Generate plugins header
    {
        echo "# Jenkins plugins extracted from systemd installation"
        echo "# Edit versions for controlled updates"
        echo "# Format: plugin-name:version"
        echo "# Use 'latest' for most recent version"
        echo
    } > "${output_file}"

    # Extract installed plugins with versions
    local plugin_count=0
    
    # Look for .jpi and .hpi files
    for plugin_file in "${plugins_dir}"/*.{jpi,hpi}; do
        [[ ! -f "${plugin_file}" ]] && continue
        
        local plugin_name version
        plugin_name=$(basename "${plugin_file}" | sed 's/\.[jh]pi$//')
        
        # Try to extract version from MANIFEST.MF
        version="latest"
        if command -v unzip >/dev/null 2>&1 && command -v jar >/dev/null 2>&1; then
            local manifest_version
            manifest_version=$(unzip -p "${plugin_file}" META-INF/MANIFEST.MF 2>/dev/null | grep "^Plugin-Version:" | cut -d: -f2 | tr -d ' \r') || true
            [[ -n "${manifest_version}" ]] && version="${manifest_version}"
        fi
        
        echo "${plugin_name}:${version}" >> "${output_file}"
        plugin_count=$((plugin_count + 1))
    done
    
    # Sort the plugins file
    {
        head -n 4 "${output_file}"  # Keep header
        tail -n +5 "${output_file}" | sort
    } > "${output_file}.tmp" && mv "${output_file}.tmp" "${output_file}"
    
    if [[ ${plugin_count} -gt 0 ]]; then
        log_success "Extracted ${plugin_count} plugins to ${output_file}"
    else
        log_error "No plugins found in ${plugins_dir}"
        return 1
    fi
    
    return 0
}
#######################################
# Validate JCasC configuration
#######################################
validate_jcasc_config() {
    local config_file="$1"
    
    if [[ ! -f "${config_file}" ]]; then
        log_error "JCasC configuration file not found: ${config_file}"
        return 1
    fi
    
    log_info "Validating JCasC configuration..."
    
    # Basic YAML syntax validation
    if command -v python3 >/dev/null 2>&1; then
        if ! python3 -c "import yaml; yaml.safe_load(open('${config_file}', 'r'))" 2>/dev/null; then
            log_error "JCasC configuration has invalid YAML syntax"
            return 1
        fi
        log_debug "✓ YAML syntax is valid"
    else
        log_debug "Python3 not available, skipping YAML syntax validation"
    fi
    
    # Check for required sections
    local required_sections=("jenkins:" "security:" "unclassified:")
    local missing_sections=()
    
    for section in "${required_sections[@]}"; do
        if ! grep -q "^${section}" "${config_file}"; then
            missing_sections+=("${section}")
        fi
    done
    
    if [[ ${#missing_sections[@]} -gt 0 ]]; then
        log_warning "JCasC configuration missing sections: ${missing_sections[*]}"
    else
        log_debug "✓ All required sections present"
    fi
    
    # Check for common configuration issues
    local warnings=0
    
    # Check for potentially problematic configurations
    if grep -q "allowAnonymousRead: true" "${config_file}"; then
        log_warning "Anonymous read access is enabled"
        warnings=$((warnings + 1))
    fi
    
    if grep -q "useScriptSecurity: false" "${config_file}"; then
        log_warning "Script security is disabled (potential security risk)"
        warnings=$((warnings + 1))
    fi
    
    if [[ ${warnings} -eq 0 ]]; then
        log_success "JCasC configuration validation passed"
    else
        log_info "JCasC configuration validation completed with ${warnings} warnings"
    fi
    
    return 0
}
