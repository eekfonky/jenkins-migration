#!/usr/bin/env bash
# Plugin Analysis Module for Jenkins Migration Tool

# Add a confirmation prompter since one doesn't exist in the library
confirm() {
    # Default to no if INTERACTIVE is false
    if [[ "${INTERACTIVE:-true}" == "false" ]]; then
        return 0 # Automatically confirm
    fi

    local prompt="${1:-Are you sure?}"
    while true; do
        read -r -p "${prompt} [y/N] " response
        case "${response}" in
            [yY][eE][sS]|[yY])
                return 0
                ;;
            [nN][oO]|[nN]|"")
                return 1
                ;;
            *)
                echo "Please answer yes or no."
                ;;
        esac
    done
}


run_plugin_analysis() {
    log_info "🔬 Starting Jenkins plugin usage analysis..."

    # 1. Check for Python 3
    if ! command -v python3 &>/dev/null; then
        log_warning "Python 3 is not installed. Skipping plugin analysis."
        return 0
    fi

    # 2. Define file paths
    local original_plugins_file="${DOCKER_DIR}/plugins.txt"
    local cleaned_plugins_file="${MIGRATION_STATE_DIR}/plugins.cleaned.txt"
    local report_file="${MIGRATION_STATE_DIR}/unused_plugins_report.txt"

    if [[ ! -f "${original_plugins_file}" ]]; then
        log_warning "Cannot find plugins.txt. Skipping analysis."
        return 0
    fi

    # 3. Build arguments for the Python script
    local python_args=(
        "--jenkins-home" "${JENKINS_HOME}"
        "--plugins-file" "${original_plugins_file}"
        "--output-file" "${cleaned_plugins_file}"
        "--report-file" "${report_file}"
    )

    if [[ -n "${JENKINS_URL:-}" && -n "${JENKINS_USER:-}" && -n "${JENKINS_API_TOKEN:-}" ]]; then
        python_args+=(
            "--jenkins-url" "${JENKINS_URL}"
            "--jenkins-user" "${JENKINS_USER}"
            "--jenkins-token" "${JENKINS_API_TOKEN}"
        )
    else
        log_warning "Jenkins API credentials not found. Plugin dependency analysis will be less accurate."
    fi

    # 4. Validate connectivity once before running analysis
    if [[ -n "${JENKINS_URL:-}" && -n "${JENKINS_USER:-}" && -n "${JENKINS_API_TOKEN:-}" ]]; then
        if [[ ! -f "${MIGRATION_STATE_DIR}/jenkins_validated" ]]; then
            if ! validate_jenkins_connectivity "${JENKINS_URL}" "${JENKINS_USER}" "${JENKINS_API_TOKEN}"; then
                log_error "Jenkins connectivity validation failed. Plugin analysis will be less accurate."
            else
                touch "${MIGRATION_STATE_DIR}/jenkins_validated"
                # Pre-cache API data for faster analysis
                cache_jenkins_api_data "${JENKINS_URL}" "${JENKINS_USER}" "${JENKINS_API_TOKEN}" "${MIGRATION_STATE_DIR}/cache"
            fi
        fi
    fi

    # 5. Run the analysis script
    log_info "Running Python script to analyze plugin usage..."
    if ! python3 "${SCRIPT_DIR}/modules/analyze_plugins.py" "${python_args[@]}"; then
        log_error "Plugin analysis script failed. Aborting plugin cleanup."
        log_error "The original plugins.txt file will be used."
        return 0 # Continue migration with original plugins list
    fi

    # 5. Check the report for unused plugins
    if [[ ! -s "${report_file}" ]] || ! grep -q -v "^#" "${report_file}"; then
        log_success "✅ No unused plugins found. All installed plugins appear to be in use."
        return 0
    fi

    # 6. Present report and ask for confirmation
    log_info "Plugin analysis identified the following plugins as potentially unused:"
    echo "--------------------------------------------------" >&2
    # The >&2 redirects the output to stderr, so it appears on the console but not in the main log file's stdout pipe
    grep -v "^#" "${report_file}" | sed 's/^/  - /' >&2
    echo "--------------------------------------------------" >&2
    log_warning "Removing these plugins may cause issues if they are used in a way not detectable by the analysis script (e.g., by dynamically loaded Groovy scripts)."

    if confirm "Do you want to remove these plugins from your migration?"; then
        local unused_count
        unused_count=$(grep -c -v "^#" "${report_file}")
        log_info "User confirmed. Overwriting plugins.txt with the cleaned version."
        mv "${cleaned_plugins_file}" "${original_plugins_file}"
        log_success "✅ Successfully removed ${unused_count} unused plugins."
    else
        log_info "User declined. The original plugins.txt will be used for the migration."
    fi

    # Clean up temporary files
    rm -f "${cleaned_plugins_file}" "${report_file}"
}
