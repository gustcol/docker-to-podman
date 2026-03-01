#!/bin/bash
# test_migration.sh - Test suite for docker-to-podman migration tool

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Source libraries
source "$PROJECT_DIR/scripts/utils.sh"
source "$PROJECT_DIR/scripts/parser.sh"

# Test utilities
assert_equals() {
    local expected="$1"
    local actual="$2"
    local message="${3:-Assertion failed}"

    ((TESTS_RUN++)) || true

    if [[ "$expected" == "$actual" ]]; then
        ((TESTS_PASSED++)) || true
        echo -e "${GREEN}PASS${NC}: $message"
        return 0
    else
        ((TESTS_FAILED++)) || true
        echo -e "${RED}FAIL${NC}: $message"
        echo "  Expected: '$expected'"
        echo "  Actual:   '$actual'"
        return 1
    fi
}

assert_not_empty() {
    local value="$1"
    local message="${2:-Value should not be empty}"

    ((TESTS_RUN++)) || true

    if [[ -n "$value" ]]; then
        ((TESTS_PASSED++)) || true
        echo -e "${GREEN}PASS${NC}: $message"
        return 0
    else
        ((TESTS_FAILED++)) || true
        echo -e "${RED}FAIL${NC}: $message"
        return 1
    fi
}

assert_file_exists() {
    local file="$1"
    local message="${2:-File should exist: $file}"

    ((TESTS_RUN++)) || true

    if [[ -f "$file" ]]; then
        ((TESTS_PASSED++)) || true
        echo -e "${GREEN}PASS${NC}: $message"
        return 0
    else
        ((TESTS_FAILED++)) || true
        echo -e "${RED}FAIL${NC}: $message"
        return 1
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="${3:-Should contain '$needle'}"

    ((TESTS_RUN++)) || true

    if [[ "$haystack" == *"$needle"* ]]; then
        ((TESTS_PASSED++)) || true
        echo -e "${GREEN}PASS${NC}: $message"
        return 0
    else
        ((TESTS_FAILED++)) || true
        echo -e "${RED}FAIL${NC}: $message"
        return 1
    fi
}

# Setup test fixtures
setup_fixtures() {
    mkdir -p "$SCRIPT_DIR/fixtures"

    # Create simple test compose file
    cat > "$SCRIPT_DIR/fixtures/simple.yml" << 'EOF'
version: '3.8'

services:
  web:
    image: nginx:alpine
    ports:
      - "8080:80"
    volumes:
      - ./html:/usr/share/nginx/html:ro
    environment:
      - NGINX_HOST=localhost
    restart: always
EOF

    # Create complex test compose file
    cat > "$SCRIPT_DIR/fixtures/complex.yml" << 'EOF'
version: '3.8'

services:
  app:
    image: myapp:latest
    ports:
      - "3000:3000"
      - "3001:3001/udp"
    volumes:
      - app_data:/app/data
      - ./config:/app/config:ro
    environment:
      - DATABASE_URL=postgres://db:5432/app
      - REDIS_URL=redis://cache:6379
    depends_on:
      - db
      - cache
    networks:
      - frontend
      - backend
    restart: unless-stopped
    deploy:
      resources:
        limits:
          memory: 512M
          cpus: '1.0'
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3000/health"]
      interval: 30s
      timeout: 10s
      retries: 3

  db:
    image: postgres:15
    volumes:
      - db_data:/var/lib/postgresql/data
    environment:
      POSTGRES_USER: app
      POSTGRES_PASSWORD: secret
    networks:
      - backend
    restart: always

  cache:
    image: redis:7
    networks:
      - backend
    restart: always

networks:
  frontend:
    driver: bridge
  backend:
    driver: bridge

volumes:
  app_data:
  db_data:
EOF

    echo "Test fixtures created"
}

# Cleanup
cleanup() {
    rm -rf "$SCRIPT_DIR/fixtures"
    rm -rf "$SCRIPT_DIR/output"
}

# Test: Utils
test_utils() {
    echo ""
    echo "=== Testing Utils ==="

    # Test sanitize_service_name
    local result
    result=$(sanitize_service_name "my-service_123")
    assert_equals "my-service_123" "$result" "sanitize_service_name: normal name"

    result=$(sanitize_service_name "my.service.name")
    assert_equals "my-service-name" "$result" "sanitize_service_name: dots to dashes"

    result=$(sanitize_service_name "--my-service--")
    assert_equals "my-service" "$result" "sanitize_service_name: trim dashes"

    # Test normalize_image
    result=$(normalize_image "nginx")
    assert_equals "docker.io/library/nginx" "$result" "normalize_image: official image"

    result=$(normalize_image "myuser/myimage")
    assert_equals "docker.io/myuser/myimage" "$result" "normalize_image: user image"

    result=$(normalize_image "ghcr.io/owner/image")
    assert_equals "ghcr.io/owner/image" "$result" "normalize_image: custom registry"

    # Test parse_port
    result=$(parse_port "8080:80")
    assert_equals "8080:80/tcp" "$result" "parse_port: host:container"

    result=$(parse_port "8080:80/udp")
    assert_equals "8080:80/udp" "$result" "parse_port: with protocol"

    result=$(parse_port "80")
    assert_equals "80:80/tcp" "$result" "parse_port: single port"

    # Test to_boolean
    result=$(to_boolean "true")
    assert_equals "true" "$result" "to_boolean: true"

    result=$(to_boolean "yes")
    assert_equals "true" "$result" "to_boolean: yes"

    result=$(to_boolean "false")
    assert_equals "false" "$result" "to_boolean: false"
}

# Test: Parser
test_parser() {
    echo ""
    echo "=== Testing Parser ==="

    local file="$SCRIPT_DIR/fixtures/simple.yml"

    # Test get_compose_version
    local version
    version=$(get_compose_version "$file")
    assert_equals "3.8" "$version" "get_compose_version"

    # Test get_services
    local services
    services=$(get_services "$file")
    assert_contains "$services" "web" "get_services: contains web"

    # Test get_service_image
    local image
    image=$(get_service_image "$file" "web")
    assert_equals "nginx:alpine" "$image" "get_service_image"

    # Test get_service_ports
    local ports
    ports=$(get_service_ports "$file" "web")
    assert_contains "$ports" "8080:80" "get_service_ports"

    # Test get_service_restart
    local restart
    restart=$(get_service_restart "$file" "web")
    assert_equals "always" "$restart" "get_service_restart"
}

# Test: Parser with complex file
test_parser_complex() {
    echo ""
    echo "=== Testing Parser (Complex) ==="

    local file="$SCRIPT_DIR/fixtures/complex.yml"

    # Test multiple services
    local services
    services=$(get_services "$file")
    assert_contains "$services" "app" "get_services: contains app"
    assert_contains "$services" "db" "get_services: contains db"
    assert_contains "$services" "cache" "get_services: contains cache"

    # Test depends_on
    local deps
    deps=$(get_service_depends_on "$file" "app")
    assert_contains "$deps" "db" "get_service_depends_on: db"
    assert_contains "$deps" "cache" "get_service_depends_on: cache"

    # Test networks
    local nets
    nets=$(get_service_networks "$file" "app")
    assert_contains "$nets" "frontend" "get_service_networks: frontend"
    assert_contains "$nets" "backend" "get_service_networks: backend"

    # Test environment
    local env
    env=$(get_service_environment "$file" "app")
    assert_contains "$env" "DATABASE_URL" "get_service_environment"

    # Test top-level networks
    local networks
    networks=$(get_networks "$file")
    assert_contains "$networks" "frontend" "get_networks: frontend"
    assert_contains "$networks" "backend" "get_networks: backend"

    # Test top-level volumes
    local volumes
    volumes=$(get_volumes "$file")
    assert_contains "$volumes" "app_data" "get_volumes: app_data"
    assert_contains "$volumes" "db_data" "get_volumes: db_data"
}

# Test: Migration script
test_migration_script() {
    echo ""
    echo "=== Testing Migration Script ==="

    local output_dir="$SCRIPT_DIR/output"
    mkdir -p "$output_dir"

    # Test help
    local help_output
    help_output=$("$PROJECT_DIR/migrate.sh" --help 2>&1)
    assert_contains "$help_output" "Usage:" "migrate.sh --help"
    assert_contains "$help_output" "migrate" "migrate.sh: has migrate command"

    # Test version
    local version_output
    version_output=$("$PROJECT_DIR/migrate.sh" --version 2>&1)
    assert_contains "$version_output" "docker-to-podman" "migrate.sh --version"

    # Test dry run
    local dry_run_output
    dry_run_output=$("$PROJECT_DIR/migrate.sh" -f "$SCRIPT_DIR/fixtures/simple.yml" -o "$output_dir/dry" -n migrate 2>&1) || true
    assert_contains "$dry_run_output" "DRY RUN" "migrate.sh: dry run mode"

    # Test validation
    local validate_output
    validate_output=$("$PROJECT_DIR/migrate.sh" -f "$SCRIPT_DIR/fixtures/simple.yml" validate 2>&1) || true
    assert_contains "$validate_output" "Validation" "migrate.sh: validate command"
}

# Test: Quadlet generation
test_quadlet_generation() {
    echo ""
    echo "=== Testing Quadlet Generation ==="

    local output_dir="$SCRIPT_DIR/output/quadlet"

    # Skip if podman not available
    if ! command -v podman &>/dev/null; then
        echo -e "${YELLOW}SKIP${NC}: Podman not available, skipping Quadlet tests"
        return 0
    fi

    # Generate Quadlet files
    "$PROJECT_DIR/migrate.sh" -f "$SCRIPT_DIR/fixtures/simple.yml" -o "$output_dir" --force migrate 2>&1 || true

    # Check generated files (project name comes from directory: fixtures)
    assert_file_exists "$output_dir/fixtures-web.container" "Generated web.container"
    assert_file_exists "$output_dir/fixtures.network" "Generated default network"

    # Check container file content
    local container_content
    container_content=$(cat "$output_dir/fixtures-web.container" 2>/dev/null || echo "")

    if [[ -n "$container_content" ]]; then
        assert_contains "$container_content" "[Container]" "Container section exists"
        assert_contains "$container_content" "Image=" "Image directive exists"
        assert_contains "$container_content" "[Service]" "Service section exists"
    fi
}

# Test: Converter
test_converter() {
    echo ""
    echo "=== Testing Converter ==="

    source "$PROJECT_DIR/scripts/converter.sh"

    # Test convert_restart_policy
    local result
    result=$(convert_restart_policy "always")
    assert_equals "always" "$result" "convert_restart_policy: always"

    result=$(convert_restart_policy "unless-stopped")
    assert_equals "always" "$result" "convert_restart_policy: unless-stopped"

    result=$(convert_restart_policy "on-failure")
    assert_equals "on-failure" "$result" "convert_restart_policy: on-failure"

    result=$(convert_restart_policy "no")
    assert_equals "no" "$result" "convert_restart_policy: no"
}

# Test: SELinux
test_selinux() {
    echo ""
    echo "=== Testing SELinux ==="

    source "$PROJECT_DIR/scripts/selinux.sh"

    # Test detect_selinux function exists and returns valid value
    local status
    status=$(detect_selinux)
    assert_not_empty "$status" "detect_selinux: returns a status"

    # Verify status is one of the expected values
    local valid_statuses="enforcing permissive disabled not_installed apparmor wsl macos"
    local is_valid="false"
    for valid_status in $valid_statuses; do
        if [[ "$status" == "$valid_status" ]]; then
            is_valid="true"
            break
        fi
    done
    ((TESTS_RUN++)) || true
    if [[ "$is_valid" == "true" ]]; then
        ((TESTS_PASSED++)) || true
        echo -e "${GREEN}PASS${NC}: detect_selinux: valid status ($status)"
    else
        ((TESTS_FAILED++)) || true
        echo -e "${RED}FAIL${NC}: detect_selinux: invalid status ($status)"
    fi

    # Test validate_selinux_mode
    local result
    result=$(validate_selinux_mode "auto" 2>&1 && echo "valid" || echo "invalid")
    assert_equals "valid" "$result" "validate_selinux_mode: auto is valid"

    result=$(validate_selinux_mode "enforcing" 2>&1 && echo "valid" || echo "invalid")
    assert_equals "valid" "$result" "validate_selinux_mode: enforcing is valid"

    result=$(validate_selinux_mode "disabled" 2>&1 && echo "valid" || echo "invalid")
    assert_equals "valid" "$result" "validate_selinux_mode: disabled is valid"

    result=$(validate_selinux_mode "shared" 2>&1 && echo "valid" || echo "invalid")
    assert_equals "valid" "$result" "validate_selinux_mode: shared is valid"

    result=$(validate_selinux_mode "private" 2>&1 && echo "valid" || echo "invalid")
    assert_equals "valid" "$result" "validate_selinux_mode: private is valid"

    result=$(validate_selinux_mode "invalid_mode" 2>/dev/null && echo "valid" || echo "invalid")
    assert_equals "invalid" "$result" "validate_selinux_mode: invalid_mode is rejected"

    # Test get_selinux_label with explicit modes
    local label

    # Test disabled mode
    label=$(SELINUX_MODE=disabled get_selinux_label "disabled")
    assert_equals "" "$label" "get_selinux_label: disabled returns empty"

    # Test shared mode
    label=$(get_selinux_label "shared")
    assert_equals ":z" "$label" "get_selinux_label: shared returns :z"

    # Test private mode
    label=$(get_selinux_label "private")
    assert_equals ":Z" "$label" "get_selinux_label: private returns :Z"

    # Test enforcing mode without shared
    label=$(get_selinux_label "enforcing" "false")
    assert_equals ":Z" "$label" "get_selinux_label: enforcing non-shared returns :Z"

    # Test enforcing mode with shared
    label=$(get_selinux_label "enforcing" "true")
    assert_equals ":z" "$label" "get_selinux_label: enforcing shared returns :z"

    # Test is_selinux_active function
    local active_result
    active_result=$(is_selinux_active && echo "active" || echo "inactive")
    assert_not_empty "$active_result" "is_selinux_active: returns a result"

    # Test requires_selinux_labels function
    local requires_result
    requires_result=$(requires_selinux_labels && echo "requires" || echo "not_required")
    assert_not_empty "$requires_result" "requires_selinux_labels: returns a result"
}

# Test: SELinux Shared Volume Detection
test_selinux_shared_volumes() {
    echo ""
    echo "=== Testing SELinux Shared Volume Detection ==="

    source "$PROJECT_DIR/scripts/selinux.sh"

    # Create test compose file with shared volumes
    cat > "$SCRIPT_DIR/fixtures/shared_volumes.yml" << 'EOF'
version: '3.8'

services:
  web:
    image: nginx:alpine
    volumes:
      - ./shared:/data
      - ./web-only:/web
  worker:
    image: worker:latest
    volumes:
      - ./shared:/data
      - ./worker-only:/worker
EOF

    # Test get_shared_volumes
    local shared
    shared=$(get_shared_volumes "$SCRIPT_DIR/fixtures/shared_volumes.yml")

    # The 'shared' directory should be detected as shared
    ((TESTS_RUN++)) || true
    if [[ "$shared" == *"shared"* ]]; then
        ((TESTS_PASSED++)) || true
        echo -e "${GREEN}PASS${NC}: get_shared_volumes: detects shared volume"
    else
        ((TESTS_FAILED++)) || true
        echo -e "${RED}FAIL${NC}: get_shared_volumes: should detect 'shared' as shared volume"
        echo "  Got: $shared"
    fi

    # Test is_volume_shared
    local result
    result=$(is_volume_shared "$SCRIPT_DIR/fixtures/shared_volumes.yml" "./shared" && echo "shared" || echo "not_shared")
    assert_equals "shared" "$result" "is_volume_shared: ./shared is shared"

    result=$(is_volume_shared "$SCRIPT_DIR/fixtures/shared_volumes.yml" "./web-only" && echo "shared" || echo "not_shared")
    assert_equals "not_shared" "$result" "is_volume_shared: ./web-only is not shared"

    result=$(is_volume_shared "$SCRIPT_DIR/fixtures/shared_volumes.yml" "./worker-only" && echo "shared" || echo "not_shared")
    assert_equals "not_shared" "$result" "is_volume_shared: ./worker-only is not shared"

    # Cleanup
    rm -f "$SCRIPT_DIR/fixtures/shared_volumes.yml"
}

# Test: SELinux Volume Mount Conversion
test_selinux_volume_conversion() {
    echo ""
    echo "=== Testing SELinux Volume Mount Conversion ==="

    source "$PROJECT_DIR/scripts/converter.sh"

    # Test with SELinux disabled
    SELINUX_MODE="disabled"
    export SELINUX_MODE

    local result
    result=$(convert_volume_mount "./data:/app" "myproject")
    assert_equals "./data:/app" "$result" "convert_volume_mount: disabled mode, no label added"

    # Test with SELinux enforcing (simulated)
    SELINUX_MODE="enforcing"
    export SELINUX_MODE

    # Force SELinux to return enforcing for testing
    _SELINUX_STATUS_CACHE="enforcing"

    result=$(convert_volume_mount "./data:/app" "myproject")
    assert_contains "$result" ":Z" "convert_volume_mount: enforcing mode adds :Z"

    # Test with existing options
    result=$(convert_volume_mount "./data:/app:ro" "myproject")
    assert_contains "$result" "ro" "convert_volume_mount: preserves existing options"
    assert_contains "$result" "Z" "convert_volume_mount: adds label with existing options"

    # Test named volume (should not add SELinux label)
    result=$(convert_volume_mount "myvolume:/app" "myproject")
    assert_equals "myproject_myvolume:/app" "$result" "convert_volume_mount: named volume prefixed"

    # Test with shared mode
    SELINUX_MODE="shared"
    export SELINUX_MODE

    result=$(convert_volume_mount "./data:/app" "myproject")
    assert_contains "$result" ":z" "convert_volume_mount: shared mode adds :z"

    # Test already has SELinux label (should not duplicate)
    SELINUX_MODE="enforcing"
    export SELINUX_MODE

    result=$(convert_volume_mount "./data:/app:Z" "myproject")
    # Should not have :Z:Z
    local double_z
    double_z=$(echo "$result" | grep -c "Z.*Z" || true)
    ((TESTS_RUN++)) || true
    if [[ "$double_z" -eq 0 ]]; then
        ((TESTS_PASSED++)) || true
        echo -e "${GREEN}PASS${NC}: convert_volume_mount: does not duplicate :Z"
    else
        ((TESTS_FAILED++)) || true
        echo -e "${RED}FAIL${NC}: convert_volume_mount: duplicated :Z"
    fi

    # Reset
    SELINUX_MODE="auto"
    export SELINUX_MODE
    _SELINUX_STATUS_CACHE=""
}

# Test: SELinux CLI Commands
test_selinux_cli() {
    echo ""
    echo "=== Testing SELinux CLI Commands ==="

    # Test selinux-check command
    local output
    output=$("$PROJECT_DIR/migrate.sh" selinux-check 2>&1) || true
    assert_contains "$output" "SELinux" "selinux-check: outputs SELinux information"

    # Test selinux-info command
    output=$("$PROJECT_DIR/migrate.sh" selinux-info 2>&1) || true
    assert_not_empty "$output" "selinux-info: returns output"

    # Test selinux-analyze command
    output=$("$PROJECT_DIR/migrate.sh" -f "$SCRIPT_DIR/fixtures/simple.yml" selinux-analyze 2>&1) || true
    assert_contains "$output" "Volume" "selinux-analyze: analyzes volumes"

    # Test invalid SELinux mode
    output=$("$PROJECT_DIR/migrate.sh" --selinux=invalid_mode -f "$SCRIPT_DIR/fixtures/simple.yml" validate 2>&1) || true
    assert_contains "$output" "Invalid" "selinux: rejects invalid mode"

    # Test help includes SELinux options
    local help_output
    help_output=$("$PROJECT_DIR/migrate.sh" --help 2>&1)
    assert_contains "$help_output" "selinux" "help: includes SELinux options"
    assert_contains "$help_output" "selinux-check" "help: includes selinux-check command"
    assert_contains "$help_output" "selinux-validate" "help: includes selinux-validate command"
    assert_contains "$help_output" "selinux-fix" "help: includes selinux-fix command"
}

# =============================================================================
# SECURITY TESTS
# =============================================================================

# Test: Input Validation (Command Injection Prevention)
test_security_input_validation() {
    echo ""
    echo "=== Testing Security: Input Validation ==="

    source "$PROJECT_DIR/scripts/selinux.sh"

    # Test validate_path_safe - VALID paths
    local result

    # Normal path
    result=$(validate_path_safe "/home/user/data" 2>&1 && echo "valid" || echo "invalid")
    assert_equals "valid" "$result" "validate_path_safe: normal absolute path is valid"

    # Path with dots
    result=$(validate_path_safe "./relative/path" 2>&1 && echo "valid" || echo "invalid")
    assert_equals "valid" "$result" "validate_path_safe: relative path is valid"

    # Path with spaces
    result=$(validate_path_safe "/home/user/my data" 2>&1 && echo "valid" || echo "invalid")
    assert_equals "valid" "$result" "validate_path_safe: path with spaces is valid"

    # Test validate_path_safe - DANGEROUS paths (command injection attempts)
    # Semicolon injection
    result=$(validate_path_safe "/tmp/data;rm -rf /" 2>&1 && echo "valid" || echo "invalid")
    assert_equals "invalid" "$result" "validate_path_safe: semicolon injection blocked"

    # Pipe injection
    result=$(validate_path_safe "/tmp/data|cat /etc/passwd" 2>&1 && echo "valid" || echo "invalid")
    assert_equals "invalid" "$result" "validate_path_safe: pipe injection blocked"

    # Ampersand injection
    result=$(validate_path_safe "/tmp/data&whoami" 2>&1 && echo "valid" || echo "invalid")
    assert_equals "invalid" "$result" "validate_path_safe: ampersand injection blocked"

    # Dollar sign injection (variable expansion)
    result=$(validate_path_safe '/tmp/$HOME' 2>&1 && echo "valid" || echo "invalid")
    assert_equals "invalid" "$result" "validate_path_safe: dollar sign injection blocked"

    # Command substitution injection
    result=$(validate_path_safe '/tmp/$(whoami)' 2>&1 && echo "valid" || echo "invalid")
    assert_equals "invalid" "$result" "validate_path_safe: command substitution blocked"

    # Backtick injection
    result=$(validate_path_safe '/tmp/`id`' 2>&1 && echo "valid" || echo "invalid")
    assert_equals "invalid" "$result" "validate_path_safe: backtick injection blocked"

    # Newline injection
    result=$(validate_path_safe $'/tmp/data\nrm -rf /' 2>&1 && echo "valid" || echo "invalid")
    assert_equals "invalid" "$result" "validate_path_safe: newline injection blocked"

    # Empty path
    result=$(validate_path_safe "" 2>&1 && echo "valid" || echo "invalid")
    assert_equals "invalid" "$result" "validate_path_safe: empty path blocked"
}

# Test: SELinux Type Validation
test_security_selinux_type_validation() {
    echo ""
    echo "=== Testing Security: SELinux Type Validation ==="

    source "$PROJECT_DIR/scripts/selinux.sh"

    local result

    # Valid SELinux types
    result=$(validate_selinux_type "container_file_t" 2>&1 && echo "valid" || echo "invalid")
    assert_equals "valid" "$result" "validate_selinux_type: container_file_t is valid"

    result=$(validate_selinux_type "container_t" 2>&1 && echo "valid" || echo "invalid")
    assert_equals "valid" "$result" "validate_selinux_type: container_t is valid"

    result=$(validate_selinux_type "spc_t" 2>&1 && echo "valid" || echo "invalid")
    assert_equals "valid" "$result" "validate_selinux_type: spc_t is valid"

    result=$(validate_selinux_type "svirt_sandbox_file_t" 2>&1 && echo "valid" || echo "invalid")
    assert_equals "valid" "$result" "validate_selinux_type: svirt_sandbox_file_t is valid"

    # Invalid SELinux types (injection attempts)
    result=$(validate_selinux_type "container_t;rm" 2>&1 && echo "valid" || echo "invalid")
    assert_equals "invalid" "$result" "validate_selinux_type: semicolon in type blocked"

    result=$(validate_selinux_type "container_t|cat" 2>&1 && echo "valid" || echo "invalid")
    assert_equals "invalid" "$result" "validate_selinux_type: pipe in type blocked"

    result=$(validate_selinux_type "container-t" 2>&1 && echo "valid" || echo "invalid")
    assert_equals "invalid" "$result" "validate_selinux_type: dash in type blocked"

    # Too long type name
    local long_type
    long_type=$(printf 'a%.0s' {1..100})
    result=$(validate_selinux_type "$long_type" 2>&1 && echo "valid" || echo "invalid")
    assert_equals "invalid" "$result" "validate_selinux_type: too long type blocked"
}

# Test: SELinux Level Validation
test_security_selinux_level_validation() {
    echo ""
    echo "=== Testing Security: SELinux Level Validation ==="

    source "$PROJECT_DIR/scripts/selinux.sh"

    local result

    # Valid MCS levels
    result=$(validate_selinux_level "s0" 2>&1 && echo "valid" || echo "invalid")
    assert_equals "valid" "$result" "validate_selinux_level: s0 is valid"

    result=$(validate_selinux_level "s0:c0" 2>&1 && echo "valid" || echo "invalid")
    assert_equals "valid" "$result" "validate_selinux_level: s0:c0 is valid"

    result=$(validate_selinux_level "s0:c0,c1" 2>&1 && echo "valid" || echo "invalid")
    assert_equals "valid" "$result" "validate_selinux_level: s0:c0,c1 is valid"

    result=$(validate_selinux_level "s0:c100,c200" 2>&1 && echo "valid" || echo "invalid")
    assert_equals "valid" "$result" "validate_selinux_level: s0:c100,c200 is valid"

    # Invalid levels (injection attempts)
    result=$(validate_selinux_level "s0;rm" 2>&1 && echo "valid" || echo "invalid")
    assert_equals "invalid" "$result" "validate_selinux_level: semicolon injection blocked"

    result=$(validate_selinux_level "invalid_level" 2>&1 && echo "valid" || echo "invalid")
    assert_equals "invalid" "$result" "validate_selinux_level: invalid format blocked"
}

# Test: Security Options Parsing
test_security_opt_parsing() {
    echo ""
    echo "=== Testing Security: security_opt Parsing ==="

    source "$PROJECT_DIR/scripts/selinux.sh"

    # Test parse_security_opt_selinux function
    local result

    # Label type parsing
    result=$(parse_security_opt_selinux "label:type:container_t")
    assert_equals "type=container_t" "$result" "parse_security_opt: label:type parsed"

    # Label level parsing
    result=$(parse_security_opt_selinux "label:level:s0:c100,c200")
    assert_equals "level=s0:c100,c200" "$result" "parse_security_opt: label:level parsed"

    # Label disable parsing
    result=$(parse_security_opt_selinux "label:disable")
    assert_equals "disabled=true" "$result" "parse_security_opt: label:disable parsed"

    # Label user parsing
    result=$(parse_security_opt_selinux "label:user:system_u")
    assert_equals "user=system_u" "$result" "parse_security_opt: label:user parsed"

    # Label role parsing
    result=$(parse_security_opt_selinux "label:role:system_r")
    assert_equals "role=system_r" "$result" "parse_security_opt: label:role parsed"

    # No-new-privileges parsing
    result=$(parse_security_opt_selinux "no-new-privileges")
    assert_equals "no_new_privileges=true" "$result" "parse_security_opt: no-new-privileges parsed"

    # Seccomp parsing
    result=$(parse_security_opt_selinux "seccomp:unconfined")
    assert_equals "seccomp=unconfined" "$result" "parse_security_opt: seccomp parsed"

    # AppArmor parsing
    result=$(parse_security_opt_selinux "apparmor:unconfined")
    assert_equals "apparmor=unconfined" "$result" "parse_security_opt: apparmor parsed"
}

# Test: Security Options from Compose File
test_security_opt_from_compose() {
    echo ""
    echo "=== Testing Security: security_opt from Compose File ==="

    source "$PROJECT_DIR/scripts/parser.sh"
    source "$PROJECT_DIR/scripts/selinux.sh"

    # Create test compose file with security options
    cat > "$SCRIPT_DIR/fixtures/security_test.yml" << 'EOF'
version: '3.8'

services:
  secure-app:
    image: nginx:alpine
    privileged: true
    read_only: true
    cap_add:
      - NET_ADMIN
      - SYS_TIME
    cap_drop:
      - ALL
    security_opt:
      - label:type:spc_t
      - label:level:s0:c100,c200
      - no-new-privileges
EOF

    local file="$SCRIPT_DIR/fixtures/security_test.yml"

    # Test get_service_privileged
    local privileged
    privileged=$(get_service_privileged "$file" "secure-app")
    assert_equals "true" "$privileged" "get_service_privileged: detects privileged mode"

    # Test get_service_read_only
    local read_only
    read_only=$(get_service_read_only "$file" "secure-app")
    assert_equals "true" "$read_only" "get_service_read_only: detects read_only mode"

    # Test get_service_cap_add
    local cap_add
    cap_add=$(get_service_cap_add "$file" "secure-app")
    assert_contains "$cap_add" "NET_ADMIN" "get_service_cap_add: detects NET_ADMIN"
    assert_contains "$cap_add" "SYS_TIME" "get_service_cap_add: detects SYS_TIME"

    # Test get_service_cap_drop
    local cap_drop
    cap_drop=$(get_service_cap_drop "$file" "secure-app")
    assert_contains "$cap_drop" "ALL" "get_service_cap_drop: detects ALL"

    # Test get_service_security_opt
    local security_opt
    security_opt=$(get_service_security_opt "$file" "secure-app")
    assert_contains "$security_opt" "label:type:spc_t" "get_service_security_opt: detects label:type"
    assert_contains "$security_opt" "no-new-privileges" "get_service_security_opt: detects no-new-privileges"

    # Test get_selinux_context_from_compose
    local context
    context=$(get_selinux_context_from_compose "$file" "secure-app")
    assert_contains "$context" "SELINUX_TYPE=spc_t" "get_selinux_context_from_compose: extracts type"
    assert_contains "$context" "SELINUX_LEVEL=s0:c100,c200" "get_selinux_context_from_compose: extracts level"

    # Cleanup
    rm -f "$SCRIPT_DIR/fixtures/security_test.yml"
}

# Test: Namespace Modes
test_namespace_modes() {
    echo ""
    echo "=== Testing Security: Namespace Modes ==="

    source "$PROJECT_DIR/scripts/parser.sh"
    source "$PROJECT_DIR/scripts/selinux.sh"

    # Create test compose file with namespace options
    cat > "$SCRIPT_DIR/fixtures/namespace_test.yml" << 'EOF'
version: '3.8'

services:
  host-networked:
    image: nginx:alpine
    network_mode: host
    ipc: host
    pid: host
    userns_mode: keep-id
EOF

    local file="$SCRIPT_DIR/fixtures/namespace_test.yml"

    # Test get_service_network_mode
    local network_mode
    network_mode=$(get_service_network_mode "$file" "host-networked")
    assert_equals "host" "$network_mode" "get_service_network_mode: detects host mode"

    # Test get_service_ipc
    local ipc_mode
    ipc_mode=$(get_service_ipc "$file" "host-networked")
    assert_equals "host" "$ipc_mode" "get_service_ipc: detects host mode"

    # Test get_service_pid
    local pid_mode
    pid_mode=$(get_service_pid "$file" "host-networked")
    assert_equals "host" "$pid_mode" "get_service_pid: detects host mode"

    # Test get_service_userns_mode
    local userns_mode
    userns_mode=$(get_service_userns_mode "$file" "host-networked")
    assert_equals "keep-id" "$userns_mode" "get_service_userns_mode: detects keep-id mode"

    # Cleanup
    rm -f "$SCRIPT_DIR/fixtures/namespace_test.yml"
}

# Test: OpenShift SCC Detection
test_openshift_scc() {
    echo ""
    echo "=== Testing Security: OpenShift SCC Detection ==="

    source "$PROJECT_DIR/scripts/kubernetes.sh"

    # Create test compose file with various security requirements
    cat > "$SCRIPT_DIR/fixtures/scc_test.yml" << 'EOF'
version: '3.8'

services:
  restricted-app:
    image: nginx:alpine

  privileged-app:
    image: nginx:alpine
    privileged: true

  host-network-app:
    image: nginx:alpine
    network_mode: host

  root-app:
    image: nginx:alpine
    user: "0"

  caps-app:
    image: nginx:alpine
    cap_add:
      - NET_ADMIN
      - SYS_ADMIN
EOF

    local file="$SCRIPT_DIR/fixtures/scc_test.yml"

    # Test get_recommended_scc for restricted app
    local scc
    scc=$(get_recommended_scc "$file" "restricted-app")
    assert_equals "restricted-v2" "$scc" "get_recommended_scc: restricted app uses restricted-v2"

    # Test get_recommended_scc for privileged app
    scc=$(get_recommended_scc "$file" "privileged-app")
    assert_equals "privileged" "$scc" "get_recommended_scc: privileged app uses privileged SCC"

    # Test get_recommended_scc for host network app
    scc=$(get_recommended_scc "$file" "host-network-app")
    assert_equals "hostnetwork" "$scc" "get_recommended_scc: host network app uses hostnetwork SCC"

    # Test get_recommended_scc for root user app
    scc=$(get_recommended_scc "$file" "root-app")
    assert_equals "anyuid" "$scc" "get_recommended_scc: root user app uses anyuid SCC"

    # Test get_recommended_scc for capabilities app
    scc=$(get_recommended_scc "$file" "caps-app")
    assert_equals "anyuid" "$scc" "get_recommended_scc: dangerous caps app uses anyuid SCC"

    # Cleanup
    rm -f "$SCRIPT_DIR/fixtures/scc_test.yml"
}

# Test: Kubernetes Security Context Generation
test_k8s_security_context() {
    echo ""
    echo "=== Testing Security: Kubernetes Security Context ==="

    source "$PROJECT_DIR/scripts/kubernetes.sh"

    # Create test compose file
    cat > "$SCRIPT_DIR/fixtures/k8s_security_test.yml" << 'EOF'
version: '3.8'

services:
  secure-app:
    image: nginx:alpine
    read_only: true
    cap_add:
      - NET_BIND_SERVICE
    cap_drop:
      - ALL
    user: "1000:1000"
EOF

    local file="$SCRIPT_DIR/fixtures/k8s_security_test.yml"

    # Test get_k8s_container_security_context
    local context
    context=$(get_k8s_container_security_context "$file" "secure-app" "            ")

    # Should contain readOnlyRootFilesystem
    assert_contains "$context" "readOnlyRootFilesystem: true" "k8s_security_context: has readOnlyRootFilesystem"

    # Should contain capabilities
    assert_contains "$context" "capabilities:" "k8s_security_context: has capabilities section"
    assert_contains "$context" "add:" "k8s_security_context: has add capabilities"
    assert_contains "$context" "drop:" "k8s_security_context: has drop capabilities"
    assert_contains "$context" "NET_BIND_SERVICE" "k8s_security_context: has NET_BIND_SERVICE cap"
    assert_contains "$context" "ALL" "k8s_security_context: has ALL in drop"

    # Should contain runAsUser
    assert_contains "$context" "runAsUser: 1000" "k8s_security_context: has runAsUser"

    # Cleanup
    rm -f "$SCRIPT_DIR/fixtures/k8s_security_test.yml"
}

# Test: SELinux Booleans Check
test_selinux_booleans() {
    echo ""
    echo "=== Testing Security: SELinux Booleans ==="

    source "$PROJECT_DIR/scripts/selinux.sh"

    # Test that CONTAINER_SELINUX_BOOLEANS is defined
    ((TESTS_RUN++)) || true
    if [[ ${#CONTAINER_SELINUX_BOOLEANS[@]} -gt 0 ]]; then
        ((TESTS_PASSED++)) || true
        echo -e "${GREEN}PASS${NC}: CONTAINER_SELINUX_BOOLEANS is defined"
    else
        ((TESTS_FAILED++)) || true
        echo -e "${RED}FAIL${NC}: CONTAINER_SELINUX_BOOLEANS should be defined"
    fi

    # Test get_recommended_booleans function exists
    ((TESTS_RUN++)) || true
    if declare -f get_recommended_booleans >/dev/null; then
        ((TESTS_PASSED++)) || true
        echo -e "${GREEN}PASS${NC}: get_recommended_booleans function exists"
    else
        ((TESTS_FAILED++)) || true
        echo -e "${RED}FAIL${NC}: get_recommended_booleans function should exist"
    fi

    # Test check_selinux_booleans function exists
    ((TESTS_RUN++)) || true
    if declare -f check_selinux_booleans >/dev/null; then
        ((TESTS_PASSED++)) || true
        echo -e "${GREEN}PASS${NC}: check_selinux_booleans function exists"
    else
        ((TESTS_FAILED++)) || true
        echo -e "${RED}FAIL${NC}: check_selinux_booleans function should exist"
    fi
}

# Test: Port SELinux Validation
test_port_selinux_validation() {
    echo ""
    echo "=== Testing Security: Port SELinux Validation ==="

    source "$PROJECT_DIR/scripts/selinux.sh"

    # Test validate_port_selinux function exists
    ((TESTS_RUN++)) || true
    if declare -f validate_port_selinux >/dev/null; then
        ((TESTS_PASSED++)) || true
        echo -e "${GREEN}PASS${NC}: validate_port_selinux function exists"
    else
        ((TESTS_FAILED++)) || true
        echo -e "${RED}FAIL${NC}: validate_port_selinux function should exist"
    fi

    # Test invalid port validation
    local result
    result=$(validate_port_selinux "99999" 2>&1 && echo "valid" || echo "invalid")
    assert_equals "invalid" "$result" "validate_port_selinux: port 99999 is invalid"

    result=$(validate_port_selinux "0" 2>&1 && echo "valid" || echo "invalid")
    assert_equals "invalid" "$result" "validate_port_selinux: port 0 is invalid"

    result=$(validate_port_selinux "abc" 2>&1 && echo "valid" || echo "invalid")
    assert_equals "invalid" "$result" "validate_port_selinux: non-numeric port is invalid"
}

# Print summary
print_summary() {
    echo ""
    echo "=== Test Summary ==="
    echo "Total:  $TESTS_RUN"
    echo -e "Passed: ${GREEN}$TESTS_PASSED${NC}"
    echo -e "Failed: ${RED}$TESTS_FAILED${NC}"
    echo ""

    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo -e "${GREEN}All tests passed!${NC}"
        return 0
    else
        echo -e "${RED}Some tests failed!${NC}"
        return 1
    fi
}

# Main
main() {
    echo "Docker-to-Podman Migration Tool - Test Suite"
    echo "============================================="

    # Setup
    setup_fixtures

    # Run tests
    test_utils
    test_parser
    test_parser_complex
    test_converter
    test_selinux
    test_selinux_shared_volumes
    test_selinux_volume_conversion
    test_selinux_cli

    # Security tests
    test_security_input_validation
    test_security_selinux_type_validation
    test_security_selinux_level_validation
    test_security_opt_parsing
    test_security_opt_from_compose
    test_namespace_modes
    test_openshift_scc
    test_k8s_security_context
    test_selinux_booleans
    test_port_selinux_validation

    test_migration_script
    test_quadlet_generation

    # Cleanup
    cleanup

    # Summary
    print_summary
}

# Run tests
main "$@"
