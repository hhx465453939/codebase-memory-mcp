# codebase-memory-mcp 本地部署指南

> 面向 **Claude Code** 与 **Codex CLI** 的本地接入
> 适用环境：Linux（重点覆盖 Ubuntu 20.04 / glibc 2.31 等较低版本系统）
>
> 本文档基于对本机环境的实测撰写，文中的命令、配置路径、注意事项均已核对。

---

## 0. 这个项目是什么，用什么写的

**codebase-memory-mcp** 是一个为 AI 编程 Agent 服务的「代码库知识图谱」后端。它用 tree-sitter 对整个代码仓库做全量结构化解析，构建出函数、类、调用链、HTTP 路由、跨服务依赖等关系图谱，再通过 **MCP（Model Context Protocol）** 把 15 个查询工具暴露给 Claude Code / Codex 等 Agent 调用。

**价值**：一次图谱查询可替代几十次 grep + read，实测可将探索相同问题所需的 token 降低到原来的 ~0.8%（5 次结构化查询 ≈ 3,400 tokens vs 逐文件搜索 ≈ 412,000 tokens）。

**实现语言**：⚠️ **纯 C（pure C），不是 Go**。

- README 徽章明确标注 `pure_C · zero_dependencies`
- 源码构成：579 个 `.c` + 610 个 `.h` 文件
- 构建系统 `Makefile.cbm`（"Build system for **pure C rewrite**"）
- README 里出现的 `go install` 仅为**分发渠道之一**（背后是一个极小的 Go 包装器，用于下载预编译的 C 二进制），不代表项目用 Go 实现

> 💡 **这一点决定了部署方式**：不能用 `go build`/`go install` 来"构建"它；只能 **① 下载预编译二进制** 或 **② 用 gcc 从源码编译**。

---

## 1. 本机环境实测（撰写时核对结果）

| 检查项 | 实测值 | 对部署的影响 |
|--------|--------|-------------|
| 操作系统 | Linux 5.15（Ubuntu 20.04） | 常规 |
| **glibc 版本** | **2.31** | ⚠️ **关键**：低于官方标准二进制要求的 **2.38**，**标准 Linux 二进制无法运行**，必须用 `-portable` 全静态包或源码编译 |
| gcc | 9.4.0 | 可用于源码编译 |
| make | 4.2.1 | 可用 |
| zlib 开发头文件 | `zlib.h` 1.2.11（已存在） | 源码编译无需额外安装 `zlib1g-dev` |
| Codex CLI | `~/.npm-global/bin/codex`（0.144.4） | 已安装，配置目录 `~/.codex`（`CODEX_HOME` 未设，走默认） |
| Claude Code | `~/.npm-global/bin/claude` | 已安装，配置文件 `~/.claude.json`（59 KB，已存在） |
| `~/.local/bin` 是否在 PATH | **不在** | install 默认装到此处；MCP 配置若用**绝对路径**则不受影响，但直接敲 `codebase-memory-mcp` 命令需先修复 PATH |
| 网络代理 | SOCKS5 `localhost:1080` / HTTP `localhost:10940` | 从 GitHub Releases 下载二进制、更新检查时可能需要 |

> 📌 快速自检命令（复制到终端运行即可）：
> ```bash
> ldd --version | head -1          # 看 glibc 版本
> gcc --version | head -1          # 看编译器
> test -f /usr/include/zlib.h && echo "zlib.h OK" || echo "缺 zlib1g-dev"
> echo $PATH | tr ':' '\n' | grep -q "$HOME/.local/bin" && echo "PATH OK" || echo "~/.local/bin 不在 PATH"
> ```

---

## 2. 部署方案选型

| 方案 | 说明 | 适合本机？ | 推荐度 |
|------|------|-----------|--------|
| **A. 一键安装脚本** | `install.sh` 从 GitHub Releases 下载预编译二进制。**Linux 上会自动追加 `-portable`，下载全静态包**，正好规避 glibc 2.31 问题 | ✅ | ⭐⭐⭐ 首选 |
| **B. 从源码本地编译** | `scripts/build.sh` → `make -f Makefile.cbm cbm`，产出 `build/c/codebase-memory-mcp`。本机 gcc 9.4 + zlib.h 齐备，可行 | ✅ | ⭐⭐ 完全可控/离线场景 |
| **C. 包管理器（npm/pip/brew）** | `npm i -g` / `pip install` 等。注意：这些渠道背后仍是下载预编译二进制，**同样受 glibc 版本约束**；且本机 `npm-global` 已承载 codex/claude，不建议混用 | ⚠️ | ⭐ 不推荐 |

> ⚠️ **千万不要直接下载 `codebase-memory-mcp-linux-amd64.tar.gz`（非 portable 标准包）** —— 它动态链接 glibc 2.38+，在本机会报 `version 'GLIBC_2.38' not found` 而无法运行。本机只认 `codebase-memory-mcp-linux-amd64-portable.tar.gz`。

---

## 3. 方案 A：一键脚本安装（推荐）

### 3.1 执行安装

```bash
# 标准（headless）版本 —— 推荐大多数场景
curl -fsSL https://raw.githubusercontent.com/DeusData/codebase-memory-mcp/main/install.sh | bash

# 如需内置 3D 图谱可视化 UI：
curl -fsSL https://raw.githubusercontent.com/DeusData/codebase-memory-mcp/main/install.sh | bash -s -- --ui
```

**需要走代理时**（本机访问 GitHub 较慢）：

```bash
# 方式一：临时给当前 shell 设代理（影响 curl 下载）
export https_proxy=http://127.0.0.1:10940
export http_proxy=http://127.0.0.1:10940
curl -fsSL https://raw.githubusercontent.com/DeusData/codebase-memory-mcp/main/install.sh | bash
unset http_proxy https_proxy
```

### 3.2 安装脚本做了什么

`install.sh` 的关键行为（已核对源码）：

1. 探测 OS / 架构（本机 → `linux` / `amd64`）
2. **Linux 自动追加 `-portable`**，下载全静态包 `codebase-memory-mcp-linux-amd64-portable.tar.gz`
3. 下载 `checksums.txt` 做 **SHA-256 校验**，不一致直接报错退出
4. 解压、安装到 `~/.local/bin/codebase-memory-mcp`，赋权 `755`
5. 运行 `codebase-memory-mcp install -y`：**自动检测已安装的 Agent（Claude Code / Codex 等）并写入它们的 MCP 配置 + 持久化上下文（skill、子 agent、生命周期 hook）**
6. 若 `~/.local/bin` 不在 PATH，会提示修复方法

常用参数：

| 参数 | 作用 |
|------|------|
| `--ui` | 安装带图谱 UI 的变体 |
| `--standard` | 安装标准变体（默认） |
| `--dir=<路径>` | 自定义安装目录 |
| `--skip-config` | 只装二进制，**不**自动配置任何 Agent（想完全手动配置时用） |

### 3.3 PATH 说明

**实测：`install.sh` 会自动把 `~/.local/bin` 追加到 `~/.bashrc`**（本机安装时写入成功）。无需手动处理，新开终端或 `source ~/.bashrc` 即生效。若自动写入未生效、或你用的是 zsh/fish 等其它 shell，再按下面手动添加：

```bash
# bash 用户
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc

# zsh 用户
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc

# 验证
which codebase-memory-mcp && codebase-memory-mcp --version
```

> 💡 **不修 PATH 也行**：MCP 配置里写**绝对路径** `/home/<用户名>/.local/bin/codebase-memory-mcp`，Agent 照样能调用（见第 5、6 节）。

---

## 4. 方案 B：从源码本地编译（离线 / 完全可控）

本机 gcc 9.4 + make + zlib.h 均齐备，可直接编译。

### 4.1 编译

```bash
cd /home/shpc_101170/Development/codebase-memory-mcp

# 标准二进制
scripts/build.sh

# 或带 UI：
# scripts/build.sh --with-ui

# 产物路径：
#   build/c/codebase-memory-mcp
```

`build.sh` 内部执行 `make -j$(nproc) -f Makefile.cbm cbm`，链接 `-lm -lstdc++ -lpthread -lz`，依赖均自带于 `vendored/`（mimalloc / sqlite3 / yyjson / xxhash / nomic / tre），零外部库依赖（除系统的 zlib / pthread）。

### 4.2 部署二进制

```bash
mkdir -p ~/.local/bin
cp build/c/codebase-memory-mcp ~/.local/bin/codebase-memory-mcp
chmod 755 ~/.local/bin/codebase-memory-mcp

# 验证
~/.local/bin/codebase-memory-mcp --version
```

### 4.3 让其自动配置 Agent

```bash
# 自动检测并写入 Claude Code / Codex 的配置
~/.local/bin/codebase-memory-mcp install -y

# 或只看会改哪些文件、不实际写入（强烈建议先 dry-run）
~/.local/bin/codebase-memory-mcp install --dry-run
```

> 💡 想产出**全静态二进制**（不依赖系统 glibc，便于拷到其它机器）：`make -f Makefile.cbm cbm STATIC=1`。

---

## 5. 配置 Claude Code

### 方式一：自动配置（推荐）

```bash
codebase-memory-mcp install -y
```

实测 installer 会写入**两处** MCP 条目（均为绝对路径）：

- 用户级 `~/.claude.json` → `mcpServers.codebase-memory-mcp`
- 目录级 `~/.claude/.mcp.json`（结构相同）

并追加：一个 skill、三个图谱子 agent（Scout / Verify / Auditor）、以及 `SessionStart` / `SubagentStart` / 非阻塞 `PreToolUse(Grep,Glob)` / `PostToolUse(Read)` 覆盖检查 hook。

> ⚠️ 本机 `~/.claude.json` 已有内容（且检测到已有 `codebase-memory` 相关条目）。安装前建议先确认是否重复：
> ```bash
> grep -n "codebase-memory" ~/.claude.json
> ```
> installer 采用「字节级所有权」策略，只会迁移它自己之前写入的定义，**不会覆盖用户手改的内容**。

### 方式二：手动配置

编辑 `~/.claude.json`（用户级），或项目根目录的 `.mcp.json`（项目级），加入：

```json
{
  "mcpServers": {
    "codebase-memory-mcp": {
      "command": "/home/shpc_101170/.local/bin/codebase-memory-mcp",
      "args": []
    }
  }
}
```

> ⚠️ `command` 务必用**绝对路径**，避免 Agent 启动时 PATH 不含 `~/.local/bin` 导致找不到二进制。

### 验证

重启 Claude Code 后，在会话中输入：

```
/mcp
```

应看到 `codebase-memory-mcp` 且工具数为 **15**。

---

## 6. 配置 Codex CLI

Codex 的 MCP 配置写在 **TOML** 文件中，路径 `$CODEX_HOME/config.toml`（本机 `CODEX_HOME` 未设，默认即 `~/.codex/config.toml`）。

### 方式一：自动配置（推荐）

```bash
codebase-memory-mcp install -y
```

installer 会在 `~/.codex/config.toml` 中 upsert MCP 表项，并写入 `AGENTS.md`、skill、三个只读子 agent，以及 `SessionStart` / `SubagentStart` hook。

> 📌 **Codex 用户须手动信任 hook**：Codex 要求通过 `/hooks` 审查并信任已安装的 hook。**修改 hook 定义会改变其信任哈希**，因此每次 cbm 更新后可能需要重新信任。这是 Codex 的安全机制，非 bug。

### 方式二：手动配置

编辑 `~/.codex/config.toml`，追加以下表（与现有 `model` / `[projects.*]` / `[notice]` 等段落并列，互不冲突）：

```toml
[mcp_servers.codebase-memory-mcp]
command = "/home/shpc_101170/.local/bin/codebase-memory-mcp"
args = []
```

> 说明：表名 `mcp_servers.codebase-memory-mcp` 是项目 installer 硬编码的规范名（见源码 `src/cli/cli.c`），手动配置请保持一致，便于后续 `update` / `uninstall` 自动维护。

### 验证

重启 Codex 后，在会话中确认 MCP 已连接：

```
/mcp            # 或 codex 提供的等价命令查看已加载 server
```

首次调用任意 cbm 工具（如让 Codex「分析这个项目的调用关系」）即会触发图谱查询。

---

## 7. 首次索引与日常使用

### 7.1 索引项目

在 Claude Code / Codex 会话中，进入目标项目目录后直接说：

```
Index this project
```

或在命令行手动索引（CLI 模式）：

```bash
# 索引（推荐 flags 写法；raw JSON 已 deprecated）
#   --mode: full(默认,全量+相似/语义边) / moderate / fast / cross-repo-intelligence
#   --name:  自定义项目名 ⭐ 强烈推荐设短名（如 kairos-trader / cbm）
#            否则用路径转义长名 home-shpc_101170-Development-xxx，查询时极易传错（见 Q9）
#   --persistence true: 生成团队共享产物 .codebase-memory/graph.db.zst
codebase-memory-mcp cli index_repository --repo-path /home/shpc_101170/Development/你的项目 --name 你的短名 --mode full

# 查看已索引项目（后续查询的 project 参数用这里返回的 "name" 字段）
codebase-memory-mcp cli list_projects

# 查询类工具同样支持 flags / --args-file / stdin 三种写法（推荐 stdin，对所有工具通用）
# 结构化搜索
echo '{"project":"项目名","name_pattern":".*Handler.*","label":"Function"}' | codebase-memory-mcp cli search_graph

# 调用链追踪
echo '{"project":"项目名","function_name":"Search","direction":"both"}' | codebase-memory-mcp cli trace_path

# Cypher 查询
echo '{"project":"项目名","query":"MATCH (f:Function) RETURN f.name LIMIT 5"}' | codebase-memory-mcp cli query_graph
```

### 7.2 开启自动索引（推荐）

```bash
codebase-memory-mcp config set auto_index true             # 新项目首次连接自动索引
codebase-memory-mcp config set auto_index_limit 50000      # 自动索引的文件数上限
codebase-memory-mcp config list                            # 查看全部运行时配置
```

> `auto_watch`（默认 `true`）控制后台文件监听，会基于 git 变更自动增量重索引。跨多项目工作时如想让每个会话保持独立，可 `config set auto_watch false`。

### 7.3 图谱数据位置

- 默认缓存目录：`~/.cache/codebase-memory-mcp/`
- 团队共享产物：项目根 `.codebase-memory/graph.db.zst`（可提交到仓库，队友 clone 后首次运行会解压并增量补齐，省去全量重索引）

---

## 8. 进阶配置

### 8.1 关键环境变量

| 变量 | 默认 | 作用 |
|------|------|------|
| `CBM_CACHE_DIR` | `~/.cache/codebase-memory-mcp` | 索引、`_config.db`、UI 配置的存放目录。**网络盘 IO 慢时可指向本地快盘** |
| `CBM_WORKERS` | 自动 | 索引 worker 数（CPU 核数受限时可调小） |
| `CBM_LOG_LEVEL` | `info` | 日志级别：`debug`/`info`/`warn`/`error`/`none` |
| `CBM_DIAGNOSTICS` | `false` | 设 `1` 输出内存/性能诊断轨迹到 `/tmp/cbm-diagnostics-<pid>.ndjson` |
| `CBM_ALLOWED_ROOT` | 未设 | 限制 `index_repository` 只能索引该目录下的路径（多租户/不可信调用方场景） |
| `CBM_DOWNLOAD_URL` | GitHub Releases | 覆盖更新下载源 |

> 💡 **本机建议**：`/home` 为 Ceph 网络盘、IO 较慢。若索引大型仓库性能不佳，可把缓存放到更快的位置：
> ```bash
> export CBM_CACHE_DIR=/yjmdata/cbm-cache   # 写入 ~/.bashrc 持久化
> ```
> （需确保该目录可读写。注意 Codex/Claude 的 MCP 配置 `env` 块里也要同步该变量，server 才能读到。）

在 MCP 配置中注入环境变量示例（Codex）：

```toml
[mcp_servers.codebase-memory-mcp]
command = "/home/shpc_101170/.local/bin/codebase-memory-mcp"
args = []
[mcp_servers.codebase-memory-mcp.env]
CBM_CACHE_DIR = "/yjmdata/cbm-cache"
CBM_LOG_LEVEL = "info"
```

Claude Code（`~/.claude.json`）对应写法：

```json
"codebase-memory-mcp": {
  "command": "/home/shpc_101170/.local/bin/codebase-memory-mcp",
  "args": [],
  "env": { "CBM_CACHE_DIR": "/yjmdata/cbm-cache" }
}
```

### 8.2 图谱可视化 UI（可选）

仅当安装了 `--ui` 变体时可用：

```bash
codebase-memory-mcp --ui=true --port=9749
# 浏览器打开 http://localhost:9749
```

UI 作为后台线程随 MCP server 运行，Agent 连接期间即可访问。

---

## 9. 常见问题排查

### Q1：标准二进制报 `version 'GLIBC_2.38' not found`

**原因**：误用了非 portable 的标准 Linux 包，它要求 glibc 2.38+，本机只有 2.31。
**解决**：改用 `install.sh`（Linux 自动选 portable），或源码编译，或手动下载 `*-linux-amd64-portable.tar.gz`。

### Q2：`codebase-memory-mcp: command not found`

**原因**：`~/.local/bin` 不在 PATH。
**解决**：见 [3.3 修复 PATH](#33-修复-path重要)；或所有命令改用绝对路径 `~/.local/bin/codebase-memory-mcp`。

### Q3：Agent 连不上 / `/mcp` 看不到该 server

- 确认 `command` 用的是**绝对路径**且文件存在、有执行权限（`chmod 755`）
- 确认配置写对位置：Claude Code → `~/.claude.json`；Codex → `~/.codex/config.toml`
- **重启 Agent**（MCP 配置仅在启动时加载）
- 手动跑一次确认二进制可执行：`/home/shpc_101170/.local/bin/codebase-memory-mcp --version`
- 开启调试日志定位：在 MCP 配置 `env` 中设 `CBM_LOG_LEVEL=debug`

### Q4：Codex 提示需要信任 hook

Codex 的安全机制。运行 `/hooks`，审查并信任 codebase-memory 相关条目即可。cbm 升级后若 hook 定义变化，可能需要重新信任。

### Q5：源码编译失败

- 缺 zlib 头文件：`sudo apt install zlib1g-dev`（本机已具备，通常无需）
- 内存/核数受限：编辑 `scripts/env.sh` 或显式 `make -j2 -f Makefile.cbm cbm` 降低并行度
- 编译器过旧：本机 gcc 9.4 可用；若更老建议升级或改用方案 A

### Q6：索引很慢

本机为网络盘 + 无 AVX2，大型仓库索引耗时偏长属正常现象。可：
- 调小 `CBM_WORKERS` 避免 IO 争抢
- 把 `CBM_CACHE_DIR` 指向本地快盘
- 优先使用团队共享的 `.codebase-memory/graph.db.zst` 产物，避免每人各自全量重索引

### Q7：更新检查连不上 GitHub

更新检查走 GitHub Releases，本机可能需代理。设 `https_proxy=http://127.0.0.1:10940` 后再启动 Agent；或手动更新（见下节）。

### Q8：CLI 报 `cannot read cache directory`

首次安装后直接跑 `list_projects` 可能报 `cannot read cache directory: ~/.cache/codebase-memory-mcp`——因为该目录尚未创建。`list_projects` 不会自动建目录，只有 `index_repository` 会建。解决：

```bash
mkdir -p ~/.cache/codebase-memory-mcp      # 手动建一次即可
# 或直接索引项目，目录会随之创建：
codebase-memory-mcp cli index_repository --repo-path /path/to/repo
```

> 对 Agent 使用无影响：Agent 调用 `index_repository` 时会自动创建该目录。

### Q9：search/trace/query 报 `project not found`，但 `list_projects` 能看到该项目

**根因**：`project` 参数传了**简称**（如 `kairos-trader`），但实际存储的名字是从 repo 路径派生的**完整名**（如 `home-shpc_101170-Development-kairos-trader`）。project 名要求**精确匹配**，不支持模糊/前缀。报错信息会列出 `available_projects`，照抄即可。

报错示例：

```json
{"error":"project not found or not indexed",
 "hint":"Use list_projects to see all indexed projects, then pass it as the \"project\" argument.",
 "available_projects":["home-shpc_101170-Development-kairos-trader"]}
```

**两种解决（本机实测均有效）**：

1. **治本（推荐）**——用 `--name` 重建短名索引，一劳永逸：

   ```bash
   # a. 删旧的完整名索引（名字从 list_projects 抄）
   echo '{"project":"home-shpc_101170-Development-kairos-trader"}' | codebase-memory-mcp cli delete_project
   # b. 用短名重建
   codebase-memory-mcp cli index_repository --repo-path /home/shpc_101170/Development/kairos-trader --name kairos-trader --mode full
   ```

   重建后**所有工具（含 MCP，无需重启 Agent）**都能用短名，连 `qualified_name` 前缀都会更新成 `kairos-trader.src...`。

2. **治标**——调用时直接用 `list_projects` 返回的完整 `name`。

> 💡 AI agent（Claude/Codex）常自作主张用短名，建议每个项目索引时都 `--name` 设短名，从源头避免。

---

## 10. 更新与卸载

### 更新

```bash
codebase-memory-mcp update
```

> server 启动时也会自检版本，并在首次工具调用时提示有新版。本机若网络不通，可重跑方案 A 的安装脚本覆盖升级。

### 卸载

```bash
codebase-memory-mcp uninstall
```

会移除：installer 写入的 Agent 配置条目、skill、hook、指令及二进制；已生成的图谱索引会**列出并经确认后**才删除。

---

## 附录 A：本机一键部署速查（复制即用）

```bash
# 1) 走代理下载 + 安装（Linux 自动取 portable 全静态包，规避 glibc 2.31 问题）
export https_proxy=http://127.0.0.1:10940 http_proxy=http://127.0.0.1:10940
curl -fsSL https://raw.githubusercontent.com/DeusData/codebase-memory-mcp/main/install.sh | bash
unset http_proxy https_proxy

# 2) 修复 PATH
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc && source ~/.bashrc

# 3) 验证
codebase-memory-mcp --version
codebase-memory-mcp install --dry-run    # 先看会改哪些 Agent 配置

# 4) 自动配置 Claude Code + Codex（如未在第 1 步自动完成）
codebase-memory-mcp install -y

# 5) 开启自动索引
codebase-memory-mcp config set auto_index true

# 6) 重启 Claude Code / Codex，在会话内 /mcp 确认 15 个工具已加载，然后说 "Index this project"

# —— 可选：命令行冒烟测试（已实测通过）——
mkdir -p ~/.cache/codebase-memory-mcp
codebase-memory-mcp cli index_repository --repo-path /home/shpc_101170/Development/codebase-memory-mcp --name cbm --mode full
codebase-memory-mcp cli list_projects     # 应看到 'cbm'（本机实测 16588 节点 / 94034 边）
```

## 附录 B：15 个 MCP 工具速查

| 工具 | 用途 |
|------|------|
| `index_repository` | 索引仓库到图谱（之后自动同步） |
| `list_projects` | 列出已索引项目及节点/边数 |
| `delete_project` | 删除项目及其图谱数据 |
| `index_status` | 查询项目索引状态 |
| `get_graph_schema` | 节点/边数量、关系模式、属性定义（**建议最先调用**） |
| `search_graph` | 结构化搜索：label、名称正则、文件范围、度数过滤 |
| `trace_path` | BFS 调用链追踪（谁调用了它 / 它调用了谁，深度 1-5） |
| `detect_changes` | 把 git diff 映射到受影响符号 + 影响半径 + 风险分级 |
| `query_graph` | 执行类 Cypher 只读查询 |
| `get_code_snippet` | 按限定名读取函数源码 |
| `get_architecture` | 代码库总览：语言、包、路由、热点、聚类、ADR |
| `search_code` | 仅在已索引文件内做类 grep 文本搜索 |
| `manage_adr` | 架构决策记录（ADR）的增删改查 |
| `ingest_traces` | 导入运行时 trace 以校验 `HTTP_CALLS` 边 |
| （第 15 个随版本演进，以 `/mcp` 实际加载为准） | |

---

*本文档由对本机（Ubuntu 20.04 / glibc 2.31）的实测核对撰写。如官方 README 与本文有出入，部署命令以仓库根 `README.md` 与 `install.sh` 源码为准。*
