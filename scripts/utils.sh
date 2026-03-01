#!/bin/bash
# utils.sh - Common utility functions for docker-to-podman migration tool

# Guard against multiple loading
[[ -n "${_UTILS_LOADED:-}" ]] && return 0
_UTILS_LOADED=1

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_debug() {
    if [[ "${DEBUG:-0}" == "1" ]]; then
        echo -e "${CYAN}[DEBUG]${NC} $1"
    fi
}

# Check if a command exists
command_exists() {
    command -v "$1" &> /dev/null
}

# Check required dependencies
check_dependencies() {
    local missing=()

    if ! command_exists podman; then
        missing+=("podman")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required dependencies: ${missing[*]}"
        log_info "Please install the missing dependencies and try again."
        return 1
    fi

    # Check podman version
    local podman_version
    podman_version=$(podman --version 2>/dev/null | sed -n 's/.*version \([0-9]*\.[0-9]*\).*/\1/p' | head -1)
    local major_version
    major_version=$(echo "$podman_version" | cut -d. -f1)
    local minor_version
    minor_version=$(echo "$podman_version" | cut -d. -f2)

    if [[ -z "$podman_version" ]]; then
        log_warning "Could not determine Podman version"
    elif [[ "$major_version" -lt 4 ]] || [[ "$major_version" -eq 4 && "$minor_version" -lt 4 ]]; then
        log_warning "Podman version $podman_version detected. Quadlet requires Podman 4.4+."
        log_warning "Some features may not work correctly."
    else
        log_info "Podman version $podman_version detected - Quadlet support available"
    fi

    # Check for yq (optional but recommended)
    if command_exists yq; then
        log_debug "yq found - using for YAML parsing"
        export USE_YQ=1
    else
        log_debug "yq not found - using fallback parser"
        export USE_YQ=0
    fi

    return 0
}

# Create backup of existing files
create_backup() {
    local file="$1"
    local backup_dir="${2:-./backup}"

    if [[ -f "$file" ]]; then
        mkdir -p "$backup_dir"
        local backup_name
        backup_name="$(basename "$file").$(date +%Y%m%d_%H%M%S).bak"
        cp "$file" "$backup_dir/$backup_name"
        log_debug "Backed up $file to $backup_dir/$backup_name"
    fi
}

# Sanitize service name for systemd
sanitize_service_name() {
    local name="$1"
    # Replace invalid characters with dash, remove leading/trailing dashes
    echo "$name" | sed 's/[^a-zA-Z0-9_-]/-/g' | sed 's/^-*//' | sed 's/-*$//'
}

# Convert docker image reference to be podman-friendly
normalize_image() {
    local image="$1"

    # If image doesn't contain a registry, prepend docker.io
    if [[ ! "$image" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]+/ ]] && [[ ! "$image" =~ ^localhost/ ]]; then
        # Check if it's an official image (no /)
        if [[ ! "$image" =~ / ]]; then
            echo "docker.io/library/$image"
        else
            echo "docker.io/$image"
        fi
    else
        echo "$image"
    fi
}

# Get the quadlet directory for the current user
get_quadlet_dir() {
    local user_mode="${1:-user}"

    if [[ "$user_mode" == "system" ]]; then
        echo "/etc/containers/systemd"
    else
        echo "${HOME}/.config/containers/systemd"
    fi
}

# Ensure quadlet directory exists
ensure_quadlet_dir() {
    local quadlet_dir
    quadlet_dir=$(get_quadlet_dir "$1")

    if [[ ! -d "$quadlet_dir" ]]; then
        mkdir -p "$quadlet_dir"
        log_info "Created Quadlet directory: $quadlet_dir"
    fi

    echo "$quadlet_dir"
}

# Convert memory string to bytes
parse_memory() {
    local mem="$1"
    local value
    local unit

    value="${mem//[^0-9.]/}"
    unit="${mem//[0-9.]/}"
    unit=$(printf '%s' "$unit" | tr '[:upper:]' '[:lower:]')

    # Truncate to integer for bash arithmetic (handles values like 1.5g)
    value="${value%%.*}"
    [[ -z "$value" ]] && value=0

    case "$unit" in
        b|"")   echo "$value" ;;
        k|kb)   echo "$((value * 1024))" ;;
        m|mb)   echo "$((value * 1024 * 1024))" ;;
        g|gb)   echo "$((value * 1024 * 1024 * 1024))" ;;
        *)      echo "$value" ;;
    esac
}

# Parse port mapping (host:container or just container)
parse_port() {
    local port="$1"
    local host_port=""
    local container_port=""
    local protocol="tcp"

    # Check for protocol suffix
    if [[ "$port" =~ /udp$ ]]; then
        protocol="udp"
        port="${port%/udp}"
    elif [[ "$port" =~ /tcp$ ]]; then
        port="${port%/tcp}"
    fi

    # Parse host:container
    if [[ "$port" =~ : ]]; then
        host_port=$(echo "$port" | cut -d: -f1)
        container_port=$(echo "$port" | cut -d: -f2)
    else
        container_port="$port"
        host_port="$port"
    fi

    echo "$host_port:$container_port/$protocol"
}

# Check if running as root
is_root() {
    [[ $EUID -eq 0 ]]
}

# Get project name from directory or compose file
get_project_name() {
    local compose_file="$1"
    local dir_name
    local base_name

    dir_name=$(dirname "$(realpath "$compose_file")")
    base_name=$(basename "$dir_name")
    sanitize_service_name "$base_name"
}

# Trim whitespace from string
trim() {
    local var="$*"
    var="${var#"${var%%[![:space:]]*}"}"
    var="${var%"${var##*[![:space:]]}"}"
    echo -n "$var"
}

# Check if string is a valid boolean
is_boolean() {
    local value
    value=$(echo "$1" | tr '[:upper:]' '[:lower:]')
    case "$value" in
        true|false|yes|no|1|0) return 0 ;;
        *) return 1 ;;
    esac
}

# Convert various boolean representations to true/false
to_boolean() {
    local value
    value=$(echo "$1" | tr '[:upper:]' '[:lower:]')
    case "$value" in
        true|yes|1) echo "true" ;;
        *) echo "false" ;;
    esac
}
