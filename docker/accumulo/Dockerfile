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

# Apache Accumulo Docker Image
# Based on the official Accumulo distribution

FROM eclipse-temurin:17-jre-jammy

# Set environment variables
ENV ACCUMULO_VERSION=4.0.0-SNAPSHOT
ENV HADOOP_VERSION=3.3.6  
ENV ZOOKEEPER_VERSION=3.8.4
ENV ACCUMULO_HOME=/opt/accumulo
ENV HADOOP_HOME=/opt/hadoop/hadoop-${HADOOP_VERSION}
ENV ZOOKEEPER_HOME=/opt/zookeeper
ENV JAVA_HOME=/opt/java/openjdk
ENV ALLUXIO_CLIENT_HOME=/opt/alluxio/client
ENV ALLUXIO_HOME=/opt/alluxio/client


# Install required packages
RUN apt-get update && \
    apt-get install -y \
    curl \
    wget \
    netcat \
    procps \
    bash \
    gettext-base \
    && rm -rf /var/lib/apt/lists/*

# Create accumulo user
RUN groupadd -r accumulo && \
    useradd -r -g accumulo -d $ACCUMULO_HOME -s /bin/bash accumulo

# Create directories
RUN mkdir -p $ACCUMULO_HOME $HADOOP_HOME $ZOOKEEPER_HOME && \
    chown -R accumulo:accumulo $ACCUMULO_HOME $HADOOP_HOME $ZOOKEEPER_HOME

# Download and install Hadoop (client libraries only)

# Download and install Hadoop (client libraries only)
RUN wget -q https://archive.apache.org/dist/hadoop/common/hadoop-${HADOOP_VERSION}/hadoop-${HADOOP_VERSION}.tar.gz && \
    tar -xzf hadoop-${HADOOP_VERSION}.tar.gz -C /opt/hadoop && \
    rm hadoop-${HADOOP_VERSION}.tar.gz && \
    chown -R accumulo:accumulo /opt/hadoop


# Download and install ZooKeeper (client libraries only)
RUN set -eux; \
    cd /opt; \
    wget -q https://archive.apache.org/dist/zookeeper/zookeeper-${ZOOKEEPER_VERSION}/apache-zookeeper-${ZOOKEEPER_VERSION}-bin.tar.gz; \
    tar -xzf apache-zookeeper-${ZOOKEEPER_VERSION}-bin.tar.gz; \
    mkdir -p ${ZOOKEEPER_HOME}; \
    cp -r apache-zookeeper-${ZOOKEEPER_VERSION}-bin/* ${ZOOKEEPER_HOME}/; \
    rm -rf apache-zookeeper-${ZOOKEEPER_VERSION}-bin apache-zookeeper-${ZOOKEEPER_VERSION}-bin.tar.gz; \
    test -d ${ZOOKEEPER_HOME}/lib || (echo "ERROR: ZooKeeper lib directory still missing" && ls -R ${ZOOKEEPER_HOME} && exit 1); \
    chown -R accumulo:accumulo ${ZOOKEEPER_HOME}; \
    echo "✅ ZooKeeper installed at ${ZOOKEEPER_HOME} with lib populated"

# Download and install Alluxio client (binaries + JARs)
# Using 2.10+ for Java 17 support (Accumulo 4.x requires Java 17)
ENV ALLUXIO_VERSION=2.10.1
RUN set -eux; \
    mkdir -p /opt/alluxio/client; \
    wget -q https://downloads.alluxio.io/downloads/files/${ALLUXIO_VERSION}/alluxio-${ALLUXIO_VERSION}-bin.tar.gz; \
    tar -xzf alluxio-${ALLUXIO_VERSION}-bin.tar.gz -C /opt; \
    mv /opt/alluxio-${ALLUXIO_VERSION} /opt/alluxio-full; \
    # Copy client JARs for Accumulo integration \
    if [ -d /opt/alluxio-full/client/alluxio-*-client.jar ]; then \
        cp /opt/alluxio-full/client/alluxio-*-client.jar /opt/alluxio/client/; \
    fi; \
    # Copy all client JARs from client directory \
    if [ -d /opt/alluxio-full/client ] && [ "$(ls -A /opt/alluxio-full/client/*.jar 2>/dev/null)" ]; then \
        cp /opt/alluxio-full/client/*.jar /opt/alluxio/client/ 2>/dev/null || true; \
    fi; \
    # Copy necessary directories for CLI to work \
    mkdir -p /opt/alluxio/client/bin /opt/alluxio/client/lib /opt/alluxio/client/conf /opt/alluxio/client/libexec; \
    cp /opt/alluxio-full/bin/alluxio /opt/alluxio/client/bin/; \
    cp -r /opt/alluxio-full/lib/* /opt/alluxio/client/lib/ 2>/dev/null || true; \
    cp -r /opt/alluxio-full/conf/* /opt/alluxio/client/conf/ 2>/dev/null || true; \
    cp -r /opt/alluxio-full/libexec/* /opt/alluxio/client/libexec/ 2>/dev/null || true; \
    # Clean up full installation, keep only client \
    rm -rf /opt/alluxio-full alluxio-${ALLUXIO_VERSION}-bin.tar.gz; \
    # Verify the CLI exists and required files \
    test -f /opt/alluxio/client/bin/alluxio || (echo "ERROR: Alluxio CLI not found" && exit 1); \
    test -f /opt/alluxio/client/libexec/alluxio-config.sh || (echo "ERROR: alluxio-config.sh not found" && exit 1); \
    chown -R accumulo:accumulo /opt/alluxio; \
    echo "✅ Alluxio client (binaries + JARs) installed at /opt/alluxio/client"

# Add missing XML parser dependencies for Alluxio client
RUN curl -L -o /opt/alluxio/client/woodstox-core-6.4.0.jar https://repo1.maven.org/maven2/com/fasterxml/woodstox/woodstox-core/6.4.0/woodstox-core-6.4.0.jar && \
    curl -L -o /opt/alluxio/client/stax2-api-4.2.1.jar https://repo1.maven.org/maven2/org/codehaus/woodstox/stax2-api/4.2.1/stax2-api-4.2.1.jar && \
    chown -R accumulo:accumulo /opt/alluxio
RUN wget -q https://repo1.maven.org/maven2/commons-collections/commons-collections/3.2.2/commons-collections-3.2.2.jar \
    -O /opt/alluxio/client/commons-collections-3.2.2.jar


# Copy Accumulo distribution (built from source)
COPY --chown=accumulo:accumulo dist/ $ACCUMULO_HOME/

# Ensure Accumulo lib directory exists
RUN mkdir -p $ACCUMULO_HOME/lib && chown -R accumulo:accumulo $ACCUMULO_HOME

# After you place Alluxio client + its deps
RUN cp /opt/alluxio/client/*.jar $ACCUMULO_HOME/lib/


# Add ZooKeeper and Hadoop jars to classpath
ENV ACCUMULO_CLASSPATH="$ACCUMULO_HOME/lib/*:$ZOOKEEPER_HOME/lib/*:$HADOOP_HOME/share/hadoop/common/*:$HADOOP_HOME/share/hadoop/hdfs/*"



# Create necessary directories
RUN mkdir -p $ACCUMULO_HOME/logs $ACCUMULO_HOME/walogs $ACCUMULO_HOME/conf && \
    chown -R accumulo:accumulo $ACCUMULO_HOME

# Set up classpath and environment
RUN echo 'export JAVA_HOME=/opt/java/openjdk' >> /etc/environment && \
    echo 'export HADOOP_HOME=/opt/hadoop' >> /etc/environment && \
    echo 'export ZOOKEEPER_HOME=/opt/zookeeper' >> /etc/environment && \
    echo 'export ACCUMULO_HOME=/opt/accumulo' >> /etc/environment

RUN ln -s $ZOOKEEPER_HOME/lib/*.jar $ACCUMULO_HOME/lib/ || true

# Copy entrypoint script
COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh



# Switch to accumulo user
USER accumulo
WORKDIR $ACCUMULO_HOME

# Set default environment variables
ENV PATH=$ACCUMULO_HOME/bin:$HADOOP_HOME/bin:$ZOOKEEPER_HOME/bin:$ALLUXIO_HOME/bin:$PATH
ENV ACCUMULO_LOG_DIR=$ACCUMULO_HOME/logs
ENV HADOOP_CONF_DIR=$ACCUMULO_HOME/conf
ENV ACCUMULO_CONF_DIR=$ACCUMULO_HOME/conf

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD $ACCUMULO_HOME/bin/accumulo info || exit 1


# Default command
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["help"]