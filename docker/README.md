# Accumulo Docker Image

This directory contains the Dockerfile and scripts for building Apache Accumulo container images with Alluxio integration.

## Features

The Docker image includes:
- Apache Accumulo 4.0.0-SNAPSHOT
- Hadoop 3.3.6 client libraries
- ZooKeeper 3.8.4 client libraries
- **Alluxio 2.10.1 client (binaries + JARs)** for filesystem integration
- Java 17 (Eclipse Temurin)

**Note**: Alluxio 2.10+ is required for Java 17 compatibility. Earlier versions (2.9.x and below) only support Java 8 or 11.

### Alluxio Client Integration

The image includes the full Alluxio client installation at `/opt/alluxio/client`:
- **CLI Tool**: `/opt/alluxio/client/bin/alluxio` - Command-line interface for Alluxio filesystem operations
- **Client JARs**: `/opt/alluxio/client/*.jar` - Alluxio client libraries copied to Accumulo's classpath
- **Libraries**: `/opt/alluxio/client/lib/` - Required dependencies for the CLI tool
- **Configuration**: `/opt/alluxio/client/conf/` - Alluxio configuration files
- **Scripts**: `/opt/alluxio/client/libexec/` - Helper scripts required by the CLI (alluxio-config.sh, etc.)

This enables:
1. Accumulo to read/write data to Alluxio filesystem via the client JARs
2. Init containers to validate Alluxio connectivity using the `alluxio fs` CLI commands
3. Troubleshooting and debugging with direct Alluxio filesystem access

## Building the Image

```bash
# Build from the repository root
cd /path/to/veculo
./scripts/build-docker.sh -r accumulo -t 4.0.0-SNAPSHOT

# Or build manually
cd docker/accumulo
docker build -t accumulo/accumulo:4.0.0-SNAPSHOT .
```

## Loading into Minikube

```bash
minikube image load accumulo/accumulo:4.0.0-SNAPSHOT
```

## Environment Variables

- `ACCUMULO_HOME=/opt/accumulo`
- `HADOOP_HOME=/opt/hadoop/hadoop-3.3.6`
- `ZOOKEEPER_HOME=/opt/zookeeper`
- `ALLUXIO_HOME=/opt/alluxio/client`
- `ALLUXIO_CLIENT_HOME=/opt/alluxio/client`
- `JAVA_HOME=/opt/java/openjdk`

## Using the Alluxio Client

Inside the container:

```bash
# List Alluxio filesystem
/opt/alluxio/client/bin/alluxio fs ls /

# Check if a file exists
/opt/alluxio/client/bin/alluxio fs test -e /path/to/file

# Create directory
/opt/alluxio/client/bin/alluxio fs mkdir /path/to/dir
```

## Related Documentation

- [Helm Chart Validation](../charts/accumulo/VALIDATION.md) - Uses Alluxio CLI for initialization validation
- [Deployment Guide](../charts/accumulo/DEPLOYMENT.md) - Deployment procedures
