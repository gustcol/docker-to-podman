#!/bin/bash
# validator.sh - Validation utilities for docker-compose to podman migration

# Guard against multiple loading
[[ -n "${_VALIDATOR_LOADED:-}" ]] && return 0
_VALIDATOR_LOADED=1

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -z "${_UTILS_LOADED:-}" ]] && source "$_LIB_DIR/utils.sh"
[[ -z "${_PARSER_LOADED:-}" ]] && source "$_LIB_DIR/parser.sh"

# Validation result tracking
declare -a VALIDATION_ERRORS
declare -a VALIDATION_WARNINGS

# Reset validation state
reset_validation() {
    VALIDATION_ERRORS=()
    VALIDATION_WARNINGS=()
}

# Add validation error
add_error() {
    VALIDATION_ERRORS+=("$1")
}

# Add validation warning
add_warning() {
    VALIDATION_WARNINGS+=("$1")
}

# Check if docker-compose file exists and is readable
validate_compose_file() {
    local file="$1"

    if [[ ! -f "$file" ]]; then
        add_error "Compose file not found: $file"
        return 1
    fi

    if [[ ! -r "$file" ]]; then
        add_error "Compose file not readable: $file"
        return 1
    fi

    # Check if it's valid YAML (basic check)
    if [[ "${USE_YQ:-0}" == "1" ]]; then
        if ! yq '.' "$file" &>/dev/null; then
            add_error "Invalid YAML syntax in: $file"
            return 1
        fi
    fi

    return 0
}

# Validate compose version
validate_compose_version() {
    local file="$1"
    local version
    version=$(get_compose_version "$file")

    case "$version" in
        2|2.*|3|3.*)
            log_debug "Compose version: $version (supported)"
            ;;
        1|1.*)
            add_warning "Compose version $version is legacy. Consider upgrading."
            ;;
        "")
            add_warning "No version specified. Assuming version 3."
            ;;
        *)
            add_warning "Unknown compose version: $version"
            ;;
    esac
}

# Validate service definitions
validate_services() {
    local file="$1"
    local services
    services=$(get_services "$file")

    if [[ -z "$services" ]]; then
        add_error "No services defined in compose file"
        return 1
    fi

    while IFS= read -r service; do
        [[ -z "$service" ]] && continue
        validate_service "$file" "$service"
    done <<< "$services"
}

# Validate individual service
validate_service() {
    local file="$1"
    local service="$2"

    # Check for image or build
    local image
    image=$(get_service_image "$file" "$service")

    if [[ -z "$image" ]]; then
        # Check for build context
        local build
        if [[ "${USE_YQ:-0}" == "1" ]]; then
            build=$(yq -r ".services.${service}.build" "$file" 2>/dev/null)
            [[ "$build" == "null" ]] && build=""
        fi

        if [[ -z "$build" ]]; then
            add_error "Service '$service': No image or build context specified"
        else
            add_warning "Service '$service': Has build context. You'll need to build the image first."
        fi
    fi

    # Check for unsupported features
    check_unsupported_features "$file" "$service"

    # Validate ports
    validate_service_ports "$file" "$service"

    # Validate volumes
    validate_service_volumes "$file" "$service"
}

# Check for unsupported or problematic features
check_unsupported_features() {
    local file="$1"
    local service="$2"

    if [[ "${USE_YQ:-0}" != "1" ]]; then
        return  # Can't check without yq
    fi

    # Features that need special handling
    local features=(
        "links:Links are deprecated. Use networks instead."
        "extends:Extends is not fully supported. Manual merge required."
        "external_links:External links may not work as expected."
        "pid:PID namespace sharing requires special configuration."
        "ipc:IPC namespace sharing requires special configuration."
        "privileged:Privileged mode may have security implications."
        "cap_add:Capabilities need to be explicitly allowed in Podman."
        "cap_drop:Capability dropping works differently in rootless mode."
        "devices:Device access may require additional configuration."
        "security_opt:Security options may differ between Docker and Podman."
    )

    for feature_info in "${features[@]}"; do
        local feature="${feature_info%%:*}"
        local message="${feature_info#*:}"

        local value
        value=$(yq -r ".services.${service}.${feature}" "$file" 2>/dev/null)
        [[ "$value" == "null" ]] && value=""

        if [[ -n "$value" && "$value" != "null" ]]; then
            add_warning "Service '$service': Uses '$feature'. $message"
        fi
    done

    # Check for Docker-specific networking
    local network_mode
    network_mode=$(yq -r ".services.${service}.network_mode" "$file" 2>/dev/null)
    [[ "$network_mode" == "null" ]] && network_mode=""

    case "$network_mode" in
        "host")
            add_warning "Service '$service': Uses host network mode. May require --network=host in rootless."
            ;;
        "bridge")
            # OK
            ;;
        "none")
            # OK
            ;;
        container:*)
            add_warning "Service '$service': Uses container network sharing. May need manual configuration."
            ;;
    esac
}

# Validate port mappings
validate_service_ports() {
    local file="$1"
    local service="$2"
    local ports
    ports=$(get_service_ports "$file" "$service")

    while IFS= read -r port; do
        [[ -z "$port" ]] && continue

        # Check for privileged ports in rootless mode
        local host_port
        if [[ "$port" =~ : ]]; then
            host_port=$(echo "$port" | cut -d: -f1)
        else
            host_port="$port"
        fi

        # Remove protocol suffix if present
        host_port="${host_port%/*}"

        if [[ "$host_port" =~ ^[0-9]+$ ]] && [[ "$host_port" -lt 1024 ]]; then
            add_warning "Service '$service': Port $host_port is privileged. Rootless Podman may need net.ipv4.ip_unprivileged_port_start=0"
        fi
    done <<< "$ports"
}

# Validate volume mounts
validate_service_volumes() {
    local file="$1"
    local service="$2"
    local volumes
    volumes=$(get_service_volumes "$file" "$service")

    while IFS= read -r vol; do
        [[ -z "$vol" ]] && continue

        local source
        source=$(echo "$vol" | cut -d: -f1)

        # Check if source is a path
        if [[ "$source" == /* ]]; then
            if [[ ! -e "$source" ]]; then
                add_warning "Service '$service': Volume source '$source' does not exist"
            fi
        elif [[ "$source" == ./* ]] || [[ "$source" == ../* ]]; then
            # Relative path - check from compose file directory
            local compose_dir
            compose_dir=$(dirname "$file")
            local full_path="$compose_dir/$source"
            if [[ ! -e "$full_path" ]]; then
                add_warning "Service '$service': Volume source '$source' does not exist"
            fi
        fi
    done <<< "$volumes"
}

# Validate networks
validate_networks() {
    local file="$1"

    if [[ "${USE_YQ:-0}" != "1" ]]; then
        return
    fi

    local networks
    networks=$(get_networks "$file")

    while IFS= read -r network; do
        [[ -z "$network" ]] && continue

        local driver
        driver=$(get_network_driver "$file" "$network")

        case "$driver" in
            bridge|macvlan|ipvlan|host|none)
                # Supported
                ;;
            overlay)
                add_warning "Network '$network': Overlay driver requires Podman in swarm mode or manual setup"
                ;;
            *)
                add_warning "Network '$network': Unknown driver '$driver'. May not be supported."
                ;;
        esac
    done <<< "$networks"
}

# Print validation results
print_validation_results() {
    echo ""
    log_info "=== Validation Results ==="
    echo ""

    if [[ ${#VALIDATION_ERRORS[@]} -eq 0 ]] && [[ ${#VALIDATION_WARNINGS[@]} -eq 0 ]]; then
        log_success "No issues found!"
        return 0
    fi

    if [[ ${#VALIDATION_ERRORS[@]} -gt 0 ]]; then
        log_error "Errors (${#VALIDATION_ERRORS[@]}):"
        for error in "${VALIDATION_ERRORS[@]}"; do
            echo "  - $error"
        done
        echo ""
    fi

    if [[ ${#VALIDATION_WARNINGS[@]} -gt 0 ]]; then
        log_warning "Warnings (${#VALIDATION_WARNINGS[@]}):"
        for warning in "${VALIDATION_WARNINGS[@]}"; do
            echo "  - $warning"
        done
        echo ""
    fi

    if [[ ${#VALIDATION_ERRORS[@]} -gt 0 ]]; then
        return 1
    fi

    return 0
}

# Run full validation
run_validation() {
    local file="$1"

    reset_validation

    log_info "Validating compose file: $file"

    validate_compose_file "$file" || return 1
    validate_compose_version "$file"
    validate_services "$file"
    validate_networks "$file"

    print_validation_results
}

# Validate Podman environment
validate_podman_environment() {
    log_info "Checking Podman environment..."

    local issues=0

    # Check Podman installation
    if ! command_exists podman; then
        log_error "Podman is not installed"
        return 1
    fi

    # Check Podman version
    local podman_version
    podman_version=$(podman --version 2>/dev/null | sed -n 's/.*version \([0-9]*\.[0-9]*\.[0-9]*\).*/\1/p' | head -1)
    log_info "Podman version: $podman_version"

    local major_version
    major_version=$(echo "$podman_version" | cut -d. -f1)
    local minor_version
    minor_version=$(echo "$podman_version" | cut -d. -f2)

    if [[ "$major_version" -lt 4 ]] || [[ "$major_version" -eq 4 && "$minor_version" -lt 4 ]]; then
        log_warning "Podman $podman_version detected. Quadlet requires 4.4+. Using legacy mode."
        ((issues++))
    fi

    # Check if Podman is working
    if ! podman info &>/dev/null; then
        log_error "Podman is not running properly"
        ((issues++))
    fi

    # Check for rootless setup
    if ! is_root; then
        log_info "Running in rootless mode"

        # Check subuid/subgid
        if [[ ! -f /etc/subuid ]] || ! grep -q "^$(whoami):" /etc/subuid; then
            log_warning "User may not have subuid range configured"
            ((issues++))
        fi

        if [[ ! -f /etc/subgid ]] || ! grep -q "^$(whoami):" /etc/subgid; then
            log_warning "User may not have subgid range configured"
            ((issues++))
        fi

        # Check user systemd
        if ! systemctl --user status &>/dev/null; then
            log_warning "User systemd is not running. Enable with: loginctl enable-linger $USER"
            ((issues++))
        fi
    fi

    # Check cgroups
    if [[ -f /sys/fs/cgroup/cgroup.controllers ]]; then
        log_info "cgroups v2 detected (recommended)"
    else
        log_warning "cgroups v1 detected. Consider upgrading to cgroups v2 for better performance."
    fi

    if [[ $issues -eq 0 ]]; then
        log_success "Podman environment is ready!"
    else
        log_warning "Found $issues potential issues. Migration may still work but with limitations."
    fi

    return 0
}

# Post-migration verification
verify_migration() {
    local project_name="$1"
    local mode="${2:-user}"

    log_info "Verifying migration for project: $project_name"

    local quadlet_dir
    quadlet_dir=$(get_quadlet_dir "$mode")

    # Check if Quadlet files exist
    local container_files
    container_files=$(find "$quadlet_dir" -name "${project_name}*.container" 2>/dev/null | wc -l)

    if [[ "$container_files" -eq 0 ]]; then
        log_error "No container files found for project: $project_name"
        return 1
    fi

    log_info "Found $container_files container file(s)"

    # Check systemd unit generation
    if [[ "$mode" == "user" ]]; then
        systemctl --user daemon-reload
        local units
        units=$(systemctl --user list-unit-files "${project_name}*.service" 2>/dev/null | grep -c ".service")
        log_info "Generated $units systemd unit(s)"
    fi

    log_success "Migration verification complete!"
    return 0
}

# Check health of running containers for a project
check_containers_health() {
    local project_name="$1"

    log_info "Checking health of containers for project: $project_name"

    local containers
    containers=$(podman ps --filter "name=${project_name}" --format "{{.Names}}" 2>/dev/null)

    if [[ -z "$containers" ]]; then
        log_warning "No running containers found for project: $project_name"
        return 1
    fi

    local healthy=0
    local unhealthy=0
    local starting=0
    local no_healthcheck=0

    while IFS= read -r container; do
        [[ -z "$container" ]] && continue

        local health_status
        health_status=$(podman inspect "$container" --format '{{.State.Health.Status}}' 2>/dev/null)

        case "$health_status" in
            healthy)
                log_success "$container: healthy"
                ((healthy++))
                ;;
            unhealthy)
                log_error "$container: unhealthy"
                ((unhealthy++))
                # Show last health check log
                local last_log
                last_log=$(podman inspect "$container" --format '{{range .State.Health.Log}}{{.Output}}{{end}}' 2>/dev/null | tail -1)
                [[ -n "$last_log" ]] && log_info "  Last check output: $last_log"
                ;;
            starting)
                log_warning "$container: starting (health check in progress)"
                ((starting++))
                ;;
            *)
                log_info "$container: no health check configured"
                ((no_healthcheck++))
                ;;
        esac
    done <<< "$containers"

    echo ""
    log_info "=== Health Summary ==="
    log_info "Healthy: $healthy"
    [[ $unhealthy -gt 0 ]] && log_error "Unhealthy: $unhealthy"
    [[ $starting -gt 0 ]] && log_warning "Starting: $starting"
    log_info "No healthcheck: $no_healthcheck"

    if [[ $unhealthy -gt 0 ]]; then
        return 1
    fi
    return 0
}

# Validate that all required ports are available
validate_ports_available() {
    local file="$1"
    local conflicts=0

    log_info "Checking port availability..."

    local services
    services=$(get_services "$file")

    while IFS= read -r service; do
        [[ -z "$service" ]] && continue

        local ports
        ports=$(get_service_ports "$file" "$service")

        while IFS= read -r port; do
            [[ -z "$port" ]] && continue

            local host_port
            if [[ "$port" =~ : ]]; then
                host_port=$(echo "$port" | cut -d: -f1)
            else
                host_port="$port"
            fi
            host_port="${host_port%/*}"

            if [[ "$host_port" =~ ^[0-9]+$ ]]; then
                # Check if port is in use
                if command_exists lsof; then
                    if lsof -i :"$host_port" &>/dev/null; then
                        log_warning "Port $host_port is already in use (service: $service)"
                        ((conflicts++))
                    fi
                elif command_exists ss; then
                    if ss -tuln | grep -q ":${host_port} " 2>/dev/null; then
                        log_warning "Port $host_port is already in use (service: $service)"
                        ((conflicts++))
                    fi
                fi
            fi
        done <<< "$ports"
    done <<< "$services"

    if [[ $conflicts -eq 0 ]]; then
        log_success "All required ports are available"
    else
        log_warning "Found $conflicts port conflict(s)"
    fi

    return $conflicts
}
