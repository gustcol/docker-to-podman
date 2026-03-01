# Docker-Compose to Podman Migration Tool

A comprehensive CLI tool to migrate Docker Compose projects to Podman using the modern Quadlet system. Designed for production Linux servers with performance optimizations and systemd integration.

[![Bash](https://img.shields.io/badge/Bash-3.2%2B-green.svg)](https://www.gnu.org/software/bash/)
[![Podman](https://img.shields.io/badge/Podman-4.4%2B-blue.svg)](https://podman.io/)
[![License](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

## Table of Contents

- [Overview](#overview)
- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Architecture](#architecture)
- [Migration Workflow](#migration-workflow)
- [Detailed Usage](#detailed-usage)
- [Command Reference](#command-reference)
- [Configuration Options](#configuration-options)
- [Examples](#examples)
- [Generated Quadlet Files](#generated-quadlet-files)
- [Performance Optimizations](#performance-optimizations)
- [Docker to Podman Differences](#docker-to-podman-differences)
- [SELinux Integration](#selinux-integration)
  - [Platform Detection](#platform-detection)
  - [SELinux Commands Reference](#selinux-commands-reference)
  - [SELinux Migration Options](#selinux-migration-options)
  - [SELinux Modes](#selinux-modes)
  - [Understanding :Z vs :z Labels](#understanding-z-vs-z-labels)
  - [Automatic Shared Volume Detection](#automatic-shared-volume-detection)
  - [Pre-Migration Validation](#pre-migration-validation)
  - [Automated Remediation](#automated-remediation)
  - [Manual SELinux Fixes](#manual-selinux-fixes)
  - [Troubleshooting SELinux Issues](#troubleshooting-selinux-issues)
  - [SELinux Best Practices](#selinux-best-practices)
- [SELinux Checker Tool](#selinux-checker-tool)
  - [Issue Codes](#issue-codes)
  - [Output Formats](#output-formats)
  - [CI/CD Integration](#cicd-integration)
- [Kubernetes Migration](#kubernetes-migration)
  - [SELinux for Kubernetes](#selinux-for-kubernetes)
- [Troubleshooting](#troubleshooting)
- [Running Tests](#running-tests)
- [Project Structure](#project-structure)
- [Contributing](#contributing)
- [License](#license)
- [References](#references)

---

## Overview

This tool automates the migration from Docker Compose to Podman's native Quadlet system, which provides:

- **Native systemd integration** - Containers managed as systemd services
- **Rootless by default** - Enhanced security without root privileges
- **Production-ready** - Automatic restarts, logging, and dependency management
- **No daemon required** - Unlike Docker, Podman doesn't require a background daemon

### Why Migrate to Podman?

```
Docker Compose                    Podman Quadlet
┌─────────────────┐              ┌─────────────────┐
│  docker-compose │              │    systemd      │
│      ↓          │    ═════►    │      ↓          │
│  Docker Daemon  │   Migrate    │  Podman (OCI)   │
│      ↓          │              │      ↓          │
│   Containers    │              │   Containers    │
└─────────────────┘              └─────────────────┘
    Requires root                   Rootless OK
    Docker daemon                   No daemon
    docker-compose.yml              .container files
```

---

## Features

| Feature | Description |
|---------|-------------|
| **Quadlet Generation** | Creates `.container`, `.network`, and `.volume` files for Podman 4.4+ |
| **Systemd Integration** | Auto-generates systemd service units for production deployment |
| **Performance Optimizations** | Includes tuning recommendations for cgroups v2, network, and storage |
| **Validation** | Pre-migration checks to identify compatibility issues |
| **Rootless Support** | Optimized for rootless Podman deployments |
| **No Dependencies** | Pure Bash implementation (optional `yq` for better YAML parsing) |
| **Dry-Run Mode** | Preview changes before applying them |
| **Multi-Service Support** | Handles complex multi-container applications |
| **Health Monitoring** | Check container health status post-migration |
| **Service Management** | Start, stop, restart, enable/disable services |
| **Log Viewing** | View container logs directly from CLI |
| **Export to Compose** | Export running Podman containers back to docker-compose.yml |
| **Labels Support** | Full support for container labels |
| **Environment Files** | Support for `env_file` directive |

---

## Requirements

| Component | Version | Required |
|-----------|---------|----------|
| Podman | 4.4+ (tested up to 5.8) | Yes |
| Bash | 4.0+ | Yes |
| systemd | 245+ | Yes |
| yq | 4.0+ (latest: 4.52) | Optional (recommended) |
| Helm | 3.x or 4.x | Optional (for Helm chart generation) |
| kubectl | 1.28+ | Optional (for Kubernetes manifests) |

### Installing Dependencies

#### Fedora/RHEL/CentOS

```bash
# Install Podman
sudo dnf install podman

# Optional: Install yq for better YAML parsing
sudo dnf install yq
# Or download binary
sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
sudo chmod +x /usr/local/bin/yq
```

#### Ubuntu/Debian

```bash
# Install Podman
sudo apt update
sudo apt install podman

# Optional: Install yq
sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
sudo chmod +x /usr/local/bin/yq
```

#### macOS (for development/testing)

```bash
# Install Podman
brew install podman

# Initialize Podman machine
podman machine init
podman machine start

# Optional: Install yq
brew install yq
```

---

## Installation

### Option 1: Clone Repository

```bash
# Clone the repository
git clone https://github.com/gustcol/docker-to-podman.git
cd docker-to-podman

# Make scripts executable
chmod +x migrate.sh scripts/*.sh

# Verify installation
./migrate.sh --version
```

### Option 2: Add to System PATH

```bash
# After cloning, create symlink
sudo ln -s $(pwd)/migrate.sh /usr/local/bin/docker-to-podman

# Now use from anywhere
docker-to-podman --help
```

### Option 3: Direct Download

```bash
# Download and extract
curl -L https://github.com/gustcol/docker-to-podman/archive/main.tar.gz | tar xz
cd docker-to-podman-main
chmod +x migrate.sh scripts/*.sh
```

---

## Quick Start

### 5-Minute Migration

```bash
# Step 1: Navigate to your docker-compose project
cd /path/to/your/project

# Step 2: Validate the compose file
./migrate.sh -f docker-compose.yml validate

# Step 3: Generate Quadlet files
./migrate.sh -f docker-compose.yml migrate

# Step 4: Install and start services
./migrate.sh -f docker-compose.yml -i migrate
systemctl --user daemon-reload
systemctl --user start myproject-web.service
```

---

## Architecture

### System Architecture Diagram

```
┌──────────────────────────────────────────────────────────────────────────┐
│                        Docker-to-Podman Migration Tool                    │
├──────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌───────────┐ │
│  │   INPUT     │    │  PARSING    │    │ CONVERSION  │    │  OUTPUT   │ │
│  │             │    │             │    │             │    │           │ │
│  │ docker-     │───►│  parser.sh  │───►│converter.sh │───►│ .container│ │
│  │ compose.yml │    │             │    │             │    │ .network  │ │
│  │             │    │  Extract:   │    │  Convert:   │    │ .volume   │ │
│  │             │    │  - services │    │  - images   │    │           │ │
│  │             │    │  - volumes  │    │  - ports    │    │           │ │
│  │             │    │  - networks │    │  - volumes  │    │           │ │
│  │             │    │  - config   │    │  - env vars │    │           │ │
│  └─────────────┘    └─────────────┘    └─────────────┘    └───────────┘ │
│         │                                                        │       │
│         │          ┌─────────────┐                              │       │
│         └─────────►│ validator.sh│◄─────────────────────────────┘       │
│                    │             │                                       │
│                    │  Validate:  │                                       │
│                    │  - Syntax   │                                       │
│                    │  - Compat.  │                                       │
│                    │  - Warnings │                                       │
│                    └─────────────┘                                       │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌──────────────────────────────────────────────────────────────────────────┐
│                              SYSTEMD                                      │
├──────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  ~/.config/containers/systemd/          /etc/containers/systemd/         │
│  (User Mode - Rootless)                 (System Mode - Root)             │
│                                                                          │
│  ┌─────────────────┐                    ┌─────────────────┐              │
│  │ project-web     │                    │ project-web     │              │
│  │   .container    │                    │   .container    │              │
│  ├─────────────────┤                    ├─────────────────┤              │
│  │ project         │                    │ project         │              │
│  │   .network      │                    │   .network      │              │
│  ├─────────────────┤                    ├─────────────────┤              │
│  │ project_data    │                    │ project_data    │              │
│  │   .volume       │                    │   .volume       │              │
│  └─────────────────┘                    └─────────────────┘              │
│           │                                      │                       │
│           ▼                                      ▼                       │
│  systemctl --user                       systemctl                        │
│  daemon-reload                          daemon-reload                    │
│           │                                      │                       │
│           ▼                                      ▼                       │
│  ┌─────────────────┐                    ┌─────────────────┐              │
│  │ Podman          │                    │ Podman          │              │
│  │ (Rootless)      │                    │ (Root)          │              │
│  └─────────────────┘                    └─────────────────┘              │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

### Component Overview

| Component | File | Purpose |
|-----------|------|---------|
| Main CLI | `migrate.sh` | Command-line interface and workflow orchestration |
| Parser | `scripts/parser.sh` | Docker-compose YAML parsing (with yq or fallback) |
| Converter | `scripts/converter.sh` | Docker to Podman syntax conversion |
| Quadlet Generator | `scripts/quadlet.sh` | Generates .container, .network, .volume files |
| Validator | `scripts/validator.sh` | Pre/post migration validation |
| Performance | `scripts/performance.sh` | System optimization recommendations |
| Utilities | `scripts/utils.sh` | Common helper functions |
| Kubernetes | `scripts/kubernetes.sh` | Kubernetes manifest generation |
| Helm | `scripts/helm.sh` | Helm chart generation |
| SELinux | `scripts/selinux.sh` | SELinux policy management |

---

## Migration Workflow

### Complete Migration Process

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         MIGRATION WORKFLOW                               │
└─────────────────────────────────────────────────────────────────────────┘

     ┌──────────┐
     │  START   │
     └────┬─────┘
          │
          ▼
┌─────────────────────┐
│ 1. VALIDATE INPUT   │
│                     │
│ • Check compose     │
│   file exists       │
│ • Validate YAML     │
│   syntax            │
│ • Check version     │
└─────────┬───────────┘
          │
          ▼
┌─────────────────────┐     ┌─────────────────────┐
│ 2. CHECK ENVIRON.   │────►│  Show Warnings      │
│                     │     │  • Unsupported      │
│ • Podman version    │     │    features         │
│ • Systemd status    │     │  • Privileged ports │
│ • Rootless setup    │     │  • Missing volumes  │
└─────────┬───────────┘     └─────────────────────┘
          │
          ▼
┌─────────────────────┐
│ 3. PARSE COMPOSE    │
│                     │
│ • Extract services  │
│ • Extract networks  │
│ • Extract volumes   │
│ • Extract configs   │
└─────────┬───────────┘
          │
          ▼
┌─────────────────────┐
│ 4. CONVERT SYNTAX   │
│                     │
│ • Image names       │
│ • Port mappings     │
│ • Volume mounts     │
│ • Environment vars  │
│ • Restart policies  │
│ • Health checks     │
└─────────┬───────────┘
          │
          ▼
┌─────────────────────┐
│ 5. GENERATE FILES   │
│                     │
│ • .container files  │
│ • .network files    │
│ • .volume files     │
└─────────┬───────────┘
          │
          ▼
     ┌────────────┐
     │  INSTALL?  │
     └─────┬──────┘
           │
     ┌─────┴─────┐
     │           │
    YES          NO
     │           │
     ▼           ▼
┌─────────┐  ┌─────────┐
│ Copy to │  │ Output  │
│ systemd │  │ to dir  │
│ dir     │  │         │
└────┬────┘  └────┬────┘
     │            │
     ▼            │
┌─────────┐       │
│ Reload  │       │
│ systemd │       │
└────┬────┘       │
     │            │
     └─────┬──────┘
           │
           ▼
      ┌────────┐
      │  DONE  │
      └────────┘
```

### Decision Flow: User Mode vs System Mode

```
                    ┌─────────────────┐
                    │ Choose Mode     │
                    └────────┬────────┘
                             │
              ┌──────────────┴──────────────┐
              │                             │
              ▼                             ▼
    ┌─────────────────┐           ┌─────────────────┐
    │   USER MODE     │           │   SYSTEM MODE   │
    │   (Rootless)    │           │     (Root)      │
    └────────┬────────┘           └────────┬────────┘
             │                             │
             ▼                             ▼
    ┌─────────────────┐           ┌─────────────────┐
    │ Best for:       │           │ Best for:       │
    │ • Development   │           │ • Production    │
    │ • Testing       │           │ • System svc    │
    │ • User apps     │           │ • Multi-user    │
    └────────┬────────┘           └────────┬────────┘
             │                             │
             ▼                             ▼
    ┌─────────────────┐           ┌─────────────────┐
    │ Location:       │           │ Location:       │
    │ ~/.config/      │           │ /etc/           │
    │ containers/     │           │ containers/     │
    │ systemd/        │           │ systemd/        │
    └────────┬────────┘           └────────┬────────┘
             │                             │
             ▼                             ▼
    ┌─────────────────┐           ┌─────────────────┐
    │ Commands:       │           │ Commands:       │
    │ systemctl       │           │ sudo systemctl  │
    │ --user ...      │           │ ...             │
    └─────────────────┘           └─────────────────┘
```

---

## Detailed Usage

### Step-by-Step Migration Guide

#### Step 1: Prepare Your Environment

```bash
# Check Podman installation
podman --version

# For rootless mode, ensure user lingering is enabled
loginctl enable-linger $USER

# Verify systemd user session
systemctl --user status
```

#### Step 2: Validate Your Docker Compose File

```bash
# Run validation
./migrate.sh -f docker-compose.yml validate

# Example output:
# [INFO] Validating compose file: docker-compose.yml
# [INFO] === Validation Results ===
# [WARNING] Warnings (1):
#   - Service 'web': Port 80 is privileged. Rootless Podman may need...
```

#### Step 3: Check Your Podman Environment

```bash
# Run environment check
./migrate.sh check

# Example output:
# [INFO] Checking Podman environment...
# [INFO] Podman version: 4.7.0
# [INFO] Running in rootless mode
# [INFO] cgroups v2 detected (recommended)
# [SUCCESS] Podman environment is ready!
```

#### Step 4: Perform Dry Run (Recommended)

```bash
# Preview what will be generated
./migrate.sh -f docker-compose.yml -n migrate

# Output shows planned changes without making them
# [INFO] DRY RUN: Would generate Quadlet files
# [INFO] DRY RUN: myproject-web.container
# [INFO] DRY RUN: myproject.network
```

#### Step 5: Generate Quadlet Files

```bash
# Generate files to custom directory
./migrate.sh -f docker-compose.yml -o ./quadlet migrate

# Or generate and install directly
./migrate.sh -f docker-compose.yml -i migrate
```

#### Step 6: Start Your Services

```bash
# Reload systemd to pick up new units
systemctl --user daemon-reload

# Start individual service
systemctl --user start myproject-web.service

# Or start all project services
./migrate.sh -p myproject start

# Enable auto-start on boot
systemctl --user enable myproject-web.service
```

#### Step 7: Monitor and Manage

```bash
# Check status
systemctl --user status myproject-web.service

# View logs
journalctl --user -u myproject-web.service -f

# Stop service
systemctl --user stop myproject-web.service

# Restart service
systemctl --user restart myproject-web.service
```

---

## Command Reference

```
Docker-Compose to Podman Migration Tool v1.0.0

Usage: migrate.sh [OPTIONS] COMMAND

Commands:
  migrate       Convert docker-compose.yml to Podman Quadlet files (default)
  validate      Validate docker-compose.yml without migrating
  check         Check Podman environment and suggest optimizations
  start         Start all services for a project
  stop          Stop all services for a project
  restart       Restart all services for a project
  status        Show status of migrated services
  logs          Show logs for migrated services
  health        Check health of running containers
  enable        Enable auto-start on boot for all services
  disable       Disable auto-start on boot for all services
  cleanup       Remove unused Podman resources
  export        Export running containers as docker-compose.yml

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
```

### Command Details

#### `migrate` - Main Migration Command

Converts docker-compose.yml to Podman Quadlet files.

```bash
# Basic usage
./migrate.sh -f docker-compose.yml migrate

# With custom project name
./migrate.sh -f docker-compose.yml -p myapp migrate

# Generate and install
./migrate.sh -f docker-compose.yml -i migrate

# Force overwrite existing files
./migrate.sh -f docker-compose.yml --force migrate

# System-wide installation (requires root)
sudo ./migrate.sh -f docker-compose.yml -m system -i migrate
```

#### `validate` - Validation Command

Checks docker-compose.yml for compatibility issues.

```bash
./migrate.sh -f docker-compose.yml validate

# With debug output
./migrate.sh -f docker-compose.yml -d validate
```

#### `check` - Environment Check

Analyzes your Podman environment and suggests optimizations.

```bash
./migrate.sh check

# Example recommendations:
# [NETWORK] Install pasta for better rootless network performance
# [ROOTLESS] Enable lingering for user services to persist after logout
# [KERNEL] Increase inotify watches for better file monitoring
```

#### `start` / `stop` / `restart` - Service Management

```bash
# Start all project services
./migrate.sh -p myproject start

# Stop all project services
./migrate.sh -p myproject stop

# Restart all services
./migrate.sh -p myproject restart
```

#### `status` - Check Service Status

```bash
# View systemd service status and container state
./migrate.sh -p myproject status
```

#### `logs` - View Container Logs

```bash
# View last 50 lines of logs for all project containers
./migrate.sh -p myproject logs
```

#### `health` - Container Health Check

```bash
# Check health status of running containers
./migrate.sh -p myproject health

# Example output:
# [INFO] Checking health of containers for project: myproject
# [SUCCESS] myproject-web: healthy
# [WARNING] myproject-api: starting (health check in progress)
# [ERROR] myproject-worker: unhealthy
#   Last check output: Connection refused
```

#### `enable` / `disable` - Auto-Start Management

```bash
# Enable auto-start on system boot
./migrate.sh -p myproject enable

# Disable auto-start
./migrate.sh -p myproject disable
```

#### `export` - Export to Docker Compose

Export running Podman containers back to a docker-compose.yml file (useful for documentation or reverting).

```bash
# Export containers for a project
./migrate.sh -p myproject export

# Creates docker-compose.exported.yml with current configuration
```

#### `cleanup` - Resource Cleanup

Removes unused Podman resources.

```bash
./migrate.sh cleanup

# Removes:
# - Stopped containers
# - Dangling images
# - Unused volumes
# - Unused networks
```

---

## Configuration Options

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `DEBUG` | `0` | Set to `1` for debug output |
| `USE_YQ` | auto | Set to `0` to force fallback parser |

### Project Name Resolution

The project name is determined in this order:
1. `-p, --project` command line option
2. Directory name containing the compose file

```bash
# Explicit project name
./migrate.sh -p myapp -f /path/to/docker-compose.yml migrate
# Result: myapp-web.container

# Automatic from directory
./migrate.sh -f /projects/webapp/docker-compose.yml migrate
# Result: webapp-web.container
```

---

## Examples

### Example 1: Simple Web Server

**docker-compose.yml:**
```yaml
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
```

**Migration:**
```bash
./migrate.sh -f docker-compose.yml -p webserver migrate
```

**Generated `webserver-web.container`:**
```ini
[Unit]
Description=web container (migrated from docker-compose)

[Container]
Image=docker.io/library/nginx:alpine
ContainerName=webserver-web
PublishPort=8080:80/tcp
Volume=./html:/usr/share/nginx/html:ro,Z
Environment=NGINX_HOST=localhost
Network=webserver.network

# Performance optimizations
AutoUpdate=registry

[Service]
Restart=always
TimeoutStartSec=300

[Install]
WantedBy=default.target
```

### Example 2: Multi-Service Application

**docker-compose.yml:**
```yaml
version: '3.8'

services:
  app:
    image: myapp:latest
    ports:
      - "3000:3000"
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
  db_data:
```

**Migration:**
```bash
./migrate.sh -f docker-compose.yml -p myapp -i migrate
```

**Generated Files:**
```
quadlet/
├── myapp-app.container      # App service with dependencies
├── myapp-db.container       # Database service
├── myapp-cache.container    # Redis cache service
├── myapp.network            # Default network
├── myapp-frontend.network   # Frontend network
├── myapp-backend.network    # Backend network
└── myapp_db_data.volume     # Database volume
```

**Starting the Application:**
```bash
# Reload systemd
systemctl --user daemon-reload

# Start in dependency order (handled automatically)
systemctl --user start myapp-app.service

# Check all services
./migrate.sh -p myapp status
```

### Example 3: Application with Health Checks

**docker-compose.yml:**
```yaml
version: '3.8'

services:
  api:
    image: myapi:latest
    ports:
      - "8080:8080"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
    deploy:
      resources:
        limits:
          memory: 512M
          cpus: '1.0'
    restart: always
```

**Generated health check configuration:**
```ini
[Container]
...
HealthCmd=curl -f http://localhost:8080/health
HealthInterval=30s
HealthTimeout=10s
HealthRetries=3
PodmanArgs=--memory=512M
PodmanArgs=--cpus=1.0
```

### Example 4: Application with Environment Files and Labels

**docker-compose.yml:**
```yaml
version: '3.8'

services:
  app:
    image: myapp:latest
    env_file:
      - .env
      - .env.local
    labels:
      - "app.name=myapp"
      - "app.version=1.0.0"
      - "maintainer=team@example.com"
    user: "1000:1000"
    working_dir: /app
    ports:
      - "3000:3000"
```

**.env file:**
```
DATABASE_URL=postgres://localhost:5432/mydb
REDIS_URL=redis://localhost:6379
LOG_LEVEL=info
```

**Generated container file:**
```ini
[Container]
Image=docker.io/library/myapp:latest
ContainerName=myapp-app
PublishPort=3000:3000/tcp
EnvironmentFile=/path/to/.env
EnvironmentFile=/path/to/.env.local
User=1000:1000
WorkingDir=/app
Label=app.name=myapp
Label=app.version=1.0.0
Label=maintainer=team@example.com
```

---

## Generated Quadlet Files

### Container File Structure (`.container`)

```ini
# project-service.container

[Unit]
Description=service container (migrated from docker-compose)
After=project-dependency.service          # From depends_on
Requires=project-dependency.service       # From depends_on

[Container]
Image=docker.io/library/image:tag         # Normalized image name
ContainerName=project-service             # Container name
PublishPort=8080:80/tcp                   # Port mappings
Volume=/host/path:/container/path:Z       # Volume mounts with SELinux
Environment=KEY=value                     # Environment variables
EnvironmentFile=/path/to/.env             # Environment file
Network=project.network                   # Network reference
User=1000                                 # Container user
WorkingDir=/app                           # Working directory
Label=app.version=1.0                     # Container labels
Label=maintainer=team@example.com
Entrypoint=/custom/entrypoint             # Custom entrypoint
Exec=command args                         # Command to run
HealthCmd=curl -f http://localhost/health # Health check
HealthInterval=30s
HealthTimeout=10s
HealthRetries=3
PodmanArgs=--memory=512M                  # Resource limits
PodmanArgs=--cpus=1.0

# Performance optimizations
AutoUpdate=registry                       # Auto-update from registry

[Service]
Restart=always                            # Restart policy
TimeoutStartSec=300                       # Start timeout

[Install]
WantedBy=default.target                   # Enable on boot
```

### Network File Structure (`.network`)

```ini
# project-network.network

[Network]
NetworkName=project-network
Driver=bridge

[Install]
WantedBy=default.target
```

### Volume File Structure (`.volume`)

```ini
# project_volume.volume

[Volume]
VolumeName=project_volume

[Install]
WantedBy=default.target
```

### Quadlet File Locations

| Mode | Location | Command Prefix |
|------|----------|----------------|
| User (rootless) | `~/.config/containers/systemd/` | `systemctl --user` |
| System (root) | `/etc/containers/systemd/` | `sudo systemctl` |

---

## Performance Optimizations

### Automatic Optimizations

The tool automatically applies these optimizations:

| Optimization | Description |
|--------------|-------------|
| Image normalization | Adds `docker.io/library/` prefix for official images |
| SELinux labels | Adds `:Z` to volume mounts for proper labeling |
| Auto-update | Enables automatic container updates from registry |
| Proper timeouts | Sets appropriate service start timeouts |

### Network Performance

```bash
# Check current network backend
podman info --format '{{.Host.NetworkBackend}}'

# Install pasta for better rootless performance
sudo dnf install passt  # Fedora/RHEL
sudo apt install passt  # Ubuntu/Debian

# Configure in containers.conf
cat >> ~/.config/containers/containers.conf << EOF
[network]
default_rootless_network_cmd = "pasta"
EOF
```

### Storage Performance

```bash
# Create optimized storage.conf
cat > ~/.config/containers/storage.conf << 'EOF'
[storage]
driver = "overlay"

[storage.options.overlay]
mountopt = "nodev,metacopy=on"
EOF
```

### Kernel Tuning for Production

```bash
# Generate sysctl configuration
cat > /tmp/podman-sysctl.conf << 'EOF'
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
EOF

# Apply configuration
sudo cp /tmp/podman-sysctl.conf /etc/sysctl.d/99-podman.conf
sudo sysctl --system
```

### Rootless Setup Checklist

```bash
# 1. Enable user lingering (persist services after logout)
loginctl enable-linger $USER

# 2. Configure subuid/subgid (if not already configured)
sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $USER

# 3. Verify configuration
podman unshare cat /proc/self/uid_map

# 4. Reset storage if needed
podman system reset
```

---

## Docker to Podman Differences

### Configuration Mapping

| Docker Compose | Podman Quadlet | Notes |
|----------------|----------------|-------|
| `image: nginx` | `Image=docker.io/library/nginx` | Registry prefix added |
| `restart: always` | `Restart=always` | In [Service] section |
| `restart: unless-stopped` | `Restart=always` | Closest equivalent |
| `restart: on-failure` | `Restart=on-failure` | Direct mapping |
| `ports: "80:80"` | `PublishPort=80:80/tcp` | Explicit protocol |
| `volumes: ./data:/app` | `Volume=./data:/app:Z` | SELinux label added |
| `volumes: data:/app` | `Volume=project_data:/app` | Named volume prefixed |
| `depends_on: [db]` | `After=project-db.service` | In [Unit] section |
| `networks: [frontend]` | `Network=project-frontend.network` | References .network file |
| `environment: KEY=val` | `Environment=KEY=val` | Direct mapping |
| `command: args` | `Exec=args` | Container command |
| `entrypoint: /entry` | `Entrypoint=/entry` | Container entrypoint |
| `mem_limit: 512m` | `PodmanArgs=--memory=512m` | Via PodmanArgs |
| `cpus: 1.0` | `PodmanArgs=--cpus=1.0` | Via PodmanArgs |
| `env_file: [.env]` | `EnvironmentFile=.env` | Environment file loading |
| `labels: [key=val]` | `Label=key=val` | Container labels |
| `user: "1000"` | `User=1000` | Container user |
| `working_dir: /app` | `WorkingDir=/app` | Working directory |

### Unsupported Features

These Docker Compose features require manual handling:

| Feature | Status | Workaround |
|---------|--------|------------|
| `build:` | Warning | Build image separately with `podman build` |
| `links:` | Deprecated | Use networks instead |
| `extends:` | Not supported | Manually merge configurations |
| `external_links:` | Limited | May need manual network configuration |
| `network_mode: host` | Supported | Works but requires additional setup in rootless |

---

## SELinux Integration

This tool provides comprehensive SELinux support for systems running SELinux (RHEL, Fedora, CentOS, Rocky Linux, AlmaLinux). The SELinux module includes automatic detection, shared volume analysis, pre-migration validation, and automated remediation.

### Platform Detection

The tool automatically detects your system's security configuration:

| Platform | Detection | Behavior |
|----------|-----------|----------|
| SELinux Enforcing | `getenforce` returns Enforcing | Full SELinux labels applied (`:Z` or `:z`) |
| SELinux Permissive | `getenforce` returns Permissive | Labels applied for future enforcement |
| SELinux Disabled | `getenforce` returns Disabled | No labels added |
| AppArmor (Ubuntu/Debian) | `aa-status` detected | No SELinux labels, AppArmor handles security |
| WSL (Windows) | `/proc/version` contains "microsoft" | No SELinux labels |
| macOS | `uname -s` returns Darwin | No SELinux labels (Podman runs in VM) |
| Not Installed | No `getenforce` command | No SELinux labels |

### SELinux Commands Reference

The tool provides multiple SELinux-related commands:

```bash
# Check SELinux status and get recommendations
./migrate.sh selinux-check

# Validate volume SELinux contexts before migration
./migrate.sh -f docker-compose.yml selinux-validate

# Automatically fix SELinux contexts for volumes
./migrate.sh -f docker-compose.yml selinux-fix

# Analyze which volumes are shared between containers
./migrate.sh -f docker-compose.yml selinux-analyze

# Check recent SELinux denials (requires audit access)
./migrate.sh selinux-denials

# Show detailed SELinux information
./migrate.sh selinux-info

# Generate policy suggestions from audit logs
./migrate.sh selinux-policy
```

### SELinux Migration Options

```bash
# Migrate with automatic SELinux detection (default)
./migrate.sh -f docker-compose.yml migrate

# Force private labels (:Z) on all bind mounts
./migrate.sh -f docker-compose.yml --selinux=enforcing migrate

# Use shared labels (:z) for all volumes
./migrate.sh -f docker-compose.yml --selinux=shared migrate

# Use private labels (:Z) explicitly
./migrate.sh -f docker-compose.yml --selinux=private migrate

# Disable SELinux labels completely
./migrate.sh -f docker-compose.yml --selinux=disabled migrate

# Validate SELinux contexts before migration
./migrate.sh -f docker-compose.yml --selinux-validate migrate

# Auto-fix SELinux contexts during migration
./migrate.sh -f docker-compose.yml --selinux-auto-fix migrate

# Combine validation and auto-fix
./migrate.sh -f docker-compose.yml --selinux-validate --selinux-auto-fix migrate
```

### SELinux Modes

| Mode | Flag | Label | Description |
|------|------|-------|-------------|
| Auto | `--selinux=auto` | Depends on detection | Auto-detect SELinux and apply appropriate labels (default) |
| Enforcing | `--selinux=enforcing` | `:Z` or `:z` | Force labels, respects shared volume detection |
| Private | `--selinux=private` | `:Z` | Force private labels on all bind mounts |
| Shared | `--selinux=shared` | `:z` | Force shared labels on all bind mounts |
| Disabled | `--selinux=disabled` | None | No SELinux labels added |

### Understanding :Z vs :z Labels

The SELinux labels determine how container volumes are relabeled:

| Label | Type | SELinux Context | Use Case |
|-------|------|-----------------|----------|
| `:Z` | Private | `container_file_t` | Volume accessed by single container only |
| `:z` | Shared | `container_share_t` | Volume shared between multiple containers |

**Important considerations:**

- **`:Z` (Private)**: Relabels the content with a private unshared label. Only one container can access this volume. Using `:Z` on a shared volume will cause permission issues for other containers.
- **`:z` (Shared)**: Relabels the content with a shared label. Multiple containers can share this volume safely. This is less restrictive but still provides SELinux protection.

### Automatic Shared Volume Detection

The tool automatically analyzes your `docker-compose.yml` to detect volumes shared between multiple services:

```yaml
# Example: ./data is shared between web and worker
services:
  web:
    volumes:
      - ./data:/app/data      # Shared volume - gets :z
      - ./web-config:/config  # Private volume - gets :Z
  worker:
    volumes:
      - ./data:/app/data      # Same volume - detected as shared
      - ./worker-logs:/logs   # Private volume - gets :Z
```

When using `--selinux=auto` or `--selinux=enforcing`, the tool will:
1. Analyze all volume mounts across services
2. Detect volumes used by multiple containers
3. Apply `:z` (shared) to shared volumes
4. Apply `:Z` (private) to single-container volumes

To see which volumes are detected as shared:

```bash
./migrate.sh -f docker-compose.yml selinux-analyze
```

### Pre-Migration Validation

Validate volume SELinux contexts before migration:

```bash
./migrate.sh -f docker-compose.yml selinux-validate
```

This checks:
- If volume paths exist
- If paths have correct SELinux context (`container_file_t` or `container_share_t`)
- Provides fix suggestions for any issues

Example output:
```
=== SELinux Volume Validation ===

[OK] /home/user/project/data
[WARNING] Incorrect SELinux context for: /home/user/project/logs
          Current: unconfined_u:object_r:user_home_t:s0
          Expected: container_file_t or container_share_t

=== Issues Found ===

Run './migrate.sh selinux-fix' to automatically fix these issues
Or use the following manual commands:

  chcon -Rt container_file_t '/home/user/project/logs'
```

### Automated Remediation

Automatically fix SELinux contexts:

```bash
# Temporary fix (lost on system relabel)
./migrate.sh -f docker-compose.yml selinux-fix

# Permanent fix (persists across relabels)
./migrate.sh -f docker-compose.yml selinux-fix permanent
```

The fix command will:
1. Create missing directories
2. Apply appropriate SELinux context (`container_file_t` or `container_share_t`)
3. Optionally create persistent fcontext rules using `semanage`

### Manual SELinux Fixes

If you prefer manual control or need to fix specific paths:

```bash
# For private volumes (single container)
chcon -Rt container_file_t /path/to/volume

# For shared volumes (multiple containers)
chcon -Rt container_share_t /path/to/volume

# Make changes persistent across system relabels
semanage fcontext -a -t container_file_t '/path/to/volume(/.*)?'
restorecon -Rv /path/to/volume

# Verify the context was applied
ls -Zd /path/to/volume
```

### Troubleshooting SELinux Issues

#### Check for SELinux Denials

```bash
# Using the migration tool
./migrate.sh selinux-denials

# Using system tools
ausearch -m avc -ts recent
journalctl -t setroubleshoot
```

#### Generate Policy Suggestions

If you have persistent SELinux denials:

```bash
# Using the migration tool
./migrate.sh selinux-policy

# Using system tools
ausearch -m avc -ts recent | audit2allow -M mycontainerpolicy
semodule -i mycontainerpolicy.pp
```

#### Common SELinux Errors and Solutions

| Error | Cause | Solution |
|-------|-------|----------|
| `Permission denied` on volume | Wrong SELinux context | Run `selinux-fix` or add `:Z`/`:z` label |
| `avc: denied` in audit log | SELinux blocking access | Check context with `ls -Z`, apply correct type |
| Volume works for one container, not another | Using `:Z` on shared volume | Change to `:z` for shared volumes |
| Context resets after reboot | Not using persistent fix | Use `semanage fcontext` + `restorecon` |

#### Required Packages

For full SELinux functionality, ensure these packages are installed:

**Fedora/RHEL/CentOS:**
```bash
# Core container SELinux policy
sudo dnf install container-selinux

# For semanage command (persistent contexts)
sudo dnf install policycoreutils-python-utils

# For audit2allow (policy generation)
sudo dnf install policycoreutils-devel

# For auditing
sudo dnf install audit
```

**Ubuntu/Debian (if using SELinux):**
```bash
sudo apt install selinux-policy-default policycoreutils
```

### SELinux Best Practices

1. **Always validate before migration**: Run `selinux-validate` before `migrate` to catch issues early.

2. **Use auto mode for most cases**: The `--selinux=auto` mode handles most scenarios correctly.

3. **Analyze shared volumes**: If your compose file has complex volume sharing, run `selinux-analyze` first.

4. **Test in permissive mode first**: If unsure, set SELinux to permissive (`setenforce 0`), migrate, then check for denials.

5. **Use persistent fixes for production**: Always use `selinux-fix permanent` or `semanage fcontext` for production deployments.

6. **Document your volume sharing**: Add comments in your compose file indicating which volumes are shared.

### Advanced Security Options

The tool supports comprehensive security configurations from docker-compose.yml that affect SELinux and container security:

#### security_opt Support

All SELinux-related security options are parsed and converted:

```yaml
services:
  app:
    security_opt:
      - label:type:container_runtime_t  # Custom SELinux type
      - label:level:s0:c100,c200        # MCS/MLS level
      - label:user:system_u             # SELinux user
      - label:role:system_r             # SELinux role
      - label:disable                    # Disable SELinux labeling
      - no-new-privileges               # Prevent privilege escalation
```

**Generated Quadlet output:**
```ini
[Container]
SecurityLabelType=container_runtime_t
PodmanArgs=--security-opt=label=level:s0:c100,c200
PodmanArgs=--security-opt=label=user:system_u
PodmanArgs=--security-opt=label=role:system_r
```

#### Capability Management

Linux capabilities are fully supported for fine-grained security control:

```yaml
services:
  app:
    cap_add:
      - NET_ADMIN       # Network administration
      - SYS_TIME        # System time manipulation
    cap_drop:
      - ALL             # Drop all capabilities first
      - MKNOD           # Prevent device creation
```

**Generated Quadlet output:**
```ini
[Container]
AddCapability=NET_ADMIN
AddCapability=SYS_TIME
DropCapability=ALL
DropCapability=MKNOD
```

**SELinux Impact:** Adding dangerous capabilities like `SYS_ADMIN` or `ALL` is equivalent to running privileged and will trigger warnings from `selinux-check`.

#### Privileged Containers

Privileged containers automatically use the `spc_t` (super privileged container) SELinux type:

```yaml
services:
  privileged-app:
    privileged: true
```

**Generated Quadlet output:**
```ini
[Container]
SecurityLabelType=spc_t
PodmanArgs=--privileged
```

**Warning:** Privileged containers bypass most SELinux protections. Use only when absolutely necessary.

#### Namespace Modes

Namespace sharing options are converted with appropriate SELinux considerations:

```yaml
services:
  host-network-app:
    network_mode: host      # Share host network namespace

  shared-ipc-app:
    ipc: host               # Share host IPC namespace

  pid-sharing-app:
    pid: host               # Share host PID namespace

  custom-userns:
    userns_mode: keep-id    # User namespace mode
```

**Generated Quadlet output:**
```ini
[Container]
Network=host
PodmanArgs=--ipc=host
PodmanArgs=--pid=host
PodmanArgs=--userns=keep-id
```

**SELinux Impact:** Host namespace sharing reduces isolation and may require custom SELinux policies.

#### Tmpfs and Device Mounts

Tmpfs mounts and device access are supported with SELinux context awareness:

```yaml
services:
  app:
    tmpfs:
      - /tmp
      - /run:size=100m,mode=1777
    devices:
      - /dev/sda:/dev/sda:rwm
      - /dev/fuse
```

**Generated Quadlet output:**
```ini
[Container]
Tmpfs=/tmp
Tmpfs=/run:size=100m,mode=1777
AddDevice=/dev/sda:/dev/sda:rwm
AddDevice=/dev/fuse
```

**SELinux Impact:** Device access typically requires the `container_device_t` context on the device node.

#### Read-Only Root Filesystem

Security hardening with read-only root filesystem:

```yaml
services:
  secure-app:
    read_only: true
    tmpfs:
      - /tmp
      - /var/run
```

**Generated Quadlet output:**
```ini
[Container]
ReadOnly=true
Tmpfs=/tmp
Tmpfs=/var/run
```

#### Complete Security Example

Here's a comprehensive example showing all security options:

```yaml
version: '3.8'

services:
  secure-web:
    image: nginx:alpine
    read_only: true
    security_opt:
      - label:type:container_t
      - label:level:s0:c123,c456
      - no-new-privileges
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
      - CHOWN
    tmpfs:
      - /tmp:size=64m
      - /var/cache/nginx:size=128m
    volumes:
      - ./config:/etc/nginx/conf.d:ro,Z
      - ./logs:/var/log/nginx:z
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SELINUX_MODE` | `auto` | SELinux mode (auto, enforcing, shared, private, disabled) |
| `SELINUX_AUTO_FIX` | `false` | Automatically fix SELinux contexts during migration |
| `SELINUX_VALIDATE` | `false` | Validate SELinux contexts before migration |

---

## SELinux Checker Tool

The project includes `selinux-check`, a standalone tool similar to `shellcheck` but for SELinux container configurations. It analyzes compose files, paths, and system configuration for potential SELinux issues.

### Quick Start

```bash
# Check a compose file
./selinux-check docker-compose.yml

# Check multiple paths
./selinux-check /data/app /var/lib/containers

# Full system check
./selinux-check --verbose

# JSON output for CI/CD
./selinux-check -f json docker-compose.yml
```

### Issue Codes

The tool reports issues with specific codes for easy identification:

#### System Checks (SC1xxx)

| Code | Severity | Description |
|------|----------|-------------|
| SC1001 | warning | SELinux not installed or disabled |
| SC1002 | error | container-selinux package not installed |
| SC1003 | warning | SELinux in permissive mode |
| SC1004 | warning | Missing SELinux policy tools |
| SC1005 | warning | Outdated container-selinux version |
| SC1006 | warning | Missing audit tools for denial analysis |

#### Compose File Checks (SC2xxx)

| Code | Severity | Description |
|------|----------|-------------|
| SC2001 | warning | Volume mount missing SELinux label (:Z or :z) |
| SC2002 | error | Shared volume using private label (:Z instead of :z) |
| SC2003 | warning | Privileged container may bypass SELinux |
| SC2004 | warning | security_opt disabling SELinux |
| SC2005 | warning | Incompatible volume options |
| SC2006 | info | Custom SELinux type specified |
| SC2007 | error/warning | Dangerous capabilities added (SYS_ADMIN, ALL, etc.) |
| SC2008 | warning | Host network namespace sharing |
| SC2009 | warning | Host IPC namespace sharing |
| SC2010 | warning | Host PID namespace sharing |
| SC2011 | info | Tmpfs without size limits |
| SC2012 | info | Device access may require SELinux policy |
| SC2013 | info | Read-only root filesystem not set |
| SC2014 | info | No capabilities dropped (security hardening) |
| SC2015 | info | User namespace mode may affect SELinux |

#### Path Checks (SC3xxx)

| Code | Severity | Description |
|------|----------|-------------|
| SC3001 | warning | Path has incorrect SELinux context |
| SC3002 | warning | Path context will be lost on relabel |
| SC3003 | error | Path not accessible to containers |
| SC3004 | info | Path requires manual SELinux fix |
| SC3005 | info | Device path requires container_device_t context |

#### Runtime Checks (SC4xxx)

| Code | Severity | Description |
|------|----------|-------------|
| SC4001 | warning | Recent SELinux denials for containers |
| SC4002 | warning | Container running with wrong context |
| SC4003 | error | Volume mount causing denials |
| SC4004 | warning | Container running as privileged (spc_t) |
| SC4005 | warning | Container capabilities elevated |

### Output Formats

```bash
# Text output (default, colorized)
./selinux-check docker-compose.yml

# JSON output (for programmatic use)
./selinux-check -f json docker-compose.yml

# GCC-style output (for IDE integration)
./selinux-check -f gcc docker-compose.yml

# Checkstyle XML (for CI/CD tools)
./selinux-check -f checkstyle docker-compose.yml
```

### Example Output

```
selinux-check v1.0.0 - SELinux Configuration Checker

=== System SELinux Checks ===

[INFO] SC1000: SELinux is enforcing
[OK] SC1002: container-selinux installed: container-selinux-2.229.0-1.fc39

=== Compose File Checks: docker-compose.yml ===

[WARNING] docker-compose.yml:15 SC2001: Volume mount missing SELinux label (:Z or :z): ./data
[ERROR] docker-compose.yml:22 SC2002: Shared volume using private label (:Z). Use :z for shared volumes: ./shared

=== SELinux Check Summary ===

Errors: 1
[ERROR] docker-compose.yml:22 SC2002: Shared volume using private label (:Z). Use :z for shared volumes: ./shared

Warnings: 1
[WARNING] docker-compose.yml:15 SC2001: Volume mount missing SELinux label (:Z or :z): ./data

Total issues: 2
```

### CI/CD Integration

#### GitHub Actions

```yaml
- name: SELinux Check
  run: |
    ./selinux-check -f json docker-compose.yml > selinux-report.json
    if [ $? -eq 1 ]; then
      echo "SELinux errors found!"
      exit 1
    fi
```

#### GitLab CI

```yaml
selinux-check:
  script:
    - ./selinux-check -f checkstyle docker-compose.yml > selinux-report.xml
  artifacts:
    reports:
      junit: selinux-report.xml
```

### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | No issues found |
| 1 | Errors found |
| 2 | Warnings found (no errors) |
| 3 | Usage error |

---

## Kubernetes Migration

This tool can also generate Kubernetes manifests and Helm charts from your docker-compose.yml files.

### Kubernetes Commands

```bash
# Generate Kubernetes manifests
./migrate.sh -f docker-compose.yml k8s

# Generate Kubernetes manifests with custom namespace
./migrate.sh -f docker-compose.yml k8s --k8s-namespace=production

# Generate Helm chart
./migrate.sh -f docker-compose.yml k8s --helm

# Custom output directory
./migrate.sh -f docker-compose.yml k8s --k8s-output=./manifests
```

### Docker Compose to Kubernetes Mapping

| Docker Compose | Kubernetes Resource |
|---------------|---------------------|
| `services:` | Deployment + Service |
| `image:` | `spec.containers[].image` |
| `ports:` | Service ports + containerPort |
| `volumes:` (named) | PersistentVolumeClaim |
| `volumes:` (bind) | hostPath or ConfigMap |
| `environment:` | ConfigMap or env vars |
| `env_file:` | ConfigMap from file |
| `deploy.replicas:` | `spec.replicas` |
| `deploy.resources:` | `resources.limits/requests` |
| `healthcheck:` | livenessProbe / readinessProbe |
| `restart:` | `restartPolicy` |
| `command:` | `spec.containers[].args` |
| `entrypoint:` | `spec.containers[].command` |

### Generated Kubernetes Files

```
k8s/
├── namespace.yaml          # Namespace (if not default)
├── kustomization.yaml      # Kustomize configuration
├── web-deployment.yaml     # Deployment for each service
├── web-service.yaml        # Service for exposed ports
├── web-configmap.yaml      # Environment variables
└── myproject-data-pvc.yaml # PVC for named volumes
```

### Helm Chart Structure

When using `--helm`, a complete Helm chart is generated:

```
charts/myproject/
├── Chart.yaml              # Chart metadata
├── values.yaml             # Configurable values
├── .helmignore             # Files to ignore
└── templates/
    ├── _helpers.tpl        # Template helpers
    ├── deployment.yaml     # Deployment template
    ├── service.yaml        # Service template
    └── NOTES.txt           # Post-install notes
```

### Deploying to Kubernetes

```bash
# Using kubectl directly
kubectl apply -f ./k8s/

# Using kustomize
kubectl apply -k ./k8s/

# Using Helm
helm install myproject ./charts/myproject

# Helm with custom values
helm install myproject ./charts/myproject -f custom-values.yaml

# Dry run to preview
helm install myproject ./charts/myproject --dry-run --debug
```

### Kubernetes Requirements

| Tool | Required | Purpose |
|------|----------|---------|
| kubectl | Optional | Deploy and manage K8s resources |
| helm | Optional | Deploy Helm charts |
| kustomize | Optional | Customize manifests |

### SELinux for Kubernetes

When generating Kubernetes manifests, SELinux security contexts are automatically added to pod specifications when appropriate.

#### Kubernetes SELinux Options

```bash
# Enable SELinux in Kubernetes manifests (auto-detected by default)
K8S_SELINUX_ENABLED=true ./migrate.sh -k -f docker-compose.yml migrate

# Disable SELinux in Kubernetes manifests
K8S_SELINUX_ENABLED=false ./migrate.sh -k -f docker-compose.yml migrate

# Custom SELinux type
K8S_SELINUX_TYPE=spc_t ./migrate.sh -k -f docker-compose.yml migrate

# With MCS level for multi-tenancy
K8S_SELINUX_LEVEL=s0:c123,c456 ./migrate.sh -k -f docker-compose.yml migrate
```

#### Generated Kubernetes Security Context

When SELinux is enabled, the generated Deployment includes a security context:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myapp
spec:
  template:
    spec:
      securityContext:
        seLinuxOptions:
          type: container_t
          # level: s0:c123,c456  # If K8S_SELINUX_LEVEL is set
      containers:
        - name: myapp
          image: myapp:latest
```

#### Kubernetes SELinux Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `K8S_SELINUX_ENABLED` | `auto` | Enable SELinux in K8s manifests (auto, true, false) |
| `K8S_SELINUX_TYPE` | `container_t` | SELinux type for container processes |
| `K8S_SELINUX_LEVEL` | (empty) | MCS/MLS level for multi-tenancy (e.g., s0:c123,c456) |
| `K8S_SELINUX_USER` | (empty) | SELinux user (rarely needed) |
| `K8S_SELINUX_ROLE` | (empty) | SELinux role (rarely needed) |
| `K8S_FS_GROUP` | (empty) | fsGroup for pod-level security context |
| `K8S_SUPPLEMENTAL_GROUPS` | (empty) | Space-separated supplemental groups |
| `K8S_RUN_AS_USER` | (empty) | Pod-level runAsUser |
| `K8S_RUN_AS_GROUP` | (empty) | Pod-level runAsGroup |
| `K8S_RUN_AS_NON_ROOT` | `false` | Enforce non-root container execution |

#### Container-Level Security Context

When generating Kubernetes manifests, security settings from docker-compose are converted to container-level security contexts:

```yaml
# docker-compose.yml
services:
  app:
    user: "1000:1000"
    read_only: true
    privileged: true
    cap_add:
      - NET_ADMIN
    cap_drop:
      - ALL
    security_opt:
      - label:type:spc_t
      - label:level:s0:c100,c200
```

**Generated Kubernetes Deployment:**
```yaml
apiVersion: apps/v1
kind: Deployment
spec:
  template:
    spec:
      securityContext:
        fsGroup: 1000
        seLinuxOptions:
          type: spc_t
          level: s0:c100,c200
      containers:
        - name: app
          securityContext:
            privileged: true
            readOnlyRootFilesystem: true
            runAsUser: 1000
            runAsGroup: 1000
            capabilities:
              add:
                - NET_ADMIN
              drop:
                - ALL
            seLinuxOptions:
              type: spc_t
              level: s0:c100,c200
```

#### OpenShift Considerations

OpenShift uses SELinux by default with auto-generated MCS labels. When deploying to OpenShift:

```bash
# Let OpenShift manage SELinux (recommended)
K8S_SELINUX_ENABLED=false ./migrate.sh -k -f docker-compose.yml migrate

# Or use OpenShift's default container type
K8S_SELINUX_TYPE=container_t K8S_SELINUX_ENABLED=true ./migrate.sh -k -f docker-compose.yml migrate
```

#### OpenShift Security Context Constraints (SCC)

The migration tool automatically recommends appropriate SCCs based on your docker-compose configuration:

| Service Configuration | Recommended SCC |
|-----------------------|-----------------|
| Default (no special permissions) | restricted-v2 |
| privileged: true | privileged |
| network_mode: host | hostnetwork |
| ipc: host or pid: host | hostaccess |
| user: 0 (root) or cap_add with dangerous caps | anyuid |
| Host volume mounts | hostmount-anyuid |

**Analyze SCC Requirements:**

```bash
# Analyze docker-compose for SCC requirements
source scripts/kubernetes.sh
analyze_scc_requirements docker-compose.yml

# Get recommended SCC for a specific service
get_recommended_scc docker-compose.yml myservice
```

**Generate SCC RoleBindings:**

When generating Kubernetes manifests with `OPENSHIFT_SCC_ENABLED=true`, the tool creates ServiceAccount and RoleBinding resources for each service:

```bash
OPENSHIFT_SCC_ENABLED=true ./migrate.sh -k -f docker-compose.yml migrate
```

#### Kubernetes Volume SELinux

For volumes in Kubernetes with SELinux:

1. **hostPath volumes**: Ensure the host path has correct SELinux context
2. **PersistentVolumes**: Storage class should support SELinux relabeling
3. **ConfigMaps/Secrets**: Automatically handled by Kubernetes

Example pre-migration check:

```bash
# Check paths before generating manifests
./selinux-check /path/to/hostpath/volume
```

---

## Troubleshooting

### Common Issues and Solutions

#### Issue: Privileged ports (< 1024) in rootless mode

```
[WARNING] Port 80 is privileged. Rootless Podman may need configuration.
```

**Solution:**
```bash
# Allow unprivileged port binding
sudo sysctl -w net.ipv4.ip_unprivileged_port_start=80

# Make permanent
echo "net.ipv4.ip_unprivileged_port_start=80" | sudo tee /etc/sysctl.d/99-unprivileged-ports.conf
```

#### Issue: SELinux permission denied

```
Error: error mounting volume: permission denied
```

**Solution:**
Volumes are automatically labeled with `:Z`. For shared volumes between containers, use `:z` instead:
```bash
# In generated .container file, change:
Volume=/path:/container:Z
# To:
Volume=/path:/container:z
```

**SELinux Booleans:**
Some container operations require specific SELinux booleans to be enabled:

```bash
# Check recommended booleans for your compose file
source scripts/selinux.sh
get_recommended_booleans docker-compose.yml

# Common booleans for containers:
# - container_manage_cgroup: Allow containers to manage cgroups
# - container_connect_any: Allow containers to connect to any port
# - virt_sandbox_use_netlink: Allow containers to use netlink sockets

# Enable a boolean
sudo setsebool -P container_manage_cgroup on

# Check current status
getsebool container_manage_cgroup
```

#### Issue: Service won't start

**Diagnosis:**
```bash
# Check service status
systemctl --user status myproject-web.service

# View detailed logs
journalctl --user -u myproject-web.service -f

# Check Quadlet generation
/usr/libexec/podman/quadlet -dryrun -user
```

#### Issue: Container image not found

```
Error: image not found
```

**Solution:**
```bash
# Pull image manually
podman pull docker.io/library/nginx:alpine

# Or check image name in .container file
grep "Image=" ~/.config/containers/systemd/myproject-web.container
```

#### Issue: User systemd not running

```
Failed to connect to bus: No such file or directory
```

**Solution:**
```bash
# Enable user lingering
loginctl enable-linger $USER

# Start user systemd
systemctl --user start dbus

# Or log out and log back in
```

#### Issue: Volume source does not exist

```
[WARNING] Volume source './data' does not exist
```

**Solution:**
```bash
# Create the directory
mkdir -p ./data

# Or update the volume path in docker-compose.yml
```

### Debug Mode

Enable debug output for detailed logging:

```bash
# Using flag
./migrate.sh -d -f docker-compose.yml migrate

# Using environment variable
DEBUG=1 ./migrate.sh -f docker-compose.yml migrate
```

### Log Locations

| Log Type | Location |
|----------|----------|
| Container logs | `journalctl --user -u service-name.service` |
| Podman events | `podman events` |
| Quadlet generator | `/usr/libexec/podman/quadlet -dryrun -user` |

---

## Running Tests

### Execute Test Suite

```bash
# Run all tests
./tests/test_migration.sh

# Expected output:
Docker-to-Podman Migration Tool - Test Suite
=============================================
Test fixtures created

=== Testing Utils ===
PASS: sanitize_service_name: normal name
PASS: sanitize_service_name: dots to dashes
...

=== Testing Parser ===
PASS: get_compose_version
PASS: get_services: contains web
...

=== Testing Quadlet Generation ===
PASS: Generated web.container
PASS: Generated default network
...

=== Test Summary ===
Total:  43
Passed: 43
Failed: 0

All tests passed!
```

### Test Coverage

| Category | Tests |
|----------|-------|
| Utils | sanitize_service_name, normalize_image, parse_port, to_boolean |
| Parser | get_compose_version, get_services, get_service_*, get_networks, get_volumes |
| Converter | convert_restart_policy, convert_volume_mount |
| Migration | CLI help, version, dry-run, validate |
| Quadlet | File generation, content validation |

---

## Project Structure

```
docker-to-podman/
├── migrate.sh                  # Main CLI entry point
│
├── scripts/
│   ├── utils.sh               # Common utilities (logging, helpers)
│   ├── parser.sh              # Docker-compose YAML parser
│   ├── converter.sh           # Docker to Podman conversion
│   ├── quadlet.sh             # Quadlet file generation
│   ├── validator.sh           # Validation utilities
│   ├── performance.sh         # Performance tuning
│   ├── kubernetes.sh          # Kubernetes manifest generation
│   ├── helm.sh                # Helm chart generation
│   └── selinux.sh             # SELinux policy management
│
├── templates/
│   ├── container.template     # Quadlet container template
│   ├── network.template       # Quadlet network template
│   ├── volume.template        # Quadlet volume template
│   ├── helm/                  # Helm chart templates
│   └── k8s/                   # Kubernetes templates
│
├── examples/
│   ├── simple/
│   │   └── docker-compose.yml # Simple web app example
│   └── complex/
│       └── docker-compose.yml # Multi-service example
│
├── tests/
│   ├── test_migration.sh      # Test suite
│   └── fixtures/              # Test data
│
└── README.md                  # This documentation
```

---

## Compatibility Notes

### Podman Version Support

| Podman Version | Support Level | Notes |
|----------------|---------------|-------|
| 4.4 - 4.9 | Full | Minimum version for Quadlet support |
| 5.0 - 5.8 | Full | CNI removed; Netavark is the default network backend |
| 6.0+ (upcoming) | Planned | BoltDB removed; SQLite only. Run `podman system migrate --migrate-db` before upgrading |

### Helm Version Support

This tool generates Helm v2 chart format (apiVersion: v1) compatible with both Helm 3.x and Helm 4.x. Helm 4 introduced WebAssembly plugins and Server-Side Apply as default, but remains backward compatible with v2 charts.

### Kubernetes Compatibility

Generated manifests target Kubernetes 1.25+ and use standard `apps/v1` API versions. For clusters running Kubernetes 1.35+, in-place pod resource updates are available as a GA feature.

### Docker Compose File Support

Supports Docker Compose file format versions 2.x and 3.x, compatible with Docker Compose CLI v2 through v5.

---

## Contributing

### Development Setup

```bash
# Clone repository
git clone https://github.com/gustcol/docker-to-podman.git
cd docker-to-podman

# Make scripts executable
chmod +x migrate.sh scripts/*.sh tests/*.sh

# Run tests
./tests/test_migration.sh
```

### Contribution Guidelines

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/my-feature`)
3. Make your changes
4. Run tests (`./tests/test_migration.sh`)
5. Commit with descriptive message
6. Push to your fork
7. Submit a pull request

### Code Style

- Use 4 spaces for indentation
- Add comments for complex logic
- Follow existing naming conventions
- Add tests for new features

---

## License

MIT License - See [LICENSE](LICENSE) file for details.

---

## References

### Official Documentation

- [Podman Quadlet Documentation](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html)
- [Podman Documentation](https://docs.podman.io/)
- [Docker Compose Specification](https://docs.docker.com/compose/compose-file/)
- [systemd Documentation](https://www.freedesktop.org/software/systemd/man/)

### Tutorials and Guides

- [Migrating from Docker to Podman](https://podman.io/docs/installation)
- [Rootless Podman Setup](https://github.com/containers/podman/blob/main/rootless.md)
- [Quadlet Getting Started](https://www.redhat.com/sysadmin/quadlet-podman)

### Related Projects

- [podman-compose](https://github.com/containers/podman-compose) - Docker Compose compatible tool for Podman
- [Podman Desktop](https://podman-desktop.io/) - GUI for Podman
- [Podlet](https://github.com/containers/podlet) - Generate Quadlet files from Podman commands or Compose files

---

## Support

- **Issues**: [GitHub Issues](https://github.com/gustcol/docker-to-podman/issues)
- **Discussions**: [GitHub Discussions](https://github.com/gustcol/docker-to-podman/discussions)

---

*Made with care for the container community*
