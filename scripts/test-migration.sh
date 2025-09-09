#!/usr/bin/env bash
# Test Jenkins Migration Tool functionality

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"

# Load libraries
source "${PROJECT_DIR}/lib/logging.sh"
source "${PROJECT_DIR}/lib/validation.sh"

# Test results
TESTS_PASSED=0
TESTS_FAILED=0

#######################################
# Run a test and track results
#######################################
run_test() {
    local test_name="${1}"
    local test_command="${2}"
    
    log_info "Testing: ${test_name}"
    
    if eval "${test_command}" >/dev/null 2>&1; then
        log_success "✅ ${test_name}"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        log_error "❌ ${test_name}"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

#######################################
# Main test function
#######################################
main() {
    setup_logging
    
    log_info "🧪 Jenkins Migration Tool Test Suite"
    log_info "====================================="
    
    # Test 1: Check main script exists and is executable
    run_test "Main script exists and is executable" \
        "[[ -x '${PROJECT_DIR}/jenkins-migrate.sh' ]]"
    
    # Test 2: Check all library files exist
    run_test "All library files exist" \
        "[[ -f '${PROJECT_DIR}/lib/logging.sh' && -f '${PROJECT_DIR}/lib/validation.sh' && -f '${PROJECT_DIR}/lib/templating.sh' ]]"
    
    # Test 3: Check all module files exist
    run_test "All module files exist" \
        "[[ -f '${PROJECT_DIR}/modules/docker.sh' && -f '${PROJECT_DIR}/modules/jenkins_service.sh' && -f '${PROJECT_DIR}/modules/jcasc.sh' && -f '${PROJECT_DIR}/modules/migration_state.sh' ]]"
    
    # Test 4: Check template files exist (JCasC now uses live schema, not template)
    run_test "Docker template files exist" \
        "[[ -f '${PROJECT_DIR}/templates/docker-compose.yml.template' && -f '${PROJECT_DIR}/templates/docker.env.template' ]]"
    
    # Test 5: Check helper scripts exist and are executable
    run_test "Helper scripts exist and are executable" \
        "[[ -x '${PROJECT_DIR}/scripts/validate-casc.sh' && -x '${PROJECT_DIR}/scripts/status.sh' ]]"
    
    # Test 6: Check configuration file exists
    run_test "Configuration file exists" \
        "[[ -f '${PROJECT_DIR}/jenkins-migrate.conf' ]]"
    
    # Test 7: Test script syntax (bash -n)
    run_test "Main script syntax is valid" \
        "bash -n '${PROJECT_DIR}/jenkins-migrate.sh'"
    
    # Test 8: Test library syntax
    for lib_file in "${PROJECT_DIR}/lib"/*.sh; do
        [[ -f "${lib_file}" ]] && run_test "$(basename "${lib_file}") syntax is valid" \
            "bash -n '${lib_file}'"
    done
    
    # Test 9: Test module syntax
    for module_file in "${PROJECT_DIR}/modules"/*.sh; do
        [[ -f "${module_file}" ]] && run_test "$(basename "${module_file}") syntax is valid" \
            "bash -n '${module_file}'"
    done
    
    # Test 10: Test help functionality
    run_test "Help functionality works" \
        "'${PROJECT_DIR}/jenkins-migrate.sh' --help"
    
    # Test 11: Test script execution (basic validation)
    run_test "Script executes without syntax errors" \
        "'${PROJECT_DIR}/jenkins-migrate.sh' --help >/dev/null 2>&1"
    
    # Test 12: Test template validation
    run_test "Docker Compose template is valid" \
        "validate_template '${PROJECT_DIR}/templates/docker-compose.yml.template'"
    
    # Test 13: Test JCasC schema generation (requires API access, skip in unit tests)
    run_test "JCasC schema generation functions exist" \
        "grep -q 'generate_jcasc_from_schema' '${PROJECT_DIR}/modules/jcasc.sh'"
    
    # Test 14: Test envsubst is available
    run_test "envsubst is available" \
        "command -v envsubst"
    
    # Test 15: Test required commands are available
    local required_commands=("docker" "curl" "systemctl" "grep" "sed")
    for cmd in "${required_commands[@]}"; do
        run_test "${cmd} command is available" \
            "command -v ${cmd}"
    done
    
    # Summary
    echo
    log_info "Test Results Summary"
    log_info "==================="
    log_success "Tests Passed: ${TESTS_PASSED}"
    
    if [[ ${TESTS_FAILED} -gt 0 ]]; then
        log_error "Tests Failed: ${TESTS_FAILED}"
        log_error "Some functionality may not work correctly"
        exit 1
    else
        log_success "All tests passed! ✅"
        log_info "Jenkins Migration Tool is ready to use"
        exit 0
    fi
}

# Load templating module for template validation
source "${PROJECT_DIR}/lib/templating.sh"

main "${@}"