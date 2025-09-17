# Apache Accumulo Docker Image
# Based on the official Accumulo distribution

FROM eclipse-temurin:17-jre-jammy

# Set environment variables
ENV ACCUMULO_VERSION=4.0.0-SNAPSHOT
ENV HADOOP_VERSION=3.3.6  
ENV ZOOKEEPER_VERSION=3.8.4
ENV ACCUMULO_HOME=/opt/accumulo
ENV HADOOP_HOME=/opt/hadoop
ENV ZOOKEEPER_HOME=/opt/zookeeper
ENV JAVA_HOME=/opt/java/openjdk

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
RUN wget -q https://archive.apache.org/dist/hadoop/common/hadoop-${HADOOP_VERSION}/hadoop-${HADOOP_VERSION}.tar.gz && \
    tar -xzf hadoop-${HADOOP_VERSION}.tar.gz -C /opt && \
    mv /opt/hadoop-${HADOOP_VERSION} $HADOOP_HOME && \
    rm hadoop-${HADOOP_VERSION}.tar.gz && \
    chown -R accumulo:accumulo $HADOOP_HOME

# Download and install ZooKeeper (client libraries only)
RUN wget -q https://archive.apache.org/dist/zookeeper/zookeeper-${ZOOKEEPER_VERSION}/apache-zookeeper-${ZOOKEEPER_VERSION}-bin.tar.gz && \
    tar -xzf apache-zookeeper-${ZOOKEEPER_VERSION}-bin.tar.gz -C /opt && \
    mv /opt/apache-zookeeper-${ZOOKEEPER_VERSION}-bin $ZOOKEEPER_HOME && \
    rm apache-zookeeper-${ZOOKEEPER_VERSION}-bin.tar.gz && \
    chown -R accumulo:accumulo $ZOOKEEPER_HOME

# Copy Accumulo distribution (built from source)
COPY --chown=accumulo:accumulo dist/ $ACCUMULO_HOME/

# Create necessary directories
RUN mkdir -p $ACCUMULO_HOME/logs $ACCUMULO_HOME/walogs $ACCUMULO_HOME/conf && \
    chown -R accumulo:accumulo $ACCUMULO_HOME

# Set up classpath and environment
RUN echo 'export JAVA_HOME=/opt/java/openjdk' >> /etc/environment && \
    echo 'export HADOOP_HOME=/opt/hadoop' >> /etc/environment && \
    echo 'export ZOOKEEPER_HOME=/opt/zookeeper' >> /etc/environment && \
    echo 'export ACCUMULO_HOME=/opt/accumulo' >> /etc/environment

# Copy entrypoint script
COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# Switch to accumulo user
USER accumulo
WORKDIR $ACCUMULO_HOME

# Set default environment variables
ENV PATH=$ACCUMULO_HOME/bin:$HADOOP_HOME/bin:$ZOOKEEPER_HOME/bin:$PATH
ENV ACCUMULO_LOG_DIR=$ACCUMULO_HOME/logs
ENV HADOOP_CONF_DIR=$ACCUMULO_HOME/conf
ENV ACCUMULO_CONF_DIR=$ACCUMULO_HOME/conf

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD $ACCUMULO_HOME/bin/accumulo info || exit 1

# Default command
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["help"]