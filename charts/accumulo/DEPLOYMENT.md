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

# Deployment Guide

This guide provides step-by-step instructions for deploying Apache Accumulo with Alluxio on Kubernetes.

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Local Development Deployment](#local-development-deployment)
3. [Production Deployment](#production-deployment)
4. [Post-Deployment Validation](#post-deployment-validation)
5. [Common Configuration Scenarios](#common-configuration-scenarios)
6. [Troubleshooting](#troubleshooting)

## Prerequisites

### Software Requirements

- **Kubernetes**: 1.19+ (tested on 1.24+)
- **Helm**: 3.2.0+
- **kubectl**: Compatible with your cluster version

### Infrastructure Requirements

#### Development
- **CPU**: 4+ cores available to Kubernetes
- **Memory**: 8GB+ RAM available to Kubernetes  
- **Storage**: 20GB+ available storage

#### Production
- **CPU**: 20+ cores across multiple nodes
- **Memory**: 64GB+ RAM across multiple nodes
- **Storage**: Persistent volumes with high IOPS for Alluxio journal and cache
- **Network**: High bandwidth between nodes (10Gbps+ recommended)

### Cloud Prerequisites

#### AWS
- S3 bucket for data storage
- IAM role with S3 permissions (for IRSA)
- EKS cluster with CSI driver for EBS volumes

#### Google Cloud  
- GCS bucket for data storage
- Service account with Storage permissions
- GKE cluster with Workload Identity enabled

#### Azure
- Azure Blob Storage container
- Managed Identity or Service Principal
- AKS cluster with Azure Disk CSI driver

## Local Development Deployment

Perfect for development, testing, and CI/CD pipelines.

### 1. Create Local Kubernetes Cluster

Using KinD (Kubernetes in Docker):

```bash
# Install KinD
go install sigs.k8s.io/kind@latest

# Create cluster with extra ports for services
cat <<EOF | kind create cluster --name accumulo-dev --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  - containerPort: 80
    hostPort: 80
    protocol: TCP
  - containerPort: 443
    hostPort: 443
    protocol: TCP
  - containerPort: 9995
    hostPort: 9995
    protocol: TCP
EOF
```

### 2. Deploy Accumulo with MinIO

```bash
# Clone the repository
git clone https://github.com/SentriusLLC/veculo.git
cd veculo

# Deploy using development values
helm install accumulo-dev ./charts/accumulo \
  -f ./charts/accumulo/values-dev.yaml \
  --timeout 15m \
  --wait

# Wait for all pods to be ready
kubectl wait --for=condition=Ready pod --all --timeout=600s
```

### 3. Validate Initialization

Before running tests, validate that Accumulo initialized correctly with Alluxio:

```bash
# Run the validation script
./scripts/validate-accumulo-init.sh accumulo-dev default

# Or use the Makefile target
make validate-init RELEASE_NAME=accumulo-dev
```

The validation script checks:
- All pods are running (ZooKeeper, Alluxio, Accumulo components)
- Services have endpoints
- Alluxio Master is accessible
- Accumulo instance is properly initialized in ZooKeeper
- Accumulo data directories exist in Alluxio filesystem
- Alluxio client libraries are available

### 4. Run Smoke Tests

```bash
# Run the built-in smoke tests
helm test accumulo-dev

# Check test results
kubectl logs accumulo-dev-smoke-test
```

The smoke tests validate:
- All services are accessible (ZooKeeper, Alluxio, Accumulo)
- Accumulo table operations work correctly
- Data can be written and read from Alluxio
- Alluxio filesystem integration is functional
- Monitor web interface is available

### 5. Access Services

```bash
# Access Accumulo Monitor (web UI)
kubectl port-forward svc/accumulo-dev-monitor 9995:9995 &
echo "Accumulo Monitor: http://localhost:9995"

# Access Alluxio Master UI
kubectl port-forward svc/accumulo-dev-alluxio-master 19999:19999 &
echo "Alluxio Master: http://localhost:19999"

# Access MinIO Console
kubectl port-forward svc/accumulo-dev-minio 9001:9001 &
echo "MinIO Console: http://localhost:9001 (minioadmin/minioadmin)"
```

### 6. Connect with Accumulo Shell

```bash
# Get a shell into the manager pod
kubectl exec -it deployment/accumulo-dev-manager -- /opt/accumulo/bin/accumulo shell -u root -p dev-secret-change-me
```

## Production Deployment

### 1. Prepare Cloud Resources

#### AWS Setup

```bash
# Create S3 bucket
aws s3 mb s3://your-company-accumulo-prod --region us-west-2

# Create IAM role for IRSA
cat <<EOF > trust-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::ACCOUNT:oidc-provider/oidc.eks.REGION.amazonaws.com/id/OIDC_ID"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "oidc.eks.REGION.amazonaws.com/id/OIDC_ID:sub": "system:serviceaccount:default:accumulo-prod"
        }
      }
    }
  ]
}
EOF

aws iam create-role --role-name AccumuloProdRole --assume-role-policy-document file://trust-policy.json

# Attach S3 permissions
aws iam put-role-policy --role-name AccumuloProdRole --policy-name S3Access --policy-document '{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject", 
        "s3:DeleteObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::your-company-accumulo-prod",
        "arn:aws:s3:::your-company-accumulo-prod/*"
      ]
    }
  ]
}'
```

#### GCP Setup

```bash
# Create GCS bucket
gsutil mb gs://your-company-accumulo-prod

# Create service account
gcloud iam service-accounts create accumulo-prod

# Grant storage permissions
gcloud projects add-iam-policy-binding PROJECT_ID \
  --member="serviceAccount:accumulo-prod@PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/storage.admin"

# Enable Workload Identity
gcloud iam service-accounts add-iam-policy-binding \
  --role roles/iam.workloadIdentityUser \
  --member "serviceAccount:PROJECT_ID.svc.id.goog[default/accumulo-prod]" \
  accumulo-prod@PROJECT_ID.iam.gserviceaccount.com
```

### 2. Prepare Production Values

Create your production values file based on the examples:

```bash
# Copy and modify production values
cp ./charts/accumulo/values-production-aws.yaml my-production-values.yaml

# Edit the values file
vim my-production-values.yaml
```

Key settings to customize:
- `accumulo.instance.secret`: Use a strong secret
- `storage.s3.bucket`: Your S3 bucket name
- `auth.serviceAccount.annotations`: Your IAM role ARN
- `zookeeper.external.hosts`: Your ZooKeeper cluster
- Resource requests/limits based on your workload

### 3. Deploy to Production

```bash
# Create namespace (optional)
kubectl create namespace accumulo-prod

# Deploy with production values
helm install accumulo-prod ./charts/accumulo \
  -f my-production-values.yaml \
  --namespace accumulo-prod \
  --timeout 20m \
  --wait

# Verify deployment
kubectl get pods -n accumulo-prod
kubectl get services -n accumulo-prod
```

### 4. Configure External Access

```bash
# Get LoadBalancer external IP (if using LoadBalancer service type)
kubectl get svc accumulo-prod-monitor -n accumulo-prod

# Or use Ingress for HTTPS termination
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: accumulo-monitor
  namespace: accumulo-prod
  annotations:
    kubernetes.io/ingress.class: nginx
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  tls:
  - hosts:
    - accumulo.your-domain.com
    secretName: accumulo-tls
  rules:
  - host: accumulo.your-domain.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: accumulo-prod-monitor
            port:
              number: 9995
EOF
```

## Post-Deployment Validation

### 1. Health Checks

```bash
# Check all pods are running
kubectl get pods -l app.kubernetes.io/name=accumulo

# Check service endpoints
kubectl get endpoints

# Check persistent volumes
kubectl get pv,pvc
```

### 2. Functional Testing

```bash
# Run smoke tests (if enabled)
helm test accumulo-prod

# Manual validation - create test table
kubectl exec -it deployment/accumulo-prod-manager -- /opt/accumulo/bin/accumulo shell -u root -p YOUR_SECRET << 'EOF'
createtable test
insert row1 cf1 cq1 value1
scan
deletetable -f test
quit
EOF
```

### 3. Performance Validation

```bash
# Check Alluxio cache utilization
kubectl port-forward svc/accumulo-prod-alluxio-master 19999:19999 &
curl http://localhost:19999/metrics

# Monitor resource usage
kubectl top pods -l app.kubernetes.io/name=accumulo
```

## Common Configuration Scenarios

### Scenario 1: Multi-Region Deployment

For disaster recovery across regions:

```yaml
# values-multi-region.yaml
accumulo:
  tserver:
    replicaCount: 9  # 3 per region
    podAntiAffinity:
      enabled: true
      topologyKey: topology.kubernetes.io/region

storage:
  s3:
    # Use S3 Cross-Region Replication
    bucket: "accumulo-prod-primary"
```

### Scenario 2: Heavy Compaction Workload

For write-heavy workloads requiring aggressive compaction:

```yaml
accumulo:
  compactor:
    replicaCount: 8
    resources:
      requests:
        memory: "4Gi"
        cpu: "2000m"
      limits:
        memory: "8Gi"
        cpu: "4000m"

alluxio:
  pathWriteModes:
    "/accumulo/tables": "ASYNC_THROUGH"  # Faster writes for compaction
```

### Scenario 3: Analytics Workload

For read-heavy analytical workloads:

```yaml
alluxio:
  worker:
    replicaCount: 12  # More workers for caching
    resources:
      memory: "16Gi"  # Larger cache
    storage:
      size: "1Ti"     # Larger local cache

  properties:
    alluxio.worker.memory.size: "8GB"
    # Optimize for read performance
    alluxio.user.file.read.type.default: "CACHE"
```

## Troubleshooting

### Common Issues

#### 1. Pods Stuck in Pending

```bash
# Check node resources
kubectl describe nodes

# Check pod events
kubectl describe pod POD_NAME

# Common causes:
# - Insufficient CPU/memory on nodes
# - PVC not bound (check StorageClass)
# - Image pull failures
```

#### 2. Alluxio Mount Issues

```bash
# Check Alluxio master logs
kubectl logs deployment/accumulo-prod-alluxio-master

# Check storage credentials
kubectl get secret accumulo-prod-secret -o yaml

# Test storage connectivity
kubectl run -it --rm debug --image=amazonlinux:2 --restart=Never -- bash
# Inside pod: test S3 access with AWS CLI
```

#### 3. Accumulo Initialization Failures

```bash
# Check manager initialization logs
kubectl logs deployment/accumulo-prod-manager -c init-accumulo

# Common causes:
# - ZooKeeper not accessible
# - Alluxio not ready
# - Incorrect instance secret
# - Volume mount issues
```

#### 4. Performance Issues

```bash
# Check resource utilization
kubectl top nodes
kubectl top pods

# Check Accumulo tablet distribution
kubectl exec deployment/accumulo-prod-manager -- /opt/accumulo/bin/accumulo shell -u root -e "tables -l"

# Check Alluxio cache hit rates
curl http://ALLUXIO_MASTER:19999/metrics | grep cache
```

### Debugging Commands

```bash
# Get comprehensive cluster state
kubectl get all -l app.kubernetes.io/name=accumulo

# Check configuration
kubectl get configmap accumulo-prod-config -o yaml
kubectl get configmap accumulo-prod-alluxio-config -o yaml

# Check logs for all components
kubectl logs -l app.kubernetes.io/component=manager
kubectl logs -l app.kubernetes.io/component=tserver
kubectl logs -l app.kubernetes.io/component=alluxio-master
kubectl logs -l app.kubernetes.io/component=alluxio-worker

# Network connectivity tests
kubectl run -it --rm netdebug --image=nicolaka/netshoot --restart=Never -- bash
```

### Recovery Procedures

#### Rolling Restart

```bash
# Restart all components in order
kubectl rollout restart deployment/accumulo-prod-manager
kubectl rollout restart deployment/accumulo-prod-tserver  
kubectl rollout restart deployment/accumulo-prod-compactor
kubectl rollout restart deployment/accumulo-prod-gc
kubectl rollout restart deployment/accumulo-prod-monitor
```

#### Emergency Recovery

```bash
# If cluster is unresponsive, scale down non-essential components
kubectl scale deployment accumulo-prod-compactor --replicas=0
kubectl scale deployment accumulo-prod-gc --replicas=0
kubectl scale deployment accumulo-prod-monitor --replicas=0

# Focus on core components
kubectl logs deployment/accumulo-prod-manager
kubectl logs deployment/accumulo-prod-tserver

# Once stable, scale back up
kubectl scale deployment accumulo-prod-compactor --replicas=4
kubectl scale deployment accumulo-prod-gc --replicas=1  
kubectl scale deployment accumulo-prod-monitor --replicas=1
```

For additional support, consult:
- [Accumulo Documentation](https://accumulo.apache.org/docs/)
- [Alluxio Documentation](https://docs.alluxio.io/)
- [Kubernetes Troubleshooting](https://kubernetes.io/docs/tasks/debug-application-cluster/)