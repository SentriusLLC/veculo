#!/bin/bash
#
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.
#

# Build script for Apache Accumulo Docker images

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Default values
REGISTRY="${DOCKER_REGISTRY:-accumulo}"
TAG="${DOCKER_TAG:-4.0.0-SNAPSHOT}"
BUILD_ARGS=""
PUSH=false
PLATFORM=""

# Usage function
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Build Apache Accumulo Docker images

OPTIONS:
    -r, --registry REGISTRY     Docker registry (default: accumulo)
    -t, --tag TAG              Docker tag (default: 4.0.0-SNAPSHOT)
    -p, --push                 Push images to registry
    --platform PLATFORM       Target platform (e.g., linux/amd64,linux/arm64)
    --build-arg KEY=VALUE      Pass build argument to docker build
    -h, --help                 Show this help message

EXAMPLES:
    # Build for local use
    $0

    # Build and push to registry
    $0 -r myregistry.com/accumulo -t latest -p

    # Build for multiple platforms
    $0 --platform linux/amd64,linux/arm64
    
    # Build with custom build args
    $0 --build-arg ACCUMULO_VERSION=3.0.0
EOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -r|--registry)
            REGISTRY="$2"
            shift 2
            ;;
        -t|--tag)
            TAG="$2" 
            shift 2
            ;;
        -p|--push)
            PUSH=true
            shift
            ;;
        --platform)
            PLATFORM="$2"
            shift 2
            ;;
        --build-arg)
            BUILD_ARGS="$BUILD_ARGS --build-arg $2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Build Accumulo distribution if needed
build_accumulo_dist() {
    log_info "Checking if Accumulo distribution exists..."
    
    if [ ! -d "$PROJECT_DIR/assemble/target" ]; then
        log_info "Building Accumulo distribution..."
        cd "$PROJECT_DIR"
        
        # Check if Maven is available
        if ! command -v mvn &> /dev/null; then
            log_error "Maven is required to build Accumulo distribution"
            exit 1
        fi
        
        # Build the distribution
        mvn clean package -DskipTests -pl assemble -am
        
        if [ $? -ne 0 ]; then
            log_error "Failed to build Accumulo distribution"
            exit 1
        fi
    fi
    
    # Extract distribution for Docker build
    local dist_dir="$PROJECT_DIR/docker/accumulo/dist"
    mkdir -p "$dist_dir"
    
    local tarball=$(find "$PROJECT_DIR/assemble/target" -name "accumulo-*-bin.tar.gz" | head -1)
    if [ -z "$tarball" ]; then
        log_error "No Accumulo distribution found in assemble/target"
        exit 1
    fi
    
    log_info "Extracting distribution: $(basename "$tarball")"
    tar -xzf "$tarball" -C "$dist_dir" --strip-components=1
    
    log_success "Accumulo distribution prepared"
}

# Build Docker image
build_docker_image() {
    local image_name="$REGISTRY/accumulo:$TAG"
    local dockerfile="$PROJECT_DIR/docker/accumulo/Dockerfile"
    local context="$PROJECT_DIR/docker/accumulo"
    
    log_info "Building Docker image: $image_name"
    
    # Prepare build command
    local build_cmd="docker build"
    
    if [ -n "$PLATFORM" ]; then
        build_cmd="$build_cmd --platform $PLATFORM"
    fi
    
    build_cmd="$build_cmd $BUILD_ARGS -t $image_name -f $dockerfile $context"
    
    log_info "Build command: $build_cmd"
    
    # Execute build
    if eval "$build_cmd"; then
        log_success "Successfully built $image_name"
    else
        log_error "Failed to build $image_name"
        exit 1
    fi
    
    # Push if requested
    if [ "$PUSH" = true ]; then
        log_info "Pushing image: $image_name"
        if docker push "$image_name"; then
            log_success "Successfully pushed $image_name"
        else
            log_error "Failed to push $image_name"
            exit 1
        fi
    fi
}

# Validate environment
validate_environment() {
    log_info "Validating build environment..."
    
    # Check Docker
    if ! command -v docker &> /dev/null; then
        log_error "Docker is required but not installed"
        exit 1
    fi
    
    # Check Docker daemon
    if ! docker info &> /dev/null; then
        log_error "Docker daemon is not running"
        exit 1
    fi
    
    log_success "Environment validation passed"
}

# Main execution
main() {
    log_info "Starting Accumulo Docker build process"
    
    validate_environment
    build_accumulo_dist
    build_docker_image
    
    log_success "Build process completed successfully!"
    log_info "Image: $REGISTRY/accumulo:$TAG"
    
    # Show image info
    docker images "$REGISTRY/accumulo:$TAG"
}

# Execute main function
main "$@"