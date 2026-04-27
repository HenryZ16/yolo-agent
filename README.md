# Agentic Coding YOLO Mode

一套容器化方案，让 [Claude Code](https://docs.anthropic.com/en/docs/agents-and-tools/claude-code/overview) 和 [Kimi Code](https://www.moonshot.cn/) 能够在 Docker 容器中运行，自动加载配置、工具链和项目代码。

**核心设计**：`--` 之后的所有参数直接透传给 agent，跟直接在本地运行 `claude` 或 `kimi` 完全一样。

## 特性

- **零侵入透传**：`--` 后的一切参数直接传给 agent，无任何包装或限制
- **双工具支持**：同时支持 Claude Code 和 Kimi Code，一键切换
- **工具链挂载**：通过少量参数挂载主机上的 Python (uv/conda/pyenv)、Rust、Node.js、Go 等开发环境
- **权限保持**：容器内始终以非 root 用户运行，映射主机 UID/GID，修改后的文件权限与主机一致
- **SSH 转发**：自动转发 SSH agent，容器内 git 操作直接使用主机的 SSH 密钥
- **配置复用**：自动挂载主机的 agent 配置文件（`~/.claude/`、`~/.kimi/`）

## 快速开始

### 1. 构建镜像

```bash
./run-yolo.sh --build
```

### 2. 交互模式（默认）

跟直接运行 `claude` 或 `kimi` 一样，启动一个交互式会话。

```bash
# 启动 Claude Code 交互会话
./run-yolo.sh --

# 指定模型
./run-yolo.sh -- --model sonnet

# 挂载 uv 工具链后启动
./run-yolo.sh --with-python uv --

# 使用 Kimi Code
./run-yolo.sh -t kimi --with-rust --
```

### 3. 非交互模式（YOLO）

传一个 prompt 给 agent，它执行完就退出。

```bash
# Claude: -p 表示非交互模式
./run-yolo.sh -- -p "Review this codebase and suggest improvements"

# Kimi: --print 表示非交互模式（同时启用 --yolo）
./run-yolo.sh -t kimi -- --print "Refactor error handling"

# 挂载工具链 + YOLO
./run-yolo.sh --with-python uv -- -p "Add type hints to all functions"
```

### 4. 传任意参数给 Agent

`--` 后面的所有内容都会原样透传给 agent，你可以使用 agent 支持的任何参数。

```bash
# 指定模型 + prompt
./run-yolo.sh -- --model opus -p "Implement auth middleware"

# Claude 的 --effort 参数
./run-yolo.sh -- --effort max -p "Write comprehensive tests"

# Kimi 指定模型
./run-yolo.sh -t kimi --with-python uv -- -m kimi-k2 --print "Review PR"

# 恢复之前的 session（项目路径与主机一致，session 数据自动匹配）
./run-yolo.sh -- -p --resume 77edf4c9-3ad9-47b0-8d72-47115b460fdf

# 只传参数不传 prompt（进入交互模式但指定了模型）
./run-yolo.sh -- --model sonnet
```

### 5. 进入容器调试

```bash
./run-yolo.sh --shell --with-python uv
```

## 用法

```
Usage: run-yolo.sh [OPTIONS] -- [AGENT_ARGS...]

Options:
  -t, --tool claude|kimi        Agent tool to use (default: claude)
  -p, --project PATH            Project directory to mount (default: current directory)
  --with-python [uv|conda|pyenv] Mount Python toolchain
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
```

## 工作原理

`run-yolo.sh` 负责组装 `docker run` 命令（挂载项目、配置、工具链、SSH agent 等），然后启动容器。容器内的 `entrypoint.sh` 只做三件事：

1. **动态用户创建**（映射主机 UID/GID 到容器内的非 root 用户）
2. **工具链 PATH 设置**（检测挂载的 uv、conda、rust、node 等）
3. **启动 agent**（加载 YOLO 配置文件，透传 `$@`）

**项目路径保持**：为了让 session resumption（`--resume`）正常工作，项目目录不仅会挂载到 `/workspace`，还会挂载到与主机完全一致的原路径（如 `/home/henryz16/my-project`），并且容器的工作目录会设为该原路径。这样 Claude Code / Kimi Code 内部编码的项目路径与主机完全一致，session 数据可以正确读写。

因此 `--` 之后的参数体验与直接运行 `claude` 或 `kimi` 完全一致。

## 工具链挂载

`run-yolo.sh` 会自动检测主机上对应工具链的目录是否存在，并挂载到容器内。

此外，`~/.local/bin` 目录（用户本地安装的命令行工具，如 pipx）会在存在时**自动挂载**并加入 `PATH`，无需额外参数。

| 参数 | 主机路径 | 容器路径 | 说明 |
|------|----------|----------|------|
| `--with-python uv` | `~/.local/share/uv/`, `~/.cache/uv/` | 对应路径 | uv Python 工具链 |
| `--with-python conda` | `~/miniconda3/` 或 `~/anaconda3/` | `/opt/conda` | Conda 环境 |
| `--with-python pyenv` | `~/.pyenv/` | `~/.pyenv/` | pyenv 版本管理 |
| `--with-rust` | `~/.cargo/`, `~/.rustup/` | 对应路径 | Rust/cargo |
| `--with-node` | `~/.nvm/`, `~/.npm/` | 对应路径 | Node.js/nvm |
| `--with-go` | `~/go/`, `/usr/local/go/` | 对应路径 | Go 工具链 |

## YOLO 配置说明

容器启动时会自动加载 YOLO 配置文件，预设了权限绕过等配置。

### Claude Code

容器内自动加载 `config/claude-yolo.json`:

```json
{
  "permissions": {
    "defaultMode": "bypassPermissions"
  },
  "skipAutoPermissionPrompt": true
}
```

这意味着交互模式下 agent 执行操作时也不会反复请求确认。如果你**不想**自动绕过权限，可以传 `--permission-mode acceptEdits` 覆盖：

```bash
./run-yolo.sh -- --permission-mode acceptEdits
```

### Kimi Code

容器内自动加载 `config/kimi-yolo.toml`:

```toml
default_yolo = true
```

同样会默认自动批准操作。可以传 `--no-yolo` 覆盖：

```bash
./run-yolo.sh -t kimi -- --no-yolo
```

## ⚠️ 安全警告

**YOLO 配置下 agent 会自动执行操作而无需确认**，包括：
- 修改、删除、创建文件
- 执行任意 shell 命令
- 执行 git 操作（commit、push 等）
- 安装/卸载依赖

**建议:**
1. 仅在版本控制完善的项目上使用
2. 优先在可丢弃的副本上测试
3. 在执行前确保已提交所有重要更改

## 项目结构

```
.
├── Dockerfile              # 基础镜像定义
├── entrypoint.sh           # 容器入口脚本（动态用户、PATH 设置、agent 分发）
├── run-yolo.sh             # 用户启动脚本
├── docker-compose.yml      # Compose 配置（可选）
├── config/
│   ├── claude-yolo.json    # Claude Code YOLO 默认配置
│   └── kimi-yolo.toml      # Kimi Code YOLO 默认配置
└── README.md               # 本文档
```

## 环境变量

| 变量 | 说明 |
|------|------|
| `AGENT_TOOL` | 选择 agent: `claude` 或 `kimi` |
| `YOLO_IMAGE` | 自定义镜像名（默认: `agentic-yolo:latest`） |
| `YOLO_DEBUG` | 设置为 `1` 启用容器内调试输出 |
| `HOST_UID` / `HOST_GID` | 主机用户 ID（自动映射到容器内非 root 用户） |

## License

MIT
