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
    
    # Verify Jenkins is accessible
    log_info "Testing Jenkins API connectivity to ${JENKINS_URL}/api/json..."
    if ! curl -sf -u "${JENKINS_USER}:${JENKINS_API_TOKEN}" "${JENKINS_URL}/api/json" >/dev/null 2>&1; then
        log_error "Jenkins API not accessible for schema-based generation"
        log_error "Curl failed connecting to ${JENKINS_URL}/api/json"
        log_error "Check if Jenkins is running and credentials are correct"
        return 1
    fi
    
    log_info "Generating JCasC configuration from live Jenkins schema..."
    
    # Get current Jenkins configuration via JCasC export
    local export_url="${JENKINS_URL}/configuration-as-code/export"
    local temp_export
    temp_export=$(mktemp)
    
    log_info "Attempting JCasC export from ${export_url}..."
    if curl -sf -X POST -u "${JENKINS_USER}:${JENKINS_API_TOKEN}" "${export_url}" > "${temp_export}"; then
        log_success "Retrieved current JCasC configuration from ${export_url}"
        
        # Enhance exported config with migration-specific settings
        enhance_exported_jcasc "${temp_export}" "${output_file}"
        local enhance_status=$?
        
        rm -f "${temp_export}"
        return ${enhance_status}
    else
        rm -f "${temp_export}"
        log_error "Could not export JCasC configuration from Jenkins"
        log_error "URL: ${export_url}"
        log_error ""
        log_error "SOLUTION: The Jenkins user '${JENKINS_USER}' needs admin permissions."
        log_error "Please ensure this user has 'Administer' permission in Jenkins."
        log_error ""
        log_error "To fix:"
        log_error "  1. Go to Jenkins > Manage Jenkins > Manage Users"
        log_error "  2. Edit user '${JENKINS_USER}'"  
        log_error "  3. Grant 'Administer' permission or make user admin"
        log_error "  4. Or use a different admin user in jenkins-migrate.conf"
        return 1
    fi
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
    python3 << EOF > "${output_file}"
import yaml
import sys
import os
from datetime import datetime

try:
    # Load exported configuration
    with open('${exported_file}', 'r') as f:
        config = yaml.safe_load(f) or {}
    
    # Ensure we have the main sections
    if 'jenkins' not in config:
        config['jenkins'] = {}
    if 'security' not in config:
        config['security'] = {}
    if 'unclassified' not in config:
        config['unclassified'] = {}
    if 'tool' not in config:
        config['tool'] = {}
    
    # Get migration variables from environment
    migration_timestamp = os.environ.get('MIGRATION_TIMESTAMP', datetime.now().isoformat())
    migration_id = os.environ.get('MIGRATION_ID', 'mig_' + datetime.now().strftime('%Y%m%d_%H%M%S'))
    
    # Preserve existing system message if it exists, otherwise don't add migration message
    # User doesn't want migration messages in the Jenkins UI
    if 'systemMessage' not in config['jenkins'] or not config['jenkins']['systemMessage']:
        # Only set if there was no existing system message
        pass  # Don't set any migration system message
    
    # Preserve agent port setting
    if 'slaveAgentPort' not in config['jenkins']:
        config['jenkins']['slaveAgentPort'] = '\${JENKINS_AGENT_PORT}'
    
    # Ensure CSRF protection is properly configured
    if 'security' not in config or not config['security']:
        config['security'] = {}
    
    # Use correct CSRF crumb issuer configuration
    if 'crumb' not in config['security']:
        config['security']['crumb'] = {}
    
    # Remove any invalid attributes we've seen
    if 'installState' in config['jenkins']:
        del config['jenkins']['installState']
    
    if 'crumbIssuer' in config['security']:
        # Replace crumbIssuer with correct crumb configuration 
        # The crumb section should be empty for default CSRF protection
        config['security']['crumb'] = {}
        del config['security']['crumbIssuer']
    
    # Ensure location configuration
    if 'location' not in config['unclassified']:
        config['unclassified']['location'] = {
            'url': '\${JENKINS_URL:-http://localhost:8080}',
            'adminAddress': 'jenkins@localhost'
        }
    
    # Remove deprecated AdminWhitelistRule configuration that causes stack traces
    if 'security' in config and config['security']:
        # Remove AdminWhitelistRule and its variants
        deprecated_keys = ['adminWhitelistRule', 'AdminWhitelistRule', 'slaveToMasterAccessControl']
        for key in deprecated_keys:
            if key in config['security']:
                del config['security'][key]
    
    # Add validation header with actual values
    header = f"""---
# Jenkins Configuration as Code (JCasC)
# Generated by Jenkins Migration Tool on {migration_timestamp}
# Migration ID: {migration_id}
#
# VALIDATION NOTES:
# - Generated from live Jenkins instance schema
# - Automatically excludes invalid attributes
# - Enhanced with migration-specific settings
# - Deprecated AdminWhitelistRule configurations removed

"""
    
    # Output enhanced configuration
    print(header, end='')
    yaml.dump(config, sys.stdout, default_flow_style=False, sort_keys=False)
    
except Exception as e:
    print(f"# ERROR: Failed to enhance JCasC configuration: {e}", file=sys.stderr)
    sys.exit(1)
EOF

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
