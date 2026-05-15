#!/usr/bin/env bash
# ==============================================================================
# Kirklin's openclaw-pack 一键部署脚本
#
# 使用方式：
#   curl -fsSL https://raw.githubusercontent.com/kirklin/openclaw-pack/main/scripts/deploy.sh | bash
#
# 或手动执行：
#   chmod +x deploy.sh && ./deploy.sh
#
# 该脚本会：
#   1. 检测并安装 Docker + Docker Compose（如尚未安装）
#   2. 交互式询问 3 个必要凭证（LLM API Key、飞书 App ID、飞书 Secret）
#   3. 克隆仓库、生成 .env 配置、构建镜像并启动服务
# ==============================================================================

set -euo pipefail

# ---- 颜色 & 日志 ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }

# ---- 常量 ----
INSTALL_DIR="/opt/openclaw"
REPO_URL="https://github.com/kirklin/openclaw-pack.git"
DATA_DIR="$HOME/.openclaw"

# ==============================================================================
# 0. 前置检查
# ==============================================================================
banner() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                                                  ║${NC}"
    echo -e "${CYAN}║   🦞  Kirklin's OpenClaw-Pack 一键部署           ║${NC}"
    echo -e "${CYAN}║                                                  ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
    echo ""
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "请使用 root 用户运行此脚本：sudo bash deploy.sh"
        exit 1
    fi
}

check_os() {
    if [[ ! -f /etc/os-release ]]; then
        log_error "无法识别操作系统，仅支持 Ubuntu/Debian/CentOS"
        exit 1
    fi
    . /etc/os-release
    log_info "检测到操作系统：$PRETTY_NAME"
}

# ==============================================================================
# 1. Docker 安装
# ==============================================================================
install_docker() {
    if command -v docker &>/dev/null; then
        local docker_ver
        docker_ver=$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',')
        log_success "Docker 已安装（$docker_ver）"
    else
        log_info "正在安装 Docker..."

        # 优先使用官方脚本
        if curl -fsSL https://get.docker.com -o /tmp/get-docker.sh 2>/dev/null; then
            sh /tmp/get-docker.sh
            rm -f /tmp/get-docker.sh
        else
            # 备用：手动安装（Ubuntu/Debian）
            apt-get update -y
            apt-get install -y docker.io docker-compose-plugin
        fi

        systemctl enable docker
        systemctl start docker
        log_success "Docker 安装完成"
    fi

    # 检查 Docker Compose
    if docker compose version &>/dev/null; then
        local compose_ver
        compose_ver=$(docker compose version --short 2>/dev/null || echo "unknown")
        log_success "Docker Compose 已就绪（$compose_ver）"
    else
        log_info "正在安装 Docker Compose 插件..."
        apt-get update -y && apt-get install -y docker-compose-plugin
        log_success "Docker Compose 插件安装完成"
    fi
}

# ==============================================================================
# 2. 交互式收集凭证
# ==============================================================================
collect_credentials() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  📝  请输入以下 3 个必要配置${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    # --- 1. LLM API Key ---
    echo -e "${YELLOW}1/3${NC} 大模型 API Key"
    echo -e "     用于接入 AI 大模型（支持 OpenAI 兼容的 API）"
    echo -e "     如使用中转站，请先设置 Base URL"
    echo ""

    local default_base_url="https://aihubmix.com/v1"
    read -rp "     LLM Base URL [默认: $default_base_url]: " INPUT_BASE_URL
    INPUT_BASE_URL="${INPUT_BASE_URL:-$default_base_url}"

    local default_model="gemini-3.1-flash-lite-preview"
    read -rp "     模型名称 [默认: $default_model]: " INPUT_MODEL
    INPUT_MODEL="${INPUT_MODEL:-$default_model}"

    while true; do
        read -rp "     API Key: " INPUT_API_KEY
        if [[ -n "$INPUT_API_KEY" ]]; then break; fi
        log_warn "API Key 不能为空"
    done

    echo ""

    # --- 2. 飞书 App ID ---
    echo -e "${YELLOW}2/3${NC} 飞书应用 App ID"
    echo -e "     在飞书开发者后台 (https://open.feishu.cn) 创建应用后获取"
    echo ""

    while true; do
        read -rp "     飞书 App ID: " INPUT_FEISHU_APP_ID
        if [[ -n "$INPUT_FEISHU_APP_ID" ]]; then break; fi
        log_warn "飞书 App ID 不能为空"
    done

    echo ""

    # --- 3. 飞书 App Secret ---
    echo -e "${YELLOW}3/3${NC} 飞书应用 App Secret"
    echo ""

    while true; do
        read -rp "     飞书 Secret: " INPUT_FEISHU_SECRET
        if [[ -n "$INPUT_FEISHU_SECRET" ]]; then break; fi
        log_warn "飞书 Secret 不能为空"
    done

    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${GREEN}✓${NC} Base URL : $INPUT_BASE_URL"
    echo -e "  ${GREEN}✓${NC} 模型     : $INPUT_MODEL"
    echo -e "  ${GREEN}✓${NC} API Key  : ${INPUT_API_KEY:0:8}****"
    echo -e "  ${GREEN}✓${NC} 飞书 ID  : $INPUT_FEISHU_APP_ID"
    echo -e "  ${GREEN}✓${NC} 飞书密钥 : ${INPUT_FEISHU_SECRET:0:6}****"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    read -rp "确认以上信息无误？[Y/n]: " CONFIRM
    CONFIRM="${CONFIRM:-Y}"
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        log_warn "已取消，请重新运行脚本"
        exit 0
    fi
}

# ==============================================================================
# 3. 克隆仓库 & 生成 .env
# ==============================================================================
setup_project() {
    log_info "准备项目目录：$INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"

    if [[ -d "$INSTALL_DIR/.git" ]]; then
        log_info "项目已存在，拉取最新代码..."
        cd "$INSTALL_DIR"
        git pull --ff-only origin main 2>/dev/null || {
            log_warn "自动更新失败，使用现有代码继续"
        }
    else
        log_info "克隆仓库..."
        # 如果目录非空（但不是 git 仓库），备份后清空
        if [[ -n "$(ls -A "$INSTALL_DIR" 2>/dev/null)" ]]; then
            log_warn "目录非空且非 Git 仓库，备份旧文件..."
            mv "$INSTALL_DIR" "${INSTALL_DIR}.bak.$(date +%s)"
            mkdir -p "$INSTALL_DIR"
        fi
        git clone "$REPO_URL" "$INSTALL_DIR"
        cd "$INSTALL_DIR"
    fi

    log_success "项目代码就绪"
}

generate_env() {
    log_info "生成 .env 配置文件..."

    # 如果已有 .env，备份
    if [[ -f "$INSTALL_DIR/.env" ]]; then
        cp "$INSTALL_DIR/.env" "$INSTALL_DIR/.env.bak.$(date +%s)"
        log_warn "已备份旧的 .env 文件"
    fi

    # 从模板复制
    cp "$INSTALL_DIR/.env.example" "$INSTALL_DIR/.env"

    # 生成随机 Gateway Token
    local gw_token
    gw_token="sk-$(openssl rand -hex 16 2>/dev/null || head -c 32 /dev/urandom | xxd -p)"

    # 写入用户配置
    sed -i "s|^LLM_API_KEY=.*|LLM_API_KEY=$INPUT_API_KEY|" "$INSTALL_DIR/.env"
    sed -i "s|^LLM_BASE_URL=.*|LLM_BASE_URL=$INPUT_BASE_URL|" "$INSTALL_DIR/.env"
    sed -i "s|^LLM_PRIMARY_MODEL=.*|LLM_PRIMARY_MODEL=$INPUT_MODEL|" "$INSTALL_DIR/.env"
    sed -i "s|^BOT_FEISHU_APP_ID=.*|BOT_FEISHU_APP_ID=$INPUT_FEISHU_APP_ID|" "$INSTALL_DIR/.env"
    sed -i "s|^BOT_FEISHU_SECRET=.*|BOT_FEISHU_SECRET=$INPUT_FEISHU_SECRET|" "$INSTALL_DIR/.env"
    sed -i "s|^OPENCLAW_GATEWAY_TOKEN=.*|OPENCLAW_GATEWAY_TOKEN=$gw_token|" "$INSTALL_DIR/.env"

    # 根据模型名推断上下文窗口
    if [[ "$INPUT_MODEL" == *gemini* ]]; then
        sed -i "s|^LLM_CTX_WINDOW=.*|LLM_CTX_WINDOW=1000000|" "$INSTALL_DIR/.env"
    fi

    log_success ".env 配置文件已生成"
}

# ==============================================================================
# 4. 构建 & 启动
# ==============================================================================
deploy() {
    cd "$INSTALL_DIR"

    log_info "构建 Docker 镜像（首次构建约需 1-2 分钟）..."
    docker compose build --quiet 2>&1 | tail -5

    log_info "启动服务..."
    docker compose up -d

    log_info "等待服务启动..."
    local max_wait=60
    local waited=0
    while [[ $waited -lt $max_wait ]]; do
        if docker logs openclaw-pack 2>&1 | grep -q "ws client ready"; then
            break
        fi
        sleep 2
        waited=$((waited + 2))
    done

    echo ""
}

# ==============================================================================
# 5. 验证 & 输出结果
# ==============================================================================
verify_and_print() {
    local success=true

    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  🔍  部署验证${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    # 检查容器运行状态
    if docker ps --filter "name=openclaw-pack" --format '{{.Status}}' | grep -q "Up"; then
        echo -e "  ${GREEN}✓${NC} 容器运行中"
    else
        echo -e "  ${RED}✗${NC} 容器未运行"
        success=false
    fi

    # 检查飞书 WebSocket
    if docker logs openclaw-pack 2>&1 | grep -q "ws client ready"; then
        echo -e "  ${GREEN}✓${NC} 飞书 WebSocket 已连接"
    else
        echo -e "  ${YELLOW}⚠${NC} 飞书 WebSocket 尚未连接（可能仍在启动中）"
    fi

    # 检查 Gateway
    if docker logs openclaw-pack 2>&1 | grep -q "gateway.*ready"; then
        echo -e "  ${GREEN}✓${NC} Gateway 已就绪"
    else
        echo -e "  ${YELLOW}⚠${NC} Gateway 尚未就绪"
    fi

    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    if [[ "$success" == "true" ]]; then
        echo -e "${GREEN}🎉 部署成功！${NC}"
    else
        echo -e "${YELLOW}⚠  部署可能存在问题，请查看日志排查${NC}"
    fi

    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  📋  后续操作指南${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${YELLOW}【首次使用】${NC}"
    echo -e "  在飞书中搜索并私聊你的机器人，发送任意消息。"
    echo -e "  首次会收到配对码提示，在服务器上执行："
    echo -e "  ${GREEN}docker exec openclaw-pack openclaw pairing approve feishu <配对码>${NC}"
    echo ""
    echo -e "  ${YELLOW}【飞书开发者后台设置】${NC}"
    echo -e "  确保已开启以下配置："
    echo -e "  • 事件订阅方式 → 使用长连接接收事件"
    echo -e "  • 启用机器人能力"
    echo -e "  • 应用已发布并在可用范围内"
    echo ""
    echo -e "  ${YELLOW}【常用运维命令】${NC}"
    echo -e "  查看日志:      ${GREEN}docker logs -f openclaw-pack${NC}"
    echo -e "  重启服务:      ${GREEN}cd $INSTALL_DIR && docker compose restart${NC}"
    echo -e "  更新代码:      ${GREEN}cd $INSTALL_DIR && git pull && docker compose up -d --build${NC}"
    echo -e "  重置配置:      ${GREEN}rm -f ~/.openclaw/openclaw.json && docker compose restart${NC}"
    echo -e "  配对审批:      ${GREEN}docker exec openclaw-pack openclaw pairing approve feishu <code>${NC}"
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# ==============================================================================
# Main
# ==============================================================================
main() {
    banner
    check_root
    check_os

    install_docker
    collect_credentials
    setup_project
    generate_env
    deploy
    verify_and_print
}

main "$@"
