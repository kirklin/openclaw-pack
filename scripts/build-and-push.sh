#!/usr/bin/env bash

# ==============================================================================
# Kirklin's openclaw-pack: Unified Build & Push Script
# Supports multi-architecture builds and both Docker Hub & GHCR.
# Compatible with macOS & Linux.
# ==============================================================================

set -e

log_info() { echo "[INFO] $1"; }
log_error() { echo "[ERROR] $1" >&2; exit 1; }
log_success() { echo "[SUCCESS] $1"; }

# Default values
TARGET_REGISTRY="dockerhub"
NAMESPACE="kirklin"
IMAGE_NAME="openclaw-pack"
DO_BUILD=false
NO_CACHE=false
PLATFORMS="linux/amd64,linux/arm64"

show_help() {
    cat << EOF
Usage: $0 [OPTIONS] <VERSION>

Unified script to build and push Kirklin's openclaw-pack Docker images.

Options:
  -r, --registry      Registry to push to: 'dockerhub' (default) or 'ghcr'
  -n, --namespace     Docker namespace or github user (default: 'kirklin')
  -i, --image         Image name (default: 'openclaw-pack')
  -b, --build         Build the image before pushing (using buildx)
  --no-cache          Don't use cache when building
  -p, --platforms     Platforms to build for (default: 'linux/amd64,linux/arm64')
  -h, --help          Show this help message

Version:
  Required. The tag version to assign to the image (e.g. 1.0.0, latest).
EOF
}

# Parse parameters
while [[ $# -gt 0 ]]; do
    case "$1" in
        -r|--registry) TARGET_REGISTRY="$2"; shift 2 ;;
        -n|--namespace) NAMESPACE="$2"; shift 2 ;;
        -i|--image) IMAGE_NAME="$2"; shift 2 ;;
        -b|--build) DO_BUILD=true; shift 1 ;;
        --no-cache) NO_CACHE=true; shift 1 ;;
        -p|--platforms) PLATFORMS="$2"; shift 2 ;;
        -h|--help) show_help; exit 0 ;;
        -*) log_error "Unknown option $1" ;;
        *)
            if [[ -z "$VERSION" ]]; then
                VERSION="$1"
                shift
            else
                log_error "Multiple versions provided. Unexpected argument: $1"
            fi
            ;;
    esac
done

if [[ -z "$VERSION" ]]; then
    # Try reading from version.txt if no version argument is passed
    if [[ -f "version.txt" ]]; then
        VERSION="$(cat version.txt | tr -d '[:space:]')"
        log_info "No version provided via CLI. Reading from version.txt -> ${VERSION}"
    else
        log_error "Version is required. Pass it as an argument or create version.txt"
    fi
fi

# Determine full registry path
if [[ "$TARGET_REGISTRY" == "ghcr" ]]; then
    FULL_IMAGE_NAME="ghcr.io/$(echo "$NAMESPACE" | tr '[:upper:]' '[:lower:]')/$(echo "$IMAGE_NAME" | tr '[:upper:]' '[:lower:]')"
elif [[ "$TARGET_REGISTRY" == "dockerhub" ]]; then
    FULL_IMAGE_NAME="$(echo "$NAMESPACE" | tr '[:upper:]' '[:lower:]')/$(echo "$IMAGE_NAME" | tr '[:upper:]' '[:lower:]')"
else
    log_error "Invalid registry: $TARGET_REGISTRY. Choose 'dockerhub' or 'ghcr'"
fi

log_info "Target Image: ${FULL_IMAGE_NAME}:${VERSION}"

# Auth Checks
if [[ "$TARGET_REGISTRY" == "ghcr" ]]; then
    if ! docker info 2>/dev/null | grep -q 'ghcr.io'; then
        log_error "You do not appear to be logged into ghcr.io. Run: docker login ghcr.io"
    fi
else
    if ! docker info 2>/dev/null | grep -q 'Username'; then
        log_error "You do not appear to be logged into Docker Hub. Run: docker login"
    fi
fi

if [[ "$DO_BUILD" == true ]]; then
    log_info "Building image for platforms: $PLATFORMS..."
    
    CACHE_ARGS=""
    if [[ "$NO_CACHE" == true ]]; then
        CACHE_ARGS="--no-cache"
    fi
    
    # Needs docker buildx enabled
    docker buildx build --push $CACHE_ARGS \
        --platform "$PLATFORMS" \
        -t "${FULL_IMAGE_NAME}:${VERSION}" \
        -t "${FULL_IMAGE_NAME}:latest" \
        .
    
    log_success "Build & Multi-arch Push completed."
else
    # Assume image is built locally and we just tag/push standard arch
    log_info "Skipping build, tagging local image..."
    
    # Verify local image exists
    LOCAL_IMAGE="${NAMESPACE}/${IMAGE_NAME}:latest"
    if ! docker image inspect "$LOCAL_IMAGE" > /dev/null 2>&1; then
        LOCAL_IMAGE="openclaw-pack:latest"
        if ! docker image inspect "$LOCAL_IMAGE" > /dev/null 2>&1; then
             log_error "No local image found to tag. Please use --build to build one first."
        fi
    fi
    
    docker tag "$LOCAL_IMAGE" "${FULL_IMAGE_NAME}:${VERSION}"
    docker tag "$LOCAL_IMAGE" "${FULL_IMAGE_NAME}:latest"
    
    log_info "Pushing ${FULL_IMAGE_NAME}:${VERSION}..."
    docker push "${FULL_IMAGE_NAME}:${VERSION}"
    
    log_info "Pushing ${FULL_IMAGE_NAME}:latest..."
    docker push "${FULL_IMAGE_NAME}:latest"
    
    log_success "Push completed."
fi

echo ""
log_info "Pull command: docker pull ${FULL_IMAGE_NAME}:${VERSION}"
