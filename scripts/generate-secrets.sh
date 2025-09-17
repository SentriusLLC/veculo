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

# Generate secrets and configuration for Accumulo Helm deployment

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Default values
OUTPUT_FILE=""
INSTANCE_NAME="accumulo"
NAMESPACE="default"
INTERACTIVE=true
OVERWRITE=false

# Usage function
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Generate secrets and configuration for Accumulo Helm deployment

OPTIONS:
    -o, --output FILE          Output values file (default: values-generated.yaml)
    -i, --instance NAME        Accumulo instance name (default: accumulo)
    -n, --namespace NAMESPACE  Kubernetes namespace (default: default)
    --non-interactive          Run in non-interactive mode with defaults
    --overwrite                Overwrite existing output file
    -h, --help                 Show this help message

EXAMPLES:
    # Interactive mode (default)
    $0 -o my-values.yaml

    # Non-interactive with custom instance
    $0 --non-interactive -i prod-accumulo -o prod-values.yaml
    
    # Generate for specific namespace
    $0 -n accumulo-prod -o prod-values.yaml
EOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -o|--output)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        -i|--instance)
            INSTANCE_NAME="$2"
            shift 2
            ;;
        -n|--namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        --non-interactive)
            INTERACTIVE=false
            shift
            ;;
        --overwrite)
            OVERWRITE=true
            shift
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

# Set default output file if not specified
if [ -z "$OUTPUT_FILE" ]; then
    OUTPUT_FILE="$PROJECT_DIR/charts/accumulo/values-generated.yaml"
fi

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

# Generate secure random string
generate_secret() {
    local length=${1:-32}
    openssl rand -base64 "$length" | tr -d "=+/" | cut -c1-25
}

# Generate UUID
generate_uuid() {
    if command -v uuidgen &> /dev/null; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    else
        cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "$(date +%s)-$(shuf -i 1000-9999 -n 1)"
    fi
}

# Interactive input function
get_input() {
    local prompt="$1"
    local default="$2"
    local secret="${3:-false}"
    
    if [ "$INTERACTIVE" = false ]; then
        echo "$default"
        return
    fi
    
    if [ "$secret" = true ]; then
        echo -n "$prompt [$default]: " >&2
        read -s input
        echo >&2
    else  
        echo -n "$prompt [$default]: " >&2
        read input
    fi
    
    echo "${input:-$default}"
}

# Validate tools
validate_tools() {
    local missing_tools=()
    
    if ! command -v openssl &> /dev/null; then
        missing_tools+=("openssl")
    fi
    
    if [ ${#missing_tools[@]} -gt 0 ]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        log_info "Please install the missing tools and try again"
        exit 1
    fi
}

# Generate configuration
generate_config() {
    log_info "Generating Accumulo configuration..."
    
    # Check if output file exists
    if [ -f "$OUTPUT_FILE" ] && [ "$OVERWRITE" = false ]; then
        log_error "Output file already exists: $OUTPUT_FILE"
        log_info "Use --overwrite to overwrite existing file"
        exit 1
    fi
    
    # Collect configuration values
    log_info "Collecting configuration values..."
    
    local instance_secret
    local storage_provider
    local s3_bucket
    local s3_region
    local s3_access_key
    local s3_secret_key
    local gcs_project
    local gcs_bucket
    local azure_account
    local azure_container
    local azure_key
    
    # Instance configuration
    if [ "$INTERACTIVE" = true ]; then
        echo
        echo "=== Accumulo Instance Configuration ==="
    fi
    
    INSTANCE_NAME=$(get_input "Instance name" "$INSTANCE_NAME")
    instance_secret=$(generate_secret)
    
    if [ "$INTERACTIVE" = true ]; then
        log_info "Generated instance secret: $instance_secret"
        echo
        echo "=== Storage Configuration ==="
        echo "Choose storage provider:"
        echo "1) AWS S3"
        echo "2) Google Cloud Storage"
        echo "3) Azure Blob Storage" 
        echo "4) MinIO (development)"
        echo -n "Selection [4]: "
        read storage_choice
        storage_choice=${storage_choice:-4}
    else
        storage_choice=4  # Default to MinIO for non-interactive
    fi
    
    case $storage_choice in
        1)
            storage_provider="s3"
            s3_bucket=$(get_input "S3 bucket name" "${INSTANCE_NAME}-data")
            s3_region=$(get_input "AWS region" "us-west-2")
            s3_access_key=$(get_input "AWS access key (leave empty for IRSA)" "")
            if [ -n "$s3_access_key" ]; then
                s3_secret_key=$(get_input "AWS secret key" "" true)
            fi
            ;;
        2)
            storage_provider="gcs"
            gcs_project=$(get_input "GCP project ID" "")
            gcs_bucket=$(get_input "GCS bucket name" "${INSTANCE_NAME}-data")
            ;;
        3)
            storage_provider="azure"
            azure_account=$(get_input "Azure storage account" "")
            azure_container=$(get_input "Azure container name" "${INSTANCE_NAME}-data")
            azure_key=$(get_input "Azure access key (leave empty for Managed Identity)" "" true)
            ;;
        *)
            storage_provider="minio"
            ;;
    esac
    
    # Generate values file
    log_info "Generating values file: $OUTPUT_FILE"
    
    cat > "$OUTPUT_FILE" << EOF
# Generated Accumulo configuration
# Generated on: $(date)
# Instance: $INSTANCE_NAME
# Namespace: $NAMESPACE

# Global settings
global:
  commonLabels:
    instance: "$INSTANCE_NAME"
    generated: "$(date +%Y%m%d)"

# Accumulo configuration
accumulo:
  instance:
    name: "$INSTANCE_NAME"
    secret: "$instance_secret"
    volumes: "alluxio://$INSTANCE_NAME-alluxio-master:19998/accumulo"

EOF

    # Add storage configuration
    case $storage_provider in
        s3)
            cat >> "$OUTPUT_FILE" << EOF
# AWS S3 storage configuration
storage:
  provider: "s3"
  s3:
    endpoint: "https://s3.amazonaws.com"
    bucket: "$s3_bucket"
    region: "$s3_region"
EOF
            if [ -n "$s3_access_key" ]; then
                cat >> "$OUTPUT_FILE" << EOF
    accessKey: "$s3_access_key"
    secretKey: "$s3_secret_key"

# Use access keys authentication
auth:
  method: "accessKeys"
EOF
            else
                cat >> "$OUTPUT_FILE" << EOF
    accessKey: ""
    secretKey: ""

# Use IRSA authentication
auth:
  method: "serviceAccount"
  serviceAccount:
    create: true
    name: "$INSTANCE_NAME"
    annotations:
      eks.amazonaws.com/role-arn: "arn:aws:iam::ACCOUNT_ID:role/${INSTANCE_NAME}-role"
EOF
            fi
            ;;
        gcs)
            cat >> "$OUTPUT_FILE" << EOF  
# Google Cloud Storage configuration
storage:
  provider: "gcs"
  gcs:
    projectId: "$gcs_project"
    bucket: "$gcs_bucket"
    keyFile: ""

# Use Workload Identity
auth:
  method: "workloadIdentity"
  serviceAccount:
    create: true
    name: "$INSTANCE_NAME"
    annotations:
      iam.gke.io/gcp-service-account: "$INSTANCE_NAME@$gcs_project.iam.gserviceaccount.com"
EOF
            ;;
        azure)
            cat >> "$OUTPUT_FILE" << EOF
# Azure Blob Storage configuration  
storage:
  provider: "azure"
  azure:
    account: "$azure_account"
    container: "$azure_container"
EOF
            if [ -n "$azure_key" ]; then
                cat >> "$OUTPUT_FILE" << EOF
    key: "$azure_key"

# Use access keys authentication
auth:
  method: "accessKeys"
EOF
            else
                cat >> "$OUTPUT_FILE" << EOF
    key: ""

# Use Managed Identity
auth:
  method: "managedIdentity"
  serviceAccount:
    create: true
    name: "$INSTANCE_NAME"
    annotations:
      azure.workload.identity/client-id: "USER_ASSIGNED_CLIENT_ID"
EOF
            fi
            ;;
        *)
            cat >> "$OUTPUT_FILE" << EOF
# MinIO storage configuration (development)
storage:
  provider: "minio"
  minio:
    endpoint: "http://$INSTANCE_NAME-minio:9000"
    bucket: "$INSTANCE_NAME-data"
    accessKey: "minioadmin"
    secretKey: "minioadmin"

# Enable built-in MinIO
minio:
  enabled: true
  defaultBuckets: "$INSTANCE_NAME-data"
  auth:
    rootUser: minioadmin
    rootPassword: minioadmin

# Enable built-in ZooKeeper
zookeeper:
  enabled: true
EOF
            ;;
    esac
    
    # Add common footer
    cat >> "$OUTPUT_FILE" << EOF

# Service account configuration
auth:
  serviceAccount:
    create: true
    name: "$INSTANCE_NAME"

# Enable smoke tests
dev:
  smokeTest:
    enabled: true
EOF

    log_success "Configuration generated successfully!"
    log_info "Output file: $OUTPUT_FILE"
    
    if [ "$INTERACTIVE" = true ]; then
        echo
        echo "=== Next Steps ==="
        echo "1. Review and customize the generated configuration"
        echo "2. Deploy using: helm install $INSTANCE_NAME ./charts/accumulo -f $OUTPUT_FILE"
        echo "3. Run tests: helm test $INSTANCE_NAME"
        echo
        echo "=== Security Note ==="
        echo "The generated instance secret is: $instance_secret"
        echo "Store this securely - you'll need it to access the Accumulo shell"
    fi
}

# Main execution
main() {
    log_info "Starting Accumulo configuration generation"
    
    validate_tools
    generate_config
    
    log_success "Configuration generation completed!"
}

# Execute main function
main "$@"