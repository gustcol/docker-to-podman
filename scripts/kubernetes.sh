#!/bin/bash
# kubernetes.sh - Docker Compose to Kubernetes manifests conversion
# Part of docker-to-podman migration tool

# Guard against multiple loading
[[ -n "${_KUBERNETES_LOADED:-}" ]] && return 0
_KUBERNETES_LOADED=1

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -z "${_UTILS_LOADED:-}" ]] && source "$_LIB_DIR/utils.sh"
[[ -z "${_PARSER_LOADED:-}" ]] && source "$_LIB_DIR/parser.sh"
[[ -z "${_SELINUX_LOADED:-}" ]] && source "$_LIB_DIR/selinux.sh"

# Kubernetes settings
K8S_NAMESPACE="${K8S_NAMESPACE:-default}"
K8S_OUTPUT_DIR="${K8S_OUTPUT_DIR:-./k8s}"

# SELinux settings for Kubernetes
K8S_SELINUX_ENABLED="${K8S_SELINUX_ENABLED:-auto}"
K8S_SELINUX_TYPE="${K8S_SELINUX_TYPE:-container_t}"
K8S_SELINUX_LEVEL="${K8S_SELINUX_LEVEL:-}"
K8S_SELINUX_USER="${K8S_SELINUX_USER:-}"
K8S_SELINUX_ROLE="${K8S_SELINUX_ROLE:-}"

# Pod-level security settings
K8S_FS_GROUP="${K8S_FS_GROUP:-}"
K8S_SUPPLEMENTAL_GROUPS="${K8S_SUPPLEMENTAL_GROUPS:-}"
K8S_RUN_AS_USER="${K8S_RUN_AS_USER:-}"
K8S_RUN_AS_GROUP="${K8S_RUN_AS_GROUP:-}"
K8S_RUN_AS_NON_ROOT="${K8S_RUN_AS_NON_ROOT:-false}"

# Get SELinux options for Kubernetes securityContext
# Returns SELinux options block for pod spec
# Args: $1 = selinux_enabled, $2 = indent, $3 = compose_file (optional), $4 = service (optional)
get_k8s_selinux_options() {
    local selinux_enabled="${1:-$K8S_SELINUX_ENABLED}"
    local indent="${2:-          }"
    local compose_file="${3:-}"
    local service="${4:-}"

    # Check if SELinux should be enabled
    case "$selinux_enabled" in
        disabled|false|no|off)
            return 0
            ;;
        auto)
            # Auto-detect: only enable if system has SELinux
            if ! requires_selinux_labels; then
                return 0
            fi
            ;;
        *)
            # enabled, enforcing, true, yes, on - proceed
            ;;
    esac

    # Get service-specific SELinux context if compose file provided
    local selinux_type="$K8S_SELINUX_TYPE"
    local selinux_level="$K8S_SELINUX_LEVEL"
    local selinux_user="$K8S_SELINUX_USER"
    local selinux_role="$K8S_SELINUX_ROLE"

    if [[ -n "$compose_file" ]] && [[ -n "$service" ]]; then
        # Check if SELinux is disabled for this service
        if is_selinux_disabled_for_service "$compose_file" "$service" 2>/dev/null; then
            return 0
        fi

        # Get context from compose file
        local context_info
        context_info=$(get_selinux_context_from_compose "$compose_file" "$service" 2>/dev/null)

        if [[ -n "$context_info" ]]; then
            local compose_type compose_level compose_user compose_role
            compose_type=$(echo "$context_info" | grep "^SELINUX_TYPE=" | cut -d= -f2)
            compose_level=$(echo "$context_info" | grep "^SELINUX_LEVEL=" | cut -d= -f2)
            compose_user=$(echo "$context_info" | grep "^SELINUX_USER=" | cut -d= -f2)
            compose_role=$(echo "$context_info" | grep "^SELINUX_ROLE=" | cut -d= -f2)

            [[ -n "$compose_type" ]] && selinux_type="$compose_type"
            [[ -n "$compose_level" ]] && selinux_level="$compose_level"
            [[ -n "$compose_user" ]] && selinux_user="$compose_user"
            [[ -n "$compose_role" ]] && selinux_role="$compose_role"
        fi

        # Check for privileged containers -> spc_t
        local privileged
        privileged=$(get_service_privileged "$compose_file" "$service" 2>/dev/null)
        if [[ "$privileged" == "true" ]]; then
            selinux_type="spc_t"
        fi
    fi

    # Generate SELinux options
    echo "${indent}seLinuxOptions:"
    echo "${indent}  type: ${selinux_type}"

    if [[ -n "$selinux_level" ]]; then
        echo "${indent}  level: ${selinux_level}"
    fi

    if [[ -n "$selinux_user" ]]; then
        echo "${indent}  user: ${selinux_user}"
    fi

    if [[ -n "$selinux_role" ]]; then
        echo "${indent}  role: ${selinux_role}"
    fi
}

# Get container-level security context for Kubernetes
# Args: $1 = compose_file, $2 = service, $3 = indent
get_k8s_container_security_context() {
    local compose_file="$1"
    local service="$2"
    local indent="${3:-          }"

    local has_context=false
    local context_lines=""

    # Check privileged
    local privileged
    privileged=$(get_service_privileged "$compose_file" "$service" 2>/dev/null)
    if [[ "$privileged" == "true" ]]; then
        context_lines+="${indent}privileged: true\n"
        has_context=true
    fi

    # Check read_only
    local read_only
    read_only=$(get_service_read_only "$compose_file" "$service" 2>/dev/null)
    if [[ "$read_only" == "true" ]]; then
        context_lines+="${indent}readOnlyRootFilesystem: true\n"
        has_context=true
    fi

    # Check capabilities
    local cap_add cap_drop
    cap_add=$(get_service_cap_add "$compose_file" "$service" 2>/dev/null)
    cap_drop=$(get_service_cap_drop "$compose_file" "$service" 2>/dev/null)

    if [[ -n "$cap_add" ]] || [[ -n "$cap_drop" ]]; then
        context_lines+="${indent}capabilities:\n"
        has_context=true

        if [[ -n "$cap_add" ]]; then
            context_lines+="${indent}  add:\n"
            while IFS= read -r cap; do
                [[ -z "$cap" ]] && continue
                context_lines+="${indent}    - ${cap}\n"
            done <<< "$cap_add"
        fi

        if [[ -n "$cap_drop" ]]; then
            context_lines+="${indent}  drop:\n"
            while IFS= read -r cap; do
                [[ -z "$cap" ]] && continue
                context_lines+="${indent}    - ${cap}\n"
            done <<< "$cap_drop"
        fi
    fi

    # Get user from compose
    local user
    user=$(get_service_user "$compose_file" "$service" 2>/dev/null)
    if [[ -n "$user" ]]; then
        # Strip quotes if present (YAML parser may include them)
        user="${user//\"/}"
        user="${user//\'/}"

        # Handle user:group format
        local uid gid
        if [[ "$user" == *":"* ]]; then
            uid="${user%%:*}"
            gid="${user#*:}"
        else
            uid="$user"
            gid=""
        fi

        # Only add if numeric
        if [[ "$uid" =~ ^[0-9]+$ ]]; then
            context_lines+="${indent}runAsUser: ${uid}\n"
            has_context=true
        fi
        if [[ "$gid" =~ ^[0-9]+$ ]]; then
            context_lines+="${indent}runAsGroup: ${gid}\n"
        fi
    fi

    # Check for SELinux options at container level
    local selinux_opts
    selinux_opts=$(get_k8s_selinux_options "$K8S_SELINUX_ENABLED" "$indent" "$compose_file" "$service")
    if [[ -n "$selinux_opts" ]]; then
        context_lines+="$selinux_opts\n"
        has_context=true
    fi

    if [[ "$has_context" == "true" ]]; then
        echo -e "$context_lines"
    fi
}

# Get pod-level security context for Kubernetes
# Args: $1 = compose_file, $2 = service (optional for shared settings), $3 = indent
get_k8s_pod_security_context() {
    local compose_file="$1"
    local service="${2:-}"
    local indent="${3:-      }"

    local has_context=false
    local context_lines=""

    # fsGroup
    if [[ -n "$K8S_FS_GROUP" ]]; then
        context_lines+="${indent}fsGroup: ${K8S_FS_GROUP}\n"
        has_context=true
    fi

    # supplementalGroups
    if [[ -n "$K8S_SUPPLEMENTAL_GROUPS" ]]; then
        context_lines+="${indent}supplementalGroups:\n"
        for group in $K8S_SUPPLEMENTAL_GROUPS; do
            context_lines+="${indent}  - ${group}\n"
        done
        has_context=true
    fi

    # runAsNonRoot
    if [[ "$K8S_RUN_AS_NON_ROOT" == "true" ]]; then
        context_lines+="${indent}runAsNonRoot: true\n"
        has_context=true
    fi

    # runAsUser (pod level)
    if [[ -n "$K8S_RUN_AS_USER" ]]; then
        context_lines+="${indent}runAsUser: ${K8S_RUN_AS_USER}\n"
        has_context=true
    fi

    # runAsGroup (pod level)
    if [[ -n "$K8S_RUN_AS_GROUP" ]]; then
        context_lines+="${indent}runAsGroup: ${K8S_RUN_AS_GROUP}\n"
        has_context=true
    fi

    # SELinux options at pod level (if not using container-level)
    local selinux_opts
    selinux_opts=$(get_k8s_selinux_options "$K8S_SELINUX_ENABLED" "${indent}" "$compose_file" "$service")
    if [[ -n "$selinux_opts" ]]; then
        context_lines+="$selinux_opts\n"
        has_context=true
    fi

    if [[ "$has_context" == "true" ]]; then
        echo "${indent%  }securityContext:"
        echo -e "$context_lines"
    fi
}

# Get SELinux security context for volume mounts in Kubernetes
# Args: $1 = is_shared (true/false)
get_k8s_volume_selinux_context() {
    local is_shared="${1:-false}"

    if [[ "$K8S_SELINUX_ENABLED" == "disabled" ]] || \
       [[ "$K8S_SELINUX_ENABLED" == "false" ]] || \
       [[ "$K8S_SELINUX_ENABLED" == "no" ]]; then
        return 0
    fi

    if [[ "$K8S_SELINUX_ENABLED" == "auto" ]]; then
        if ! requires_selinux_labels; then
            return 0
        fi
    fi

    # For shared volumes, use MCS label sharing
    if [[ "$is_shared" == "true" ]]; then
        echo "container_share_t"
    else
        echo "container_file_t"
    fi
}

# Convert memory format from Docker to Kubernetes
# Docker: 512m, 1g -> K8s: 512Mi, 1Gi
convert_memory_k8s() {
    local mem="$1"

    # Already in K8s format
    if [[ "$mem" =~ ^[0-9]+(Mi|Gi|Ki)$ ]]; then
        echo "$mem"
        return
    fi

    # Convert docker format
    if [[ "$mem" =~ ^([0-9]+)([mMgGkK])?$ ]]; then
        local value="${BASH_REMATCH[1]}"
        local unit="${BASH_REMATCH[2]}"
        # Convert unit to lowercase for macOS compatibility
        unit=$(echo "$unit" | tr '[:upper:]' '[:lower:]')

        case "$unit" in
            m) echo "${value}Mi" ;;
            g) echo "${value}Gi" ;;
            k) echo "${value}Ki" ;;
            *) echo "${value}" ;;
        esac
    else
        echo "$mem"
    fi
}

# Convert CPU format from Docker to Kubernetes
# Docker: 0.5, 1.0 -> K8s: 500m, 1000m
convert_cpu_k8s() {
    local cpu="$1"

    # Already in K8s format (millicores)
    if [[ "$cpu" =~ ^[0-9]+m$ ]]; then
        echo "$cpu"
        return
    fi

    # Convert decimal to millicores
    if [[ "$cpu" =~ ^([0-9]+)\.?([0-9]*)$ ]]; then
        local whole="${BASH_REMATCH[1]}"
        local decimal="${BASH_REMATCH[2]:-0}"

        # Calculate millicores
        local millicores=$((whole * 1000))
        if [[ -n "$decimal" ]]; then
            # Handle decimal part
            local decimal_len=${#decimal}
            local decimal_val=$((10#$decimal))
            millicores=$((millicores + decimal_val * 1000 / (10 ** decimal_len)))
        fi

        echo "${millicores}m"
    else
        echo "$cpu"
    fi
}

# Convert restart policy from Docker to Kubernetes
convert_restart_policy_k8s() {
    local docker_restart="$1"

    case "$docker_restart" in
        "no"|"")
            echo "Never"
            ;;
        "always"|"unless-stopped")
            echo "Always"
            ;;
        "on-failure"*)
            echo "OnFailure"
            ;;
        *)
            echo "Always"
            ;;
    esac
}

# Generate Deployment YAML for a service
generate_deployment() {
    local file="$1"
    local service="$2"
    local project_name="$3"
    local output_dir="$4"

    local output_file="${output_dir}/${service}-deployment.yaml"

    # Get service properties
    local image ports volumes environment depends_on
    local command entrypoint restart memory cpus labels

    image=$(get_service_image "$file" "$service")
    if [[ -z "$image" ]]; then
        log_error "Service '$service' has no image defined"
        return 1
    fi
    image=$(normalize_image "$image")

    ports=$(get_service_ports "$file" "$service")
    volumes=$(get_service_volumes "$file" "$service")
    environment=$(get_service_environment "$file" "$service")
    # Note: depends_on available for future initContainers implementation
    # shellcheck disable=SC2034
    depends_on=$(get_service_depends_on "$file" "$service")
    command=$(get_service_command "$file" "$service")
    entrypoint=$(get_service_entrypoint "$file" "$service")
    restart=$(get_service_restart "$file" "$service")
    memory=$(get_service_resource "$file" "$service" "memory")
    cpus=$(get_service_resource "$file" "$service" "cpus")
    labels=$(get_service_labels "$file" "$service")

    # Get replicas from deploy section (default: 1)
    local replicas=1

    cat > "$output_file" << EOF
# Kubernetes Deployment for $service
# Generated by docker-to-podman migration tool
# Source: docker-compose.yml -> kubernetes manifests
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${service}
  namespace: ${K8S_NAMESPACE}
  labels:
    app: ${service}
    project: ${project_name}
spec:
  replicas: ${replicas}
  selector:
    matchLabels:
      app: ${service}
  template:
    metadata:
      labels:
        app: ${service}
        project: ${project_name}
EOF

    # Add custom labels
    if [[ -n "$labels" ]]; then
        while IFS= read -r label; do
            [[ -z "$label" ]] && continue
            local key="${label%%=*}"
            local value="${label#*=}"
            echo "        ${key}: \"${value}\"" >> "$output_file"
        done <<< "$labels"
    fi

    # Generate pod-level security context
    local pod_security_context
    pod_security_context=$(get_k8s_pod_security_context "$file" "$service" "        ")

    cat >> "$output_file" << EOF
    spec:
EOF

    # Add pod-level security context if any settings are configured
    if [[ -n "$pod_security_context" ]]; then
        echo "$pod_security_context" >> "$output_file"
    fi

    cat >> "$output_file" << EOF
      containers:
        - name: ${service}
          image: ${image}
          imagePullPolicy: IfNotPresent
EOF

    # Add container-level security context
    local container_security_context
    container_security_context=$(get_k8s_container_security_context "$file" "$service" "            ")
    if [[ -n "$container_security_context" ]]; then
        echo "          securityContext:" >> "$output_file"
        echo -e "$container_security_context" >> "$output_file"
    fi

    # Add command/entrypoint
    if [[ -n "$entrypoint" ]]; then
        echo "          command:" >> "$output_file"
        echo "            - ${entrypoint}" >> "$output_file"
    fi

    if [[ -n "$command" ]]; then
        echo "          args:" >> "$output_file"
        # Split command into arguments
        while IFS= read -r arg; do
            [[ -z "$arg" ]] && continue
            echo "            - \"${arg}\"" >> "$output_file"
        done <<< "$(printf '%s\n' $command)"
    fi

    # Add ports
    if [[ -n "$ports" ]]; then
        echo "          ports:" >> "$output_file"
        while IFS= read -r port; do
            [[ -z "$port" ]] && continue
            local parsed_port
            parsed_port=$(parse_port "$port")
            local container_port="${parsed_port#*:}"
            container_port="${container_port%/*}"
            local protocol="${parsed_port##*/}"
            protocol=$(echo "$protocol" | tr '[:lower:]' '[:upper:]')

            cat >> "$output_file" << EOF
            - containerPort: ${container_port}
              protocol: ${protocol}
EOF
        done <<< "$ports"
    fi

    # Add environment variables
    if [[ -n "$environment" ]]; then
        echo "          env:" >> "$output_file"
        while IFS= read -r env; do
            [[ -z "$env" ]] && continue
            local key="${env%%=*}"
            local value="${env#*=}"
            cat >> "$output_file" << EOF
            - name: ${key}
              value: "${value}"
EOF
        done <<< "$environment"
    fi

    # Add resource limits
    if [[ -n "$memory" ]] || [[ -n "$cpus" ]]; then
        echo "          resources:" >> "$output_file"
        echo "            limits:" >> "$output_file"
        [[ -n "$memory" ]] && echo "              memory: $(convert_memory_k8s "$memory")" >> "$output_file"
        [[ -n "$cpus" ]] && echo "              cpu: $(convert_cpu_k8s "$cpus")" >> "$output_file"
        echo "            requests:" >> "$output_file"
        # Requests at 50% of limits by default
        if [[ -n "$memory" ]]; then
            local mem_val="${memory%[mMgGkK]*}"
            local mem_unit="${memory##*[0-9]}"
            mem_unit=$(printf '%s' "$mem_unit" | tr '[:lower:]' '[:upper:]')
            local half_val=$(( mem_val > 1 ? mem_val / 2 : 1 ))
            echo "              memory: ${half_val}${mem_unit}i" >> "$output_file"
        fi
        if [[ -n "$cpus" ]]; then
            echo "              cpu: $(convert_cpu_k8s "0.25")" >> "$output_file"
        fi
    fi

    # Add healthcheck as liveness/readiness probes (before volumeMounts)
    local healthcheck_test
    healthcheck_test=$(get_service_healthcheck "$file" "$service" "test")
    if [[ -n "$healthcheck_test" ]]; then
        # Clean up healthcheck command - MUST trim spaces first before removing brackets
        healthcheck_test=$(echo "$healthcheck_test" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
        healthcheck_test=$(echo "$healthcheck_test" | sed 's/^\[//' | sed 's/\]$//')
        healthcheck_test=$(echo "$healthcheck_test" | sed 's/"//g' | sed 's/,/ /g')
        healthcheck_test=$(echo "$healthcheck_test" | sed 's/^CMD-SHELL[[:space:]]*//' | sed 's/^CMD[[:space:]]*//')
        # Remove extra spaces
        healthcheck_test=$(echo "$healthcheck_test" | tr -s ' ')

        local interval timeout retries
        interval=$(get_service_healthcheck "$file" "$service" "interval")
        timeout=$(get_service_healthcheck "$file" "$service" "timeout")
        retries=$(get_service_healthcheck "$file" "$service" "retries")

        # Convert interval/timeout to seconds
        local interval_sec=30
        local timeout_sec=10
        [[ "$interval" =~ ^([0-9]+)s$ ]] && interval_sec="${BASH_REMATCH[1]}"
        [[ "$timeout" =~ ^([0-9]+)s$ ]] && timeout_sec="${BASH_REMATCH[1]}"

        cat >> "$output_file" << EOF
          livenessProbe:
            exec:
              command:
                - /bin/sh
                - -c
                - "${healthcheck_test}"
            initialDelaySeconds: 30
            periodSeconds: ${interval_sec}
            timeoutSeconds: ${timeout_sec}
            failureThreshold: ${retries:-3}
          readinessProbe:
            exec:
              command:
                - /bin/sh
                - -c
                - "${healthcheck_test}"
            initialDelaySeconds: 5
            periodSeconds: 10
            timeoutSeconds: ${timeout_sec}
EOF
    fi

    # Add volume mounts
    if [[ -n "$volumes" ]]; then
        echo "          volumeMounts:" >> "$output_file"
        local vol_index=0
        while IFS= read -r vol; do
            [[ -z "$vol" ]] && continue
            local source target options
            IFS=':' read -r source target options <<< "$vol"
            local mount_name="volume-${vol_index}"
            local read_only="false"
            [[ "$options" == *"ro"* ]] && read_only="true"

            cat >> "$output_file" << EOF
            - name: ${mount_name}
              mountPath: ${target}
              readOnly: ${read_only}
EOF
            ((vol_index++))
        done <<< "$volumes"

        # Add pod-level volumes section
        echo "      volumes:" >> "$output_file"
        vol_index=0
        while IFS= read -r vol; do
            [[ -z "$vol" ]] && continue
            local source target options
            IFS=':' read -r source target options <<< "$vol"
            local mount_name="volume-${vol_index}"

            # Check if it's a named volume or bind mount
            if [[ "$source" == /* ]] || [[ "$source" == ./* ]] || [[ "$source" == ~/* ]]; then
                # Bind mount -> hostPath
                cat >> "$output_file" << EOF
        - name: ${mount_name}
          hostPath:
            path: ${source}
            type: DirectoryOrCreate
EOF
            else
                # Named volume -> PVC reference
                cat >> "$output_file" << EOF
        - name: ${mount_name}
          persistentVolumeClaim:
            claimName: ${source}
EOF
            fi
            ((vol_index++))
        done <<< "$volumes"
    fi

    # Add restart policy
    local restart_policy
    restart_policy=$(convert_restart_policy_k8s "$restart")
    echo "      restartPolicy: ${restart_policy}" >> "$output_file"

    log_success "Generated: $output_file"
}

# Generate Service YAML for a service
generate_service() {
    local file="$1"
    local service="$2"
    local project_name="$3"
    local output_dir="$4"

    local ports
    ports=$(get_service_ports "$file" "$service")

    # Only generate service if there are ports
    if [[ -z "$ports" ]]; then
        log_debug "No ports for service '$service', skipping Service generation"
        return 0
    fi

    local output_file="${output_dir}/${service}-service.yaml"

    cat > "$output_file" << EOF
# Kubernetes Service for $service
# Generated by docker-to-podman migration tool
apiVersion: v1
kind: Service
metadata:
  name: ${service}
  namespace: ${K8S_NAMESPACE}
  labels:
    app: ${service}
    project: ${project_name}
spec:
  selector:
    app: ${service}
  ports:
EOF

    while IFS= read -r port; do
        [[ -z "$port" ]] && continue
        local parsed_port
        parsed_port=$(parse_port "$port")
        local host_port="${parsed_port%%:*}"
        local container_port="${parsed_port#*:}"
        container_port="${container_port%/*}"
        local protocol="${parsed_port##*/}"
        protocol=$(echo "$protocol" | tr '[:lower:]' '[:upper:]')

        cat >> "$output_file" << EOF
    - name: port-${container_port}
      port: ${host_port}
      targetPort: ${container_port}
      protocol: ${protocol}
EOF
    done <<< "$ports"

    echo "  type: ClusterIP" >> "$output_file"

    log_success "Generated: $output_file"
}

# Generate ConfigMap from environment file
generate_configmap() {
    local file="$1"
    local service="$2"
    local project_name="$3"
    local output_dir="$4"

    local environment
    environment=$(get_service_environment "$file" "$service")

    if [[ -z "$environment" ]]; then
        return 0
    fi

    local output_file="${output_dir}/${service}-configmap.yaml"

    cat > "$output_file" << EOF
# Kubernetes ConfigMap for $service
# Generated by docker-to-podman migration tool
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${service}-config
  namespace: ${K8S_NAMESPACE}
  labels:
    app: ${service}
    project: ${project_name}
data:
EOF

    while IFS= read -r env; do
        [[ -z "$env" ]] && continue
        local key="${env%%=*}"
        local value="${env#*=}"
        echo "  ${key}: \"${value}\"" >> "$output_file"
    done <<< "$environment"

    log_success "Generated: $output_file"
}

# Generate PersistentVolumeClaim for named volumes
generate_pvc() {
    local volume="$1"
    local project_name="$2"
    local output_dir="$3"

    local output_file="${output_dir}/${project_name}-${volume}-pvc.yaml"

    cat > "$output_file" << EOF
# Kubernetes PersistentVolumeClaim for $volume
# Generated by docker-to-podman migration tool
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${project_name}-${volume}
  namespace: ${K8S_NAMESPACE}
  labels:
    project: ${project_name}
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  # Uncomment and modify if you need a specific storage class
  # storageClassName: standard
EOF

    log_success "Generated: $output_file"
}

# Generate namespace YAML
generate_namespace() {
    local namespace="$1"
    local output_dir="$2"

    if [[ "$namespace" == "default" ]]; then
        return 0
    fi

    local output_file="${output_dir}/namespace.yaml"

    cat > "$output_file" << EOF
# Kubernetes Namespace
# Generated by docker-to-podman migration tool
apiVersion: v1
kind: Namespace
metadata:
  name: ${namespace}
EOF

    log_success "Generated: $output_file"
}

# Generate kustomization.yaml
generate_kustomization() {
    local project_name="$1"
    local output_dir="$2"

    local output_file="${output_dir}/kustomization.yaml"

    cat > "$output_file" << EOF
# Kustomization file
# Generated by docker-to-podman migration tool
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: ${K8S_NAMESPACE}

resources:
EOF

    # Add all generated files
    for f in "$output_dir"/*.yaml; do
        [[ -f "$f" ]] || continue
        local basename
        basename=$(basename "$f")
        [[ "$basename" == "kustomization.yaml" ]] && continue
        echo "  - ${basename}" >> "$output_file"
    done

    log_success "Generated: $output_file"
}

# Generate all Kubernetes manifests
generate_kubernetes_manifests() {
    local file="$1"
    local project_name="$2"
    local output_dir="${3:-$K8S_OUTPUT_DIR}"

    log_info "Generating Kubernetes manifests for project: $project_name"
    log_info "Namespace: $K8S_NAMESPACE"
    log_info "Output directory: $output_dir"

    # Create output directory
    mkdir -p "$output_dir"

    # Generate namespace if not default
    generate_namespace "$K8S_NAMESPACE" "$output_dir"

    # Generate PVCs for named volumes
    local volumes
    volumes=$(get_volumes "$file")
    while IFS= read -r volume; do
        [[ -z "$volume" ]] && continue
        generate_pvc "$volume" "$project_name" "$output_dir"
    done <<< "$volumes"

    # Generate resources for each service
    local services
    services=$(get_services "$file")
    while IFS= read -r service; do
        [[ -z "$service" ]] && continue
        generate_deployment "$file" "$service" "$project_name" "$output_dir"
        generate_service "$file" "$service" "$project_name" "$output_dir"
        generate_configmap "$file" "$service" "$project_name" "$output_dir"
    done <<< "$services"

    # Generate kustomization.yaml
    generate_kustomization "$project_name" "$output_dir"

    echo ""
    log_success "=== Kubernetes Manifests Generated ==="
    echo ""
    log_info "Files generated in: $output_dir"
    echo ""
    log_info "To apply these manifests:"
    echo ""
    echo "  # Using kubectl directly"
    echo "  kubectl apply -f $output_dir/"
    echo ""
    echo "  # Or using kustomize"
    echo "  kubectl apply -k $output_dir/"
    echo ""
    log_info "To verify deployment:"
    echo "  kubectl get all -n $K8S_NAMESPACE"
}

# =============================================================================
# OPENSHIFT SECURITY CONTEXT CONSTRAINTS (SCC) SUPPORT
# =============================================================================

# OpenShift SCC settings
OPENSHIFT_SCC_ENABLED="${OPENSHIFT_SCC_ENABLED:-false}"
OPENSHIFT_SCC_NAME="${OPENSHIFT_SCC_NAME:-}"

# Standard OpenShift SCCs (in order of restrictiveness)
readonly OPENSHIFT_SCCS=(
    "restricted"          # Most restrictive, default for most pods
    "restricted-v2"       # OpenShift 4.11+ default
    "nonroot"             # Must run as non-root
    "nonroot-v2"          # OpenShift 4.11+ non-root
    "hostmount-anyuid"    # Host mounts with any UID
    "hostnetwork"         # Host network access
    "hostaccess"          # Host network, ports, and IPC
    "anyuid"              # Any UID but no host access
    "privileged"          # Full privileged access
)

# Determine the best SCC for a service based on its security requirements
# Args: $1 = compose_file, $2 = service
# Returns: SCC name
get_recommended_scc() {
    local compose_file="$1"
    local service="$2"

    # Check for privileged mode
    local privileged
    privileged=$(get_service_privileged "$compose_file" "$service" 2>/dev/null)
    if [[ "$privileged" == "true" ]]; then
        echo "privileged"
        return 0
    fi

    # Check for host networking
    local network_mode
    network_mode=$(get_service_network_mode "$compose_file" "$service" 2>/dev/null)
    if [[ "$network_mode" == "host" ]]; then
        echo "hostnetwork"
        return 0
    fi

    # Check for host IPC
    local ipc_mode
    ipc_mode=$(get_service_ipc "$compose_file" "$service" 2>/dev/null)
    if [[ "$ipc_mode" == "host" ]]; then
        echo "hostaccess"
        return 0
    fi

    # Check for host PID
    local pid_mode
    pid_mode=$(get_service_pid "$compose_file" "$service" 2>/dev/null)
    if [[ "$pid_mode" == "host" ]]; then
        echo "hostaccess"
        return 0
    fi

    # Check for host volume mounts
    local volumes
    volumes=$(get_service_volumes "$compose_file" "$service" 2>/dev/null)
    local has_host_mount=false
    while IFS= read -r vol; do
        [[ -z "$vol" ]] && continue
        local source
        source=$(echo "$vol" | cut -d: -f1)
        if [[ "$source" == /* ]]; then
            has_host_mount=true
            break
        fi
    done <<< "$volumes"

    # Check for specific user (anyuid might be needed)
    local user
    user=$(get_service_user "$compose_file" "$service" 2>/dev/null)
    local needs_anyuid=false
    if [[ -n "$user" ]]; then
        local uid
        if [[ "$user" == *":"* ]]; then
            uid="${user%%:*}"
        else
            uid="$user"
        fi
        # Strip quotes if present (YAML parser may include them)
        uid="${uid//\"/}"
        uid="${uid//\'/}"
        # If UID is 0 (root) or specific non-standard UID
        if [[ "$uid" == "0" ]] || [[ "$uid" == "root" ]]; then
            needs_anyuid=true
        fi
    fi

    # Check capabilities - if adding dangerous caps, need higher SCC
    local cap_add
    cap_add=$(get_service_cap_add "$compose_file" "$service" 2>/dev/null)
    local needs_caps=false
    while IFS= read -r cap; do
        [[ -z "$cap" ]] && continue
        case "$cap" in
            NET_ADMIN|SYS_ADMIN|SYS_PTRACE|NET_RAW)
                needs_caps=true
                break
                ;;
        esac
    done <<< "$cap_add"

    # Determine SCC
    if [[ "$needs_anyuid" == "true" ]] && [[ "$has_host_mount" == "true" ]]; then
        echo "hostmount-anyuid"
    elif [[ "$needs_anyuid" == "true" ]] || [[ "$needs_caps" == "true" ]]; then
        echo "anyuid"
    elif [[ "$has_host_mount" == "true" ]]; then
        echo "hostmount-anyuid"
    else
        # Check if runAsNonRoot is set or if we can use restricted
        echo "restricted-v2"
    fi
}

# Generate OpenShift SCC resource for a service
# Args: $1 = compose_file, $2 = service, $3 = project_name, $4 = output_dir
generate_openshift_scc() {
    local compose_file="$1"
    local service="$2"
    local project_name="$3"
    local output_dir="$4"

    local scc_name
    if [[ -n "$OPENSHIFT_SCC_NAME" ]]; then
        scc_name="$OPENSHIFT_SCC_NAME"
    else
        scc_name=$(get_recommended_scc "$compose_file" "$service")
    fi

    local output_file="${output_dir}/${service}-scc-role.yaml"

    # Generate RoleBinding to use the SCC
    cat > "$output_file" << EOF
# OpenShift Security Context Constraint binding for $service
# Generated by docker-to-podman migration tool
# Recommended SCC: $scc_name
#
# This creates a RoleBinding that allows the service account to use the specified SCC.
# Review the SCC requirements before applying.
#
# Standard OpenShift SCCs (from least to most privileged):
#   - restricted-v2: Default, most restrictive
#   - nonroot-v2: Must run as non-root user
#   - hostmount-anyuid: Host mounts with any UID
#   - hostnetwork: Host network access
#   - hostaccess: Host network, ports, and IPC
#   - anyuid: Any UID but no host access
#   - privileged: Full privileged access
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${service}-sa
  namespace: ${K8S_NAMESPACE}
  labels:
    app: ${service}
    project: ${project_name}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${service}-scc-${scc_name}
  namespace: ${K8S_NAMESPACE}
  labels:
    app: ${service}
    project: ${project_name}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:openshift:scc:${scc_name}
subjects:
  - kind: ServiceAccount
    name: ${service}-sa
    namespace: ${K8S_NAMESPACE}
EOF

    log_success "Generated: $output_file (SCC: $scc_name)"

    # Return the SCC name for reference
    echo "$scc_name"
}

# Generate OpenShift-specific deployment adjustments
# Args: $1 = deployment_file, $2 = service_account_name
add_openshift_deployment_config() {
    local deployment_file="$1"
    local service_account="${2:-}"

    if [[ ! -f "$deployment_file" ]]; then
        return 1
    fi

    # Add serviceAccountName to the deployment
    if [[ -n "$service_account" ]]; then
        # Insert serviceAccountName after 'spec:' in the template spec
        # Using sed to add the line
        if grep -q "serviceAccountName:" "$deployment_file"; then
            # Already has serviceAccountName
            return 0
        fi

        # Create temp file for modification
        local temp_file
        temp_file=$(mktemp)

        # Add serviceAccountName after 'spec:' in pod template
        awk -v sa="$service_account" '
        /^    spec:$/ {
            print
            print "      serviceAccountName: " sa
            next
        }
        { print }
        ' "$deployment_file" > "$temp_file"

        mv "$temp_file" "$deployment_file"
    fi
}

# Check if running on OpenShift
is_openshift() {
    # Check for OpenShift API
    if command -v oc &>/dev/null; then
        if oc api-versions 2>/dev/null | grep -q "security.openshift.io"; then
            return 0
        fi
    fi

    # Check kubectl for OpenShift resources
    if command -v kubectl &>/dev/null; then
        if kubectl api-resources 2>/dev/null | grep -q "securitycontextconstraints"; then
            return 0
        fi
    fi

    return 1
}

# Generate OpenShift-compatible manifests
generate_openshift_manifests() {
    local file="$1"
    local project_name="$2"
    local output_dir="${3:-$K8S_OUTPUT_DIR/openshift}"

    log_info "Generating OpenShift-compatible manifests for project: $project_name"
    log_info "Namespace: $K8S_NAMESPACE"
    log_info "Output directory: $output_dir"

    # Create output directory
    mkdir -p "$output_dir"

    # Generate namespace if not default
    generate_namespace "$K8S_NAMESPACE" "$output_dir"

    # Generate PVCs for named volumes
    local volumes
    volumes=$(get_volumes "$file")
    while IFS= read -r volume; do
        [[ -z "$volume" ]] && continue
        generate_pvc "$volume" "$project_name" "$output_dir"
    done <<< "$volumes"

    # Generate resources for each service
    local services
    services=$(get_services "$file")
    while IFS= read -r service; do
        [[ -z "$service" ]] && continue

        # Generate standard K8s resources
        generate_deployment "$file" "$service" "$project_name" "$output_dir"
        generate_service "$file" "$service" "$project_name" "$output_dir"
        generate_configmap "$file" "$service" "$project_name" "$output_dir"

        # Generate OpenShift SCC binding
        local scc_name
        scc_name=$(generate_openshift_scc "$file" "$service" "$project_name" "$output_dir")

        # Update deployment with ServiceAccount
        add_openshift_deployment_config "${output_dir}/${service}-deployment.yaml" "${service}-sa"

        log_info "Service '$service' will use SCC: $scc_name"
    done <<< "$services"

    # Generate kustomization.yaml
    generate_kustomization "$project_name" "$output_dir"

    echo ""
    log_success "=== OpenShift Manifests Generated ==="
    echo ""
    log_info "Files generated in: $output_dir"
    echo ""
    log_info "To apply these manifests on OpenShift:"
    echo ""
    echo "  # Using oc"
    echo "  oc apply -f $output_dir/"
    echo ""
    echo "  # Or using kubectl"
    echo "  kubectl apply -f $output_dir/"
    echo ""
    log_warning "Review the SCC bindings before applying!"
    echo "  Check ${output_dir}/*-scc-role.yaml files"
}

# Analyze SCC requirements for a compose file
analyze_scc_requirements() {
    local file="$1"

    echo "=== OpenShift SCC Requirements Analysis ==="
    echo ""

    local services
    services=$(get_services "$file")

    while IFS= read -r service; do
        [[ -z "$service" ]] && continue

        local scc
        scc=$(get_recommended_scc "$file" "$service")

        echo "Service: $service"
        echo "  Recommended SCC: $scc"

        # Show reasons
        local reasons=()

        local privileged
        privileged=$(get_service_privileged "$file" "$service" 2>/dev/null)
        [[ "$privileged" == "true" ]] && reasons+=("privileged mode")

        local network_mode
        network_mode=$(get_service_network_mode "$file" "$service" 2>/dev/null)
        [[ "$network_mode" == "host" ]] && reasons+=("host networking")

        local ipc_mode
        ipc_mode=$(get_service_ipc "$file" "$service" 2>/dev/null)
        [[ "$ipc_mode" == "host" ]] && reasons+=("host IPC")

        local pid_mode
        pid_mode=$(get_service_pid "$file" "$service" 2>/dev/null)
        [[ "$pid_mode" == "host" ]] && reasons+=("host PID")

        local cap_add
        cap_add=$(get_service_cap_add "$file" "$service" 2>/dev/null)
        [[ -n "$cap_add" ]] && reasons+=("added capabilities: $(echo "$cap_add" | tr '\n' ' ')")

        if [[ ${#reasons[@]} -gt 0 ]]; then
            echo "  Reasons:"
            for reason in "${reasons[@]}"; do
                echo "    - $reason"
            done
        fi
        echo ""
    done <<< "$services"
}

# Check Kubernetes requirements
check_k8s_requirements() {
    log_info "Checking Kubernetes requirements..."

    local _has_errors=false  # Reserved for future use

    # Check kubectl
    if command -v kubectl &>/dev/null; then
        local kubectl_version
        kubectl_version=$(kubectl version --client --short 2>/dev/null | head -1)
        log_success "kubectl: $kubectl_version"
    else
        log_warning "kubectl: not found (optional, needed for deployment)"
    fi

    # Check oc (OpenShift CLI)
    if command -v oc &>/dev/null; then
        local oc_version
        oc_version=$(oc version --client 2>/dev/null | head -1)
        log_success "oc: $oc_version"
    else
        log_info "oc: not found (optional, needed for OpenShift deployment)"
    fi

    # Check helm (optional)
    if command -v helm &>/dev/null; then
        local helm_version
        helm_version=$(helm version --short 2>/dev/null)
        log_success "helm: $helm_version"
    else
        log_info "helm: not found (optional, needed for Helm chart deployment)"
    fi

    # Check if running on OpenShift
    if is_openshift; then
        log_success "OpenShift detected"
    fi

    return 0
}
