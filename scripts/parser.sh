#!/bin/bash
# parser.sh - Docker-compose YAML parsing utilities

# Set SCRIPT_DIR only if not already set (allows sourcing from migrate.sh)
if [[ -z "${_PARSER_LOADED:-}" ]]; then
    _PARSER_LOADED=1
    _LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    [[ -z "${_UTILS_LOADED:-}" ]] && source "$_LIB_DIR/utils.sh"
fi

# Helper to filter out yq null values
_yq_filter_null() {
    local val
    val=$(cat)
    [[ "$val" == "null" ]] && echo "" || echo "$val"
}

# Parse docker-compose.yml and extract service information
# Uses yq if available, otherwise falls back to basic parsing

# Get compose file version
get_compose_version() {
    local file="$1"

    if [[ "${USE_YQ:-0}" == "1" ]]; then
        yq -r '.version // "3"' "$file" 2>/dev/null | tr -d '"'
    else
        grep -E "^version:" "$file" | head -1 | sed "s/version:[[:space:]]*['\"]*//" | sed "s/['\"]//g" | tr -d "'"
    fi
}

# Get list of all services
get_services() {
    local file="$1"

    if [[ "${USE_YQ:-0}" == "1" ]]; then
        yq -r '.services | keys | .[]' "$file" 2>/dev/null
    else
        # Fallback: find service blocks (exactly 2 spaces for service names)
        awk '/^services:/{flag=1; next} /^[a-z]/ && flag && !/^[[:space:]]/{exit} flag && /^  [a-zA-Z0-9_-]+:[[:space:]]*$/{gsub(/[[:space:]:]+/, ""); print}' "$file"
    fi
}

# Get service property
get_service_property() {
    local file="$1"
    local service="$2"
    local property="$3"

    if [[ "${USE_YQ:-0}" == "1" ]]; then
        yq -r ".services.${service}.${property}" "$file" 2>/dev/null | _yq_filter_null
    else
        # Fallback parser - basic property extraction
        awk -v svc="$service" -v prop="$property" '
            /^services:/{in_services=1; next}
            in_services && /^  [a-zA-Z0-9_-]+:/{
                gsub(/[: ]/, "", $1)
                current_service=$1
            }
            in_services && current_service==svc && $0 ~ "^[[:space:]]*"prop":"{
                sub(/^[[:space:]]*/, "")
                sub(prop":[[:space:]]*", "")
                print
            }
        ' "$file"
    fi
}

# Get service image
get_service_image() {
    local file="$1"
    local service="$2"

    if [[ "${USE_YQ:-0}" == "1" ]]; then
        yq -r ".services.${service}.image" "$file" 2>/dev/null | _yq_filter_null
    else
        get_service_property "$file" "$service" "image"
    fi
}

# Get service ports as array
get_service_ports() {
    local file="$1"
    local service="$2"

    if [[ "${USE_YQ:-0}" == "1" ]]; then
        yq -r ".services.${service}.ports[]? " "$file" 2>/dev/null | _yq_filter_null
    else
        # Fallback: extract ports array (2 spaces = service, 4+ spaces = property)
        awk -v svc="$service" '
            /^services:/{in_services=1; next}
            in_services && /^  [a-zA-Z0-9_-]+:[[:space:]]*$/{
                gsub(/[[:space:]:]+/, "")
                current_service=$0
                in_ports=0
            }
            in_services && current_service==svc && /^[[:space:]]+ports:[[:space:]]*$/{in_ports=1; next}
            in_services && current_service==svc && in_ports && /^[[:space:]]+-/{
                gsub(/^[[:space:]]*-[[:space:]]*/, "")
                gsub(/["\047]/, "")
                print
            }
            in_services && current_service==svc && in_ports && /^[[:space:]]+[a-z]/ && !/^[[:space:]]+-/{in_ports=0}
        ' "$file"
    fi
}

# Get service volumes as array
get_service_volumes() {
    local file="$1"
    local service="$2"

    if [[ "${USE_YQ:-0}" == "1" ]]; then
        yq -r ".services.${service}.volumes[]? " "$file" 2>/dev/null | _yq_filter_null
    else
        awk -v svc="$service" '
            /^services:/{in_services=1; next}
            in_services && /^  [a-zA-Z0-9_-]+:[[:space:]]*$/{
                gsub(/[[:space:]:]+/, "")
                current_service=$0
                in_volumes=0
            }
            in_services && current_service==svc && /^[[:space:]]+volumes:[[:space:]]*$/{in_volumes=1; next}
            in_services && current_service==svc && in_volumes && /^[[:space:]]+[a-z_]+:/{in_volumes=0}
            in_services && current_service==svc && in_volumes && /^[[:space:]]+-/{
                gsub(/^[[:space:]]*-[[:space:]]*/, "")
                gsub(/["\047]/, "")
                print
            }
        ' "$file"
    fi
}

# Get service environment variables as array
get_service_environment() {
    local file="$1"
    local service="$2"

    if [[ "${USE_YQ:-0}" == "1" ]]; then
        # Handle both array and map formats
        local env_type
        env_type=$(yq -r ".services.${service}.environment | type" "$file" 2>/dev/null)

        if [[ "$env_type" == "!!map" ]] || [[ "$env_type" == "object" ]]; then
            yq -r ".services.${service}.environment | to_entries | .[] | \"\(.key)=\(.value)\"" "$file" 2>/dev/null
        else
            yq -r ".services.${service}.environment[]? " "$file" 2>/dev/null | _yq_filter_null
        fi
    else
        awk -v svc="$service" '
            /^services:/{in_services=1; next}
            in_services && /^  [a-zA-Z0-9_-]+:[[:space:]]*$/{
                gsub(/[[:space:]:]+/, "")
                current_service=$0
                in_env=0
            }
            in_services && current_service==svc && /^[[:space:]]+environment:[[:space:]]*$/{in_env=1; next}
            in_services && current_service==svc && in_env && /^[[:space:]]+-/{
                gsub(/^[[:space:]]*-[[:space:]]*/, "")
                gsub(/["\047]/, "")
                print
            }
            in_services && current_service==svc && in_env && /^[[:space:]]+[A-Z_]+:/{
                gsub(/^[[:space:]]*/, "")
                gsub(/:[[:space:]]*/, "=")
                print
            }
            in_services && current_service==svc && in_env && /^[[:space:]]+[a-z_]+:/{in_env=0}
        ' "$file"
    fi
}

# Get service depends_on
get_service_depends_on() {
    local file="$1"
    local service="$2"

    if [[ "${USE_YQ:-0}" == "1" ]]; then
        # Handle both array and map formats
        local dep_type
        dep_type=$(yq -r ".services.${service}.depends_on | type" "$file" 2>/dev/null)

        if [[ "$dep_type" == "!!map" ]] || [[ "$dep_type" == "object" ]]; then
            yq -r ".services.${service}.depends_on | keys | .[]" "$file" 2>/dev/null
        else
            yq -r ".services.${service}.depends_on[]? " "$file" 2>/dev/null | _yq_filter_null
        fi
    else
        awk -v svc="$service" '
            /^services:/{in_services=1; next}
            in_services && /^  [a-zA-Z0-9_-]+:[[:space:]]*$/{
                gsub(/[[:space:]:]+/, "")
                current_service=$0
                in_deps=0
            }
            in_services && current_service==svc && /^[[:space:]]+depends_on:[[:space:]]*$/{in_deps=1; next}
            in_services && current_service==svc && in_deps && /^[[:space:]]+-/{
                gsub(/^[[:space:]]*-[[:space:]]*/, "")
                gsub(/["\047]/, "")
                print
            }
            in_services && current_service==svc && in_deps && /^  [a-z]/{in_deps=0}
        ' "$file"
    fi
}

# Get service networks
get_service_networks() {
    local file="$1"
    local service="$2"

    if [[ "${USE_YQ:-0}" == "1" ]]; then
        local net_type
        net_type=$(yq -r ".services.${service}.networks | type" "$file" 2>/dev/null)

        if [[ "$net_type" == "!!map" ]] || [[ "$net_type" == "object" ]]; then
            yq -r ".services.${service}.networks | keys | .[]" "$file" 2>/dev/null
        else
            yq -r ".services.${service}.networks[]? " "$file" 2>/dev/null | _yq_filter_null
        fi
    else
        awk -v svc="$service" '
            /^services:/{in_services=1; next}
            in_services && /^  [a-zA-Z0-9_-]+:[[:space:]]*$/{
                gsub(/[[:space:]:]+/, "")
                current_service=$0
                in_nets=0
            }
            in_services && current_service==svc && /^[[:space:]]+networks:[[:space:]]*$/{in_nets=1; next}
            in_services && current_service==svc && in_nets && /^[[:space:]]+-/{
                gsub(/^[[:space:]]*-[[:space:]]*/, "")
                gsub(/["\047]/, "")
                print
            }
            in_services && current_service==svc && in_nets && /^  [a-z]/{in_nets=0}
        ' "$file"
    fi
}

# Get service command
get_service_command() {
    local file="$1"
    local service="$2"

    if [[ "${USE_YQ:-0}" == "1" ]]; then
        local cmd_type
        cmd_type=$(yq -r ".services.${service}.command | type" "$file" 2>/dev/null)

        if [[ "$cmd_type" == "!!seq" ]] || [[ "$cmd_type" == "array" ]]; then
            yq -r ".services.${service}.command | join(\" \")" "$file" 2>/dev/null
        else
            yq -r ".services.${service}.command " "$file" 2>/dev/null | _yq_filter_null
        fi
    else
        get_service_property "$file" "$service" "command"
    fi
}

# Get service entrypoint
get_service_entrypoint() {
    local file="$1"
    local service="$2"

    if [[ "${USE_YQ:-0}" == "1" ]]; then
        local ep_type
        ep_type=$(yq -r ".services.${service}.entrypoint | type" "$file" 2>/dev/null)

        if [[ "$ep_type" == "!!seq" ]] || [[ "$ep_type" == "array" ]]; then
            yq -r ".services.${service}.entrypoint | join(\" \")" "$file" 2>/dev/null
        else
            yq -r ".services.${service}.entrypoint " "$file" 2>/dev/null | _yq_filter_null
        fi
    else
        get_service_property "$file" "$service" "entrypoint"
    fi
}

# Get service restart policy
get_service_restart() {
    local file="$1"
    local service="$2"

    if [[ "${USE_YQ:-0}" == "1" ]]; then
        yq -r ".services.${service}.restart " "$file" 2>/dev/null | _yq_filter_null
    else
        get_service_property "$file" "$service" "restart"
    fi
}

# Get service health check
get_service_healthcheck() {
    local file="$1"
    local service="$2"
    local property="$3"

    if [[ "${USE_YQ:-0}" == "1" ]]; then
        yq -r ".services.${service}.healthcheck.${property} " "$file" 2>/dev/null | _yq_filter_null
    else
        # Basic extraction
        awk -v svc="$service" -v prop="$property" '
            /^services:/{in_services=1; next}
            in_services && /^  [a-zA-Z0-9_-]+:/{
                gsub(/[: ]/, "", $1)
                current_service=$1
                in_health=0
            }
            in_services && current_service==svc && /^    healthcheck:/{in_health=1; next}
            in_services && current_service==svc && in_health && $1==prop":"{
                gsub(prop":[[:space:]]*", "")
                gsub(/^[[:space:]]+/, "")
                gsub(/[[:space:]]+$/, "")
                print
            }
        ' "$file"
    fi
}

# Get service resource limits
get_service_resource() {
    local file="$1"
    local service="$2"
    local resource="$3"  # memory, cpus

    if [[ "${USE_YQ:-0}" == "1" ]]; then
        # Try deploy.resources.limits first (compose v3)
        local value
        value=$(yq -r ".services.${service}.deploy.resources.limits.${resource} " "$file" 2>/dev/null | _yq_filter_null)

        if [[ -z "$value" ]]; then
            # Try direct property (compose v2)
            case "$resource" in
                memory) value=$(yq -r ".services.${service}.mem_limit " "$file" 2>/dev/null | _yq_filter_null) ;;
                cpus) value=$(yq -r ".services.${service}.cpus " "$file" 2>/dev/null | _yq_filter_null) ;;
            esac
        fi

        echo "$value"
    else
        # Fallback - extract deploy.resources.limits
        local value
        value=$(awk -v svc="$service" -v res="$resource" '
            /^services:/{in_services=1; next}
            in_services && /^  [a-zA-Z0-9_-]+:/{
                gsub(/[: ]/, "", $1)
                current_service=$1
                in_deploy=0; in_resources=0; in_limits=0
            }
            in_services && current_service==svc && /deploy:/{in_deploy=1; next}
            in_services && current_service==svc && in_deploy && /resources:/{in_resources=1; next}
            in_services && current_service==svc && in_deploy && in_resources && /limits:/{in_limits=1; next}
            in_services && current_service==svc && in_deploy && in_resources && in_limits && $1==res":"{
                gsub(res":[[:space:]]*", "")
                gsub(/^[[:space:]]+/, "")
                gsub(/[[:space:]]+$/, "")
                print
                exit
            }
        ' "$file" | tr -d "'\"")

        # If not found in deploy, try v2 format
        if [[ -z "$value" ]]; then
            case "$resource" in
                memory) value=$(get_service_property "$file" "$service" "mem_limit") ;;
                cpus) value=$(get_service_property "$file" "$service" "cpus") ;;
            esac
        fi
        echo "$value"
    fi
}

# Get top-level networks
get_networks() {
    local file="$1"

    if [[ "${USE_YQ:-0}" == "1" ]]; then
        yq -r '.networks | keys | .[]' "$file" 2>/dev/null || true
    else
        awk '/^networks:/{flag=1; next} /^[a-z]/ && flag && !/^  /{exit} flag && /^  [a-zA-Z0-9_-]+:/{gsub(/[: ]/, ""); print}' "$file"
    fi
}

# Get top-level volumes
get_volumes() {
    local file="$1"

    if [[ "${USE_YQ:-0}" == "1" ]]; then
        yq -r '.volumes | keys | .[]' "$file" 2>/dev/null || true
    else
        awk '/^volumes:/{flag=1; next} /^[a-z]/ && flag && !/^  /{exit} flag && /^  [a-zA-Z0-9_-]+:/{gsub(/[: ]/, ""); print}' "$file"
    fi
}

# Get network driver
get_network_driver() {
    local file="$1"
    local network="$2"

    if [[ "${USE_YQ:-0}" == "1" ]]; then
        yq -r ".networks.${network}.driver // \"bridge\"" "$file" 2>/dev/null
    else
        echo "bridge"
    fi
}

# Get volume driver
get_volume_driver() {
    local file="$1"
    local volume="$2"

    if [[ "${USE_YQ:-0}" == "1" ]]; then
        yq -r ".volumes.${volume}.driver // \"local\"" "$file" 2>/dev/null
    else
        echo "local"
    fi
}

# Get service env_file (list of env files to load)
get_service_env_file() {
    local file="$1"
    local service="$2"

    if [[ "${USE_YQ:-0}" == "1" ]]; then
        local env_type
        env_type=$(yq -r ".services.${service}.env_file | type" "$file" 2>/dev/null)

        if [[ "$env_type" == "!!seq" ]] || [[ "$env_type" == "array" ]]; then
            yq -r ".services.${service}.env_file[]?" "$file" 2>/dev/null | _yq_filter_null
        else
            yq -r ".services.${service}.env_file" "$file" 2>/dev/null | _yq_filter_null
        fi
    else
        awk -v svc="$service" '
            /^services:/{in_services=1; next}
            in_services && /^  [a-zA-Z0-9_-]+:[[:space:]]*$/{
                gsub(/[[:space:]:]+/, "")
                current_service=$0
                in_env_file=0
            }
            in_services && current_service==svc && /^[[:space:]]+env_file:[[:space:]]*$/{in_env_file=1; next}
            in_services && current_service==svc && in_env_file && /^[[:space:]]+-/{
                gsub(/^[[:space:]]*-[[:space:]]*/, "")
                gsub(/["\047]/, "")
                print
            }
            in_services && current_service==svc && in_env_file && /^[[:space:]]+[a-z_]+:/{in_env_file=0}
        ' "$file"
    fi
}

# Get service labels
get_service_labels() {
    local file="$1"
    local service="$2"

    if [[ "${USE_YQ:-0}" == "1" ]]; then
        local labels_type
        labels_type=$(yq -r ".services.${service}.labels | type" "$file" 2>/dev/null)

        if [[ "$labels_type" == "!!map" ]] || [[ "$labels_type" == "object" ]]; then
            yq -r ".services.${service}.labels | to_entries | .[] | \"\(.key)=\(.value)\"" "$file" 2>/dev/null
        else
            yq -r ".services.${service}.labels[]?" "$file" 2>/dev/null | _yq_filter_null
        fi
    else
        awk -v svc="$service" '
            /^services:/{in_services=1; next}
            in_services && /^  [a-zA-Z0-9_-]+:[[:space:]]*$/{
                gsub(/[[:space:]:]+/, "")
                current_service=$0
                in_labels=0
            }
            in_services && current_service==svc && /^[[:space:]]+labels:[[:space:]]*$/{in_labels=1; next}
            in_services && current_service==svc && in_labels && /^[[:space:]]+-[[:space:]]*"/{
                gsub(/^[[:space:]]*-[[:space:]]*/, "")
                gsub(/["\047]/, "")
                print
            }
            in_services && current_service==svc && in_labels && /^[[:space:]]+[a-z_]+:/{in_labels=0}
        ' "$file"
    fi
}

# Get service user
get_service_user() {
    local file="$1"
    local service="$2"

    if [[ "${USE_YQ:-0}" == "1" ]]; then
        yq -r ".services.${service}.user" "$file" 2>/dev/null | _yq_filter_null
    else
        get_service_property "$file" "$service" "user"
    fi
}

# Get service working_dir
get_service_working_dir() {
    local file="$1"
    local service="$2"

    if [[ "${USE_YQ:-0}" == "1" ]]; then
        yq -r ".services.${service}.working_dir" "$file" 2>/dev/null | _yq_filter_null
    else
        get_service_property "$file" "$service" "working_dir"
    fi
}

# Get service security_opt (SELinux labels, AppArmor, etc.)
get_service_security_opt() {
    local file="$1"
    local service="$2"

    if [[ "${USE_YQ:-0}" == "1" ]]; then
        yq -r ".services.${service}.security_opt[]?" "$file" 2>/dev/null | _yq_filter_null
    else
        awk -v svc="$service" '
            /^services:/{in_services=1; next}
            in_services && /^  [a-zA-Z0-9_-]+:[[:space:]]*$/{
                gsub(/[[:space:]:]+/, "")
                current_service=$0
                in_security_opt=0
            }
            in_services && current_service==svc && /^[[:space:]]+security_opt:[[:space:]]*$/{in_security_opt=1; next}
            in_services && current_service==svc && in_security_opt && /^[[:space:]]+-/{
                gsub(/^[[:space:]]*-[[:space:]]*/, "")
                gsub(/["\047]/, "")
                print
            }
            in_services && current_service==svc && in_security_opt && /^[[:space:]]+[a-z_]+:/{in_security_opt=0}
        ' "$file"
    fi
}

# Get service cap_add (Linux capabilities to add)
get_service_cap_add() {
    local file="$1"
    local service="$2"

    if [[ "${USE_YQ:-0}" == "1" ]]; then
        yq -r ".services.${service}.cap_add[]?" "$file" 2>/dev/null | _yq_filter_null
    else
        awk -v svc="$service" '
            /^services:/{in_services=1; next}
            in_services && /^  [a-zA-Z0-9_-]+:[[:space:]]*$/{
                gsub(/[[:space:]:]+/, "")
                current_service=$0
                in_cap_add=0
            }
            in_services && current_service==svc && /^[[:space:]]+cap_add:[[:space:]]*$/{in_cap_add=1; next}
            in_services && current_service==svc && in_cap_add && /^[[:space:]]+-/{
                gsub(/^[[:space:]]*-[[:space:]]*/, "")
                gsub(/["\047]/, "")
                print
            }
            in_services && current_service==svc && in_cap_add && /^[[:space:]]+[a-z_]+:/{in_cap_add=0}
        ' "$file"
    fi
}

# Get service cap_drop (Linux capabilities to drop)
get_service_cap_drop() {
    local file="$1"
    local service="$2"

    if [[ "${USE_YQ:-0}" == "1" ]]; then
        yq -r ".services.${service}.cap_drop[]?" "$file" 2>/dev/null | _yq_filter_null
    else
        awk -v svc="$service" '
            /^services:/{in_services=1; next}
            in_services && /^  [a-zA-Z0-9_-]+:[[:space:]]*$/{
                gsub(/[[:space:]:]+/, "")
                current_service=$0
                in_cap_drop=0
            }
            in_services && current_service==svc && /^[[:space:]]+cap_drop:[[:space:]]*$/{in_cap_drop=1; next}
            in_services && current_service==svc && in_cap_drop && /^[[:space:]]+-/{
                gsub(/^[[:space:]]*-[[:space:]]*/, "")
                gsub(/["\047]/, "")
                print
            }
            in_services && current_service==svc && in_cap_drop && /^[[:space:]]+[a-z_]+:/{in_cap_drop=0}
        ' "$file"
    fi
}

# Get service privileged mode
get_service_privileged() {
    local file="$1"
    local service="$2"

    if [[ "${USE_YQ:-0}" == "1" ]]; then
        yq -r ".services.${service}.privileged" "$file" 2>/dev/null | _yq_filter_null
    else
        get_service_property "$file" "$service" "privileged"
    fi
}

# Get service network_mode
get_service_network_mode() {
    local file="$1"
    local service="$2"

    if [[ "${USE_YQ:-0}" == "1" ]]; then
        yq -r ".services.${service}.network_mode" "$file" 2>/dev/null | _yq_filter_null
    else
        get_service_property "$file" "$service" "network_mode"
    fi
}

# Get service ipc_mode
get_service_ipc() {
    local file="$1"
    local service="$2"

    if [[ "${USE_YQ:-0}" == "1" ]]; then
        yq -r ".services.${service}.ipc" "$file" 2>/dev/null | _yq_filter_null
    else
        get_service_property "$file" "$service" "ipc"
    fi
}

# Get service pid_mode
get_service_pid() {
    local file="$1"
    local service="$2"

    if [[ "${USE_YQ:-0}" == "1" ]]; then
        yq -r ".services.${service}.pid" "$file" 2>/dev/null | _yq_filter_null
    else
        get_service_property "$file" "$service" "pid"
    fi
}

# Get service userns_mode
get_service_userns_mode() {
    local file="$1"
    local service="$2"

    if [[ "${USE_YQ:-0}" == "1" ]]; then
        yq -r ".services.${service}.userns_mode" "$file" 2>/dev/null | _yq_filter_null
    else
        get_service_property "$file" "$service" "userns_mode"
    fi
}

# Get service tmpfs mounts
get_service_tmpfs() {
    local file="$1"
    local service="$2"

    if [[ "${USE_YQ:-0}" == "1" ]]; then
        local tmpfs_type
        tmpfs_type=$(yq -r ".services.${service}.tmpfs | type" "$file" 2>/dev/null)

        if [[ "$tmpfs_type" == "!!seq" ]] || [[ "$tmpfs_type" == "array" ]]; then
            yq -r ".services.${service}.tmpfs[]?" "$file" 2>/dev/null | _yq_filter_null
        else
            yq -r ".services.${service}.tmpfs" "$file" 2>/dev/null | _yq_filter_null
        fi
    else
        awk -v svc="$service" '
            /^services:/{in_services=1; next}
            in_services && /^  [a-zA-Z0-9_-]+:[[:space:]]*$/{
                gsub(/[[:space:]:]+/, "")
                current_service=$0
                in_tmpfs=0
            }
            in_services && current_service==svc && /^[[:space:]]+tmpfs:[[:space:]]*$/{in_tmpfs=1; next}
            in_services && current_service==svc && in_tmpfs && /^[[:space:]]+-/{
                gsub(/^[[:space:]]*-[[:space:]]*/, "")
                gsub(/["\047]/, "")
                print
            }
            in_services && current_service==svc && in_tmpfs && /^[[:space:]]+[a-z_]+:/{in_tmpfs=0}
        ' "$file"
    fi
}

# Get service devices
get_service_devices() {
    local file="$1"
    local service="$2"

    if [[ "${USE_YQ:-0}" == "1" ]]; then
        yq -r ".services.${service}.devices[]?" "$file" 2>/dev/null | _yq_filter_null
    else
        awk -v svc="$service" '
            /^services:/{in_services=1; next}
            in_services && /^  [a-zA-Z0-9_-]+:[[:space:]]*$/{
                gsub(/[[:space:]:]+/, "")
                current_service=$0
                in_devices=0
            }
            in_services && current_service==svc && /^[[:space:]]+devices:[[:space:]]*$/{in_devices=1; next}
            in_services && current_service==svc && in_devices && /^[[:space:]]+-/{
                gsub(/^[[:space:]]*-[[:space:]]*/, "")
                gsub(/["\047]/, "")
                print
            }
            in_services && current_service==svc && in_devices && /^[[:space:]]+[a-z_]+:/{in_devices=0}
        ' "$file"
    fi
}

# Get service read_only flag
get_service_read_only() {
    local file="$1"
    local service="$2"

    if [[ "${USE_YQ:-0}" == "1" ]]; then
        yq -r ".services.${service}.read_only" "$file" 2>/dev/null | _yq_filter_null
    else
        get_service_property "$file" "$service" "read_only"
    fi
}

# Note: parse_service() was removed for Bash 3.x compatibility
# Use individual getter functions instead:
# - get_service_image, get_service_command, get_service_entrypoint
# - get_service_restart, get_service_resource
# - get_service_ports, get_service_volumes, get_service_environment
# - get_service_depends_on, get_service_networks
# - get_service_env_file, get_service_labels, get_service_user, get_service_working_dir
# - get_service_security_opt, get_service_cap_add, get_service_cap_drop
# - get_service_privileged, get_service_network_mode, get_service_ipc
# - get_service_pid, get_service_userns_mode, get_service_tmpfs
# - get_service_devices, get_service_read_only
