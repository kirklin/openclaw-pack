#!/usr/bin/env bash

# ==============================================================================
# Kirklin's openclaw-pack: One-Click Installation Script
# This script installs Docker and deploys openclaw-pack.
# Usage: curl -fsSL https://raw.githubusercontent.com/kirklin/openclaw-pack/main/scripts/install.sh | bash
# ==============================================================================

set -e

# --- Colors for output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

# --- 1. Check Root Privileges ---
if [[ $EUID -ne 0 ]]; then
   log_error "This script must be run as root. Try: sudo bash install.sh"
fi

# --- 2. OS Detection ---
if [[ "$OSTYPE" != "linux-gnu"* ]]; then
    log_error "This script is designed for Linux systems only."
fi

log_info "Starting Kirklin's openclaw-pack installation..."

# --- 3. Install Docker & Git ---
if ! command -v docker &> /dev/null; then
    log_info "Docker not found. Installing Docker..."
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    rm get-docker.sh
    log_success "Docker installed successfully."
else
    log_info "Docker is already installed."
fi

if ! command -v git &> /dev/null; then
    log_info "Git not found. Installing Git..."
    if command -v apt-get &> /dev/null; then
        apt-get update && apt-get install -y git
    elif command -v yum &> /dev/null; then
        yum install -y git
    else
        log_error "Failed to install Git. Please install it manually."
    fi
    log_success "Git installed successfully."
fi

# --- 4. Choose Installation Method ---
echo -e "\n${YELLOW}Please choose your installation method:${NC}"
echo -e "1) ${GREEN}Pull Pre-built Image${NC} (Faster, recommended for users)"
echo -e "2) ${GREEN}Local Build from Source${NC} (Better for customization/developers)"
read -p "Enter your choice (1 or 2, default is 1): " choice
choice=${choice:-1}

INSTALL_DIR="/opt/openclaw"
log_info "Setting up installation at ${INSTALL_DIR}..."

if [[ "$choice" == "2" ]]; then
    # --- Option 2: Local Build ---
    log_info "Method: Local Build from Source"
    
    if ! command -v git &> /dev/null; then
        log_info "Git not found. Installing Git..."
        if command -v apt-get &> /dev/null; then
            apt-get update && apt-get install -y git
        elif command -v yum &> /dev/null; then
            yum install -y git
        else
            log_error "Failed to install Git. Please install it manually."
        fi
        log_success "Git installed successfully."
    fi

    mkdir -p "${INSTALL_DIR}"
    cd "$(dirname "${INSTALL_DIR}")"

    log_info "Cloning openclaw-pack repository..."
    if [[ -d "openclaw-pack" ]]; then
        log_warn "Folder openclaw-pack already exists in $(pwd). Updating..."
        cd openclaw-pack && git pull
    else
        git clone https://github.com/kirklin/openclaw-pack.git
        cd openclaw-pack
    fi

    # Initialize Configuration
    if [[ ! -f ".env" ]]; then
        cp .env.example .env
        log_success "Created .env from example."
    fi

    log_info "Building and starting services..."
    docker compose up -d --build

else
    # --- Option 1: Pull Image ---
    log_info "Method: Pull Pre-built Image"
    
    mkdir -p "${INSTALL_DIR}"
    cd "${INSTALL_DIR}"

    REPO_RAW_URL="https://raw.githubusercontent.com/kirklin/openclaw-pack/main"
    
    log_info "Downloading configuration files..."
    curl -fsSL "${REPO_RAW_URL}/compose.yaml" -o compose.yaml
    curl -fsSL "${REPO_RAW_URL}/.env.example" -o .env.example

    if [[ ! -f ".env" ]]; then
        cp .env.example .env
        log_success "Created .env from example."
    fi

    log_info "Pulling and starting services..."
    docker compose up -d
fi

# --- 5. Final Output ---
echo -e "\n${GREEN}================================================================${NC}"
log_success "Kirklin's openclaw-pack Installation complete!"
echo -e "${GREEN}================================================================${NC}"
echo -e "\n${YELLOW}Next Steps:${NC}"
echo -e "1. ${BLUE}Edit your configuration:${NC}"
echo -e "   cd $(pwd) && nano .env"
echo -e "2. ${BLUE}Apply changes:${NC}"
if [[ "$choice" == "2" ]]; then
    echo -e "   docker compose up -d --build"
else
    echo -e "   docker compose up -d"
fi
echo -e "3. ${BLUE}Check logs:${NC}"
echo -e "   docker compose logs -f"
echo -e "\n${GREEN}Enjoy your OpenClaw powered gateway!${NC}\n"
