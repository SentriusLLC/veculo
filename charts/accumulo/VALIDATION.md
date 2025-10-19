<!--
Licensed to the Apache Software Foundation (ASF) under one
or more contributor license agreements.  See the NOTICE file
distributed with this work for additional information
regarding copyright ownership.  The ASF licenses this file
to you under the Apache License, Version 2.0 (the
"License"); you may not use this file except in compliance
with the License.  You may obtain a copy of the License at

  https://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing,
software distributed under the License is distributed on an
"AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
KIND, either express or implied.  See the License for the
specific language governing permissions and limitations
under the License.
-->

# Accumulo Initialization Validation

This document describes the validation mechanisms implemented to ensure Apache Accumulo initializes correctly with Alluxio storage in Kubernetes.

## Overview

The Accumulo Helm chart includes comprehensive validation to ensure:

1. **Alluxio is operational** before Accumulo initialization begins
2. **Alluxio filesystem is accessible** and writable
3. **Accumulo instance is properly initialized** in ZooKeeper
4. **Data directories are created** in Alluxio
5. **Integration between Accumulo and Alluxio** works correctly

## Prerequisites

The validation mechanisms require:

- **Docker Image**: Accumulo image must include the Alluxio client binaries at `/opt/alluxio/client/bin/alluxio`
  - The official image includes Alluxio 2.9.4 client with full CLI support
  - See [Docker README](../../../docker/README.md) for details on the Alluxio client installation
- **Kubernetes**: Version 1.19+ with proper network connectivity between pods
- **Helm**: Version 3.2.0+ for deploying the chart

## Validation Layers

### 1. Init Container Validation

The `init-accumulo` container in the manager deployment performs pre-initialization checks:

**Location**: `charts/accumulo/templates/accumulo-manager-deployment.yaml`

**Checks Performed**:
- ✓ Alluxio Master web UI is accessible (HTTP GET to port 19999)
- ✓ Alluxio filesystem is accessible (required - fails if not accessible)
- ✓ Accumulo instance doesn't already exist (idempotent check)
- ✓ If instance exists: instance_id file must be present in Alluxio (critical check - fails if missing)
- ✓ Write permissions to Alluxio filesystem
- ✓ Accumulo initialization completes successfully
- ✓ instance_id file is created in Alluxio (critical check - fails if missing)

**Example Output (New Installation)**:
```
=== Accumulo Initialization Validation ===
Validating Alluxio connectivity...
✓ Alluxio master web UI is accessible
Validating Alluxio filesystem accessibility...
Alluxio root path: alluxio://accumulo-alluxio-master:19998/accumulo
✓ Alluxio filesystem is accessible
Checking if Accumulo instance already exists...
Initializing new Accumulo instance 'accumulo'...
Creating Accumulo directory structure in Alluxio...
Running accumulo init...
✓ Accumulo initialization completed successfully
Verifying Accumulo instance_id file in Alluxio...
✓ Accumulo instance_id file successfully created in Alluxio
=== Accumulo Initialization Validation Complete ===
```

**Example Output (Existing Installation)**:
```
=== Accumulo Initialization Validation ===
Validating Alluxio connectivity...
✓ Alluxio master web UI is accessible
Validating Alluxio filesystem accessibility...
Alluxio root path: alluxio://accumulo-alluxio-master:19998/accumulo
✓ Alluxio filesystem is accessible
Checking if Accumulo instance already exists...
✓ Accumulo instance 'accumulo' already exists in ZooKeeper
Verifying instance_id file exists in Alluxio...
✓ Accumulo instance_id file found in Alluxio at alluxio://accumulo-alluxio-master:19998/accumulo/instance_id
```

### 2. Helm Smoke Tests

The Helm smoke test validates the deployed system end-to-end.

**Location**: `charts/accumulo/templates/tests/smoke-test.yaml`

**Tests Performed**:
- Service availability (ZooKeeper, Alluxio, Accumulo components)
- Accumulo table operations (create, insert, scan, delete)
- Alluxio filesystem integration
- Alluxio cache statistics
- Monitor web interface accessibility

**Running the Test**:
```bash
helm test <release-name>
kubectl logs <release-name>-smoke-test
```

### 3. Standalone Validation Script

A comprehensive validation script for manual or automated testing.

**Location**: `scripts/validate-accumulo-init.sh`

**Usage**:
```bash
./scripts/validate-accumulo-init.sh <release-name> <namespace> <instance-name>

# Or using Make
make validate-init RELEASE_NAME=accumulo-dev NAMESPACE=default
```

**Validation Categories**:

| Category | Checks |
|----------|--------|
| **Environment** | kubectl connectivity, Helm release exists |
| **Pod Status** | All pods running (ZooKeeper, Alluxio, Accumulo) |
| **Services** | All services have endpoints |
| **Alluxio** | Master accessible, filesystem responding |
| **Accumulo Init** | Instance in ZooKeeper, init logs successful |
| **Integration** | Alluxio client available, data directories exist |
| **Functionality** | Table operations work |

**Example Output**:
```
==============================================
  Accumulo Initialization Validation
==============================================
Release Name: accumulo-dev
Namespace:    default
Instance:     accumulo
==============================================

[INFO] Checking kubectl connectivity...
[✓] Kubernetes cluster is accessible
[INFO] Checking if Helm release exists...
[✓] Helm release 'accumulo-dev' exists in namespace 'default'
[INFO] Checking pod status...
[✓] ZooKeeper pod is running
[✓] Alluxio Master pod is running
[✓] Alluxio Worker pods running: 3
[✓] Accumulo Manager pod is running
[✓] Accumulo TabletServer pods running: 3
[INFO] Checking service endpoints...
[✓] ZooKeeper service has endpoints
[✓] Alluxio Master service has endpoints
[✓] Accumulo Manager service has endpoints
[INFO] Checking Alluxio Master accessibility...
[✓] Alluxio Master web UI is accessible
[INFO] Checking Accumulo initialization...
[✓] Accumulo instance 'accumulo' exists in ZooKeeper
[✓] Accumulo initialization validation completed
[INFO] Checking Alluxio filesystem integration...
[✓] Alluxio client directory exists in Manager pod
[✓] Accumulo directory found in Alluxio filesystem

==============================================
        Validation Summary
==============================================
[✓] Passed:  14
[⚠] Warnings: 0
[✗] Failed:  0
==============================================

[✓] All critical validations passed!
```

## Validation Flow

```
┌─────────────────────────────────────────────┐
│         Helm Install/Upgrade                │
└──────────────┬──────────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────────┐
│  Wait for ZooKeeper (initContainer)         │
│  ✓ TCP connectivity to ZooKeeper:2181       │
└──────────────┬──────────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────────┐
│  Wait for Alluxio Master (initContainer)    │
│  ✓ TCP connectivity to Alluxio:19998        │
└──────────────┬──────────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────────┐
│  Validate Alluxio (init-accumulo)           │
│  ✓ HTTP GET Alluxio master:19999/           │
│  ✓ Alluxio filesystem ls /                  │
│  ✓ Create test directory in Alluxio         │
└──────────────┬──────────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────────┐
│  Initialize Accumulo (init-accumulo)        │
│  ✓ Check if instance exists                 │
│  ✓ Run accumulo init if needed              │
│  ✓ Verify instance_id in Alluxio            │
└──────────────┬──────────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────────┐
│  Start Accumulo Manager                     │
│  • Connects to ZooKeeper                    │
│  • Connects to Alluxio via alluxio://       │
│  • Manages tablet servers                   │
└──────────────┬──────────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────────┐
│  Validation Script (Optional)               │
│  • Comprehensive system check               │
│  • Reports pass/fail/warning status         │
└──────────────┬──────────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────────┐
│  Helm Smoke Test (helm test)                │
│  • End-to-end functionality test            │
│  • Create/read/delete tables                │
│  • Verify data in Alluxio                   │
└─────────────────────────────────────────────┘
```

## Troubleshooting

### Init Container Fails

**Check init container logs**:
```bash
kubectl logs <manager-pod> -c init-accumulo
```

**Common issues**:
- **Alluxio filesystem not accessible**: Initialization will fail immediately. Ensure Alluxio is fully started and accessible.
- **Instance exists but instance_id file missing**: Critical error indicating corrupted state. See detailed resolution below.
- **ZooKeeper not accessible**: Check ZooKeeper pod and service
- **Permissions issues**: Verify service account has proper RBAC permissions
- **Storage backend not configured**: Check Alluxio mount configuration

#### Critical Error: Instance exists in ZooKeeper but instance_id file not found in Alluxio

This error occurs when Accumulo is registered in ZooKeeper but the critical `instance_id` file is missing from Alluxio:

```bash
✗ ERROR: Instance exists in ZooKeeper but instance_id file not found in Alluxio
Expected file: alluxio://accumulo-alluxio-master:19998/accumulo/instance_id
This indicates a corrupted or incomplete Accumulo installation
```

**Root Causes**:
1. Alluxio storage backend was cleared/reset while ZooKeeper data remained
2. Alluxio mount configuration changed after Accumulo was initialized  
3. Storage backend credentials or permissions changed
4. Different storage backend is being used than during initialization
5. Previous incomplete initialization

**Resolution Steps**:

```bash
# Step 1: Verify current state
kubectl exec deployment/accumulo-manager -c manager -- \
  /opt/accumulo/bin/accumulo org.apache.accumulo.server.util.ListInstances

kubectl exec deployment/accumulo-manager -- \
  /opt/alluxio/client/bin/alluxio fs ls alluxio://accumulo-alluxio-master:19998/accumulo

# Step 2: Choose resolution approach

# Option A: Clean reinstall (DESTROYS ALL DATA)
kubectl delete pvc -l app.kubernetes.io/name=zookeeper
kubectl delete pvc -l app.kubernetes.io/name=minio  # if using MinIO
helm uninstall accumulo
helm install accumulo ./charts/accumulo -f values.yaml

# Option B: Fix Alluxio mount (if storage backend exists but mount is wrong)
# Update values.yaml with correct storage configuration
helm upgrade accumulo ./charts/accumulo -f corrected-values.yaml
kubectl delete pod -l app.kubernetes.io/component=alluxio-master
kubectl delete pod -l app.kubernetes.io/component=manager

# Option C: Restore from backup
# Restore instance_id and other Accumulo files to Alluxio storage backend
```

### Smoke Test Fails

**Check test logs**:
```bash
kubectl logs <release-name>-smoke-test
```

**Common issues**:
- Services not ready: Wait longer for all pods to be Running
- Authentication failures: Verify instance secret is correct
- Alluxio mount failures: Check storage backend configuration
- Network policies: Ensure pods can communicate

### Validation Script Warnings

**Review specific warnings**:
- Warnings typically indicate non-critical issues
- Check if reduced functionality is acceptable
- Some checks may fail in restricted environments

## Best Practices

1. **Always run validation** after deployment:
   ```bash
   make validate-init RELEASE_NAME=<release>
   ```

2. **Check init logs** if there are issues:
   ```bash
   kubectl logs <manager-pod> -c init-accumulo
   ```

3. **Run smoke tests** to verify functionality:
   ```bash
   helm test <release-name>
   ```

4. **Monitor Alluxio** cache hit rates:
   ```bash
   kubectl port-forward svc/<release>-alluxio-master 19999:19999
   curl http://localhost:19999/metrics
   ```

5. **Validate before upgrades**:
   - Run validation script before upgrading
   - Back up ZooKeeper data
   - Verify Alluxio storage is accessible

## Integration with CI/CD

### GitHub Actions Example

```yaml
- name: Deploy Accumulo
  run: |
    make deploy-dev

- name: Validate Initialization
  run: |
    make validate-init RELEASE_NAME=accumulo-dev
    
- name: Run Smoke Tests
  run: |
    make test RELEASE_NAME=accumulo-dev
```

### GitLab CI Example

```yaml
test:
  script:
    - make deploy-dev
    - make validate-init RELEASE_NAME=accumulo-dev
    - make test RELEASE_NAME=accumulo-dev
  artifacts:
    when: on_failure
    paths:
      - validation-results.log
```

## Additional Resources

- [Deployment Guide](DEPLOYMENT.md)
- [README](README.md)
- [Apache Accumulo Documentation](https://accumulo.apache.org/docs/)
- [Alluxio Documentation](https://docs.alluxio.io/)
