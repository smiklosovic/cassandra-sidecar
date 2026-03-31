#!/usr/bin/env bash
#
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Builds the sidecar image and starts the CDC demo stack.
#
# Usage (from anywhere in the repo):
#   ./scripts/start.sh            # build + start, keep existing data volumes
#   ./scripts/start.sh --clean    # build + start, wipe all data
set -euo pipefail

# ANSI color codes
BOLD='\033[1m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
UNDERLINE='\033[4m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEMO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CLEAN=false

for arg in "$@"; do
    case "$arg" in
        --clean) CLEAN=true ;;
        *) echo "Unknown argument: $arg" >&2; exit 1 ;;
    esac
done

# Run all docker compose commands from the demo directory so no -f flag is needed.
cd "$DEMO_DIR"

echo "==> Stopping stack..."
if $CLEAN; then
    docker compose down -v --remove-orphans
else
    docker compose down --remove-orphans
fi

echo "==> Building sidecar image..."
DOCKER_BUILDKIT=1 docker build \
    -f "$REPO_ROOT/docker/cdc-demo/Dockerfile.sidecar" \
    -t cassandra-sidecar:dev \
    "$REPO_ROOT"

echo "==> Starting stack..."
docker compose up -d

echo ""
echo "Waiting for sidecar to be ready (to follow progress: docker compose logs -f cassandra-init sidecar)..."
until curl -sf http://localhost:9043/api/v1/__health > /dev/null 2>&1; do
    sleep 5
done

echo "Sidecar is up. Waiting for CDC iterators to start..."
docker compose logs -f sidecar 2>&1 | grep -m 1 "CDC iterators started successfully" > /dev/null || true

echo ""
printf "${GREEN}${BOLD}╔══════════════════════════════════════════════╗${RESET}\n"
printf "${GREEN}${BOLD}║   Setup complete. CDC pipeline is running.   ║${RESET}\n"
printf "${GREEN}${BOLD}╚══════════════════════════════════════════════╝${RESET}\n"
echo ""
printf "  ${BOLD}Step 1 — Insert a test mutation:${RESET}\n"
printf "  ${CYAN}\$ docker exec -it cdc-demo-cassandra-1 cqlsh -e \"INSERT INTO cdc_demo.events (id, msg, ts) VALUES (uuid(), 'hello', toTimestamp(now()));\"${RESET}\n"
echo ""
printf "  ${BOLD}Step 2 — View mutations arriving in Kafka UI:${RESET}\n"
printf "  ${UNDERLINE}http://localhost:8080/ui/clusters/local/all-topics/cdc-mutations/messages${RESET}\n"
echo ""
