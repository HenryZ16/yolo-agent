#!/bin/bash
set -e

USER_NAME="developer"
HOME_DIR="/home/$USER_NAME"
RUN_AS="gosu $USER_NAME"

# If HOST_UID/HOST_GID provided, create a matching user and switch to it
if [ -n "${HOST_UID:-}" ] && [ -n "${HOST_GID:-}" ]; then
    if ! getent group "$HOST_GID" > /dev/null 2>&1; then
        groupadd -g "$HOST_GID" "$USER_NAME" 2>/dev/null || true
    fi
    if ! id -u "$HOST_UID" > /dev/null 2>&1; then
        useradd -u "$HOST_UID" -g "$HOST_GID" -d "$HOME_DIR" -m -s /bin/bash "$USER_NAME" 2>/dev/null || true
    fi
    mkdir -p "$HOME_DIR"
    chown "$HOST_UID:$HOST_GID" "$HOME_DIR" 2>/dev/null || true
    chown -R "$HOST_UID:$HOST_GID" /workspace 2>/dev/null || true
    if [ -n "${PROJECT_DIR:-}" ] && [ "$PROJECT_DIR" != "/workspace" ]; then
        chown -R "$HOST_UID:$HOST_GID" "$PROJECT_DIR" 2>/dev/null || true
    fi
    RUN_AS="gosu $HOST_UID:$HOST_GID"
else
    # Default: use the pre-created developer user (UID 1000)
    chown -R developer:developer /workspace 2>/dev/null || true
    if [ -n "${PROJECT_DIR:-}" ] && [ "$PROJECT_DIR" != "/workspace" ]; then
        chown -R developer:developer "$PROJECT_DIR" 2>/dev/null || true
    fi
fi

export HOME="$HOME_DIR"

# Use host home path for PATH if available (symlink handles resolution)
USER_HOME="${HOST_HOME:-$HOME_DIR}"

# Detect and set up toolchain PATHs
# Toolchains are mounted to developer's home ($HOME_DIR); check there
# even if USER_HOME symlink failed (e.g. HOST_HOME dir exists and non-empty)
declare -a PATH_ADDITIONS=()

# Helper: check both USER_HOME and HOME_DIR, prefer HOME_DIR for mount target
_toolchain_path() {
    local subpath="$1"
    if [ -d "$HOME_DIR/$subpath" ]; then
        echo "$HOME_DIR/$subpath"
    elif [ -d "$USER_HOME/$subpath" ]; then
        echo "$USER_HOME/$subpath"
    fi
}

LOCAL_BIN=$(_toolchain_path ".local/bin")
if [ -n "$LOCAL_BIN" ]; then
    PATH_ADDITIONS+=("$LOCAL_BIN")
fi

UV_BIN=$(_toolchain_path ".local/share/uv")
if [ -n "$UV_BIN" ]; then
    PATH_ADDITIONS+=("$UV_BIN/bin")
fi

if [ -d "/opt/conda/bin" ]; then
    PATH_ADDITIONS+=("/opt/conda/bin")
    if [ -f "/opt/conda/etc/profile.d/conda.sh" ]; then
        . "/opt/conda/etc/profile.d/conda.sh" 2>/dev/null || true
    fi
fi

PYENV_ROOT=$(_toolchain_path ".pyenv")
if [ -n "$PYENV_ROOT" ]; then
    export PYENV_ROOT
    PATH_ADDITIONS+=("$PYENV_ROOT/bin" "$PYENV_ROOT/shims")
    if command -v pyenv >/dev/null 2>&1; then
        eval "$(pyenv init -)" 2>/dev/null || true
    fi
fi

CARGO_BIN=$(_toolchain_path ".cargo/bin")
if [ -n "$CARGO_BIN" ]; then
    PATH_ADDITIONS+=("$CARGO_BIN")
fi

NVM_DIR=$(_toolchain_path ".nvm")
if [ -n "$NVM_DIR" ]; then
    export NVM_DIR
    [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" 2>/dev/null || true
    [ -s "$NVM_DIR/bash_completion" ] && . "$NVM_DIR/bash_completion" 2>/dev/null || true
fi

if [ -d "/usr/local/go/bin" ]; then
    PATH_ADDITIONS+=("/usr/local/go/bin")
fi
GO_BIN=$(_toolchain_path "go/bin")
if [ -n "$GO_BIN" ]; then
    PATH_ADDITIONS+=("$GO_BIN")
fi

if [ ${#PATH_ADDITIONS[@]} -gt 0 ]; then
    NEW_PATH=""
    for p in "${PATH_ADDITIONS[@]}"; do
        if [ -n "$NEW_PATH" ]; then
            NEW_PATH="$p:$NEW_PATH"
        else
            NEW_PATH="$p"
        fi
    done
    export PATH="$NEW_PATH:$PATH"
fi

# Create symlink from original host project path to /workspace
# so agents can find project-specific session data under ~/.claude/projects/
if [ -n "${PROJECT_DIR:-}" ] && [ "$PROJECT_DIR" != "/workspace" ]; then
    if [ ! -e "$PROJECT_DIR" ]; then
        mkdir -p "$(dirname "$PROJECT_DIR")"
        ln -sf /workspace "$PROJECT_DIR"
    fi
fi

# Create symlink from host user's home to developer's home so that
# any hardcoded host home paths resolve correctly inside the container
if [ -n "${HOST_HOME:-}" ] && [ "$HOST_HOME" != "$HOME_DIR" ]; then
    # Docker volume mounts may auto-create HOST_HOME as an empty directory.
    # If it's empty, remove it so we can create the symlink.
    if [ -d "$HOST_HOME" ] && [ -z "$(ls -A "$HOST_HOME" 2>/dev/null)" ]; then
        rmdir "$HOST_HOME" 2>/dev/null || true
    fi
    if [ ! -e "$HOST_HOME" ]; then
        mkdir -p "$(dirname "$HOST_HOME")"
        ln -sf "$HOME_DIR" "$HOST_HOME"
    fi
fi

if [ "${YOLO_DEBUG:-}" = "1" ]; then
    echo "=== YOLO Debug ==="
    echo "AGENT_TOOL: ${AGENT_TOOL:-claude}"
    echo "HOME: $HOME"
    echo "PATH: $PATH"
    echo "RUN_AS: $RUN_AS"
    echo "PROJECT_DIR: ${PROJECT_DIR:-(none)}"
    echo "ARGS: $*"
    echo "=================="
fi

# Handle --shell mode: start bash as the target user
if [ "${1:-}" = "--shell" ]; then
    info() { echo "[INFO] $*" >&2; }
    info "Starting shell as developer user..."
    info "HOME: $HOME"
    info "PATH: $PATH"
    exec $RUN_AS env HOME="$HOME_DIR" /bin/bash
fi

AGENT_TOOL="${AGENT_TOOL:-claude}"

if [ "$AGENT_TOOL" = "claude" ]; then
    exec $RUN_AS env HOME="$HOME_DIR" claude --settings /opt/yolo-config/claude-yolo.json "$@"
elif [ "$AGENT_TOOL" = "kimi" ]; then
    exec $RUN_AS env HOME="$HOME_DIR" kimi --config-file /opt/yolo-config/kimi-yolo.toml "$@"
else
    echo "Unknown AGENT_TOOL: $AGENT_TOOL" >&2
    echo "Supported: claude, kimi" >&2
    exit 1
fi
