# One container holding:
#   * a pixi-managed Python + R toolchain (conda-forge, plus PyPI for the MCP server)
#   * JupyterLab with Real Time Collaboration
#   * the Datalayer Jupyter MCP Server, exposed over streamable HTTP
#
# The point of the whole thing: an agent running OUTSIDE the container drives the
# notebooks over MCP, so nothing agent-like is installed inside the workspace.
FROM ghcr.io/prefix-dev/pixi:0.76.1

ENV DEBIAN_FRONTEND=noninteractive

WORKDIR /workspace
COPY pixi.toml pixi.lock ./
RUN pixi install --locked

# Put the pixi environment first on PATH so entrypoint.sh can call jupyter/python directly.
ENV PATH=/workspace/.pixi/envs/default/bin:$PATH

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh && mkdir -p /workspace/notebooks

EXPOSE 8888 4040
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
