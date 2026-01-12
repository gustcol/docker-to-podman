#!/bin/bash
# performance.sh - Performance tuning and optimization for Podman

# Guard against multiple loading
[[ -n "${_PERFORMANCE_LOADED:-}" ]] && return 0
_PERFORMANCE_LOADED=1

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -z "${_UTILS_LOADED:-}" ]] && source "$_LIB_DIR/utils.sh"

# Performance recommendations storage
declare -a PERF_RECOMMENDATIONS

# Reset recommendations
reset_recommendations() {
    PERF_RECOMMENDATIONS=()
}

# Add recommendation
add_recommendation() {
    local category="$1"
    local message="$2"
    local command="$3"

    PERF_RECOMMENDATIONS+=("[$category] $message|$command")
}

# Check system performance settings
check_system_performance() {
    log_info "Analyzing system for performance optimizations..."

    reset_recommendations

    check_cgroups_version
    check_storage_driver
    check_network_performance
    check_rootless_optimizations
    check_kernel_parameters
    check_container_runtime

    print_recommendations
}

# Check cgroups version
check_cgroups_version() {
    if [[ -f /sys/fs/cgroup/cgroup.controllers ]]; then
        log_info "cgroups v2: Enabled (optimal)"
    else
        add_recommendation "CGROUPS" \
            "Upgrade to cgroups v2 for better resource control" \
            "Add 'systemd.unified_cgroup_hierarchy=1' to kernel cmdline"
    fi
}

# Check storage driver
check_storage_driver() {
    local storage_driver
    storage_driver=$(podman info --format '{{.Store.GraphDriverName}}' 2>/dev/null)

    case "$storage_driver" in
        overlay)
            log_info "Storage driver: overlay (optimal)"

            # Check for native overlay diff
            local native_diff
            native_diff=$(podman info --format '{{.Store.GraphOptions}}' 2>/dev/null | grep -c "native")

            if [[ "$native_diff" -eq 0 ]]; then
                add_recommendation "STORAGE" \
                    "Enable native overlay diff for faster layer operations" \
                    "Add 'overlay.mountopt=nodev,metacopy=on' to storage.conf"
            fi
            ;;
        vfs)
            add_recommendation "STORAGE" \
                "VFS driver is slow. Use overlay if possible" \
                "Set driver = \"overlay\" in /etc/containers/storage.conf"
            ;;
        *)
            log_info "Storage driver: $storage_driver"
            ;;
    esac
}

# Check network performance
check_network_performance() {
    if ! is_root; then
        # Check for pasta (faster than slirp4netns)
        if command_exists pasta; then
            log_info "Network: pasta available (optimal for rootless)"
        else
            add_recommendation "NETWORK" \
                "Install pasta for better rootless network performance" \
                "dnf install passt OR apt install passt"
        fi

        # Check slirp4netns options
        local network_cmd
        network_cmd=$(podman info --format '{{.Host.NetworkBackend}}' 2>/dev/null)

        if [[ "$network_cmd" == "netavark" ]]; then
            log_info "Network backend: netavark (optimal)"
        else
            add_recommendation "NETWORK" \
                "Use netavark for better network performance" \
                "Set network_backend = \"netavark\" in containers.conf"
        fi
    fi
}

# Check rootless optimizations
check_rootless_optimizations() {
    if is_root; then
        return
    fi

    log_info "Checking rootless optimizations..."

    # Check subuid/subgid range
    local subuid_count=0
    if [[ -f /etc/subuid ]]; then
        subuid_count=$(grep "^$(whoami):" /etc/subuid | cut -d: -f3)
    fi

    if [[ "$subuid_count" -lt 65536 ]]; then
        add_recommendation "ROOTLESS" \
            "Increase subuid range for better compatibility" \
            "usermod --add-subuids 100000-165535 --add-subgids 100000-165535 \$(whoami)"
    fi

    # Check user namespaces
    local user_ns_max
    user_ns_max=$(sysctl -n user.max_user_namespaces 2>/dev/null || echo "0")

    if [[ "$user_ns_max" -lt 15000 ]]; then
        add_recommendation "ROOTLESS" \
            "Increase max user namespaces" \
            "sysctl -w user.max_user_namespaces=15000"
    fi

    # Check for lingering enabled
    if ! loginctl show-user "$(whoami)" 2>/dev/null | grep -q "Linger=yes"; then
        add_recommendation "ROOTLESS" \
            "Enable lingering for user services to persist after logout" \
            "loginctl enable-linger \$(whoami)"
    fi
}

# Check kernel parameters
check_kernel_parameters() {
    log_info "Checking kernel parameters..."

    # Check inotify limits
    local inotify_max
    inotify_max=$(sysctl -n fs.inotify.max_user_watches 2>/dev/null || echo "0")

    if [[ "$inotify_max" -lt 524288 ]]; then
        add_recommendation "KERNEL" \
            "Increase inotify watches for better file monitoring" \
            "sysctl -w fs.inotify.max_user_watches=524288"
    fi

    # Check unprivileged port access
    local unpriv_port_start
    unpriv_port_start=$(sysctl -n net.ipv4.ip_unprivileged_port_start 2>/dev/null || echo "1024")

    if [[ "$unpriv_port_start" -gt 80 ]] && ! is_root; then
        add_recommendation "KERNEL" \
            "Allow rootless containers to bind to privileged ports" \
            "sysctl -w net.ipv4.ip_unprivileged_port_start=80"
    fi

    # Check ARP table size
    local arp_gc_thresh3
    arp_gc_thresh3=$(sysctl -n net.ipv4.neigh.default.gc_thresh3 2>/dev/null || echo "0")

    if [[ "$arp_gc_thresh3" -lt 4096 ]]; then
        add_recommendation "KERNEL" \
            "Increase ARP table size for many containers" \
            "sysctl -w net.ipv4.neigh.default.gc_thresh3=4096"
    fi
}

# Check container runtime
check_container_runtime() {
    log_info "Checking container runtime..."

    # Check OCI runtime
    local oci_runtime
    oci_runtime=$(podman info --format '{{.Host.OCIRuntime.Name}}' 2>/dev/null)

    case "$oci_runtime" in
        crun)
            log_info "OCI runtime: crun (optimal, written in C)"
            ;;
        runc)
            add_recommendation "RUNTIME" \
                "Consider using crun for better performance" \
                "dnf install crun OR apt install crun"
            ;;
        *)
            log_info "OCI runtime: $oci_runtime"
            ;;
    esac

    # Check conmon version
    local conmon_version
    conmon_version=$(podman info --format '{{.Host.Conmon.Version}}' 2>/dev/null)
    log_info "Conmon version: $conmon_version"
}

# Print recommendations
print_recommendations() {
    echo ""
    log_info "=== Performance Recommendations ==="
    echo ""

    if [[ ${#PERF_RECOMMENDATIONS[@]} -eq 0 ]]; then
        log_success "No performance improvements needed. System is optimized!"
        return 0
    fi

    log_warning "Found ${#PERF_RECOMMENDATIONS[@]} recommendation(s):"
    echo ""

    for rec in "${PERF_RECOMMENDATIONS[@]}"; do
        local message="${rec%%|*}"
        local command="${rec#*|}"

        echo "  $message"
        if [[ -n "$command" && "$command" != "$message" ]]; then
            echo "    Command: $command"
        fi
        echo ""
    done
}

# Apply performance optimizations
apply_optimizations() {
    local scope="${1:-user}"

    log_info "Applying performance optimizations..."

    # Create containers.conf if it doesn't exist
    local conf_dir
    if [[ "$scope" == "system" ]]; then
        conf_dir="/etc/containers"
    else
        conf_dir="${HOME}/.config/containers"
    fi

    mkdir -p "$conf_dir"

    local conf_file="$conf_dir/containers.conf"

    if [[ ! -f "$conf_file" ]]; then
        cat > "$conf_file" << 'EOF'
# Podman containers configuration
# Optimized by docker-to-podman migration tool

[containers]
# Use cgroup v2 features
cgroups = "enabled"

# Default ulimits
default_ulimits = [
  "nofile=65535:65535",
]

# Logging
log_driver = "journald"

[engine]
# Use crun for better performance
runtime = "crun"

# Network backend
network_backend = "netavark"

# Events logger
events_logger = "journald"

[network]
# DNS settings
default_network = "podman"
EOF
        log_success "Created optimized containers.conf: $conf_file"
    else
        log_info "containers.conf already exists: $conf_file"
    fi

    # Create storage.conf optimizations
    local storage_file="$conf_dir/storage.conf"

    if [[ ! -f "$storage_file" ]]; then
        cat > "$storage_file" << 'EOF'
# Podman storage configuration
# Optimized by docker-to-podman migration tool

[storage]
driver = "overlay"

[storage.options]
# Optimize overlay
mount_program = "/usr/bin/fuse-overlayfs"

[storage.options.overlay]
# Enable metacopy for faster layer operations
mountopt = "nodev,metacopy=on"
EOF
        log_success "Created optimized storage.conf: $storage_file"
    else
        log_info "storage.conf already exists: $storage_file"
    fi

    log_success "Performance optimizations applied!"
}

# Generate sysctl configuration
generate_sysctl_config() {
    local output_file="${1:-/tmp/podman-sysctl.conf}"

    cat > "$output_file" << 'EOF'
# Podman performance optimizations
# Generated by docker-to-podman migration tool
# Copy to /etc/sysctl.d/99-podman.conf and run: sysctl --system

# Allow rootless containers to use privileged ports
net.ipv4.ip_unprivileged_port_start=80

# Increase inotify watches
fs.inotify.max_user_watches=524288
fs.inotify.max_user_instances=512

# Increase user namespaces
user.max_user_namespaces=15000

# Network tuning for many containers
net.ipv4.neigh.default.gc_thresh1=4096
net.ipv4.neigh.default.gc_thresh2=8192
net.ipv4.neigh.default.gc_thresh3=16384

# Connection tracking for NAT
net.netfilter.nf_conntrack_max=262144
EOF

    log_success "Generated sysctl configuration: $output_file"
    log_info "To apply: sudo cp $output_file /etc/sysctl.d/99-podman.conf && sudo sysctl --system"
}

# Check and report resource usage
report_resource_usage() {
    log_info "=== Current Resource Usage ==="
    echo ""

    # Podman system info
    log_info "Podman storage:"
    podman system df 2>/dev/null || log_warning "Could not get storage info"

    echo ""

    # Running containers
    log_info "Running containers:"
    podman ps --format "table {{.Names}}\t{{.Status}}\t{{.Size}}" 2>/dev/null || log_warning "Could not list containers"

    echo ""

    # Images
    log_info "Images:"
    podman images --format "table {{.Repository}}:{{.Tag}}\t{{.Size}}" 2>/dev/null | head -10

    echo ""
}

# Cleanup unused resources
cleanup_resources() {
    log_info "Cleaning up unused Podman resources..."

    # Remove stopped containers
    podman container prune -f 2>/dev/null
    log_info "Removed stopped containers"

    # Remove unused images
    podman image prune -f 2>/dev/null
    log_info "Removed dangling images"

    # Remove unused volumes
    podman volume prune -f 2>/dev/null
    log_info "Removed unused volumes"

    # Remove unused networks
    podman network prune -f 2>/dev/null
    log_info "Removed unused networks"

    # Report disk space freed
    log_success "Cleanup complete!"
    podman system df 2>/dev/null
}
