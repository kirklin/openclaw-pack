# ==============================================================================
# Kirklin's openclaw-pack
# 基于官方预编译镜像，仅叠加自定义配置层
# ==============================================================================

FROM ghcr.io/openclaw/openclaw:2026.5.7

LABEL maintainer="Kirklin"
LABEL description="集成了多种能力的 OpenClaw 核心与多插件网关环境"
LABEL org.opencontainers.image.source="https://github.com/kirklin/openclaw-pack"

# ==========================================
# 1. 补装自定义系统依赖
# ==========================================
USER root
ENV DEBIAN_FRONTEND=noninteractive

RUN echo 'Acquire::Retries "5";' > /etc/apt/apt.conf.d/80-retries && \
    apt-get update && \
    apt-get install -y --no-install-recommends --fix-missing \
    jq gosu tini procps curl wget git python3 unzip build-essential file && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# 预装飞书插件（新版已从内置改为外部插件）
RUN OPENCLAW_ALLOW_ROOT=1 openclaw plugins install @openclaw/feishu

# ==========================================
# 2. 用户工作区初始化
# ==========================================
RUN mkdir -p /home/node/.openclaw/workspace \
    /home/node/.openclaw/extensions \
    /home/node/workspace-template && \
    chown -R node:node /home/node/.openclaw /home/node/workspace-template

COPY --chown=node:node ./workspace /home/node/workspace-template

# ==========================================
# 3. Homebrew (为 Agent CLI 工具链提供扩展能力)
# ==========================================
USER node
RUN mkdir -p /home/node/.linuxbrew/Homebrew && \
    git clone --depth 1 https://github.com/Homebrew/brew /home/node/.linuxbrew/Homebrew && \
    mkdir -p /home/node/.linuxbrew/bin && \
    ln -s /home/node/.linuxbrew/Homebrew/bin/brew /home/node/.linuxbrew/bin/brew && \
    chmod -R g+rwX /home/node/.linuxbrew
USER root

# ==========================================
# 4. 启动配置
# ==========================================
COPY ./scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENV HOME=/home/node \
    TERM=xterm-256color \
    PATH="/home/node/.linuxbrew/bin:/home/node/.linuxbrew/sbin:${PATH}" \
    HOMEBREW_NO_AUTO_UPDATE=1 \
    HOMEBREW_NO_INSTALL_CLEANUP=1 \
    OPENCLAW_ALLOW_ROOT=1 \
    OPENCLAW_CONFIG_DIR=/home/node/.openclaw \
    OPENCLAW_WORKSPACE_DIR=/home/node/.openclaw/workspace \
    TINI_SUBREAPER=1

EXPOSE 18789 18790
WORKDIR /home/node

ENTRYPOINT ["/usr/bin/tini", "--", "/bin/bash", "/usr/local/bin/entrypoint.sh"]
