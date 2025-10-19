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

# Accumulo Helm Chart Tests

This directory contains documentation for Helm test manifests for validating the Accumulo deployment with Alluxio integration.

The actual test manifests are located in `templates/tests/` directory.

## Available Tests

### Smoke Test (`templates/tests/smoke-test.yaml`)

The smoke test performs comprehensive validation of the Accumulo cluster with Alluxio storage.

**Test Scope**:
- Service connectivity and availability
- Accumulo table operations (CRUD)
- Alluxio filesystem integration
- Data persistence through Alluxio
- Monitor web interface

**Running the Test**:
```bash
# Run all tests
helm test <release-name>

# Run tests with timeout
helm test <release-name> --timeout 10m

# View test logs
kubectl logs <release-name>-smoke-test

# Clean up test pods
kubectl delete pod <release-name>-smoke-test
```

## Test Execution Flow

```
1. Wait for Services (init container)
   ├─ ZooKeeper ready (port 2181)
   ├─ Alluxio master ready (port 19998)
   ├─ Accumulo manager ready (port 9999)
   └─ TabletServer ready (port 9997)

2. Test Accumulo Operations (main container)
   ├─ Create test table
   ├─ Insert test data (3 rows)
   ├─ Scan and verify data
   ├─ Flush table
   └─ Compact table

3. Test Alluxio Integration
   ├─ Check Alluxio master web UI
   ├─ Verify data directories in Alluxio
   ├─ List Accumulo directories
   └─ Check Alluxio cache metrics

4. Test Monitor Interface
   └─ Access Monitor web UI (port 9995)

5. Cleanup
   └─ Delete test table
```

## Test Configuration

Tests are configured through Helm values:

```yaml
dev:
  smokeTest:
    enabled: true
    image:
      registry: docker.io
      repository: accumulo/accumulo
      tag: "4.0.0-SNAPSHOT"
```

To disable tests:
```yaml
dev:
  smokeTest:
    enabled: false
```

## Test Results

### Success Criteria

All of the following must pass:
- ✓ All services are accessible
- ✓ Test table created successfully
- ✓ 3 test rows inserted and verified
- ✓ Table operations (flush, compact) complete
- ✓ Alluxio master responds to HTTP requests
- ✓ Accumulo directories exist in Alluxio
- ✓ Monitor web interface is accessible
- ✓ Test table deleted successfully

### Common Test Failures

#### 1. Service Timeout
```
Waiting for <service>...
Error: timed out waiting for the condition
```

**Resolution**:
- Increase test timeout: `helm test --timeout 15m`
- Check pod status: `kubectl get pods`
- Verify services: `kubectl get endpoints`

#### 2. Table Creation Fails
```
FAILED: Could not create table
```

**Resolution**:
- Check manager logs: `kubectl logs deployment/<release>-manager`
- Verify ZooKeeper connectivity
- Check Alluxio mount status

#### 3. Alluxio Integration Fails
```
WARNING: Could not verify Accumulo data in Alluxio
```

**Resolution**:
- Check Alluxio master logs: `kubectl logs deployment/<release>-alluxio-master`
- Verify storage backend configuration
- Check Alluxio mount: `kubectl exec <manager-pod> -- /opt/alluxio/client/bin/alluxio fs ls /`

#### 4. Data Verification Fails
```
FAILED: Expected 3 rows, found <n>
```

**Resolution**:
- Check TabletServer logs: `kubectl logs deployment/<release>-tserver`
- Verify write operations completed
- Check for compaction issues

## Manual Testing

For manual testing outside of Helm tests:

```bash
# Access Accumulo shell
kubectl exec -it deployment/<release>-manager -- \
  /opt/accumulo/bin/accumulo shell -u root -p <password>

# Run Accumulo commands
createtable testtable
insert row1 cf1 cq1 value1
scan
deletetable -f testtable
quit

# Check Alluxio filesystem
kubectl exec deployment/<release>-manager -- \
  /opt/alluxio/client/bin/alluxio fs ls /accumulo

# Test Alluxio master
kubectl port-forward svc/<release>-alluxio-master 19999:19999
curl http://localhost:19999/

# Test Monitor
kubectl port-forward svc/<release>-monitor 9995:9995
curl http://localhost:9995/
```

## Related Documentation

- [VALIDATION.md](../VALIDATION.md) - Comprehensive validation guide
- [DEPLOYMENT.md](../DEPLOYMENT.md) - Deployment procedures
- [README.md](../README.md) - Chart overview and configuration
