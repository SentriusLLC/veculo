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

# Apache Accumulo Helm Chart

This Helm chart deploys Apache Accumulo on Kubernetes with Alluxio as the distributed storage layer, replacing HDFS for cloud-native deployments.

## Features

- **Cloud-native storage**: Uses Alluxio to provide a unified view over cloud object stores (S3, GCS, Azure Blob)
- **Production-ready**: Includes anti-affinity rules, resource limits, probes, and PVCs for resiliency
- **Multiple storage backends**: Supports AWS S3, Google Cloud Storage, Azure Blob Storage, and MinIO
- **Development mode**: Local development setup with MinIO and reduced resource requirements
- **Comprehensive monitoring**: Includes Accumulo Monitor web UI and optional metrics integration
- **Flexible authentication**: Support for cloud provider authentication methods (IRSA, Workload Identity, etc.)

## Quick Start

### Prerequisites

- Kubernetes 1.19+
- Helm 3.2.0+
- StorageClass for persistent volumes (production)

### Local Development with MinIO

For local development and testing, use the development values:

```bash
# Install with MinIO for local testing
helm install accumulo-dev ./charts/accumulo -f ./charts/accumulo/values-dev.yaml

# Run smoke tests
helm test accumulo-dev
```

### Production Deployment

1. **Prepare values file for your cloud provider:**

For AWS S3:
```yaml
storage:
  provider: "s3"
  s3:
    endpoint: "https://s3.amazonaws.com"
    bucket: "your-accumulo-bucket"
    region: "us-west-2"
    accessKey: "your-access-key"
    secretKey: "your-secret-key"

auth:
  method: "serviceAccount"
  serviceAccount:
    annotations:
      eks.amazonaws.com/role-arn: "arn:aws:iam::123456789012:role/accumulo-role"
```

For Google Cloud Storage:
```yaml
storage:
  provider: "gcs"
  gcs:
    projectId: "your-project-id"
    bucket: "your-accumulo-bucket"
    keyFile: |
      {
        "type": "service_account",
        "project_id": "your-project-id",
        ...
      }

auth:
  method: "workloadIdentity"
  serviceAccount:
    annotations:
      iam.gke.io/gcp-service-account: "accumulo@your-project.iam.gserviceaccount.com"
```

2. **Deploy to production:**

```bash
helm install accumulo ./charts/accumulo -f your-production-values.yaml
```

## Configuration

### Core Settings

| Parameter | Description | Default |
|-----------|-------------|---------|
| `accumulo.instance.name` | Accumulo instance name | `accumulo` |
| `accumulo.instance.secret` | Instance secret (change in production!) | `DEFAULT_CHANGE_ME` |
| `accumulo.instance.volumes` | Accumulo volumes path | `alluxio://alluxio-master:19998/accumulo` |

### Component Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `accumulo.manager.enabled` | Enable Accumulo Manager | `true` |
| `accumulo.manager.replicaCount` | Number of Manager replicas | `1` |
| `accumulo.tserver.enabled` | Enable TabletServers | `true` |
| `accumulo.tserver.replicaCount` | Number of TabletServer replicas | `3` |
| `accumulo.monitor.enabled` | Enable Monitor web UI | `true` |
| `accumulo.gc.enabled` | Enable Garbage Collector | `true` |
| `accumulo.compactor.enabled` | Enable Compactors | `true` |

### Alluxio Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `alluxio.enabled` | Enable Alluxio deployment | `true` |
| `alluxio.master.replicaCount` | Number of Alluxio masters | `1` |
| `alluxio.worker.replicaCount` | Number of Alluxio workers | `3` |
| `alluxio.properties.alluxio.worker.memory.size` | Worker memory size | `1GB` |

### Storage Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `storage.provider` | Storage provider (s3, gcs, azure, minio) | `minio` |
| `storage.s3.bucket` | S3 bucket name | `accumulo-data` |
| `storage.s3.region` | S3 region | `us-west-2` |
| `storage.gcs.bucket` | GCS bucket name | `accumulo-data` |
| `storage.azure.container` | Azure container name | `accumulo-data` |

## Architecture

The chart deploys the following components:

### Accumulo Components
- **Manager**: Cluster coordination and metadata management
- **TabletServers**: Handle read/write operations and host tablets
- **Monitor**: Web UI for cluster monitoring and management
- **Garbage Collector**: Cleans up unused files
- **Compactors**: Background compaction of tablets

### Alluxio Components
- **Master**: Metadata management and coordination
- **Workers**: Distributed caching layer with memory and disk tiers

### Supporting Services
- **ZooKeeper**: Coordination service (embedded or external)
- **MinIO**: Object storage for development (optional)

## Storage Architecture

```
+------------------+    +------------------+    +------------------+
|   Accumulo       |    |     Alluxio      |    |  Cloud Storage   |
|   Components     |--->|   (Cache Layer)  |--->|   (S3/GCS/...)   |
+------------------+    +------------------+    +------------------+
```

Alluxio provides:
- **Unified namespace**: Single view across multiple storage systems
- **Intelligent caching**: Hot data cached in memory/SSD for performance
- **Write optimization**: Different write modes per path (WAL, tables, temp)

## Monitoring

### Web Interfaces

- **Accumulo Monitor**: `http://<monitor-service>:9995/`
- **Alluxio Master**: `http://<alluxio-master-service>:19999/`

### Prometheus Metrics (Optional)

Enable Prometheus metrics collection:

```yaml
monitoring:
  prometheus:
    enabled: true
```

## Security

### Cloud Authentication

The chart supports multiple authentication methods:

- **Service Account**: Use Kubernetes service accounts with cloud IAM
- **Access Keys**: Direct credential configuration
- **Workload Identity**: GKE Workload Identity
- **IRSA**: EKS IAM Roles for Service Accounts
- **Managed Identity**: Azure Managed Identity

### Network Security

- All inter-component communication uses Kubernetes services
- Optional Istio service mesh support
- Configurable network policies (not included in this chart)

## Troubleshooting

### Common Issues

1. **Pods stuck in Pending**: Check resource requests and node capacity
2. **Storage connection issues**: Verify cloud credentials and bucket permissions
3. **Alluxio mount failures**: Check storage provider configuration
4. **Alluxio "Invalid property key POD_IP"**: This error occurs when Alluxio configuration uses incorrect environment variable syntax. Ensure all environment variables in `alluxio-site.properties` use the `${env.VARIABLE_NAME}` format, not `${VARIABLE_NAME}`. For example, use `alluxio.master.hostname=${env.POD_IP}` instead of `alluxio.master.hostname=${POD_IP}`

### Debugging Commands

```bash
# Check Accumulo Manager logs
kubectl logs deployment/accumulo-manager

# Check Alluxio Master status
kubectl port-forward svc/accumulo-alluxio-master 19999:19999
curl http://localhost:19999/

# Run shell commands
kubectl exec -it deployment/accumulo-manager -- /opt/accumulo/bin/accumulo shell -u root
```

### Smoke Tests

Run the built-in smoke tests to validate deployment:

```bash
helm test <release-name>
```

The smoke test validates:
- All services are accessible
- Accumulo table operations work
- Alluxio integration is functional
- Monitor web interface is available

## Upgrade Guide

### From Previous Versions

1. **Backup your data**: Ensure data is safely stored in cloud object storage
2. **Update values**: Review new configuration options
3. **Perform upgrade**: `helm upgrade <release> ./charts/accumulo`

### Rolling Updates

The chart supports rolling updates for most components:
- TabletServers can be updated rolling
- Compactors support rolling updates
- Manager updates may cause brief unavailability

## Development

### Local Development Setup

1. **Install KinD**: For local Kubernetes cluster
2. **Deploy with dev values**: Use `values-dev.yaml`
3. **Access services**: Use port-forwarding for local access

```bash
# Create local cluster
kind create cluster --name accumulo-dev

# Install chart
helm install accumulo-dev ./charts/accumulo -f ./charts/accumulo/values-dev.yaml

# Port forward to access services
kubectl port-forward svc/accumulo-dev-monitor 9995:9995
kubectl port-forward svc/accumulo-dev-alluxio-master 19999:19999
```

### Contributing

1. **Test changes**: Always test with smoke tests
2. **Update documentation**: Keep README and values comments current
3. **Validate templates**: Use `helm template` and `helm lint`

## License

This chart is provided under the Apache License 2.0, same as Apache Accumulo.

## Support

For issues related to:
- **Chart configuration**: Open GitHub issues
- **Accumulo functionality**: Refer to Apache Accumulo documentation
- **Alluxio integration**: Check Alluxio documentation
- **Cloud provider setup**: Consult respective cloud provider documentation