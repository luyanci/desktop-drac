#!/bin/bash
#
# Build a Debian (.deb) package for desktop-drac
# This script creates a proper Debian x64 release package that can be installed via dpkg/apt
#
# Usage: ./scripts/build-debian.sh [version]
#
# If no version is provided, it will be extracted from package.json
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
DIST_DIR="$ROOT_DIR/dist"
BUILD_DIR="$ROOT_DIR/build/debian"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Detect architecture
ARCH=$(dpkg --print-architecture 2>/dev/null || echo "amd64")
if [[ "$ARCH" == "x86_64" ]]; then
    ARCH="amd64"
fi

log_info "Building for architecture: $ARCH"

# Parse arguments - flags first, then version
CLEAN="false"
VERSION=""

# Show help if requested
if [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
    cat <<EOF
Usage: $0 [version] [options]

Arguments:
  version              Optional version string (defaults to app/package.json)

Options:
  --clean              Remove dist/ directory before building
  --no-clean           Keep existing dist/ directory (default)
  --help, -h           Show this help message

Examples:
  $0                   # Build with version from app/package.json
  $0 --clean           # Clean build with default version
  $0 3.5.7             # Build version 3.5.7
  $0 3.5.7 --clean     # Clean build of version 3.5.7

EOF
    exit 0
fi

# Parse all arguments
for arg in "$@"; do
    case $arg in
        --clean)
            CLEAN="true"
            ;;
        --no-clean)
            CLEAN="false"
            ;;
        --*)
            echo "Unknown option: $arg"
            echo "Use --help for usage information"
            exit 1
            ;;
        *)
            # First non-option argument is the version
            if [[ -z "$VERSION" ]]; then
                VERSION="$arg"
            fi
            ;;
    esac
done

# Get version from package.json if not provided
if [[ -z "$VERSION" ]]; then
    # Check app/package.json first (actual app version), then fall back to root package.json
    if [[ -f "$ROOT_DIR/app/package.json" ]]; then
        VERSION=$(node -p "require('./app/package.json').version" 2>/dev/null || echo "")
    fi
    if [[ -z "$VERSION" ]]; then
        VERSION=$(node -p "require('./package.json').version" 2>/dev/null || echo "unknown")
    fi
fi

log_info "Building GitHub Desktop version: $VERSION"

if [[ "$CLEAN" == "true" ]]; then
    log_info "Clean build requested - will remove dist/ before building"
fi

# Check if Node.js and Yarn are available
if ! command -v node >/dev/null 2>&1; then
    log_error "Node.js is not installed or not in PATH"
    exit 1
fi

if ! command -v yarn >/dev/null 2>&1 && [[ ! -f "$ROOT_DIR/vendor/yarn-1.21.1.js" ]]; then
    log_error "Yarn is not installed or not in PATH"
    exit 1
fi

# Use vendored yarn if available, otherwise system yarn
if [[ -f "$ROOT_DIR/vendor/yarn-1.21.1.js" ]]; then
    YARN_CMD="node $ROOT_DIR/vendor/yarn-1.21.1.js"
else
    YARN_CMD="yarn"
fi

# Step 1: Install dependencies if needed
if [[ ! -d "$ROOT_DIR/node_modules" ]] || [[ ! -d "$ROOT_DIR/app/node_modules" ]]; then
    log_info "Installing dependencies..."
    cd "$ROOT_DIR"
    $YARN_CMD install
else
    log_info "Dependencies already installed, skipping..."
fi

# Step 2: Clean dist directory if requested
if [[ "$CLEAN" == "true" ]]; then
    log_info "Cleaning dist directory..."
    rm -rf "$DIST_DIR"
    rm -rf "$ROOT_DIR/out"
    rm -rf "$BUILD_DIR"
fi

# Step 3: Build production bundle (creates out/ directory with main.js, renderer.js, etc.)
log_info "Building production bundle..."
cd "$ROOT_DIR"
$YARN_CMD build:prod

# Verify the build output exists
if [[ ! -f "$ROOT_DIR/out/renderer.js" ]]; then
    log_error "Production build failed - out/renderer.js not found"
    exit 1
fi

log_info "Production build completed successfully"

# Step 4: Build only the Debian package (skip AppImage/RPM)
log_info "Building Debian package..."
cd "$ROOT_DIR"

# Create dist directory if it doesn't exist
mkdir -p "$DIST_DIR"

# Use environment variable to skip non-Debian packaging
# This ensures we only build the .deb even if rpmbuild is missing
PACKAGE_ONLY_DEB=1 $YARN_CMD run package

# Alternative: Directly invoke the Debian packager
# Uncomment the line below and comment out the yarn run package line if you want to skip full packaging
# ts-node -P script/tsconfig.json script/package-debian.ts

# Find the generated .deb file
DEB_FILE=$(find "$DIST_DIR" -name "GitHubDesktop-linux-${ARCH}-${VERSION}.deb" -type f | head -n 1)

if [[ -z "$DEB_FILE" ]]; then
    log_error "Debian package not found in $DIST_DIR"
    log_info "Files in dist:"
    ls -la "$DIST_DIR" || true
    exit 1
fi

# Get file size
DEB_SIZE=$(du -h "$DEB_FILE" | cut -f1)

log_info "Debian package created successfully!"
log_info "Location: $DEB_FILE"
log_info "Size: $DEB_SIZE"

# Generate SHA256 checksum
log_info "Generating SHA256 checksum..."
cd "$DIST_DIR"
sha256sum "$(basename "$DEB_FILE")" > "$(basename "$DEB_FILE").sha256"
log_info "Checksum saved to: $DEB_FILE.sha256"

log_info "Build complete!"
log_info ""
log_info "To install the package:"
log_info "  sudo dpkg -i $DEB_FILE"
log_info "  sudo apt install -f  # Fix any missing dependencies"
