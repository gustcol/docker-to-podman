#!/bin/bash
# migrate.sh - Docker-compose to Podman migration tool
# Generates Quadlet files for Podman 4.4+ with performance optimizations

set -e

VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source library files
source "$SCRIPT_DIR/scripts/utils.sh"
source "$SCRIPT_DIR/scripts/parser.sh"
source "$SCRIPT_DIR/scripts/selinux.sh"
source "$SCRIPT_DIR/scripts/converter.sh"
source "$SCRIPT_DIR/scripts/quadlet.sh"
source "$SCRIPT_DIR/scripts/validator.sh"
source "$SCRIPT_DIR/scripts/performance.sh"
source "$SCRIPT_DIR/scripts/kubernetes.sh"
source "$SCRIPT_DIR/scripts/helm.sh"

# Default values
COMPOSE_FILE=""
PROJECT_NAME=""
OUTPUT_DIR=""
MODE="user"
ACTION="migrate"
INSTALL=false
DRY_RUN=false
FORCE=false

# SELinux settings (auto, enforcing, disabled, shared, private)
SELINUX_MODE="${SELINUX_MODE:-auto}"
SELINUX_AUTO_FIX="${SELINUX_AUTO_FIX:-false}"
SELINUX_VALIDATE="${SELINUX_VALIDATE:-false}"

# Kubernetes settings
GENERATE_K8S=false
GENERATE_HELM=false
K8S_NAMESPACE="${K8S_NAMESPACE:-default}"
K8S_OUTPUT_DIR="${K8S_OUTPUT_DIR:-./k8s}"
HELM_OUTPUT_DIR="${HELM_OUTPUT_DIR:-./charts}"

# Print usage
usage() {
    cat << EOF
Docker-Compose to Podman Migration Tool v${VERSION}

Usage: $(basename "$0") [OPTIONS] COMMAND

Commands:
  migrate          Convert docker-compose.yml to Podman Quadlet files (default)
  validate         Validate docker-compose.yml without migrating
  check            Check Podman environment and suggest optimizations
  k8s              Convert docker-compose.yml to Kubernetes manifests
  selinux-check    Check SELinux status and provide recommendations
  selinux-validate Validate volume SELinux contexts in compose file
  selinux-fix      Apply SELinux fixes to volumes in compose file
  selinux-analyze  Analyze volume sharing in compose file
  selinux-denials  Check recent SELinux denials
  selinux-info     Show detailed SELinux information
  start            Start all services for a project
  stop             Stop all services for a project
  restart          Restart all services for a project
  status           Show status of migrated services
  logs             Show logs for migrated services
  health           Check health of running containers
  enable           Enable auto-start on boot for all services
  disable          Disable auto-start on boot for all services
  cleanup          Remove unused Podman resources
  export           Export running containers as docker-compose.yml

Options:
  -f, --file FILE       Docker-compose file (default: docker-compose.yml)
  -p, --project NAME    Project name (default: directory name)
  -o, --output DIR      Output directory for Quadlet files (default: ./quadlet)
  -m, --mode MODE       Install mode: user or system (default: user)
  -i, --install         Install Quadlet files to systemd directory
  -n, --dry-run         Show what would be done without making changes
  --force               Overwrite existing files
  -d, --debug           Enable debug output
  -h, --help            Show this help message
  -v, --version         Show version

SELinux Options:
  --selinux=MODE        SELinux label mode: auto, enforcing, disabled, shared, private
                        (default: auto - detects SELinux status)
  --selinux-auto-fix    Automatically fix SELinux contexts before migration
  --selinux-validate    Validate volume SELinux contexts before migration

Kubernetes Options:
  -k, --kubernetes      Generate Kubernetes manifests instead of Quadlet
  --helm                Generate Helm chart (use with -k)
  --k8s-namespace=NS    Kubernetes namespace (default: default)
  --k8s-output=DIR      Output directory for K8s manifests (default: ./k8s)

Examples:
  # Migrate docker-compose.yml to Quadlet files
  $(basename "$0") -f docker-compose.yml migrate

  # Migrate and install to user systemd
  $(basename "$0") -f docker-compose.yml -i migrate

  # Migrate with SELinux disabled (no :Z labels)
  $(basename "$0") -f docker-compose.yml --selinux=disabled migrate

  # Check SELinux status
  $(basename "$0") selinux-check

  # Migrate to Kubernetes manifests
  $(basename "$0") -f docker-compose.yml k8s

  # Migrate to Helm chart
  $(basename "$0") -f docker-compose.yml k8s --helm

  # Migrate to Kubernetes with custom namespace
  $(basename "$0") -f docker-compose.yml k8s --k8s-namespace=production

  # Validate compose file only
  $(basename "$0") -f docker-compose.yml validate

  # Check system performance
  $(basename "$0") check

  # Start migrated services
  $(basename "$0") -p myproject start

  # View logs for a project
  $(basename "$0") -p myproject logs

For more information, see: https://github.com/containers/podman
EOF
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f|--file)
                COMPOSE_FILE="$2"
                shift 2
                ;;
            -p|--project)
                PROJECT_NAME="$2"
                shift 2
                ;;
            -o|--output)
                OUTPUT_DIR="$2"
                shift 2
                ;;
            -m|--mode)
                MODE="$2"
                shift 2
                ;;
            -i|--install)
                INSTALL=true
                shift
                ;;
            -n|--dry-run)
                DRY_RUN=true
                shift
                ;;
            --force)
                FORCE=true
                shift
                ;;
            -d|--debug)
                export DEBUG=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            -v|--version)
                echo "docker-to-podman v${VERSION}"
                exit 0
                ;;
            # SELinux options
            --selinux=*)
                SELINUX_MODE="${1#*=}"
                export SELINUX_MODE
                validate_selinux_mode "$SELINUX_MODE" || exit 1
                shift
                ;;
            --selinux)
                SELINUX_MODE="$2"
                export SELINUX_MODE
                validate_selinux_mode "$SELINUX_MODE" || exit 1
                shift 2
                ;;
            --selinux-auto-fix)
                SELINUX_AUTO_FIX=true
                export SELINUX_AUTO_FIX
                shift
                ;;
            --selinux-validate)
                SELINUX_VALIDATE=true
                export SELINUX_VALIDATE
                shift
                ;;
            # Kubernetes options
            -k|--kubernetes)
                GENERATE_K8S=true
                shift
                ;;
            --helm)
                GENERATE_HELM=true
                shift
                ;;
            --k8s-namespace=*)
                K8S_NAMESPACE="${1#*=}"
                export K8S_NAMESPACE
                shift
                ;;
            --k8s-namespace)
                K8S_NAMESPACE="$2"
                export K8S_NAMESPACE
                shift 2
                ;;
            --k8s-output=*)
                K8S_OUTPUT_DIR="${1#*=}"
                export K8S_OUTPUT_DIR
                shift
                ;;
            --k8s-output)
                K8S_OUTPUT_DIR="$2"
                export K8S_OUTPUT_DIR
                shift 2
                ;;
            # Commands
            migrate|validate|check|start|stop|restart|status|logs|health|enable|disable|cleanup|optimize|export|k8s|selinux-check|selinux-validate|selinux-fix|selinux-analyze|selinux-denials|selinux-info|selinux-policy)
                ACTION="$1"
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
}

# Find compose file
find_compose_file() {
    if [[ -n "$COMPOSE_FILE" ]]; then
        if [[ ! -f "$COMPOSE_FILE" ]]; then
            log_error "Compose file not found: $COMPOSE_FILE"
            exit 1
        fi
        return
    fi

    # Try common names
    local candidates=(
        "docker-compose.yml"
        "docker-compose.yaml"
        "compose.yml"
        "compose.yaml"
    )

    for file in "${candidates[@]}"; do
        if [[ -f "$file" ]]; then
            COMPOSE_FILE="$file"
            return
        fi
    done

    log_error "No compose file found. Use -f to specify one."
    exit 1
}

# Set default project name
set_project_name() {
    if [[ -z "$PROJECT_NAME" ]]; then
        PROJECT_NAME=$(get_project_name "$COMPOSE_FILE")
    fi
    PROJECT_NAME=$(sanitize_service_name "$PROJECT_NAME")
}

# Set default output directory
set_output_dir() {
    if [[ -z "$OUTPUT_DIR" ]]; then
        OUTPUT_DIR="./quadlet"
    fi
}

# Action: migrate
do_migrate() {
    find_compose_file
    set_project_name
    set_output_dir

    log_info "=== Docker to Podman Migration ==="
    log_info "Compose file: $COMPOSE_FILE"
    log_info "Project name: $PROJECT_NAME"
    log_info "Output directory: $OUTPUT_DIR"
    log_info "Mode: $MODE"
    echo ""

    # Check dependencies
    check_dependencies || exit 1

    # Validate first
    run_validation "$COMPOSE_FILE"
    local validation_result=$?

    if [[ $validation_result -ne 0 ]] && [[ "$FORCE" != "true" ]]; then
        log_error "Validation failed. Use --force to migrate anyway."
        exit 1
    fi

    # SELinux validation if requested
    if [[ "$SELINUX_VALIDATE" == "true" ]]; then
        log_info "Validating SELinux contexts..."
        if ! validate_compose_volumes "$COMPOSE_FILE"; then
            if [[ "$SELINUX_AUTO_FIX" != "true" ]] && [[ "$FORCE" != "true" ]]; then
                log_error "SELinux validation failed. Use --selinux-auto-fix to fix or --force to continue."
                exit 1
            fi
        fi
    fi

    # SELinux auto-fix if requested
    if [[ "$SELINUX_AUTO_FIX" == "true" ]]; then
        log_info "Applying SELinux fixes..."
        fix_compose_volumes "$COMPOSE_FILE" "false"
    fi

    # Check if output exists
    if [[ -d "$OUTPUT_DIR" ]] && [[ "$FORCE" != "true" ]] && [[ "$DRY_RUN" != "true" ]]; then
        log_warning "Output directory exists: $OUTPUT_DIR"
        log_warning "Use --force to overwrite or choose a different directory."
        exit 1
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would generate Quadlet files in: $OUTPUT_DIR"

        local services
        services=$(get_services "$COMPOSE_FILE")

        while IFS= read -r service; do
            [[ -z "$service" ]] && continue
            log_info "[DRY RUN] Would generate: ${PROJECT_NAME}-${service}.container"
        done <<< "$services"

        local networks
        networks=$(get_networks "$COMPOSE_FILE")
        while IFS= read -r network; do
            [[ -z "$network" ]] && continue
            log_info "[DRY RUN] Would generate: ${PROJECT_NAME}-${network}.network"
        done <<< "$networks"

        log_info "[DRY RUN] Migration preview complete."
        return 0
    fi

    # Generate Quadlet files
    generate_quadlet_files "$COMPOSE_FILE" "$PROJECT_NAME" "$OUTPUT_DIR" "$INSTALL"

    echo ""
    log_success "=== Migration Complete ==="
    echo ""

    if [[ "$INSTALL" == "true" ]]; then
        log_info "Services have been installed. To start them:"
        echo ""
        echo "  # Reload systemd"
        if [[ "$MODE" == "user" ]]; then
            echo "  systemctl --user daemon-reload"
            echo ""
            echo "  # Start services"
            echo "  systemctl --user start ${PROJECT_NAME}-<service>.service"
            echo ""
            echo "  # Enable auto-start"
            echo "  systemctl --user enable ${PROJECT_NAME}-<service>.service"
        else
            echo "  sudo systemctl daemon-reload"
            echo ""
            echo "  # Start services"
            echo "  sudo systemctl start ${PROJECT_NAME}-<service>.service"
        fi
    else
        log_info "Quadlet files generated in: $OUTPUT_DIR"
        echo ""
        log_info "To install and start services:"
        echo ""
        echo "  # Copy files to Quadlet directory"
        if [[ "$MODE" == "user" ]]; then
            echo "  mkdir -p ~/.config/containers/systemd"
            echo "  cp $OUTPUT_DIR/*.{container,network,volume} ~/.config/containers/systemd/"
            echo ""
            echo "  # Reload and start"
            echo "  systemctl --user daemon-reload"
            echo "  systemctl --user start ${PROJECT_NAME}-<service>.service"
        else
            echo "  sudo cp $OUTPUT_DIR/*.{container,network,volume} /etc/containers/systemd/"
            echo ""
            echo "  # Reload and start"
            echo "  sudo systemctl daemon-reload"
            echo "  sudo systemctl start ${PROJECT_NAME}-<service>.service"
        fi
    fi

    echo ""
    log_info "Generated files:"
    ls -la "$OUTPUT_DIR"/ 2>/dev/null || true

    # Also generate Kubernetes manifests if requested
    if [[ "$GENERATE_K8S" == "true" ]]; then
        echo ""
        log_info "Generating Kubernetes manifests..."
        do_k8s
    fi
}

# Action: validate
do_validate() {
    find_compose_file

    log_info "=== Validating Compose File ==="
    log_info "File: $COMPOSE_FILE"
    echo ""

    check_dependencies || exit 1
    run_validation "$COMPOSE_FILE"
}

# Action: check
do_check() {
    log_info "=== Checking Podman Environment ==="
    echo ""

    check_dependencies || exit 1
    validate_podman_environment
    echo ""
    check_system_performance
}

# Action: start
do_start() {
    if [[ -z "$PROJECT_NAME" ]]; then
        log_error "Project name required. Use -p to specify."
        exit 1
    fi

    check_dependencies || exit 1
    start_quadlet_services "$PROJECT_NAME" "$MODE"
}

# Action: stop
do_stop() {
    if [[ -z "$PROJECT_NAME" ]]; then
        log_error "Project name required. Use -p to specify."
        exit 1
    fi

    check_dependencies || exit 1
    stop_quadlet_services "$PROJECT_NAME" "$MODE"
}

# Action: restart
do_restart() {
    if [[ -z "$PROJECT_NAME" ]]; then
        log_error "Project name required. Use -p to specify."
        exit 1
    fi

    check_dependencies || exit 1
    log_info "Restarting all services for project: $PROJECT_NAME"
    stop_quadlet_services "$PROJECT_NAME" "$MODE"
    sleep 2
    start_quadlet_services "$PROJECT_NAME" "$MODE"
}

# Action: logs
do_logs() {
    if [[ -z "$PROJECT_NAME" ]]; then
        log_error "Project name required. Use -p to specify."
        exit 1
    fi

    check_dependencies || exit 1

    log_info "=== Logs for $PROJECT_NAME ==="
    echo ""

    # Get all containers for the project
    local containers
    containers=$(podman ps -a --filter "name=${PROJECT_NAME}" --format "{{.Names}}" 2>/dev/null)

    if [[ -z "$containers" ]]; then
        log_warning "No containers found for project: $PROJECT_NAME"
        return 0
    fi

    while IFS= read -r container; do
        [[ -z "$container" ]] && continue
        echo "=== $container ==="
        podman logs --tail 50 "$container" 2>&1 || true
        echo ""
    done <<< "$containers"
}

# Action: enable
do_enable() {
    if [[ -z "$PROJECT_NAME" ]]; then
        log_error "Project name required. Use -p to specify."
        exit 1
    fi

    check_dependencies || exit 1
    enable_quadlet_services "$PROJECT_NAME" "$MODE"
}

# Action: disable
do_disable() {
    if [[ -z "$PROJECT_NAME" ]]; then
        log_error "Project name required. Use -p to specify."
        exit 1
    fi

    check_dependencies || exit 1
    disable_quadlet_services "$PROJECT_NAME" "$MODE"
}

# Action: export
do_export() {
    if [[ -z "$PROJECT_NAME" ]]; then
        log_error "Project name required. Use -p to specify."
        exit 1
    fi

    check_dependencies || exit 1
    export_to_compose "$PROJECT_NAME"
}

# Action: health
do_health() {
    if [[ -z "$PROJECT_NAME" ]]; then
        log_error "Project name required. Use -p to specify."
        exit 1
    fi

    check_dependencies || exit 1
    check_containers_health "$PROJECT_NAME"
}

# Action: status
do_status() {
    if [[ -z "$PROJECT_NAME" ]]; then
        log_error "Project name required. Use -p to specify."
        exit 1
    fi

    check_dependencies || exit 1

    log_info "=== Service Status for $PROJECT_NAME ==="
    echo ""

    if [[ "$MODE" == "user" ]]; then
        systemctl --user list-units "${PROJECT_NAME}*.service" --no-pager 2>/dev/null || true
    else
        systemctl list-units "${PROJECT_NAME}*.service" --no-pager 2>/dev/null || true
    fi

    echo ""
    log_info "Container status:"
    podman ps -a --filter "name=${PROJECT_NAME}" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || true
}

# Action: cleanup
do_cleanup() {
    log_info "=== Cleaning Up Podman Resources ==="
    echo ""

    check_dependencies || exit 1
    cleanup_resources
}

# Action: optimize
do_optimize() {
    log_info "=== Applying Performance Optimizations ==="
    echo ""

    check_dependencies || exit 1
    apply_optimizations "$MODE"
    generate_sysctl_config
}

# Action: k8s (Kubernetes migration)
do_k8s() {
    find_compose_file
    set_project_name

    log_info "=== Docker to Kubernetes Migration ==="
    log_info "Compose file: $COMPOSE_FILE"
    log_info "Project name: $PROJECT_NAME"
    log_info "Namespace: $K8S_NAMESPACE"
    echo ""

    # Validate first
    run_validation "$COMPOSE_FILE"
    local validation_result=$?

    if [[ $validation_result -ne 0 ]] && [[ "$FORCE" != "true" ]]; then
        log_error "Validation failed. Use --force to migrate anyway."
        exit 1
    fi

    # Check requirements
    check_k8s_requirements

    if [[ "$GENERATE_HELM" == "true" ]]; then
        # Generate Helm chart
        generate_helm_chart "$COMPOSE_FILE" "$PROJECT_NAME" "$HELM_OUTPUT_DIR/$PROJECT_NAME"
    else
        # Generate Kubernetes manifests
        generate_kubernetes_manifests "$COMPOSE_FILE" "$PROJECT_NAME" "$K8S_OUTPUT_DIR"
    fi
}

# Action: selinux-check
do_selinux_status() {
    do_selinux_check  # Function from selinux.sh
}

# Action: selinux-validate
do_selinux_validate() {
    find_compose_file
    validate_compose_volumes "$COMPOSE_FILE"
}

# Action: selinux-fix
do_selinux_fix() {
    find_compose_file
    local permanent="false"
    [[ "${1:-}" == "permanent" ]] && permanent="true"
    fix_compose_volumes "$COMPOSE_FILE" "$permanent"
}

# Action: selinux-analyze
do_selinux_analyze() {
    find_compose_file
    analyze_volume_sharing "$COMPOSE_FILE"
}

# Action: selinux-denials
do_selinux_denials() {
    check_selinux_denials "${1:-60}"
}

# Action: selinux-info
do_selinux_info() {
    get_selinux_info
}

# Action: selinux-policy
do_selinux_policy() {
    generate_selinux_policy_suggestions
}

# Main entry point
main() {
    parse_args "$@"

    case "$ACTION" in
        migrate)
            do_migrate
            ;;
        validate)
            do_validate
            ;;
        check)
            do_check
            ;;
        k8s)
            do_k8s
            ;;
        selinux-check)
            do_selinux_status
            ;;
        selinux-validate)
            do_selinux_validate
            ;;
        selinux-fix)
            do_selinux_fix
            ;;
        selinux-analyze)
            do_selinux_analyze
            ;;
        selinux-denials)
            do_selinux_denials
            ;;
        selinux-info)
            do_selinux_info
            ;;
        selinux-policy)
            do_selinux_policy
            ;;
        start)
            do_start
            ;;
        stop)
            do_stop
            ;;
        restart)
            do_restart
            ;;
        logs)
            do_logs
            ;;
        health)
            do_health
            ;;
        enable)
            do_enable
            ;;
        disable)
            do_disable
            ;;
        export)
            do_export
            ;;
        status)
            do_status
            ;;
        cleanup)
            do_cleanup
            ;;
        optimize)
            do_optimize
            ;;
        *)
            log_error "Unknown action: $ACTION"
            usage
            exit 1
            ;;
    esac
}

# Run main
main "$@"
