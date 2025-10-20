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

set -euo pipefail

# Set environment variables for Accumulo, Hadoop, and ZooKeeper
export JAVA_HOME=${JAVA_HOME:-/opt/java/openjdk}
export HADOOP_HOME=${HADOOP_HOME:-/opt/hadoop}
export ZOOKEEPER_HOME=${ZOOKEEPER_HOME:-/opt/zookeeper}
export ACCUMULO_HOME=${ACCUMULO_HOME:-/opt/accumulo}

# Default configuration directory
export ACCUMULO_CONF_DIR=${ACCUMULO_CONF_DIR:-"$ACCUMULO_HOME"/conf}

# Function to wait for a service to be available
wait_for_service() {
  local host=$1
  local port=$2
  local service_name=$3
  local timeout=${4:-300}

  echo "Waiting for $service_name at $host:$port..."
  local count=0
  until nc -z "$host" "$port" || [ "$count" -eq "$timeout" ]; do
    sleep 1
    ((count++))
  done

  if [ "$count" -eq "$timeout" ]; then
    echo "ERROR: Timeout waiting for $service_name at $host:$port"
    exit 1
  fi

  echo "$service_name is available at $host:$port"
}

# Function to setup configuration templates
setup_config() {
  echo "Setting up Accumulo configuration..."

  # Set default values if not provided
  export ACCUMULO_INSTANCE_NAME=${ACCUMULO_INSTANCE_NAME:-accumulo}
  export ACCUMULO_INSTANCE_SECRET=${ACCUMULO_INSTANCE_SECRET:-DEFAULT}
  export ZOOKEEPER_HOSTS=${ZOOKEEPER_HOSTS:-localhost:2181}
  export ACCUMULO_INSTANCE_VOLUMES=${ACCUMULO_INSTANCE_VOLUMES:-file:///accumulo}

  # Process configuration templates if they exist
  if [ -d "$ACCUMULO_CONF_DIR/templates" ]; then
    echo "Processing configuration templates..."
    for template in "$ACCUMULO_CONF_DIR/templates"/*.template; do
      if [ -f "$template" ]; then
        filename=$(basename "$template" .template)
        echo "Processing template: $template -> $ACCUMULO_CONF_DIR/$filename"
        envsubst <"$template" >"$ACCUMULO_CONF_DIR/$filename"
      fi
    done
  fi

  # Ensure log directory exists
  mkdir -p "$ACCUMULO_LOG_DIR"
}

# Function to initialize Accumulo instance
init_accumulo() {
  echo "Checking if Accumulo instance needs initialization..."

  # Wait for ZooKeeper
  local zk_host
  local zk_port
  zk_host=$(echo "$ZOOKEEPER_HOSTS" | cut -d: -f1)
  zk_port=$(echo "$ZOOKEEPER_HOSTS" | cut -d: -f2)
  wait_for_service "$zk_host" "$zk_port" "ZooKeeper"

  # Check if instance already exists
  # Match instance name with quotes to avoid false positives from ZooKeeper hostname
  if "$ACCUMULO_HOME"/bin/accumulo org.apache.accumulo.server.util.ListInstances 2>/dev/null | grep -q "\"$ACCUMULO_INSTANCE_NAME\""; then
    echo "Accumulo instance '$ACCUMULO_INSTANCE_NAME' already exists"
  else
    echo "Initializing Accumulo instance '$ACCUMULO_INSTANCE_NAME'..."
    "$ACCUMULO_HOME"/bin/accumulo init \
      --instance-name "$ACCUMULO_INSTANCE_NAME" \
      --password "$ACCUMULO_INSTANCE_SECRET" \
      --clear-instance-name
  fi
}

# Function to start specific Accumulo service
start_service() {
  local service=$1
  echo "Starting Accumulo $service..."

  case "$service" in
    manager | master)
      # Wait for ZooKeeper and optionally initialize
      if [ "${ACCUMULO_AUTO_INIT:-true}" = "true" ]; then
        init_accumulo
      fi
      exec "$ACCUMULO_HOME"/bin/accumulo manager
      ;;
    tserver)
      # Wait for manager to be available
      if [ -n "${ACCUMULO_MANAGER_HOST:-}" ]; then
        wait_for_service "${ACCUMULO_MANAGER_HOST}" "${ACCUMULO_MANAGER_PORT:-9999}" "Accumulo Manager"
      fi
      exec "$ACCUMULO_HOME"/bin/accumulo tserver
      ;;
    monitor)
      # Wait for manager to be available
      if [ -n "${ACCUMULO_MANAGER_HOST:-}" ]; then
        wait_for_service "${ACCUMULO_MANAGER_HOST}" "${ACCUMULO_MANAGER_PORT:-9999}" "Accumulo Manager"
      fi
      exec "$ACCUMULO_HOME"/bin/accumulo monitor
      ;;
    gc)
      # Wait for manager to be available
      if [ -n "${ACCUMULO_MANAGER_HOST:-}" ]; then
        wait_for_service "${ACCUMULO_MANAGER_HOST}" "${ACCUMULO_MANAGER_PORT:-9999}" "Accumulo Manager"
      fi
      exec "$ACCUMULO_HOME"/bin/accumulo gc
      ;;
    compactor)
      # Wait for manager to be available
      if [ -n "${ACCUMULO_MANAGER_HOST:-}" ]; then
        wait_for_service "${ACCUMULO_MANAGER_HOST}" "${ACCUMULO_MANAGER_PORT:-9999}" "Accumulo Manager"
      fi
      local queue="${ACCUMULO_COMPACTOR_QUEUE:-default}"
      exec "$ACCUMULO_HOME"/bin/accumulo compactor -q "$queue"
      ;;
    shell)
      exec "$ACCUMULO_HOME"/bin/accumulo shell "$@"
      ;;
    *)
      # Pass through any other accumulo commands
      exec "$ACCUMULO_HOME"/bin/accumulo "$@"
      ;;
  esac
}

# Main execution
echo "Accumulo Docker Container Starting..."
echo "Command: $*"

# Setup configuration
setup_config

# Check if this is an Accumulo service command
if [ $# -eq 0 ]; then
  echo "No command specified. Use: manager, tserver, monitor, gc, compactor, shell, or any accumulo command"
  exec "$ACCUMULO_HOME"/bin/accumulo help
elif [ "$1" = "manager" ] || [ "$1" = "master" ] || [ "$1" = "tserver" ] || [ "$1" = "monitor" ] || [ "$1" = "gc" ] || [ "$1" = "compactor" ]; then
  start_service "$@"
else
  # Pass through to accumulo binary
  exec "$ACCUMULO_HOME"/bin/accumulo "$@"
fi
