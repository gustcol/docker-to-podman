#!/bin/bash
# converter.sh - Docker to Podman conversion logic

# Guard against multiple loading
[[ -n "${_CONVERTER_LOADED:-}" ]] && return 0
_CONVERTER_LOADED=1

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -z "${_UTILS_LOADED:-}" ]] && source "$_LIB_DIR/utils.sh"
[[ -z "${_PARSER_LOADED:-}" ]] && source "$_LIB_DIR/parser.sh"
[[ -z "${_SELINUX_LOADED:-}" ]] && source "$_LIB_DIR/selinux.sh"

# Convert docker restart policy to systemd
convert_restart_policy() {
    local docker_restart="$1"

    case "$docker_restart" in
        "no"|"")
            echo "no"
            ;;
        "always")
            echo "always"
            ;;
        "unless-stopped")
            echo "always"  # Closest equivalent in systemd
            ;;
        "on-failure"*)
            echo "on-failure"
            ;;
        *)
            echo "no"
            ;;
    esac
}

# Convert docker volume mount to podman format
# Uses SELinux auto-detection and shared volume analysis to determine labels
# Args: $1 = volume, $2 = project_name, $3 = compose_file (optional)
convert_volume_mount() {
    local volume="$1"
    local project_name="$2"
    local compose_file="${3:-}"
    local source=""
    local target=""
    local options=""

    # Parse volume string (source:target:options)
    IFS=':' read -r source target options <<< "$volume"

    # Handle bind mounts vs named volumes
    if [[ "$source" == /* ]] || [[ "$source" == ./* ]] || [[ "$source" == ../* ]]; then
        # Bind mount - check if already has SELinux label
        if [[ ! "$options" =~ [Zz] ]]; then
            # Determine if volume is shared between containers
            local is_shared="false"
            if [[ -n "$compose_file" ]] && [[ -f "$compose_file" ]]; then
                if is_volume_shared "$compose_file" "$source" 2>/dev/null; then
                    is_shared="true"
                fi
            fi

            # Get SELinux label based on current mode/detection and sharing status
            local selinux_label
            selinux_label=$(get_selinux_label "$SELINUX_MODE" "$is_shared")

            # Add SELinux label if needed
            if [[ -n "$selinux_label" ]]; then
                if [[ -z "$options" ]]; then
                    options="${selinux_label#:}"  # Remove leading colon
                else
                    options="${options},${selinux_label#:}"
                fi
            fi
        fi

        if [[ -n "$options" ]]; then
            echo "${source}:${target}:${options}"
        else
            echo "${source}:${target}"
        fi
    else
        # Named volume - prefix with project name for isolation
        local vol_name="${project_name}_${source}"
        if [[ -n "$options" ]]; then
            echo "${vol_name}:${target}:${options}"
        else
            echo "${vol_name}:${target}"
        fi
    fi
}

# Convert docker network to podman format
convert_network() {
    local network="$1"
    local project_name="$2"

    # Prefix with project name for isolation
    echo "${project_name}_${network}"
}

# Convert docker health check to podman format
convert_healthcheck() {
    local file="$1"
    local service="$2"

    local test_cmd interval timeout retries start_period

    test_cmd=$(get_service_healthcheck "$file" "$service" "test")
    interval=$(get_service_healthcheck "$file" "$service" "interval")
    timeout=$(get_service_healthcheck "$file" "$service" "timeout")
    retries=$(get_service_healthcheck "$file" "$service" "retries")
    start_period=$(get_service_healthcheck "$file" "$service" "start_period")

    local cmd=""

    if [[ -n "$test_cmd" ]]; then
        # Handle array format
        test_cmd=$(echo "$test_cmd" | sed 's/^\[//' | sed 's/\]$//' | sed 's/"//g' | sed 's/,/ /g')
        # Remove CMD or CMD-SHELL prefix
        test_cmd=$(echo "$test_cmd" | sed 's/^CMD-SHELL //' | sed 's/^CMD //')
        cmd="--health-cmd=\"$test_cmd\""
    fi

    [[ -n "$interval" ]] && cmd="$cmd --health-interval=$interval"
    [[ -n "$timeout" ]] && cmd="$cmd --health-timeout=$timeout"
    [[ -n "$retries" ]] && cmd="$cmd --health-retries=$retries"
    [[ -n "$start_period" ]] && cmd="$cmd --health-start-period=$start_period"

    echo "$cmd"
}

# Convert service to podman run command
convert_to_podman_run() {
    local file="$1"
    local service="$2"
    local project_name="$3"

    local cmd="podman run -d"
    local container_name="${project_name}_${service}"

    cmd="$cmd --name $container_name"

    # Get service properties using getter functions
    local image ports volumes environment networks
    local memory cpus restart entrypoint command_str

    image=$(get_service_image "$file" "$service")
    if [[ -z "$image" ]]; then
        log_error "Service '$service' has no image defined"
        return 1
    fi
    image=$(normalize_image "$image")

    ports=$(get_service_ports "$file" "$service")
    volumes=$(get_service_volumes "$file" "$service")
    environment=$(get_service_environment "$file" "$service")
    networks=$(get_service_networks "$file" "$service")
    memory=$(get_service_resource "$file" "$service" "memory")
    cpus=$(get_service_resource "$file" "$service" "cpus")
    restart=$(get_service_restart "$file" "$service")
    entrypoint=$(get_service_entrypoint "$file" "$service")
    command_str=$(get_service_command "$file" "$service")

    # Ports
    while IFS= read -r port; do
        [[ -z "$port" ]] && continue
        local parsed_port
        parsed_port=$(parse_port "$port")
        cmd="$cmd -p $parsed_port"
    done <<< "$ports"

    # Volumes
    while IFS= read -r vol; do
        [[ -z "$vol" ]] && continue
        local converted_vol
        converted_vol=$(convert_volume_mount "$vol" "$project_name")
        cmd="$cmd -v $converted_vol"
    done <<< "$volumes"

    # Environment variables
    while IFS= read -r env; do
        [[ -z "$env" ]] && continue
        cmd="$cmd -e \"$env\""
    done <<< "$environment"

    # Networks
    while IFS= read -r net; do
        [[ -z "$net" ]] && continue
        local converted_net
        converted_net=$(convert_network "$net" "$project_name")
        cmd="$cmd --network $converted_net"
    done <<< "$networks"

    # Resource limits
    [[ -n "$memory" ]] && cmd="$cmd --memory=${memory}"
    [[ -n "$cpus" ]] && cmd="$cmd --cpus=${cpus}"

    # Restart policy
    local restart_policy
    restart_policy=$(convert_restart_policy "$restart")
    [[ "$restart_policy" != "no" ]] && cmd="$cmd --restart=$restart_policy"

    # Health check
    local healthcheck
    healthcheck=$(convert_healthcheck "$file" "$service")
    [[ -n "$healthcheck" ]] && cmd="$cmd $healthcheck"

    # Entrypoint
    [[ -n "$entrypoint" ]] && cmd="$cmd --entrypoint=\"${entrypoint}\""

    # Image
    cmd="$cmd $image"

    # Command
    [[ -n "$command_str" ]] && cmd="$cmd ${command_str}"

    echo "$cmd"
}

# Generate podman commands for all networks
generate_network_commands() {
    local file="$1"
    local project_name="$2"

    local networks
    networks=$(get_networks "$file")

    while IFS= read -r network; do
        [[ -z "$network" ]] && continue
        local net_name="${project_name}_${network}"
        local driver
        driver=$(get_network_driver "$file" "$network")

        echo "podman network create --driver $driver $net_name 2>/dev/null || true"
    done <<< "$networks"
}

# Generate podman commands for all volumes
generate_volume_commands() {
    local file="$1"
    local project_name="$2"

    local volumes
    volumes=$(get_volumes "$file")

    while IFS= read -r volume; do
        [[ -z "$volume" ]] && continue
        local vol_name="${project_name}_${volume}"

        echo "podman volume create $vol_name 2>/dev/null || true"
    done <<< "$volumes"
}

# Generate complete migration script
generate_migration_script() {
    local file="$1"
    local project_name="$2"
    local output_file="$3"

    cat > "$output_file" << 'HEADER'
#!/bin/bash
# Auto-generated Podman migration script
# Generated by docker-to-podman migration tool

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

HEADER

    echo "" >> "$output_file"
    echo "PROJECT_NAME=\"$project_name\"" >> "$output_file"
    echo "" >> "$output_file"

    # Stop function
    cat >> "$output_file" << 'STOP_FUNC'
stop_all() {
    log_info "Stopping all containers..."
STOP_FUNC

    local services
    services=$(get_services "$file")
    while IFS= read -r service; do
        [[ -z "$service" ]] && continue
        echo "    podman stop ${project_name}_${service} 2>/dev/null || true" >> "$output_file"
        echo "    podman rm ${project_name}_${service} 2>/dev/null || true" >> "$output_file"
    done <<< "$services"

    echo "}" >> "$output_file"
    echo "" >> "$output_file"

    # Start function
    cat >> "$output_file" << 'START_FUNC'
start_all() {
    log_info "Creating networks..."
START_FUNC

    # Networks
    generate_network_commands "$file" "$project_name" >> "$output_file"

    echo "" >> "$output_file"
    echo "    log_info \"Creating volumes...\"" >> "$output_file"

    # Volumes
    generate_volume_commands "$file" "$project_name" >> "$output_file"

    echo "" >> "$output_file"
    echo "    log_info \"Starting containers...\"" >> "$output_file"

    # Containers (respecting depends_on order)
    while IFS= read -r service; do
        [[ -z "$service" ]] && continue
        local run_cmd
        run_cmd=$(convert_to_podman_run "$file" "$service" "$project_name")
        echo "    $run_cmd" >> "$output_file"
    done <<< "$services"

    echo "}" >> "$output_file"
    echo "" >> "$output_file"

    # Main
    cat >> "$output_file" << 'MAIN'
case "${1:-start}" in
    start)
        start_all
        log_info "All containers started successfully!"
        ;;
    stop)
        stop_all
        log_info "All containers stopped."
        ;;
    restart)
        stop_all
        start_all
        log_info "All containers restarted."
        ;;
    *)
        echo "Usage: $0 {start|stop|restart}"
        exit 1
        ;;
esac
MAIN

    chmod +x "$output_file"
    log_success "Generated migration script: $output_file"
}
