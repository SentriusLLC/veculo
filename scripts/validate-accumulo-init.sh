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

# Accumulo Initialization Validation Script
# This script validates that Accumulo has been properly initialized with Alluxio storage

set -euo pipefail

# Script configuration
RELEASE_NAME="${1:-accumulo-dev}"
NAMESPACE="${2:-default}"
INSTANCE_NAME="${3:-accumulo}"

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
  echo -e "${GREEN}[✓]${NC} $1"
}

log_warning() {
  echo -e "${YELLOW}[⚠]${NC} $1"
}

log_error() {
  echo -e "${RED}[✗]${NC} $1"
}

# Validation results
VALIDATION_PASSED=0
VALIDATION_FAILED=0
VALIDATION_WARNING=0

validate_check() {
  local check_name="$1"
  local status="$2"
  
  if [ "$status" = "pass" ]; then
    log_success "$check_name"
    VALIDATION_PASSED=$((VALIDATION_PASSED + 1))
  elif [ "$status" = "warn" ]; then
    log_warning "$check_name"
    VALIDATION_WARNING=$((VALIDATION_WARNING + 1))
  else
    log_error "$check_name"
    VALIDATION_FAILED=$((VALIDATION_FAILED + 1))
  fi
}

# Check kubectl connectivity
check_kubectl() {
  log_info "Checking kubectl connectivity..."
  if kubectl cluster-info &>/dev/null; then
    validate_check "Kubernetes cluster is accessible" "pass"
  else
    validate_check "Kubernetes cluster is NOT accessible" "fail"
    exit 1
  fi
}

# Check if release exists
check_release() {
  log_info "Checking if Helm release exists..."
  if helm status "$RELEASE_NAME" -n "$NAMESPACE" &>/dev/null; then
    validate_check "Helm release '$RELEASE_NAME' exists in namespace '$NAMESPACE'" "pass"
  else
    validate_check "Helm release '$RELEASE_NAME' does NOT exist in namespace '$NAMESPACE'" "fail"
    exit 1
  fi
}

# Check pod status
check_pods() {
  log_info "Checking pod status..."
  
  # Check ZooKeeper
  if kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=zookeeper -o jsonpath='{.items[*].status.phase}' | grep -q "Running"; then
    validate_check "ZooKeeper pod is running" "pass"
  else
    validate_check "ZooKeeper pod is NOT running" "fail"
  fi
  
  # Check Alluxio Master
  if kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/component=alluxio-master -o jsonpath='{.items[*].status.phase}' | grep -q "Running"; then
    validate_check "Alluxio Master pod is running" "pass"
  else
    validate_check "Alluxio Master pod is NOT running" "fail"
  fi
  
  # Check Alluxio Workers
  WORKER_COUNT=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/component=alluxio-worker -o jsonpath='{.items[*].status.phase}' | grep -o "Running" | wc -l)
  if [ "$WORKER_COUNT" -gt 0 ]; then
    validate_check "Alluxio Worker pods running: $WORKER_COUNT" "pass"
  else
    validate_check "No Alluxio Worker pods are running" "warn"
  fi
  
  # Check Accumulo Manager
  if kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/component=manager -o jsonpath='{.items[*].status.phase}' | grep -q "Running"; then
    validate_check "Accumulo Manager pod is running" "pass"
  else
    validate_check "Accumulo Manager pod is NOT running" "fail"
  fi
  
  # Check Accumulo TabletServers
  TSERVER_COUNT=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/component=tserver -o jsonpath='{.items[*].status.phase}' | grep -o "Running" | wc -l)
  if [ "$TSERVER_COUNT" -gt 0 ]; then
    validate_check "Accumulo TabletServer pods running: $TSERVER_COUNT" "pass"
  else
    validate_check "No Accumulo TabletServer pods are running" "fail"
  fi
}

# Check service endpoints
check_services() {
  log_info "Checking service endpoints..."
  
  # Check ZooKeeper service
  if kubectl get endpoints "$RELEASE_NAME-zookeeper" -n "$NAMESPACE" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null | grep -q "."; then
    validate_check "ZooKeeper service has endpoints" "pass"
  else
    validate_check "ZooKeeper service has NO endpoints" "fail"
  fi
  
  # Check Alluxio Master service
  if kubectl get endpoints "$RELEASE_NAME-alluxio-master" -n "$NAMESPACE" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null | grep -q "."; then
    validate_check "Alluxio Master service has endpoints" "pass"
  else
    validate_check "Alluxio Master service has NO endpoints" "fail"
  fi
  
  # Check Accumulo Manager service
  if kubectl get endpoints "$RELEASE_NAME-manager" -n "$NAMESPACE" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null | grep -q "."; then
    validate_check "Accumulo Manager service has endpoints" "pass"
  else
    validate_check "Accumulo Manager service has NO endpoints" "fail"
  fi
}

# Check Alluxio master accessibility
check_alluxio_master() {
  log_info "Checking Alluxio Master accessibility..."
  
  # Port-forward temporarily to check master
  kubectl port-forward -n "$NAMESPACE" "svc/$RELEASE_NAME-alluxio-master" 19999:19999 &>/dev/null &
  PF_PID=$!
  sleep 2
  
  if curl -f -s http://localhost:19999/ > /dev/null 2>&1; then
    validate_check "Alluxio Master web UI is accessible" "pass"
  else
    validate_check "Alluxio Master web UI is NOT accessible" "warn"
  fi
  
  kill $PF_PID 2>/dev/null || true
  wait $PF_PID 2>/dev/null || true
}

# Check Accumulo initialization
check_accumulo_init() {
  log_info "Checking Accumulo initialization..."
  
  # Get the manager pod name
  MANAGER_POD=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/component=manager -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  
  if [ -z "$MANAGER_POD" ]; then
    validate_check "Could not find Accumulo Manager pod" "fail"
    return
  fi
  
  # Check if instance exists in ZooKeeper
  if kubectl exec -n "$NAMESPACE" "$MANAGER_POD" -- /opt/accumulo/bin/accumulo org.apache.accumulo.server.util.ListInstances 2>/dev/null | grep -q "$INSTANCE_NAME"; then
    validate_check "Accumulo instance '$INSTANCE_NAME' exists in ZooKeeper" "pass"
  else
    validate_check "Accumulo instance '$INSTANCE_NAME' NOT found in ZooKeeper" "fail"
  fi
  
  # Check init container logs for successful initialization
  INIT_LOGS=$(kubectl logs -n "$NAMESPACE" "$MANAGER_POD" -c init-accumulo 2>/dev/null || echo "")
  if echo "$INIT_LOGS" | grep -q "Accumulo Initialization Validation Complete"; then
    validate_check "Accumulo initialization validation completed" "pass"
  elif echo "$INIT_LOGS" | grep -q "already exists"; then
    validate_check "Accumulo instance was previously initialized" "pass"
  else
    validate_check "Could not verify Accumulo initialization" "warn"
  fi
  
  # Check for any initialization errors
  if echo "$INIT_LOGS" | grep -q "ERROR"; then
    validate_check "Found errors in initialization logs" "warn"
  fi
}

# Check Alluxio filesystem integration
check_alluxio_filesystem() {
  log_info "Checking Alluxio filesystem integration..."
  
  # Get the manager pod name
  MANAGER_POD=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/component=manager -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  
  if [ -z "$MANAGER_POD" ]; then
    validate_check "Could not find Accumulo Manager pod for filesystem check" "warn"
    return
  fi
  
  # Check if Alluxio client is available
  if kubectl exec -n "$NAMESPACE" "$MANAGER_POD" -- test -d /opt/alluxio/client 2>/dev/null; then
    validate_check "Alluxio client directory exists in Manager pod" "pass"
  else
    validate_check "Alluxio client directory NOT found in Manager pod" "warn"
  fi
  
  # Try to list Alluxio filesystem
  if kubectl exec -n "$NAMESPACE" "$MANAGER_POD" -- /opt/alluxio/client/bin/alluxio fs ls / 2>/dev/null | grep -q "accumulo"; then
    validate_check "Accumulo directory found in Alluxio filesystem" "pass"
  else
    validate_check "Could not verify Accumulo directory in Alluxio filesystem" "warn"
  fi
}

# Check Accumulo tables
check_accumulo_tables() {
  log_info "Checking Accumulo tables..."
  
  # Get the manager pod name
  MANAGER_POD=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/component=manager -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  
  if [ -z "$MANAGER_POD" ]; then
    validate_check "Could not find Accumulo Manager pod for table check" "warn"
    return
  fi
  
  # Try to list tables (requires root password from values)
  # This is a basic connectivity test
  if kubectl exec -n "$NAMESPACE" "$MANAGER_POD" -- /opt/accumulo/bin/accumulo shell -u root -e "tables" 2>/dev/null | grep -q "accumulo"; then
    validate_check "Successfully connected to Accumulo and listed tables" "pass"
  else
    validate_check "Could not list Accumulo tables (may need credentials)" "warn"
  fi
}

# Print summary
print_summary() {
  echo ""
  echo "=============================================="
  echo "        Validation Summary"
  echo "=============================================="
  log_success "Passed:  $VALIDATION_PASSED"
  log_warning "Warnings: $VALIDATION_WARNING"
  log_error "Failed:  $VALIDATION_FAILED"
  echo "=============================================="
  
  if [ $VALIDATION_FAILED -eq 0 ]; then
    echo ""
    log_success "All critical validations passed!"
    if [ $VALIDATION_WARNING -gt 0 ]; then
      log_warning "There are $VALIDATION_WARNING warning(s) that should be reviewed"
    fi
    exit 0
  else
    echo ""
    log_error "$VALIDATION_FAILED critical validation(s) failed!"
    exit 1
  fi
}

# Main execution
main() {
  echo ""
  echo "=============================================="
  echo "  Accumulo Initialization Validation"
  echo "=============================================="
  echo "Release Name: $RELEASE_NAME"
  echo "Namespace:    $NAMESPACE"
  echo "Instance:     $INSTANCE_NAME"
  echo "=============================================="
  echo ""
  
  check_kubectl
  check_release
  check_pods
  check_services
  check_alluxio_master
  check_accumulo_init
  check_alluxio_filesystem
  check_accumulo_tables
  
  print_summary
}

# Run main function
main "$@"
