#!/usr/bin/env bash
# Start JupyterLab (with Jupyter Collaboration) and the Datalayer Jupyter MCP Server
# inside this container, so an agent OUTSIDE the container can drive the notebooks over
# streamable-HTTP MCP.
set -euo pipefail

E=/workspace/.pixi/envs/default
JUPYTER_TOKEN="${JUPYTER_TOKEN:-jupyter-token-change-me}"
MCP_TOKEN="${MCP_TOKEN:-mcp-token-change-me}"     # streamable-http refuses to start without one
JUPYTER_PORT="${JUPYTER_PORT:-8888}"
MCP_PORT="${MCP_PORT:-4040}"
NOTEBOOK_DIR="${NOTEBOOK_DIR:-/workspace/notebooks}"
mkdir -p "$NOTEBOOK_DIR"

# Make the R kernel visible to Jupyter once (idempotent). It lands in
# $E/share/jupyter/kernels/ir, i.e. inside the pixi environment itself.
if [ ! -d "$E/share/jupyter/kernels/ir" ]; then
  "$E/bin/R" --vanilla -e 'IRkernel::installspec(name="ir", displayname="R", user=FALSE)' >/dev/null 2>&1 || \
    echo "[entrypoint] WARN: R kernel registration failed"
fi

echo "[entrypoint] starting JupyterLab on :$JUPYTER_PORT (root_dir=$NOTEBOOK_DIR)"
"$E/bin/jupyter" lab --ip 0.0.0.0 --port "$JUPYTER_PORT" --allow-root --no-browser \
  --ServerApp.token="$JUPYTER_TOKEN" --ServerApp.root_dir="$NOTEBOOK_DIR" \
  --ServerApp.allow_origin='*' &

for _ in $(seq 1 60); do
  if "$E/bin/python" -c "import urllib.request,sys; urllib.request.urlopen('http://127.0.0.1:$JUPYTER_PORT/api?token=$JUPYTER_TOKEN', timeout=3)" >/dev/null 2>&1; then
    echo "[entrypoint] JupyterLab is up"
    break
  fi
  sleep 1
done

echo "[entrypoint] starting Jupyter MCP Server (streamable-http) on :$MCP_PORT"
exec "$E/bin/python" -m jupyter_mcp_server \
  --transport streamable-http --host 0.0.0.0 --port "$MCP_PORT" \
  --jupyter-url "http://127.0.0.1:$JUPYTER_PORT" --jupyter-token "$JUPYTER_TOKEN" \
  --mcp-token "$MCP_TOKEN"
