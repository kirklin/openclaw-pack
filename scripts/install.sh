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

# Ensure Docker is started and enabled
systemctl enable --now docker &> /dev/null || log_warn "Failed to enable Docker service via systemctl."

# --- 4. Prepare Deployment Directory & Clone Repo ---
INSTALL_DIR="/opt/openclaw"
log_info "Setting up installation directory at ${INSTALL_DIR}..."

if [[ -d "${INSTALL_DIR}" ]]; then
    log_warn "Directory ${INSTALL_DIR} already exists. Backup and remove it or choose another path."
    # For now, we continue but warn.
fi

mkdir -p "${INSTALL_DIR}"
cd "$(dirname "${INSTALL_DIR}")"

log_info "Cloning openclaw-pack repository..."
if [[ -d "openclaw-pack" ]]; then
    log_warn "Folder openclaw-pack already exists in $(pwd). Attempting to use it..."
else
    git clone https://github.com/kirklin/openclaw-pack.git
fi

cd openclaw-pack

# --- 5. Initialize Configuration ---
if [[ ! -f ".env" ]]; then
    log_info "Creating .env from example..."
    cp .env.example .env
else
    log_warn ".env already exists, skipping creation."
fi

# --- 6. Build and Start Locally ---
log_info "Locally building and starting openclaw-pack services..."
if docker compose version &> /dev/null; then
    docker compose up -d --build
else
    log_error "Docker Compose plugin not found. Please ensure Docker is correctly installed."
fi

# --- 7. Final Output ---
echo -e "\n${GREEN}================================================================${NC}"
log_success "Kirklin's openclaw-pack Local Build & Installation complete!"
echo -e "${GREEN}================================================================${NC}"
echo -e "\n${YELLOW}Next Steps:${NC}"
echo -e "1. ${BLUE}Edit your configuration:${NC}"
echo -e "   cd $(pwd) && nano .env"
echo -e "2. ${BLUE}Re-build and apply changes (if needed):${NC}"
echo -e "   docker compose up -d --build"
echo -e "3. ${BLUE}Check logs:${NC}"
echo -e "   docker compose logs -f"
echo -e "\n${GREEN}Enjoy your OpenClaw powered gateway!${NC}\n"
