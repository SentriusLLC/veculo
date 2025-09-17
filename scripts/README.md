# Accumulo Deployment Scripts

This directory contains helper scripts for building, configuring, and deploying Apache Accumulo with Alluxio on Kubernetes.

## Scripts Overview

### `build-docker.sh`
Builds Docker images for Apache Accumulo from the source code in this repository.

**Usage:**
```bash
# Build for local use
./scripts/build-docker.sh

# Build and push to registry
./scripts/build-docker.sh -r myregistry.com/accumulo -t latest -p

# Build for multiple platforms
./scripts/build-docker.sh --platform linux/amd64,linux/arm64
```

**Prerequisites:**
- Docker installed and running
- Maven (for building Accumulo distribution)
- Source code built: `mvn clean package -DskipTests`

### `generate-secrets.sh`
Generates secure configuration values and secrets for Helm deployment.

**Usage:**
```bash
# Interactive mode (recommended)
./scripts/generate-secrets.sh -o my-values.yaml

# Non-interactive with defaults
./scripts/generate-secrets.sh --non-interactive -i prod-accumulo -o prod-values.yaml

# For specific namespace
./scripts/generate-secrets.sh -n accumulo-prod -o prod-values.yaml
```

**Features:**
- Generates cryptographically secure instance secrets
- Interactive configuration for different cloud providers
- Support for AWS S3, GCS, Azure Blob Storage, and MinIO
- Configures authentication methods (IRSA, Workload Identity, etc.)

### `helm-deploy.sh`
Comprehensive Helm deployment helper with dependency management.

**Usage:**
```bash
# Install with development values
./scripts/helm-deploy.sh install -r accumulo-dev -f ./charts/accumulo/values-dev.yaml

# Install with generated configuration
./scripts/helm-deploy.sh install -r my-accumulo -f values-generated.yaml --create-namespace -n accumulo

# Upgrade existing deployment
./scripts/helm-deploy.sh upgrade -r accumulo-prod -f production-values.yaml

# Run tests
./scripts/helm-deploy.sh test -r accumulo-dev

# Check status
./scripts/helm-deploy.sh status -r accumulo-dev
```

**Features:**
- Automatic dependency management (creates embedded ZooKeeper and MinIO charts)
- Validation of environment and prerequisites
- Support for all Helm operations (install, upgrade, uninstall, test, status)
- Comprehensive error handling and logging

## Quick Start Workflow

### 1. Development Setup
```bash
# Generate development configuration
./scripts/generate-secrets.sh -o values-dev-generated.yaml --non-interactive

# Deploy to local Kubernetes cluster
./scripts/helm-deploy.sh install -r accumulo-dev -f values-dev-generated.yaml --create-namespace -n accumulo-dev

# Run smoke tests
./scripts/helm-deploy.sh test -r accumulo-dev -n accumulo-dev
```

### 2. Production Setup
```bash
# Generate production configuration interactively
./scripts/generate-secrets.sh -o values-production.yaml -i accumulo-prod

# Review and customize the generated configuration
vim values-production.yaml

# Build and push custom images (optional)
./scripts/build-docker.sh -r your-registry.com/accumulo -t v1.0.0 -p

# Deploy to production
./scripts/helm-deploy.sh install -r accumulo-prod -f values-production.yaml --create-namespace -n accumulo-prod
```

### 3. Building Custom Images

If you want to use custom Accumulo images built from this repository:

```bash
# Build the Accumulo distribution first
mvn clean package -DskipTests -pl assemble -am

# Build Docker image
./scripts/build-docker.sh -r your-registry.com/accumulo -t 4.0.0-SNAPSHOT

# Push to registry
./scripts/build-docker.sh -r your-registry.com/accumulo -t 4.0.0-SNAPSHOT -p

# Update values file to use custom image
# Set accumulo.image.registry to "your-registry.com"
```

## Troubleshooting

### Common Issues

1. **Helm dependency errors**
   - The `helm-deploy.sh` script automatically creates embedded dependencies
   - No need to run `helm dependency build` manually

2. **Image pull errors**
   - If using custom images, ensure they are built and pushed to a registry accessible by your cluster
   - Check image registry and tag configuration in values file

3. **Permission errors**
   - Ensure scripts have execute permissions: `chmod +x scripts/*.sh`
   - Check Kubernetes RBAC permissions for the service account

4. **Network connectivity**
   - For development, ensure MinIO and ZooKeeper are accessible within the cluster
   - For production, verify cloud storage and authentication configuration

### Debug Commands

```bash
# Check Helm deployment status
./scripts/helm-deploy.sh status -r your-release -n your-namespace

# Run tests to validate deployment
./scripts/helm-deploy.sh test -r your-release -n your-namespace

# Check pod logs
kubectl logs -l app.kubernetes.io/name=accumulo -n your-namespace

# Access Accumulo shell
kubectl exec -it deployment/your-release-manager -n your-namespace -- /opt/accumulo/bin/accumulo shell -u root
```

## Environment Variables

Scripts support the following environment variables:

- `DOCKER_REGISTRY`: Default registry for Docker images
- `DOCKER_TAG`: Default tag for Docker images
- `KUBECONFIG`: Path to Kubernetes configuration file

## Security Notes

- **Instance Secrets**: The `generate-secrets.sh` script creates cryptographically secure secrets. Store these safely.
- **Cloud Credentials**: Use cloud-native authentication methods (IRSA, Workload Identity) instead of access keys when possible.
- **Container Images**: Consider using signed images and admission controllers in production.

## Contributing

When adding new scripts:
1. Follow the existing error handling and logging patterns
2. Add comprehensive help text and examples
3. Include validation for prerequisites
4. Test with both interactive and non-interactive modes
5. Update this README with usage information