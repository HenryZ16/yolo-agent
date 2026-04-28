#!/bin/bash
set -euo pipefail

# =============================================================================
# run-yolo.sh - Launcher for Agentic Coding YOLO Mode
# =============================================================================
# Simplifies docker run for Claude Code / Kimi Code with toolchain mounts,
# SSH agent forwarding, and dynamic user mapping.
#
# Usage: ./run-yolo.sh [OPTIONS] -- [AGENT_ARGS...]
# =============================================================================

IMAGE_NAME="${YOLO_IMAGE:-agentic-yolo:latest}"
DOCKERFILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults
TOOL="claude"
PROJECT=""
WITH_PYTHON=""
WITH_RUST=false
WITH_NODE=false
WITH_GO=false
BUILD=false
SHELL_MODE=false
EXTRA_ENVS=()
EXTRA_VOLUMES=()
CONFIG_DIR=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

show_help() {
    cat <<'EOF'
Usage: run-yolo.sh [OPTIONS] -- [AGENT_ARGS...]

Launch Claude Code or Kimi Code in a Docker container.
All arguments after -- are passed directly to the agent.

Options:
  -t, --tool claude|kimi        Agent tool to use (default: claude)
  -p, --project PATH            Project directory to mount (default: current directory)
  --with-python [uv|conda|pyenv] Mount specific Python toolchain
  --with-rust                   Mount Rust/cargo toolchain
  --with-node                   Mount Node.js toolchain
  --with-go                     Mount Go toolchain
  -e, --env KEY=VALUE           Pass additional environment variable
  -v, --volume HOST:CONTAINER   Mount additional volume
  -c, --config-dir PATH         Custom agent config directory
  --build                       Build the Docker image before running
  --shell                       Start an interactive shell in the container
  --debug                       Enable debug output inside container
  -h, --help                    Show this help message

Examples:
  # Interactive mode (default): chat with the agent
  ./run-yolo.sh --

  # Interactive mode + specify model
  ./run-yolo.sh -- --model sonnet

  # Non-interactive YOLO mode: give a prompt and exit
  ./run-yolo.sh -- -p "refactor error handling"

  # Kimi YOLO mode
  ./run-yolo.sh -t kimi -- --print "optimize performance"

  # Build image first, then run
  ./run-yolo.sh --build -- -p "review the codebase"

  # Debug: enter container shell
  ./run-yolo.sh --shell
EOF
}

warn() { echo "[WARN] $*" >&2; }
info() { echo "[INFO] $*" >&2; }

die() { echo "[ERROR] $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--tool)
            TOOL="$2"
            shift 2
            ;;
        -p|--project)
            PROJECT="$2"
            shift 2
            ;;
        --with-python)
            if [[ -n "${2:-}" && ! "${2:-}" =~ ^- ]]; then
                WITH_PYTHON="$2"
                shift 2
            else
                WITH_PYTHON="auto"
                shift
            fi
            ;;
        --with-rust)
            WITH_RUST=true
            shift
            ;;
        --with-node)
            WITH_NODE=true
            shift
            ;;
        --with-go)
            WITH_GO=true
            shift
            ;;
        -e|--env)
            EXTRA_ENVS+=("$2")
            shift 2
            ;;
        -v|--volume)
            EXTRA_VOLUMES+=("$2")
            shift 2
            ;;
        -c|--config-dir)
            CONFIG_DIR="$2"
            shift 2
            ;;
        --build)
            BUILD=true
            shift
            ;;
        --shell)
            SHELL_MODE=true
            shift
            ;;
        --debug)
            EXTRA_ENVS+=("YOLO_DEBUG=1")
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        --)
            shift
            ARGS+=("$@")
            break
            ;;
        -*)
            die "Unknown option: $1"
            ;;
        *)
            ARGS+=("$1")
            shift
            ;;
    esac
done

# Validate tool
if [[ "$TOOL" != "claude" && "$TOOL" != "kimi" ]]; then
    die "Unknown tool: $TOOL. Supported: claude, kimi"
fi

# Default project to current directory
if [[ -z "$PROJECT" ]]; then
    PROJECT="$(pwd)"
fi
PROJECT="$(cd "$PROJECT" && pwd)" || die "Project directory does not exist: $PROJECT"

# Default config directory based on selected tool
if [[ -z "$CONFIG_DIR" ]]; then
    if [[ "$TOOL" == "claude" && -d "$HOME/.claude" ]]; then
        CONFIG_DIR="$HOME/.claude"
    elif [[ "$TOOL" == "kimi" && -d "$HOME/.kimi" ]]; then
        CONFIG_DIR="$HOME/.kimi"
    fi
fi

# ---------------------------------------------------------------------------
# Build image if requested
# ---------------------------------------------------------------------------

if [[ "$BUILD" == true ]]; then
    info "Building Docker image: $IMAGE_NAME"
    docker build -t "$IMAGE_NAME" "$DOCKERFILE_DIR"
fi

# ---------------------------------------------------------------------------
# Assemble docker run arguments
# ---------------------------------------------------------------------------

DOCKER_ARGS=(
    "--rm"
    "--network=host"
    "-it"
    "-w" "$PROJECT"
    "-e" "AGENT_TOOL=$TOOL"
    "-e" "HOST_UID=$(id -u)"
    "-e" "HOST_GID=$(id -g)"
    "-e" "HOST_HOME=$HOME"
    "-e" "PROJECT_DIR=$PROJECT"
)

# Mount project at its original host path (required for session resumption)
# and also at /workspace for backward compatibility
DOCKER_ARGS+=("-v" "$PROJECT:$PROJECT")
DOCKER_ARGS+=("-v" "$PROJECT:/workspace")

# Mount agent configs to developer's home
DEV_HOME="/home/developer"
if [[ -n "$CONFIG_DIR" ]]; then
    CONFIG_DIR="$(cd "$CONFIG_DIR" && pwd)" || die "Config directory does not exist: $CONFIG_DIR"
    if [[ "$TOOL" == "claude" ]]; then
        DOCKER_ARGS+=("-v" "$CONFIG_DIR:$DEV_HOME/.claude")
    else
        DOCKER_ARGS+=("-v" "$CONFIG_DIR:$DEV_HOME/.kimi")
    fi
fi

# Mount agent home-dir-level files (not inside .claude/ or .kimi/)
if [[ "$TOOL" == "claude" ]]; then
    if [[ -f "$HOME/.claude.json" ]]; then
        DOCKER_ARGS+=("-v" "$HOME/.claude.json:$DEV_HOME/.claude.json")
    fi
    if [[ -d "$HOME/.local/share/claude" ]]; then
        DOCKER_ARGS+=("-v" "$HOME/.local/share/claude:$DEV_HOME/.local/share/claude")
    fi
    if [[ -d "$HOME/.cache/claude" ]]; then
        DOCKER_ARGS+=("-v" "$HOME/.cache/claude:$DEV_HOME/.cache/claude")
    fi
fi

if [[ "$TOOL" == "kimi" ]]; then
    # Kimi stores everything under ~/.kimi/, no known home-level files
    true
fi

# SSH agent forwarding
if [[ -n "${SSH_AUTH_SOCK:-}" ]]; then
    DOCKER_ARGS+=(
        "-e" "SSH_AUTH_SOCK=$SSH_AUTH_SOCK"
        "-v" "$SSH_AUTH_SOCK:$SSH_AUTH_SOCK"
    )
    if [[ -d "$HOME/.ssh" ]]; then
        DOCKER_ARGS+=("-v" "$HOME/.ssh:$DEV_HOME/.ssh:ro")
    fi
fi

# Git config
if [[ -f "$HOME/.gitconfig" ]]; then
    DOCKER_ARGS+=("-v" "$HOME/.gitconfig:$DEV_HOME/.gitconfig:ro")
fi

# ---------------------------------------------------------------------------
# Proxy auto-detection: pass through common proxy env vars from host
# ---------------------------------------------------------------------------

PASS_THROUGH_PROXIES=(
    HTTP_PROXY http_proxy
    HTTPS_PROXY https_proxy
    NO_PROXY no_proxy
    ALL_PROXY all_proxy
    FTP_PROXY ftp_proxy
)

for var in "${PASS_THROUGH_PROXIES[@]}"; do
    if [[ -n "${!var:-}" ]]; then
        DOCKER_ARGS+=("-e" "$var=${!var}")
    fi
done

# User-local binaries (e.g. pipx, local installs)
if [[ -d "$HOME/.local/bin" ]]; then
    DOCKER_ARGS+=("-v" "$HOME/.local/bin:$DEV_HOME/.local/bin")
fi

# ---------------------------------------------------------------------------
# Toolchain mounts (always to developer's home)
# ---------------------------------------------------------------------------

mount_toolchain() {
    local host_path="$1"
    local container_path="$2"
    if [[ -e "$host_path" ]]; then
        DOCKER_ARGS+=("-v" "$host_path:$container_path")
        info "Mounting toolchain: $host_path → $container_path"
    fi
}

# If no --with-* flags were given, auto-detect and mount all available toolchains
MOUNT_ALL=false
if [[ -z "$WITH_PYTHON" && "$WITH_RUST" == false && "$WITH_NODE" == false && "$WITH_GO" == false ]]; then
    MOUNT_ALL=true
fi

# Python toolchains
if [[ -n "$WITH_PYTHON" || "$MOUNT_ALL" == true ]]; then
    if [[ "$WITH_PYTHON" == "auto" || "$MOUNT_ALL" == true ]]; then
        if [[ -d "$HOME/.local/share/uv" ]]; then
            WITH_PYTHON="uv"
        elif [[ -d "$HOME/miniconda3" || -d "$HOME/anaconda3" ]]; then
            WITH_PYTHON="conda"
        elif [[ -d "$HOME/.pyenv" ]]; then
            WITH_PYTHON="pyenv"
        else
            WITH_PYTHON=""
        fi
    fi

    case "$WITH_PYTHON" in
        uv)
            mount_toolchain "$HOME/.local/share/uv" "$DEV_HOME/.local/share/uv"
            mount_toolchain "$HOME/.cache/uv" "$DEV_HOME/.cache/uv"
            ;;
        conda)
            if [[ -d "$HOME/miniconda3" ]]; then
                mount_toolchain "$HOME/miniconda3" "/opt/conda"
            elif [[ -d "$HOME/anaconda3" ]]; then
                mount_toolchain "$HOME/anaconda3" "/opt/conda"
            fi
            ;;
        pyenv)
            mount_toolchain "$HOME/.pyenv" "$DEV_HOME/.pyenv"
            ;;
    esac
fi

# Rust toolchain
if [[ "$WITH_RUST" == true || "$MOUNT_ALL" == true ]]; then
    mount_toolchain "$HOME/.cargo" "$DEV_HOME/.cargo"
    mount_toolchain "$HOME/.rustup" "$DEV_HOME/.rustup"
fi

# Node.js toolchain
if [[ "$WITH_NODE" == true || "$MOUNT_ALL" == true ]]; then
    mount_toolchain "$HOME/.nvm" "$DEV_HOME/.nvm"
    mount_toolchain "$HOME/.npm" "$DEV_HOME/.npm"
    if [[ -d "/usr/local/lib/node_modules" ]]; then
        mount_toolchain "/usr/local/lib/node_modules" "/usr/local/lib/node_modules"
    fi
fi

# Go toolchain
if [[ "$WITH_GO" == true || "$MOUNT_ALL" == true ]]; then
    mount_toolchain "$HOME/go" "$DEV_HOME/go"
    if [[ -d "/usr/local/go" ]]; then
        mount_toolchain "/usr/local/go" "/usr/local/go"
    fi
fi

# ---------------------------------------------------------------------------
# Extra environments and volumes
# ---------------------------------------------------------------------------

for envvar in "${EXTRA_ENVS[@]}"; do
    DOCKER_ARGS+=("-e" "$envvar")
done

for vol in "${EXTRA_VOLUMES[@]}"; do
    DOCKER_ARGS+=("-v" "$vol")
done

# ---------------------------------------------------------------------------
# Execute
# ---------------------------------------------------------------------------

if [[ "$SHELL_MODE" == true ]]; then
    info "Starting interactive shell in container..."
    info "Toolchains mounted. Type 'exit' to leave."
    exec docker run "${DOCKER_ARGS[@]}" "$IMAGE_NAME" --shell
fi

info "Running $TOOL..."
info "Project: $PROJECT"
info "Image: $IMAGE_NAME"

if [[ ${#ARGS[@]} -gt 0 ]]; then
    exec docker run "${DOCKER_ARGS[@]}" "$IMAGE_NAME" "${ARGS[@]}"
else
    exec docker run "${DOCKER_ARGS[@]}" "$IMAGE_NAME"
fi
