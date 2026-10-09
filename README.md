# Jupyter with MCP container

一个容器里同时装：

- **pixi** 管理的 Python / R 工具链（conda-forge + PyPI 混合环境）
- **JupyterLab**（带 Real Time Collaboration）
- **Datalayer Jupyter MCP Server**，以 streamable-HTTP 暴露 `/mcp`

目的是让**容器外**的 agent（Codex / Claude Code / Cursor…）通过 MCP 进来看、改 notebook、
执行代码，而**不需要在容器里装任何 agent**。容器本身就是隔离边界，不用另外准备 code sandbox。

## 文件

| 文件 | 作用 |
|---|---|
| `pixi.toml` | 依赖声明：conda-forge 装 Python 3.12 / JupyterLab / jupyter-collaboration / ipykernel / R / IRkernel；PyPI 装 `jupyter-mcp-server` |
| `pixi.lock` | 锁定文件，`pixi install --locked` 保证可复现 |
| `Dockerfile` | 单阶段镜像：`ghcr.io/prefix-dev/pixi` + `pixi install --locked` + entrypoint |
| `entrypoint.sh` | 注册 R kernel → 起 JupyterLab → 起 MCP server（streamable-http） |
| `.dockerignore` / `.gitignore` | 排除 `.pixi/`、`notebooks/`、日志 |

## 实测版本

- pixi 0.76.1
- Python 3.12.15 / JupyterLab 4.6.4 / jupyter-server 2.21.1 / jupyter-collaboration 5.0.4 / ipykernel
- jupyter-mcp-server **2.2.3**（PyPI）
- R 4.5.3 / IRkernel 1.3.2（conda-forge）
- MCP 协议：initialize 用 `protocolVersion: 2025-06-18`，服务端 18 个工具

## 构建与运行

```bash
docker build -t jupyter-pixi-mcp .
docker run -d --name jupyter-pixi -p 8888:8888 -p 4040:4040 \
  -e JUPYTER_TOKEN=<jupyter-token> -e MCP_TOKEN=<mcp-token> \
  -v "$PWD/notebooks:/workspace/notebooks" \
  jupyter-pixi-mcp
```

- JupyterLab: `http://<host>:8888/lab?token=<jupyter-token>`
- MCP endpoint: `http://<host>:4040/mcp`（Bearer `<mcp-token>`）

`MCP_TOKEN` 一定要给：streamable-http 传输下不给 token 会直接 `ValueError` 退出（这是默认的安全行为，
别去关 `--insecure-mcp-noauth`）。

## 外部 agent 怎么接

```toml
# ~/.codex/config.toml
[mcp_servers.jupyter]
url = "http://<host>:4040/mcp"
bearer_token_env_var = "JUPYTER_MCP_TOKEN"   # 值为 <mcp-token>
```

不想暴露端口也可以让 agent 走 stdio 进容器，例如：

```bash
codex mcp add jupyter -- docker exec -i <容器名> python -m jupyter_mcp_server \
  --jupyter-url http://127.0.0.1:8888 --jupyter-token <jupyter-token>
```

### 直连会被 421 拦掉：得解决 Host 校验

从别的机器/容器直接连 `http://<host>:4040/mcp` 会返回 **`421 Invalid Host header`**。

原因在 MCP Python SDK：`streamable_http_app()` 在 `host` 属于 `127.0.0.1 / localhost / ::1`
时会自动开启 DNS-rebinding 保护，白名单只有 `127.0.0.1:*`、`localhost:*`、`[::1]:*`。
`jupyter-mcp-server` 构造 server 时用的是默认 host，所以**即使 `--host 0.0.0.0`，这个白名单仍然生效**，
而且它没有暴露任何 CLI/环境变量可以改。

两条实测可行的绕法：

1. **反向代理改写 Host**（推荐，外部 agent 侧零改动）——实测通过：

```nginx
location / {
    proxy_pass http://<mcp-container>:4040;
    proxy_set_header Host 127.0.0.1:4040;   # 关键：让服务端看到的是白名单里的 Host
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_buffering off;
    proxy_read_timeout 600s;
}
```

2. **让请求的 Host 天然就是 localhost** —— 用 SSH 端口转发 / `kubectl port-forward` / 本地
   sidecar 代理，agent 连 `http://127.0.0.1:4040/mcp`，直接放行。

## R（和任何非 Python kernel）

MCP 工具里**没有**「按语言启动 kernel」的能力：

- `use_notebook` 只接受 `kernel_id`，没有 `kernel_name`；
- MCP 创建出来的 notebook，metadata 是空的 `{}`，所以之后再 `use_notebook(mode="connect")`
  打开它时，会**新建一个默认 python3 kernel**，而不是它上次用的 R kernel。把 R 代码发给这种
  notebook，实测报 `/usr/bin/sh: 1: Syntax error`。

所以跑 R 的流程是「先在 Jupyter 侧有一个 ir kernel，再让 agent 绑定它」：

```bash
# 方式 A：人在 JupyterLab UI 里新建一个 R notebook（最省事）
# 方式 B：预启动一个 R kernel 拿 id（在能访问 JupyterLab 的机器上执行）
curl -s -X POST "http://<host>:8888/api/kernels?token=$JUPYTER_TOKEN" \
     -H 'Content-Type: application/json' -d '{"name":"ir"}'
```

然后用 `list_kernels` 找到那个 `ir` kernel 的 id，`use_notebook(..., kernel_id=<id>)` 绑定，
之后 `insert_execute_code_cell` / `execute_cell` 就是 R 了（实测 R 4.5.3 正常执行并写入容器内文件）。

IRkernel 的 kernelspec 由 `entrypoint.sh` 在容器启动时注册进 pixi 环境自己的
`share/jupyter/kernels/ir`，所以 agent 一定能看到 `ir` 这个 kernel 名字。

## 依赖源（重要）

`pixi.toml` / `pixi.lock` 里用的是**清华镜像**（conda-forge 与 PyPI 各一个），因为这个项目是在
国内网络环境下做的：`pypi.org` 直连不通，所以 `[pypi-options].index-url` 必须换源。

在海外网络下想换回官方源：把 `pixi.toml` 里的 `channels` 改成 `["conda-forge"]`、删掉
`[pypi-options]`，然后跑 `pixi update`（或 `pixi install`）让它重新生成 `pixi.lock`，再用新的 lock
构建镜像。注意 lock 里记录的是完整 URL，所以换源必须跟着换 lock，不能只改 toml 后继续用 `--locked`。

镜像基础版本固定为 `ghcr.io/prefix-dev/pixi:0.76.1`（与本地实测的 pixi 版本一致）；想升级改这一行即可。

## 依赖来源上的一个硬事实

**conda-forge 上没有 `jupyter-mcp-server`**（也没有 `jupyter-mcp-tools`）。想用 pixi 装它，只能走
`[pypi-dependencies]`（本仓库的写法，实测可行）。

conda-forge 上**有**的是官方 Jupyter 团队那套 MCP 扩展：`jupyter-server-mcp` 0.4.0 +
`jupyter-ai-tools` 0.7.0。如果你要「全部依赖都是 conda 包、pixi 原生管到底」，那是唯一原生路线，
代价是工具集/行为与 Datalayer 的不同。

## 安全边界

- 容器就是隔离边界：MCP 的 `execute_code` / `execute_cell` 跑的是**容器内**的
  Python/R（实测打印出的 hostname 是容器 hostname，写出的文件在容器文件系统里）。
- 但这些工具是**无沙箱的任意代码执行** —— 能读写容器内任意路径、能用容器网络、能自己装包。
  所谓「容器即沙箱」的强度完全取决于你怎么跑这个容器：
  - 不要挂 `docker.sock`；
  - 不要挂宿主机敏感目录（只挂你要给 agent 的工作目录）；
  - 限制出口网络；
  - 需要的话把 entrypoint 里的 `--allow-root` 换成非 root 用户；
  - MCP 的 Bearer token 是唯一凭据，别用默认值，别把 4040 直接暴露到公网（走反代 + TLS 或内网 ACL）。

## 实测记录

- `docker build` 通过；容器起来后 JupyterLab 与 MCP server 都在跑。
- 外部客户端 `initialize` 握手成功，`tools/list` 返回 18 个工具：`execute_code`、`execute_cell`、
  `insert_cell`、`insert_execute_code_cell`、`edit_cell_source`、`overwrite_cell_source`、
  `read_cell`、`delete_cell`、`move_cell`、`clear_cell_output`、`read_notebook`、`list_notebooks`、
  `use_notebook`、`unuse_notebook`、`restart_notebook`、`list_files`、`list_kernels`、`connect_to_jupyter`。
- `execute_code` 在容器内执行 Python，打印出的 hostname 是容器 hostname；写出的文件能从容器外
  `docker exec ... cat` 读到。
- `insert_execute_code_cell` 绑定 `ir` kernel 后 R 代码正常执行。
