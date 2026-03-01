#!/bin/bash
# selinux.sh - Comprehensive SELinux detection and configuration for Podman containers
# Part of docker-to-podman migration tool
#
# Features:
# - Auto-detection of SELinux status across multiple platforms
# - Automatic shared volume detection from compose files
# - Pre-migration volume validation
# - Automated remediation options
# - Per-volume SELinux mode support
# - Audit log analysis
# - Custom policy management

# Prevent multiple loading
[[ -n "${_SELINUX_LOADED:-}" ]] && return 0
_SELINUX_LOADED=1

# SELinux configuration
SELINUX_MODE="${SELINUX_MODE:-auto}"
SELINUX_AUTO_FIX="${SELINUX_AUTO_FIX:-false}"
SELINUX_VALIDATE_VOLUMES="${SELINUX_VALIDATE_VOLUMES:-true}"
SELINUX_VERBOSE="${SELINUX_VERBOSE:-false}"

# Cache for SELinux status (performance optimization)
_SELINUX_STATUS_CACHE=""

# Valid SELinux types for containers
readonly SELINUX_CONTAINER_TYPES=(
    "container_file_t"
    "svirt_sandbox_file_t"
    "container_share_t"
    "container_var_lib_t"
    "container_log_t"
    "container_runtime_t"
)

# =============================================================================
# INPUT VALIDATION AND SANITIZATION (SECURITY CRITICAL)
# =============================================================================

# Validate path to prevent command injection
# Returns 0 if valid, 1 if invalid
validate_path_safe() {
    local path="$1"

    # Reject empty paths
    if [[ -z "$path" ]]; then
        log_error "Empty path provided" 2>/dev/null || echo "[ERROR] Empty path provided" >&2
        return 1
    fi

    # Reject paths with dangerous characters that could enable command injection
    # Check for shell metacharacters one by one to avoid regex issues across shells
    # Semicolon - command separator
    if [[ "$path" == *";"* ]]; then
        log_error "Path contains semicolon: $path" 2>/dev/null || echo "[ERROR] Path contains dangerous characters" >&2
        return 1
    fi
    # Pipe - command piping
    if [[ "$path" == *"|"* ]]; then
        log_error "Path contains pipe: $path" 2>/dev/null || echo "[ERROR] Path contains dangerous characters" >&2
        return 1
    fi
    # Ampersand - background execution
    if [[ "$path" == *"&"* ]]; then
        log_error "Path contains ampersand: $path" 2>/dev/null || echo "[ERROR] Path contains dangerous characters" >&2
        return 1
    fi
    # Dollar sign - variable expansion
    if [[ "$path" == *'$'* ]]; then
        log_error "Path contains dollar sign: $path" 2>/dev/null || echo "[ERROR] Path contains dangerous characters" >&2
        return 1
    fi
    # Backtick - command substitution
    if [[ "$path" == *'`'* ]]; then
        log_error "Path contains backtick: $path" 2>/dev/null || echo "[ERROR] Path contains dangerous characters" >&2
        return 1
    fi
    # Backslash - escape character (can be used for injection)
    if [[ "$path" == *'\\'* ]]; then
        log_error "Path contains backslash: $path" 2>/dev/null || echo "[ERROR] Path contains dangerous characters" >&2
        return 1
    fi
    # Newline - command separator
    if [[ "$path" == *$'\n'* ]]; then
        log_error "Path contains newline" 2>/dev/null || echo "[ERROR] Path contains dangerous characters" >&2
        return 1
    fi
    # Carriage return
    if [[ "$path" == *$'\r'* ]]; then
        log_error "Path contains carriage return" 2>/dev/null || echo "[ERROR] Path contains dangerous characters" >&2
        return 1
    fi
    # Note: Null bytes cannot exist in bash variables (bash uses null-terminated strings)
    # So we don't need to check for them - they would truncate the string before reaching here

    return 0
}

# Validate SELinux type name
validate_selinux_type() {
    local type="$1"

    # SELinux types must be alphanumeric with underscores
    if [[ ! "$type" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
        log_error "Invalid SELinux type: $type" 2>/dev/null || echo "[ERROR] Invalid SELinux type" >&2
        return 1
    fi

    # Max length check (SELinux type names have limits)
    if [[ ${#type} -gt 64 ]]; then
        log_error "SELinux type too long: $type" 2>/dev/null || echo "[ERROR] SELinux type too long" >&2
        return 1
    fi

    return 0
}

# Validate MCS/MLS level
validate_selinux_level() {
    local level="$1"

    # MCS level format: s0, s0:c0, s0:c0,c1, s0:c0.c1023
    if [[ ! "$level" =~ ^s[0-9]+(:[cC][0-9]+([.,][cC]?[0-9]+)*)?$ ]]; then
        log_error "Invalid SELinux level: $level" 2>/dev/null || echo "[ERROR] Invalid SELinux level" >&2
        return 1
    fi

    return 0
}

# Validate SELinux user
validate_selinux_user() {
    local user="$1"

    # SELinux users: system_u, unconfined_u, user_u, staff_u, etc.
    if [[ ! "$user" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
        log_error "Invalid SELinux user: $user" 2>/dev/null || echo "[ERROR] Invalid SELinux user" >&2
        return 1
    fi

    return 0
}

# Validate SELinux role
validate_selinux_role() {
    local role="$1"

    # SELinux roles: system_r, unconfined_r, object_r, etc.
    if [[ ! "$role" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
        log_error "Invalid SELinux role: $role" 2>/dev/null || echo "[ERROR] Invalid SELinux role" >&2
        return 1
    fi

    return 0
}

# =============================================================================
# SELINUX BOOLEANS MANAGEMENT
# =============================================================================

# Required SELinux booleans for container operation
CONTAINER_SELINUX_BOOLEANS=(
    "container_manage_cgroup"          # Allow containers to manage cgroups
    "virt_sandbox_use_netlink"         # Allow netlink socket access
)

# Optional SELinux booleans
OPTIONAL_SELINUX_BOOLEANS=(
    "container_use_cephfs"             # Allow CephFS access
    "virt_use_nfs"                     # Allow NFS mounts
    "virt_use_samba"                   # Allow Samba mounts
    "container_connect_any"            # Allow unrestricted network connections
)

# Check SELinux booleans required for containers
check_selinux_booleans() {
    local status
    status=$(detect_selinux)

    if [[ "$status" != "enforcing" ]] && [[ "$status" != "permissive" ]]; then
        return 0
    fi

    if ! command -v getsebool &>/dev/null; then
        log_warning "getsebool not available, cannot check SELinux booleans" 2>/dev/null
        return 0
    fi

    local issues=0

    for bool in "${CONTAINER_SELINUX_BOOLEANS[@]}"; do
        local value
        value=$(getsebool "$bool" 2>/dev/null | awk '{print $3}')

        if [[ "$value" != "on" ]]; then
            log_warning "SELinux boolean '$bool' is off. Enable with: setsebool -P $bool on" 2>/dev/null
            ((issues++))
        fi
    done

    return $issues
}

# Get recommended SELinux booleans for a service
get_recommended_booleans() {
    local compose_file="$1"
    local service="$2"
    local booleans=()

    # Check if service uses network features
    local network_mode
    network_mode=$(get_service_network_mode "$compose_file" "$service" 2>/dev/null)
    if [[ "$network_mode" == "host" ]]; then
        booleans+=("virt_sandbox_use_netlink")
    fi

    # Check if service needs cgroup management
    local privileged
    privileged=$(get_service_privileged "$compose_file" "$service" 2>/dev/null)
    if [[ "$privileged" == "true" ]]; then
        booleans+=("container_manage_cgroup")
    fi

    printf '%s\n' "${booleans[@]}"
}

# =============================================================================
# SELINUX PORT LABELING
# =============================================================================

# Validate if a port has proper SELinux label for containers
validate_port_selinux() {
    local port="$1"
    local protocol="${2:-tcp}"

    # Validate port number first (always check regardless of SELinux status)
    if [[ ! "$port" =~ ^[0-9]+$ ]] || [[ $port -lt 1 ]] || [[ $port -gt 65535 ]]; then
        log_error "Invalid port number: $port" 2>/dev/null
        return 1
    fi

    if ! is_selinux_active; then
        return 0
    fi

    if ! command -v semanage &>/dev/null; then
        return 0
    fi

    # Check if port is in container-allowed range
    local port_info
    port_info=$(semanage port -l 2>/dev/null | grep -E "\s${port}(/|,|\s|$)")

    if [[ -z "$port_info" ]]; then
        # Port not explicitly labeled - check if in ephemeral range
        if [[ $port -ge 32768 ]] && [[ $port -le 60999 ]]; then
            return 0  # Ephemeral ports typically work
        fi

        # Standard web ports
        if [[ $port -eq 80 ]] || [[ $port -eq 443 ]] || [[ $port -eq 8080 ]] || [[ $port -eq 8443 ]]; then
            return 0  # Usually allowed via http_port_t
        fi

        # Port may need labeling
        log_warning "Port $port may need SELinux label. Run: semanage port -a -t container_port_t -p $protocol $port" 2>/dev/null
        return 1
    fi

    return 0
}

# =============================================================================
# DETECTION FUNCTIONS
# =============================================================================

# Detect SELinux status with comprehensive platform support
# Returns: enforcing, permissive, disabled, not_installed, apparmor, wsl, macos
detect_selinux() {
    # Return cached result if available
    if [[ -n "$_SELINUX_STATUS_CACHE" ]]; then
        echo "$_SELINUX_STATUS_CACHE"
        return 0
    fi

    local status

    # Check for macOS (no SELinux)
    if [[ "$(uname -s)" == "Darwin" ]]; then
        status="macos"
        _SELINUX_STATUS_CACHE="$status"
        echo "$status"
        return 0
    fi

    # Check for WSL (Windows Subsystem for Linux)
    if grep -qi microsoft /proc/version 2>/dev/null || \
       grep -qi wsl /proc/version 2>/dev/null; then
        status="wsl"
        _SELINUX_STATUS_CACHE="$status"
        echo "$status"
        return 0
    fi

    # Check if getenforce command exists
    if ! command -v getenforce &>/dev/null; then
        # Check if it's a system with AppArmor instead (Ubuntu/Debian)
        if command -v aa-status &>/dev/null; then
            if aa-status --enabled 2>/dev/null; then
                status="apparmor"
            else
                status="not_installed"
            fi
        else
            status="not_installed"
        fi
        _SELINUX_STATUS_CACHE="$status"
        echo "$status"
        return 0
    fi

    # Get SELinux status
    status=$(getenforce 2>/dev/null | tr '[:upper:]' '[:lower:]')

    case "$status" in
        enforcing|permissive|disabled)
            _SELINUX_STATUS_CACHE="$status"
            echo "$status"
            ;;
        *)
            status="not_installed"
            _SELINUX_STATUS_CACHE="$status"
            echo "$status"
            ;;
    esac
}

# Check if SELinux is active (enforcing or permissive)
is_selinux_active() {
    local status
    status=$(detect_selinux)
    [[ "$status" == "enforcing" || "$status" == "permissive" ]]
}

# Check if the system requires SELinux labels
requires_selinux_labels() {
    local status
    status=$(detect_selinux)
    case "$status" in
        enforcing|permissive)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Get detailed SELinux information
get_selinux_info() {
    local info=""

    if ! is_selinux_active; then
        echo "SELinux is not active on this system"
        return 0
    fi

    # Get SELinux status
    info="Status: $(getenforce 2>/dev/null)\n"

    # Get SELinux policy type
    if [[ -f /etc/selinux/config ]]; then
        local policy_type
        policy_type=$(grep "^SELINUXTYPE=" /etc/selinux/config 2>/dev/null | cut -d= -f2)
        info+="Policy Type: ${policy_type:-unknown}\n"
    fi

    # Get current context
    if command -v id &>/dev/null; then
        local context
        context=$(id -Z 2>/dev/null)
        info+="Current Context: ${context:-unknown}\n"
    fi

    # Check for container-selinux package
    if command -v rpm &>/dev/null; then
        if rpm -q container-selinux &>/dev/null; then
            info+="container-selinux: $(rpm -q container-selinux)\n"
        else
            info+="container-selinux: NOT INSTALLED\n"
        fi
    fi

    echo -e "$info"
}

# =============================================================================
# LABEL MANAGEMENT FUNCTIONS
# =============================================================================

# Get the appropriate SELinux label for volume mounts
# Args: $1 = selinux_mode (auto, enforcing, disabled, shared, private)
#       $2 = is_shared (optional, true/false - if volume is shared between containers)
# Returns: :Z, :z, or empty string
get_selinux_label() {
    local mode="${1:-$SELINUX_MODE}"
    local is_shared="${2:-false}"

    case "$mode" in
        disabled|none|off)
            echo ""
            return 0
            ;;
        shared)
            echo ":z"
            return 0
            ;;
        private)
            echo ":Z"
            return 0
            ;;
        enforcing|force)
            if [[ "$is_shared" == "true" ]]; then
                echo ":z"
            else
                echo ":Z"
            fi
            return 0
            ;;
        auto|*)
            # Auto-detect based on system status
            local status
            status=$(detect_selinux)

            case "$status" in
                enforcing|permissive)
                    if [[ "$is_shared" == "true" ]]; then
                        echo ":z"
                    else
                        echo ":Z"
                    fi
                    ;;
                disabled|not_installed|apparmor|wsl|macos)
                    echo ""
                    ;;
                *)
                    echo ""
                    ;;
            esac
            ;;
    esac
}

# Get SELinux label for a specific volume path
# Args: $1 = volume_path, $2 = compose_file (optional), $3 = project_name (optional)
get_volume_selinux_label() {
    local volume_path="$1"
    local compose_file="${2:-}"
    local project_name="${3:-}"

    # Check if this is a shared volume
    local is_shared="false"
    if [[ -n "$compose_file" ]] && [[ -f "$compose_file" ]]; then
        if is_volume_shared "$compose_file" "$volume_path"; then
            is_shared="true"
        fi
    fi

    get_selinux_label "$SELINUX_MODE" "$is_shared"
}

# =============================================================================
# SHARED VOLUME DETECTION
# =============================================================================

# Detect if a volume is shared between multiple containers in compose file
# Args: $1 = compose_file, $2 = volume_path
# Returns: 0 if shared, 1 if not
is_volume_shared() {
    local compose_file="$1"
    local volume_path="$2"
    local count=0

    if [[ ! -f "$compose_file" ]]; then
        return 1
    fi

    # Normalize the volume path for comparison
    local normalized_path
    normalized_path=$(echo "$volume_path" | sed 's|^./||' | sed 's|^/||')

    # Count how many services use this volume
    if command -v yq &>/dev/null; then
        count=$(yq eval ".services[].volumes[]? | select(contains(\"${normalized_path}\")) | ." "$compose_file" 2>/dev/null | wc -l)
    else
        # Fallback: grep-based detection
        count=$(grep -E "^\s*-\s*['\"]?[./]*${normalized_path}" "$compose_file" 2>/dev/null | wc -l)
    fi

    [[ $count -gt 1 ]]
}

# Get all shared volumes from a compose file
# Args: $1 = compose_file
# Returns: list of shared volume paths
get_shared_volumes() {
    local compose_file="$1"
    local -A volume_count
    local shared_volumes=()

    if [[ ! -f "$compose_file" ]]; then
        return 0
    fi

    # Extract all volume mounts
    local volumes
    if command -v yq &>/dev/null; then
        volumes=$(yq eval '.services[].volumes[]?' "$compose_file" 2>/dev/null)
    else
        volumes=$(grep -E "^\s*-\s*['\"]?[./]" "$compose_file" 2>/dev/null | sed 's/^[[:space:]]*-[[:space:]]*//' | sed 's/['\''"]//g')
    fi

    # Count occurrences of each volume source
    while IFS= read -r vol; do
        [[ -z "$vol" ]] && continue
        local source
        source=$(echo "$vol" | cut -d: -f1)
        # Normalize path
        source=$(echo "$source" | sed 's|^./||' | sed 's|^/||')
        volume_count["$source"]=$((${volume_count["$source"]:-0} + 1))
    done <<< "$volumes"

    # Return volumes with count > 1
    for vol in "${!volume_count[@]}"; do
        if [[ ${volume_count["$vol"]} -gt 1 ]]; then
            shared_volumes+=("$vol")
        fi
    done

    printf '%s\n' "${shared_volumes[@]}"
}

# Analyze compose file and return volume sharing information
# Args: $1 = compose_file
analyze_volume_sharing() {
    local compose_file="$1"

    echo "=== Volume Sharing Analysis ==="
    echo ""

    if [[ ! -f "$compose_file" ]]; then
        echo "Error: Compose file not found: $compose_file"
        return 1
    fi

    local shared_volumes
    shared_volumes=$(get_shared_volumes "$compose_file")

    if [[ -z "$shared_volumes" ]]; then
        echo "No shared volumes detected."
        echo "All bind mounts can use :Z (private) label."
    else
        echo "Shared volumes detected (should use :z label):"
        echo ""
        while IFS= read -r vol; do
            [[ -z "$vol" ]] && continue
            echo "  - $vol"
        done <<< "$shared_volumes"
        echo ""
        echo "Recommendation: Use --selinux=shared for these volumes"
        echo "Or manually edit volume mounts to use :z instead of :Z"
    fi
}

# =============================================================================
# VOLUME VALIDATION
# =============================================================================

# Check if a path has the correct SELinux context for containers
# Args: $1 = path, $2 = expected_type (optional: container_file_t, container_share_t)
# Returns: 0 if correct, 1 if incorrect or not applicable
check_selinux_context() {
    local path="$1"
    local expected_type="${2:-}"

    # Check if SELinux is active
    if ! is_selinux_active; then
        return 0  # Not applicable
    fi

    # Check if path exists
    if [[ ! -e "$path" ]]; then
        return 0  # Can't check non-existent path
    fi

    # Get current context
    local context
    context=$(ls -Zd "$path" 2>/dev/null | awk '{print $1}')

    if [[ -z "$context" ]]; then
        return 1  # Can't determine context
    fi

    # Check if context contains valid container types
    if [[ -n "$expected_type" ]]; then
        # Check for specific type
        if [[ "$context" == *"$expected_type"* ]]; then
            return 0
        fi
        return 1
    else
        # Check for any valid container type
        for type in "${SELINUX_CONTAINER_TYPES[@]}"; do
            if [[ "$context" == *"$type"* ]]; then
                return 0
            fi
        done
        return 1
    fi
}

# Validate all volume paths in a compose file
# Args: $1 = compose_file
# Returns: 0 if all valid, 1 if any issues found
validate_compose_volumes() {
    local compose_file="$1"
    local has_issues=0
    local issues=()

    if [[ ! -f "$compose_file" ]]; then
        echo "Error: Compose file not found: $compose_file"
        return 1
    fi

    if ! is_selinux_active; then
        echo "SELinux is not active, skipping volume validation."
        return 0
    fi

    echo "=== SELinux Volume Validation ==="
    echo ""

    # Extract bind mount paths
    local volumes
    if command -v yq &>/dev/null; then
        volumes=$(yq eval '.services[].volumes[]?' "$compose_file" 2>/dev/null)
    else
        volumes=$(grep -E "^\s*-\s*['\"]?[./]" "$compose_file" 2>/dev/null | \
                  sed 's/^[[:space:]]*-[[:space:]]*//' | sed 's/['\''"]//g')
    fi

    while IFS= read -r vol; do
        [[ -z "$vol" ]] && continue

        local source
        source=$(echo "$vol" | cut -d: -f1)

        # Skip named volumes (don't start with . or /)
        if [[ ! "$source" =~ ^[./] ]]; then
            continue
        fi

        # Resolve relative paths
        local abs_path
        if [[ "$source" == ./* ]]; then
            abs_path="$(dirname "$compose_file")/${source#./}"
        elif [[ "$source" == /* ]]; then
            abs_path="$source"
        else
            abs_path="$(dirname "$compose_file")/$source"
        fi

        # Check if path exists
        if [[ ! -e "$abs_path" ]]; then
            echo "[WARNING] Path does not exist: $abs_path"
            issues+=("missing:$abs_path")
            has_issues=1
            continue
        fi

        # Check SELinux context
        if ! check_selinux_context "$abs_path"; then
            local current_context
            current_context=$(ls -Zd "$abs_path" 2>/dev/null | awk '{print $1}')
            echo "[WARNING] Incorrect SELinux context for: $abs_path"
            echo "          Current: $current_context"
            echo "          Expected: container_file_t or container_share_t"
            issues+=("context:$abs_path")
            has_issues=1
        else
            echo "[OK] $abs_path"
        fi
    done <<< "$volumes"

    echo ""

    if [[ $has_issues -eq 1 ]]; then
        echo "=== Issues Found ==="
        echo ""
        echo "Run './migrate.sh selinux-fix' to automatically fix these issues"
        echo "Or use the following manual commands:"
        echo ""
        for issue in "${issues[@]}"; do
            local type="${issue%%:*}"
            local path="${issue#*:}"
            case "$type" in
                missing)
                    echo "  mkdir -p '$path'"
                    ;;
                context)
                    echo "  chcon -Rt container_file_t '$path'"
                    ;;
            esac
        done
        return 1
    fi

    echo "All volume paths have correct SELinux contexts."
    return 0
}

# =============================================================================
# REMEDIATION FUNCTIONS
# =============================================================================

# Suggest SELinux fix commands for a path
# Args: $1 = path, $2 = shared (optional: true/false)
# SECURITY: This function outputs commands that users might execute
#           Path validation and proper escaping is critical
suggest_selinux_fix() {
    local path="$1"
    local shared="${2:-false}"

    # SECURITY: Validate path before suggesting commands
    if ! validate_path_safe "$path"; then
        echo "Error: Invalid path (security validation failed)" >&2
        return 1
    fi

    if ! is_selinux_active; then
        return 0
    fi

    # SECURITY: Properly escape path for shell commands
    # Use printf %q for proper shell escaping
    local escaped_path
    escaped_path=$(printf '%q' "$path")

    echo "=== SELinux Fix Suggestions for: $path ==="
    echo ""

    if [[ "$shared" == "true" ]]; then
        echo "For SHARED volumes (multiple containers access):"
        echo ""
        echo "  Temporary fix (lost on relabel):"
        echo "    chcon -Rt container_share_t -- $escaped_path"
        echo ""
        echo "  Permanent fix:"
        echo "    semanage fcontext -a -t container_share_t '${path}(/.*)?'"
        echo "    restorecon -Rv -- $escaped_path"
        echo ""
        echo "  Volume mount option:"
        echo "    Use :z (lowercase) in volume mount"
    else
        echo "For PRIVATE volumes (single container access):"
        echo ""
        echo "  Temporary fix (lost on relabel):"
        echo "    chcon -Rt container_file_t -- $escaped_path"
        echo ""
        echo "  Permanent fix:"
        echo "    semanage fcontext -a -t container_file_t '${path}(/.*)?'"
        echo "    restorecon -Rv -- $escaped_path"
        echo ""
        echo "  Volume mount option:"
        echo "    Use :Z (uppercase) in volume mount"
    fi
}

# Apply SELinux fixes to a path
# Args: $1 = path, $2 = shared (optional: true/false), $3 = permanent (optional: true/false)
# SECURITY: This function executes system commands (chcon, semanage, restorecon)
#           All inputs MUST be validated to prevent command injection
apply_selinux_fix() {
    local path="$1"
    local shared="${2:-false}"
    local permanent="${3:-false}"

    # SECURITY: Validate path to prevent command injection
    if ! validate_path_safe "$path"; then
        echo "Error: Invalid path (security validation failed): $path" >&2
        return 1
    fi

    if ! is_selinux_active; then
        echo "SELinux is not active, no fixes needed."
        return 0
    fi

    # Resolve to absolute path and verify existence
    local abs_path
    abs_path=$(realpath -e "$path" 2>/dev/null)
    if [[ -z "$abs_path" ]] || [[ ! -e "$abs_path" ]]; then
        echo "Error: Path does not exist: $path"
        return 1
    fi

    # SECURITY: Re-validate resolved path
    if ! validate_path_safe "$abs_path"; then
        echo "Error: Resolved path failed security validation" >&2
        return 1
    fi

    local context_type
    if [[ "$shared" == "true" ]]; then
        context_type="container_share_t"
    else
        context_type="container_file_t"
    fi

    # SECURITY: Validate context type
    if ! validate_selinux_type "$context_type"; then
        echo "Error: Invalid SELinux type" >&2
        return 1
    fi

    echo "Applying SELinux fix to: $abs_path"
    echo "  Type: $context_type"
    echo "  Permanent: $permanent"
    echo ""

    # SECURITY: Use -- to prevent option injection
    # Apply temporary fix
    if ! chcon -Rt "$context_type" -- "$abs_path" 2>/dev/null; then
        echo "Error: Failed to set SELinux context"
        echo "       You may need to run this as root"
        return 1
    fi

    echo "  [OK] Applied temporary context"

    # Apply permanent fix if requested
    if [[ "$permanent" == "true" ]]; then
        if command -v semanage &>/dev/null; then
            # SECURITY: Escape path for regex pattern (semanage uses regex)
            local escaped_path
            escaped_path=$(printf '%s' "$abs_path" | sed 's/[.[\*^$()+?{|]/\\&/g')

            if semanage fcontext -a -t "$context_type" "${escaped_path}(/.*)?" 2>/dev/null; then
                echo "  [OK] Added persistent fcontext rule"
                # SECURITY: Use -- to prevent option injection
                if restorecon -Rv -- "$abs_path" 2>/dev/null; then
                    echo "  [OK] Restored contexts"
                fi
            else
                echo "  [WARNING] Failed to add persistent rule (may already exist)"
            fi
        else
            echo "  [WARNING] semanage not found, permanent fix not applied"
            echo "            Install policycoreutils-python-utils package"
        fi
    fi

    return 0
}

# Fix all volumes in a compose file
# Args: $1 = compose_file, $2 = permanent (optional: true/false)
# SECURITY: This function processes paths from YAML files and creates directories
#           All paths MUST be validated before any filesystem operations
fix_compose_volumes() {
    local compose_file="$1"
    local permanent="${2:-false}"

    # SECURITY: Validate compose file path
    if ! validate_path_safe "$compose_file"; then
        echo "Error: Invalid compose file path (security validation failed)" >&2
        return 1
    fi

    if [[ ! -f "$compose_file" ]]; then
        echo "Error: Compose file not found: $compose_file"
        return 1
    fi

    if ! is_selinux_active; then
        echo "SELinux is not active, no fixes needed."
        return 0
    fi

    echo "=== Applying SELinux Fixes ==="
    echo "Compose file: $compose_file"
    echo "Permanent: $permanent"
    echo ""

    # Get shared volumes
    local shared_volumes
    shared_volumes=$(get_shared_volumes "$compose_file")

    # Extract bind mount paths
    local volumes
    if command -v yq &>/dev/null; then
        volumes=$(yq eval '.services[].volumes[]?' "$compose_file" 2>/dev/null)
    else
        volumes=$(grep -E "^\s*-\s*['\"]?[./]" "$compose_file" 2>/dev/null | \
                  sed 's/^[[:space:]]*-[[:space:]]*//' | sed 's/['\''"]//g')
    fi

    local fixed=0
    local failed=0
    local skipped=0

    while IFS= read -r vol; do
        [[ -z "$vol" ]] && continue

        local source
        source=$(echo "$vol" | cut -d: -f1)

        # Skip named volumes
        if [[ ! "$source" =~ ^[./] ]]; then
            continue
        fi

        # SECURITY: Validate volume source path before processing
        if ! validate_path_safe "$source"; then
            echo "  [SKIPPED] Volume path failed security validation: $source" >&2
            ((skipped++))
            continue
        fi

        # Resolve path
        local abs_path
        if [[ "$source" == ./* ]]; then
            abs_path="$(dirname "$compose_file")/${source#./}"
        elif [[ "$source" == /* ]]; then
            abs_path="$source"
        else
            abs_path="$(dirname "$compose_file")/$source"
        fi

        # SECURITY: Validate resolved absolute path
        if ! validate_path_safe "$abs_path"; then
            echo "  [SKIPPED] Resolved path failed security validation" >&2
            ((skipped++))
            continue
        fi

        # Check if shared
        local is_shared="false"
        local normalized_source
        normalized_source=$(echo "$source" | sed 's|^./||' | sed 's|^/||')
        if echo "$shared_volumes" | grep -q "^${normalized_source}$"; then
            is_shared="true"
        fi

        # SECURITY: Create directory if doesn't exist (using validated path)
        if [[ ! -e "$abs_path" ]]; then
            echo "Creating directory: $abs_path"
            # Use -- to prevent option injection
            mkdir -p -- "$abs_path" 2>/dev/null || {
                echo "  [FAILED] Could not create directory"
                ((failed++))
                continue
            }
        fi

        # Apply fix (apply_selinux_fix has its own validation)
        if apply_selinux_fix "$abs_path" "$is_shared" "$permanent"; then
            ((fixed++))
        else
            ((failed++))
        fi
        echo ""
    done <<< "$volumes"

    echo "=== Summary ==="
    echo "Fixed: $fixed"
    echo "Failed: $failed"
    [[ $skipped -gt 0 ]] && echo "Skipped (security): $skipped"

    [[ $failed -eq 0 ]] && [[ $skipped -eq 0 ]]
}

# =============================================================================
# AUDIT LOG ANALYSIS
# =============================================================================

# Check for recent SELinux denials related to containers
# Args: $1 = minutes (optional, default: 60)
check_selinux_denials() {
    local minutes="${1:-60}"

    if ! is_selinux_active; then
        echo "SELinux is not active."
        return 0
    fi

    echo "=== Recent SELinux Denials (last ${minutes} minutes) ==="
    echo ""

    # Try ausearch first
    if command -v ausearch &>/dev/null; then
        local denials
        denials=$(ausearch -m avc -ts recent 2>/dev/null | grep -E "container|podman|spc_t" | head -20)

        if [[ -n "$denials" ]]; then
            echo "Container-related denials found:"
            echo ""
            echo "$denials"
            echo ""
            echo "To get fix suggestions, run: audit2allow -a"
        else
            echo "No container-related SELinux denials found."
        fi
    elif [[ -f /var/log/audit/audit.log ]]; then
        # Fallback to direct log reading
        local denials
        denials=$(grep "avc:.*denied" /var/log/audit/audit.log 2>/dev/null | \
                  grep -E "container|podman|spc_t" | tail -20)

        if [[ -n "$denials" ]]; then
            echo "Container-related denials found:"
            echo ""
            echo "$denials"
        else
            echo "No container-related SELinux denials found."
        fi
    else
        echo "Cannot access audit logs."
        echo "Run as root or check /var/log/audit/audit.log permissions."
    fi
}

# Generate audit2allow suggestions for container issues
generate_selinux_policy_suggestions() {
    if ! is_selinux_active; then
        echo "SELinux is not active."
        return 0
    fi

    if ! command -v audit2allow &>/dev/null; then
        echo "Error: audit2allow not found"
        echo "Install: dnf install policycoreutils-devel"
        return 1
    fi

    echo "=== SELinux Policy Suggestions ==="
    echo ""
    echo "Analyzing audit logs for container-related denials..."
    echo ""

    local suggestions
    suggestions=$(ausearch -m avc -ts recent 2>/dev/null | \
                  grep -E "container|podman" | \
                  audit2allow 2>/dev/null)

    if [[ -n "$suggestions" ]]; then
        echo "Suggested policy module:"
        echo ""
        echo "$suggestions"
        echo ""
        echo "To create and install the policy:"
        echo "  ausearch -m avc -ts recent | audit2allow -M mycontainerpolicy"
        echo "  semodule -i mycontainerpolicy.pp"
    else
        echo "No policy suggestions generated."
        echo "This may mean there are no recent container-related denials."
    fi
}

# =============================================================================
# STATUS AND REPORTING
# =============================================================================

# Print comprehensive SELinux status and recommendations
do_selinux_check() {
    echo "=============================================="
    echo "       SELinux Status Check"
    echo "=============================================="
    echo ""

    local status
    status=$(detect_selinux)

    # Platform-specific status
    case "$status" in
        enforcing)
            echo "SELinux Status: ENFORCING"
            echo "  - SELinux is actively enforcing security policies"
            echo "  - Volume mounts will automatically get :Z label"
            echo "  - Container access to host files is restricted"
            ;;
        permissive)
            echo "SELinux Status: PERMISSIVE"
            echo "  - SELinux is logging but not enforcing"
            echo "  - Volume mounts will get :Z label (for future enforcement)"
            echo "  - Check logs for potential issues before enabling enforcing"
            ;;
        disabled)
            echo "SELinux Status: DISABLED"
            echo "  - SELinux is installed but disabled"
            echo "  - No SELinux labels will be added to volumes"
            echo "  - Consider enabling for improved container security"
            ;;
        apparmor)
            echo "Security Status: AppArmor (not SELinux)"
            echo "  - This system uses AppArmor instead of SELinux"
            echo "  - No SELinux labels will be added to volumes"
            echo "  - Podman works with AppArmor automatically"
            ;;
        wsl)
            echo "Platform: Windows Subsystem for Linux (WSL)"
            echo "  - SELinux is not available in WSL"
            echo "  - No SELinux labels will be added to volumes"
            echo "  - Podman will use host filesystem permissions"
            ;;
        macos)
            echo "Platform: macOS"
            echo "  - SELinux is not available on macOS"
            echo "  - Podman runs in a Linux VM on macOS"
            echo "  - Volume mounts use VM filesystem permissions"
            ;;
        not_installed)
            echo "SELinux Status: NOT INSTALLED"
            echo "  - SELinux is not available on this system"
            echo "  - No SELinux labels will be added to volumes"
            ;;
    esac

    echo ""
    echo "=============================================="
    echo "       Podman SELinux Integration"
    echo "=============================================="
    echo ""

    # Check container-selinux package
    if command -v rpm &>/dev/null; then
        if rpm -q container-selinux &>/dev/null; then
            echo "container-selinux: INSTALLED"
            echo "  $(rpm -q container-selinux)"
        else
            echo "container-selinux: NOT INSTALLED"
            echo "  Recommended: dnf install container-selinux"
        fi
    elif command -v dpkg &>/dev/null; then
        if dpkg -l selinux-policy-default 2>/dev/null | grep -q '^ii'; then
            echo "SELinux policy: INSTALLED"
        else
            echo "SELinux packages for Debian/Ubuntu may vary"
        fi
    fi

    echo ""
    echo "=============================================="
    echo "       Current Configuration"
    echo "=============================================="
    echo ""
    echo "SELINUX_MODE: ${SELINUX_MODE:-auto}"
    echo ""

    local label
    label=$(get_selinux_label)
    if [[ -n "$label" ]]; then
        echo "Volumes will be mounted with: $label"
    else
        echo "Volumes will be mounted without SELinux labels"
    fi

    echo ""
    echo "=============================================="
    echo "       Available Modes"
    echo "=============================================="
    echo ""
    echo "  --selinux=auto       Auto-detect and apply labels (default)"
    echo "  --selinux=enforcing  Force :Z on all bind mounts"
    echo "  --selinux=shared     Use :z for shared volumes"
    echo "  --selinux=private    Use :Z for private volumes"
    echo "  --selinux=disabled   No SELinux labels"
    echo ""

    # Recommendations based on status
    if is_selinux_active; then
        echo "=============================================="
        echo "       Recommendations"
        echo "=============================================="
        echo ""
        echo "For this system, we recommend:"
        echo ""
        echo "  1. Use :Z (private) for volumes accessed by single container"
        echo "  2. Use :z (shared) for volumes shared between containers"
        echo "  3. Run 'selinux-check' before migration to validate volumes"
        echo "  4. Check denials: ausearch -m avc -ts recent"
        echo ""
        echo "If you encounter permission issues:"
        echo "  - Run './migrate.sh selinux-validate' to check volume contexts"
        echo "  - Run './migrate.sh selinux-fix' to automatically fix issues"
    fi
}

# Validate SELinux mode parameter
validate_selinux_mode() {
    local mode="$1"

    case "$mode" in
        auto|enforcing|disabled|shared|private|none|force|off)
            return 0
            ;;
        *)
            echo "Error: Invalid SELinux mode: $mode" >&2
            echo "Valid modes: auto, enforcing, disabled, shared, private" >&2
            return 1
            ;;
    esac
}

# =============================================================================
# SECURITY_OPT PARSING
# =============================================================================

# Parse security_opt array and extract SELinux options
# Args: $1 = security_opt (e.g., "label:type:container_t", "label:disable")
# Returns: associative array style output: type=value
parse_security_opt_selinux() {
    local opt="$1"

    # Handle different security_opt formats
    case "$opt" in
        label:disable)
            echo "disabled=true"
            ;;
        label:type:*)
            local type="${opt#label:type:}"
            echo "type=$type"
            ;;
        label:level:*)
            local level="${opt#label:level:}"
            echo "level=$level"
            ;;
        label:user:*)
            local user="${opt#label:user:}"
            echo "user=$user"
            ;;
        label:role:*)
            local role="${opt#label:role:}"
            echo "role=$role"
            ;;
        no-new-privileges|no-new-privileges:true)
            echo "no_new_privileges=true"
            ;;
        seccomp:*)
            local profile="${opt#seccomp:}"
            echo "seccomp=$profile"
            ;;
        apparmor:*)
            local profile="${opt#apparmor:}"
            echo "apparmor=$profile"
            ;;
        *)
            # Unknown format, pass through
            echo "raw=$opt"
            ;;
    esac
}

# Parse all security_opt entries and return SELinux context
# Args: $1 = compose_file, $2 = service
# Returns: SELinux context options (type, level, user, role)
get_selinux_context_from_compose() {
    local compose_file="$1"
    local service="$2"

    local selinux_type=""
    local selinux_level=""
    local selinux_user=""
    local selinux_role=""
    local selinux_disabled="false"

    # Get security_opt entries
    local security_opts
    security_opts=$(get_service_security_opt "$compose_file" "$service" 2>/dev/null)

    if [[ -z "$security_opts" ]]; then
        return 0
    fi

    while IFS= read -r opt; do
        [[ -z "$opt" ]] && continue

        local parsed
        parsed=$(parse_security_opt_selinux "$opt")

        case "$parsed" in
            disabled=*)
                selinux_disabled="true"
                ;;
            type=*)
                selinux_type="${parsed#type=}"
                ;;
            level=*)
                selinux_level="${parsed#level=}"
                ;;
            user=*)
                selinux_user="${parsed#user=}"
                ;;
            role=*)
                selinux_role="${parsed#role=}"
                ;;
        esac
    done <<< "$security_opts"

    # Output as key=value pairs
    echo "SELINUX_DISABLED=$selinux_disabled"
    [[ -n "$selinux_type" ]] && echo "SELINUX_TYPE=$selinux_type"
    [[ -n "$selinux_level" ]] && echo "SELINUX_LEVEL=$selinux_level"
    [[ -n "$selinux_user" ]] && echo "SELINUX_USER=$selinux_user"
    [[ -n "$selinux_role" ]] && echo "SELINUX_ROLE=$selinux_role"

    return 0
}

# Get SELinux type for privileged containers
# Args: $1 = compose_file, $2 = service
# Returns: spc_t for privileged, container_t otherwise
get_selinux_type_for_service() {
    local compose_file="$1"
    local service="$2"

    # Check if privileged
    local privileged
    privileged=$(get_service_privileged "$compose_file" "$service" 2>/dev/null)

    if [[ "$privileged" == "true" ]]; then
        echo "spc_t"
        return 0
    fi

    # Check if specific type is set via security_opt
    local context_info
    context_info=$(get_selinux_context_from_compose "$compose_file" "$service")

    if [[ -n "$context_info" ]]; then
        local selinux_type
        selinux_type=$(echo "$context_info" | grep "^SELINUX_TYPE=" | cut -d= -f2)
        if [[ -n "$selinux_type" ]]; then
            echo "$selinux_type"
            return 0
        fi
    fi

    # Default container type
    echo "container_t"
}

# Check if SELinux is disabled for a service
# Args: $1 = compose_file, $2 = service
# Returns: 0 if disabled, 1 if enabled
is_selinux_disabled_for_service() {
    local compose_file="$1"
    local service="$2"

    local context_info
    context_info=$(get_selinux_context_from_compose "$compose_file" "$service")

    if echo "$context_info" | grep -q "^SELINUX_DISABLED=true"; then
        return 0
    fi

    return 1
}

# =============================================================================
# CAPABILITY AND NAMESPACE SUPPORT
# =============================================================================

# Get podman arguments for capabilities
# Args: $1 = compose_file, $2 = service
# Returns: --cap-add and --cap-drop arguments
get_capability_args() {
    local compose_file="$1"
    local service="$2"
    local args=""

    # Get cap_add
    local cap_add
    cap_add=$(get_service_cap_add "$compose_file" "$service" 2>/dev/null)
    while IFS= read -r cap; do
        [[ -z "$cap" ]] && continue
        args+="--cap-add=$cap "
    done <<< "$cap_add"

    # Get cap_drop
    local cap_drop
    cap_drop=$(get_service_cap_drop "$compose_file" "$service" 2>/dev/null)
    while IFS= read -r cap; do
        [[ -z "$cap" ]] && continue
        args+="--cap-drop=$cap "
    done <<< "$cap_drop"

    echo "$args"
}

# Get podman arguments for namespace modes
# Args: $1 = compose_file, $2 = service
# Returns: namespace related arguments
get_namespace_args() {
    local compose_file="$1"
    local service="$2"
    local args=""

    # Network mode
    local network_mode
    network_mode=$(get_service_network_mode "$compose_file" "$service" 2>/dev/null)
    if [[ -n "$network_mode" ]]; then
        case "$network_mode" in
            host|none|bridge)
                args+="--network=$network_mode "
                ;;
            service:*)
                local target_service="${network_mode#service:}"
                args+="--network=container:$target_service "
                ;;
            container:*)
                args+="--network=$network_mode "
                ;;
        esac
    fi

    # IPC mode
    local ipc_mode
    ipc_mode=$(get_service_ipc "$compose_file" "$service" 2>/dev/null)
    if [[ -n "$ipc_mode" ]]; then
        case "$ipc_mode" in
            host|private|shareable)
                args+="--ipc=$ipc_mode "
                ;;
            service:*)
                local target_service="${ipc_mode#service:}"
                args+="--ipc=container:$target_service "
                ;;
            container:*)
                args+="--ipc=$ipc_mode "
                ;;
        esac
    fi

    # PID mode
    local pid_mode
    pid_mode=$(get_service_pid "$compose_file" "$service" 2>/dev/null)
    if [[ -n "$pid_mode" ]]; then
        case "$pid_mode" in
            host)
                args+="--pid=$pid_mode "
                ;;
            service:*)
                local target_service="${pid_mode#service:}"
                args+="--pid=container:$target_service "
                ;;
            container:*)
                args+="--pid=$pid_mode "
                ;;
        esac
    fi

    # User namespace mode
    local userns_mode
    userns_mode=$(get_service_userns_mode "$compose_file" "$service" 2>/dev/null)
    if [[ -n "$userns_mode" ]]; then
        args+="--userns=$userns_mode "
    fi

    echo "$args"
}

# Get SELinux security context arguments for podman
# Args: $1 = compose_file, $2 = service
# Returns: --security-opt arguments
get_selinux_security_args() {
    local compose_file="$1"
    local service="$2"
    local args=""

    # Check if SELinux is disabled for this service
    if is_selinux_disabled_for_service "$compose_file" "$service"; then
        args+="--security-opt label=disable "
        return
    fi

    # Get SELinux context from compose
    local context_info
    context_info=$(get_selinux_context_from_compose "$compose_file" "$service")

    if [[ -n "$context_info" ]]; then
        local selinux_type selinux_level selinux_user selinux_role
        selinux_type=$(echo "$context_info" | grep "^SELINUX_TYPE=" | cut -d= -f2)
        selinux_level=$(echo "$context_info" | grep "^SELINUX_LEVEL=" | cut -d= -f2)
        selinux_user=$(echo "$context_info" | grep "^SELINUX_USER=" | cut -d= -f2)
        selinux_role=$(echo "$context_info" | grep "^SELINUX_ROLE=" | cut -d= -f2)

        [[ -n "$selinux_type" ]] && args+="--security-opt label=type:$selinux_type "
        [[ -n "$selinux_level" ]] && args+="--security-opt label=level:$selinux_level "
        [[ -n "$selinux_user" ]] && args+="--security-opt label=user:$selinux_user "
        [[ -n "$selinux_role" ]] && args+="--security-opt label=role:$selinux_role "
    fi

    # Check for privileged mode -> use spc_t
    local privileged
    privileged=$(get_service_privileged "$compose_file" "$service" 2>/dev/null)
    if [[ "$privileged" == "true" ]] && [[ -z "$args" ]]; then
        args+="--security-opt label=type:spc_t "
    fi

    echo "$args"
}

# Get tmpfs mount options with SELinux context
# Args: $1 = compose_file, $2 = service
# Returns: --tmpfs arguments
get_tmpfs_args() {
    local compose_file="$1"
    local service="$2"
    local args=""

    local tmpfs_mounts
    tmpfs_mounts=$(get_service_tmpfs "$compose_file" "$service" 2>/dev/null)

    while IFS= read -r tmpfs; do
        [[ -z "$tmpfs" ]] && continue

        # Check if tmpfs has options
        if [[ "$tmpfs" == *":"* ]]; then
            # Has options
            args+="--tmpfs=$tmpfs "
        else
            # No options, use defaults with SELinux
            if is_selinux_active; then
                args+="--tmpfs=$tmpfs:rw,noexec,nosuid,size=64m "
            else
                args+="--tmpfs=$tmpfs "
            fi
        fi
    done <<< "$tmpfs_mounts"

    echo "$args"
}

# Get device mount options with SELinux context
# Args: $1 = compose_file, $2 = service
# Returns: --device arguments
get_device_args() {
    local compose_file="$1"
    local service="$2"
    local args=""

    local devices
    devices=$(get_service_devices "$compose_file" "$service" 2>/dev/null)

    while IFS= read -r device; do
        [[ -z "$device" ]] && continue
        args+="--device=$device "
    done <<< "$devices"

    echo "$args"
}

# =============================================================================
# INTEGRATION HELPERS
# =============================================================================

# Process a volume mount string and add appropriate SELinux label
# Args: $1 = volume_string (e.g., "./data:/app:ro")
#       $2 = compose_file (optional, for shared volume detection)
#       $3 = project_name (optional)
# Returns: volume string with SELinux label if needed
process_volume_with_selinux() {
    local volume="$1"
    local compose_file="${2:-}"
    local project_name="${3:-}"

    local source target options
    IFS=':' read -r source target options <<< "$volume"

    # Only process bind mounts (paths starting with . or /)
    if [[ ! "$source" =~ ^[./] ]]; then
        echo "$volume"
        return 0
    fi

    # Check if already has SELinux label
    if [[ "$options" =~ [Zz] ]]; then
        echo "$volume"
        return 0
    fi

    # Get appropriate label
    local selinux_label
    selinux_label=$(get_volume_selinux_label "$source" "$compose_file" "$project_name")

    if [[ -z "$selinux_label" ]]; then
        echo "$volume"
        return 0
    fi

    # Add label to options
    if [[ -z "$options" ]]; then
        echo "${source}:${target}${selinux_label}"
    else
        echo "${source}:${target}:${options}${selinux_label}"
    fi
}

# Get volume label for Quadlet format
# Args: $1 = volume_path
#       $2 = is_shared (true/false)
get_quadlet_volume_options() {
    local volume_path="$1"
    local is_shared="${2:-false}"

    local label
    label=$(get_selinux_label "$SELINUX_MODE" "$is_shared")

    if [[ -n "$label" ]]; then
        # Remove leading colon for Quadlet format
        echo "${label#:}"
    fi
}

# =============================================================================
# MAIN SELINUX COMMAND HANDLER
# =============================================================================

# Main SELinux command dispatcher
# Args: $1 = subcommand, $2+ = arguments
do_selinux_command() {
    local subcmd="${1:-check}"
    shift

    case "$subcmd" in
        check|status)
            do_selinux_check
            ;;
        validate)
            if [[ -n "$1" ]]; then
                validate_compose_volumes "$1"
            else
                echo "Usage: selinux-validate <compose-file>"
                return 1
            fi
            ;;
        fix)
            local compose_file="$1"
            local permanent="${2:-false}"
            if [[ -n "$compose_file" ]]; then
                fix_compose_volumes "$compose_file" "$permanent"
            else
                echo "Usage: selinux-fix <compose-file> [permanent]"
                return 1
            fi
            ;;
        analyze)
            if [[ -n "$1" ]]; then
                analyze_volume_sharing "$1"
            else
                echo "Usage: selinux-analyze <compose-file>"
                return 1
            fi
            ;;
        denials)
            check_selinux_denials "${1:-60}"
            ;;
        suggest)
            if [[ -n "$1" ]]; then
                suggest_selinux_fix "$1" "${2:-false}"
            else
                echo "Usage: selinux-suggest <path> [shared]"
                return 1
            fi
            ;;
        info)
            get_selinux_info
            ;;
        policy)
            generate_selinux_policy_suggestions
            ;;
        *)
            echo "Unknown SELinux command: $subcmd"
            echo ""
            echo "Available commands:"
            echo "  check     - Show SELinux status and recommendations"
            echo "  validate  - Validate volume SELinux contexts"
            echo "  fix       - Apply SELinux fixes to volumes"
            echo "  analyze   - Analyze volume sharing in compose file"
            echo "  denials   - Check recent SELinux denials"
            echo "  suggest   - Show fix suggestions for a path"
            echo "  info      - Show detailed SELinux information"
            echo "  policy    - Generate policy suggestions from audit logs"
            return 1
            ;;
    esac
}
