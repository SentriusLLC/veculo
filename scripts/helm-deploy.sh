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

# Helm deployment helper for Apache Accumulo

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CHART_DIR="$PROJECT_DIR/charts/accumulo"

# Default values
RELEASE_NAME=""
VALUES_FILE=""
NAMESPACE="default"
ACTION="install"
TIMEOUT="15m"
WAIT=true
CREATE_NAMESPACE=false
DRY_RUN=false

# Usage function
usage() {
  cat <<EOF
Usage: $0 ACTION [OPTIONS]

Deploy Apache Accumulo using Helm

ACTIONS:
    install     Install a new release
    upgrade     Upgrade an existing release
    uninstall   Remove a release
    test        Run smoke tests
    status      Show release status

OPTIONS:
    -r, --release NAME         Release name (required for install/upgrade)
    -f, --values FILE          Values file path
    -n, --namespace NAMESPACE  Target namespace (default: default)
    -t, --timeout DURATION    Operation timeout (default: 15m)
    --create-namespace         Create namespace if it doesn't exist
    --dry-run                  Show what would be done without executing
    --no-wait                  Don't wait for deployment to complete
    -h, --help                 Show this help message

EXAMPLES:
    # Install with development values
    $0 install -r accumulo-dev -f ./charts/accumulo/values-dev.yaml

    # Install with generated configuration
    $0 install -r my-accumulo -f values-generated.yaml --create-namespace -n accumulo

    # Upgrade existing deployment
    $0 upgrade -r accumulo-prod -f production-values.yaml

    # Run tests
    $0 test -r accumulo-dev

    # Check status
    $0 status -r accumulo-dev
EOF
}

# Parse command line arguments
if [[ $# -eq 0 ]]; then
  usage
  exit 1
fi

ACTION="$1"
shift

while [[ $# -gt 0 ]]; do
  case $1 in
    -r | --release)
      RELEASE_NAME="$2"
      shift 2
      ;;
    -f | --values)
      VALUES_FILE="$2"
      shift 2
      ;;
    -n | --namespace)
      NAMESPACE="$2"
      shift 2
      ;;
    -t | --timeout)
      TIMEOUT="$2"
      shift 2
      ;;
    --create-namespace)
      CREATE_NAMESPACE=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --no-wait)
      WAIT=false
      shift
      ;;
    -h | --help)
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
NC='\033[0m'

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

# Validate environment
validate_environment() {
  log_info "Validating environment..."

  # Check Helm
  if ! command -v helm &>/dev/null; then
    log_error "Helm is required but not installed"
    exit 1
  fi

  # Check kubectl
  if ! command -v kubectl &>/dev/null; then
    log_error "kubectl is required but not installed"
    exit 1
  fi

  # Check cluster connectivity
  if ! kubectl cluster-info &>/dev/null; then
    log_error "Cannot connect to Kubernetes cluster"
    exit 1
  fi

  # Check chart exists
  if [ ! -f "$CHART_DIR/Chart.yaml" ]; then
    log_error "Helm chart not found at $CHART_DIR"
    exit 1
  fi

  log_success "Environment validation passed"
}

# Setup dependencies
setup_dependencies() {
  log_info "Setting up Helm chart dependencies..."

  # Create embedded dependencies instead of external ones
  # This avoids the network connectivity issues
  local deps_dir="$CHART_DIR/charts"
  mkdir -p "$deps_dir"

  # Create simple ZooKeeper subchart
  if [ ! -f "$deps_dir/zookeeper/Chart.yaml" ]; then
    log_info "Creating embedded ZooKeeper chart..."
    mkdir -p "$deps_dir/zookeeper/templates"

    cat >"$deps_dir/zookeeper/Chart.yaml" <<'EOF'
apiVersion: v2
name: zookeeper
description: ZooKeeper for Accumulo
version: 1.0.0
appVersion: "3.8.4"
EOF

    cat >"$deps_dir/zookeeper/values.yaml" <<'EOF'
enabled: true
replicaCount: 1
image:
  registry: docker.io
  repository: zookeeper
  tag: "3.8.4"
  pullPolicy: IfNotPresent
resources:
  requests:
    memory: 256Mi
    cpu: 250m
  limits:
    memory: 512Mi
    cpu: 500m
persistence:
  enabled: false
  size: 1Gi
EOF

    cat >"$deps_dir/zookeeper/templates/deployment.yaml" <<'EOF'
{{- if .Values.enabled }}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "accumulo.fullname" . }}-zookeeper
  labels:
    app.kubernetes.io/name: zookeeper
    app.kubernetes.io/instance: {{ .Release.Name }}
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      app.kubernetes.io/name: zookeeper
      app.kubernetes.io/instance: {{ .Release.Name }}
  template:
    metadata:
      labels:
        app.kubernetes.io/name: zookeeper
        app.kubernetes.io/instance: {{ .Release.Name }}
    spec:
      containers:
      - name: zookeeper
        image: "{{ .Values.image.registry }}/{{ .Values.image.repository }}:{{ .Values.image.tag }}"
        imagePullPolicy: {{ .Values.image.pullPolicy }}
        ports:
        - containerPort: 2181
          name: client
        - containerPort: 2888
          name: server
        - containerPort: 3888
          name: leader-election
        env:
        - name: ALLOW_ANONYMOUS_LOGIN
          value: "yes"
        resources:
          {{- toYaml .Values.resources | nindent 10 }}
        volumeMounts:
        - name: data
          mountPath: /bitnami/zookeeper
      volumes:
      - name: data
        {{- if .Values.persistence.enabled }}
        persistentVolumeClaim:
          claimName: {{ include "accumulo.fullname" . }}-zookeeper-data
        {{- else }}
        emptyDir: {}
        {{- end }}
{{- end }}
EOF

    cat >"$deps_dir/zookeeper/templates/service.yaml" <<'EOF'
{{- if .Values.enabled }}
apiVersion: v1
kind: Service
metadata:
  name: {{ include "accumulo.fullname" . }}-zookeeper
  labels:
    app.kubernetes.io/name: zookeeper
    app.kubernetes.io/instance: {{ .Release.Name }}
spec:
  type: ClusterIP
  ports:
  - port: 2181
    targetPort: client
    protocol: TCP
    name: client
  selector:
    app.kubernetes.io/name: zookeeper
    app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
EOF
  fi

  # Create simple MinIO subchart
  if [ ! -f "$deps_dir/minio/Chart.yaml" ]; then
    log_info "Creating embedded MinIO chart..."
    mkdir -p "$deps_dir/minio/templates"

    cat >"$deps_dir/minio/Chart.yaml" <<'EOF'
apiVersion: v2
name: minio
description: MinIO for Accumulo development
version: 1.0.0
appVersion: "2024.1.1"
EOF

    cat >"$deps_dir/minio/values.yaml" <<'EOF'
enabled: true
defaultBuckets: "accumulo-data"
auth:
  rootUser: minioadmin
  rootPassword: minioadmin
image:
  registry: docker.io
  repository: minio/minio
  tag: "RELEASE.2024-01-01T16-36-33Z"
  pullPolicy: IfNotPresent
resources:
  requests:
    memory: 256Mi
    cpu: 250m
persistence:
  enabled: false
  size: 10Gi
EOF

    cat >"$deps_dir/minio/templates/deployment.yaml" <<'EOF'
{{- if .Values.enabled }}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "accumulo.fullname" . }}-minio
  labels:
    app.kubernetes.io/name: minio
    app.kubernetes.io/instance: {{ .Release.Name }}
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: minio
      app.kubernetes.io/instance: {{ .Release.Name }}
  template:
    metadata:
      labels:
        app.kubernetes.io/name: minio
        app.kubernetes.io/instance: {{ .Release.Name }}
    spec:
      containers:
      - name: minio
        image: "{{ .Values.image.registry }}/{{ .Values.image.repository }}:{{ .Values.image.tag }}"
        imagePullPolicy: {{ .Values.image.pullPolicy }}
        command:
        - /bin/bash
        - -c
        - |
          mkdir -p /data/{{ .Values.defaultBuckets }}
          /usr/bin/docker-entrypoint.sh minio server /data --console-address ":9001"
        ports:
        - containerPort: 9000
          name: api
        - containerPort: 9001
          name: console
        env:
        - name: MINIO_ROOT_USER
          value: {{ .Values.auth.rootUser }}
        - name: MINIO_ROOT_PASSWORD
          value: {{ .Values.auth.rootPassword }}
        resources:
          {{- toYaml .Values.resources | nindent 10 }}
        volumeMounts:
        - name: data
          mountPath: /data
      volumes:
      - name: data
        {{- if .Values.persistence.enabled }}
        persistentVolumeClaim:
          claimName: {{ include "accumulo.fullname" . }}-minio-data
        {{- else }}
        emptyDir: {}
        {{- end }}
{{- end }}
EOF

    cat >"$deps_dir/minio/templates/service.yaml" <<'EOF'
{{- if .Values.enabled }}
apiVersion: v1
kind: Service
metadata:
  name: {{ include "accumulo.fullname" . }}-minio
  labels:
    app.kubernetes.io/name: minio
    app.kubernetes.io/instance: {{ .Release.Name }}
spec:
  type: ClusterIP
  ports:
  - port: 9000
    targetPort: api
    protocol: TCP
    name: api
  - port: 9001
    targetPort: console  
    protocol: TCP
    name: console
  selector:
    app.kubernetes.io/name: minio
    app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
EOF
  fi

  log_success "Dependencies setup complete"
}

# Execute Helm action
execute_action() {
  local cmd_args=()

  case "$ACTION" in
    install)
      if [ -z "$RELEASE_NAME" ]; then
        log_error "Release name is required for install action"
        exit 1
      fi

      cmd_args=("install" "$RELEASE_NAME" "$CHART_DIR")
      ;;
    upgrade)
      if [ -z "$RELEASE_NAME" ]; then
        log_error "Release name is required for upgrade action"
        exit 1
      fi

      cmd_args=("upgrade" "$RELEASE_NAME" "$CHART_DIR")
      ;;
    uninstall)
      if [ -z "$RELEASE_NAME" ]; then
        log_error "Release name is required for uninstall action"
        exit 1
      fi

      cmd_args=("uninstall" "$RELEASE_NAME")
      ;;
    test)
      if [ -z "$RELEASE_NAME" ]; then
        log_error "Release name is required for test action"
        exit 1
      fi

      cmd_args=("test" "$RELEASE_NAME")
      ;;
    status)
      if [ -z "$RELEASE_NAME" ]; then
        log_error "Release name is required for status action"
        exit 1
      fi

      cmd_args=("status" "$RELEASE_NAME")
      ;;
    *)
      log_error "Unknown action: $ACTION"
      exit 1
      ;;
  esac

  # Add common options
  if [ "$ACTION" = "install" ] || [ "$ACTION" = "upgrade" ]; then
    if [ -n "$VALUES_FILE" ]; then
      cmd_args+=("-f" "$VALUES_FILE")
    fi

    cmd_args+=("--timeout" "$TIMEOUT")

    if [ "$WAIT" = true ]; then
      cmd_args+=("--wait")
    fi

    if [ "$CREATE_NAMESPACE" = true ]; then
      cmd_args+=("--create-namespace")
    fi
  fi

  # Add namespace
  cmd_args+=("--namespace" "$NAMESPACE")

  # Add dry-run if requested
  if [ "$DRY_RUN" = true ]; then
    cmd_args+=("--dry-run")
  fi

  # Execute command
  log_info "Executing: helm ${cmd_args[*]}"

  if helm "${cmd_args[@]}"; then
    log_success "$ACTION completed successfully"
  else
    log_error "$ACTION failed"
    exit 1
  fi
}

# Main execution
main() {
  log_info "Starting Helm deployment for Accumulo"
  log_info "Action: $ACTION"
  log_info "Release: ${RELEASE_NAME:-N/A}"
  log_info "Namespace: $NAMESPACE"

  validate_environment

  if [ "$ACTION" = "install" ] || [ "$ACTION" = "upgrade" ]; then
    setup_dependencies
  fi

  execute_action

  log_success "Operation completed successfully!"
}

# Execute main function
main "$@"
