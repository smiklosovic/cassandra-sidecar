<!--
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
-->
# CDC Demo — Docker Compose Setup

End-to-end demo that boots Cassandra, Cassandra Sidecar, and Kafka.
Writes to a CDC-enabled Cassandra table are captured by the sidecar and
published as Avro messages to a Kafka topic.

## Architecture

```
┌──────────────┐   cdc_raw/commitlog   ┌──────────────────┐
│  Cassandra   │ ─────────────────────► │  Cassandra       │──► Kafka (cdc-mutations)
│  (port 9042) │   (shared volume)      │  Sidecar         │
└──────────────┘                        │  (port 9043)     │
                                        └──────────────────┘
                                                                      │
                                                                      ▼
                                                           ┌──────────────────┐
                                                           │   Kafka UI       │
                                                           │  localhost:8080  │
                                                           └──────────────────┘
```

**Services:**
- `kafka` — KRaft Kafka broker (no ZooKeeper)
- `cassandra` — Cassandra with CDC enabled
- `cassandra-init` — one-shot container that seeds the sidecar schema and CDC/Kafka configs (reuses the already-pulled Cassandra image)
- `sidecar` — Cassandra Sidecar; starts after schema is ready
- `kafka-ui` — Web UI to browse Kafka topics at http://localhost:8080

## Prerequisites

| Tool           | Version      |
|----------------|--------------|
| Docker         | 24+          |
| Docker Compose | v2 (plugin)  |
| Java           | 11           |
| Gradle         | via wrapper  |

## Exposed ports

| Port   | Service           |
|--------|-------------------|
| `9042` | Cassandra CQL     |
| `9043` | Cassandra Sidecar |
| `8080` | Kafka UI          |

## Quick Start

### Step 1 — Build and start the stack

From `docker/cdc-demo/`, run the start script — it builds the sidecar image and
starts all services:

```bash
cd docker/cdc-demo
./scripts/start.sh
```

To wipe all data and start completely fresh:

```bash
./scripts/start.sh --clean
```

> **Manual build** (if you prefer): from the repository root, run
> `DOCKER_BUILDKIT=1 docker build -f docker/cdc-demo/Dockerfile.sidecar -t cassandra-sidecar:dev .`
> (`DOCKER_BUILDKIT=1` is required for the Gradle dependency cache mount in the Dockerfile)
> then update `docker-compose.yml` to use `image: cassandra-sidecar:dev` instead of
> the `build:` block, and run `docker compose up -d`.

### Step 2 — Wait for CDC to be ready

The `start.sh` script automatically waits until the sidecar is up and CDC
iterators have started, then prints a **Setup complete** message. No manual
log watching is needed.

To follow progress in another terminal while waiting:

```bash
docker compose logs -f cassandra-init sidecar
```

### Step 3 — Write mutations to the CDC-enabled table

```bash
docker exec -it cdc-demo-cassandra-1 cqlsh -e "
  INSERT INTO cdc_demo.events (id, msg, ts)
  VALUES (uuid(), 'hello from CDC', toTimestamp(now()));
"
```

### Step 4 — View messages in Kafka UI

The **Setup complete** message printed by `start.sh` includes a direct link to
the `cdc-mutations` topic. You can also open it directly:

```
http://localhost:8080/ui/clusters/local/all-topics/cdc-mutations/messages
```

Click the **Messages** tab to see one Avro-encoded message per Cassandra mutation.

### Step 5 — Consume events from Kafka (CLI)

```bash
docker exec -it cdc-demo-kafka-1 \
  kafka-console-consumer \
    --bootstrap-server kafka:9092 \
    --topic cdc-mutations \
    --from-beginning \
    --max-messages 5
```

## Supported Cassandra Versions

CDC is supported for **4.0, 4.1, 5.0, 5.1**. To use a different version:

```bash
CASSANDRA_VERSION=4.1 docker compose up -d
```

The default is `5.0`. Note: the `cassandra:4.0` Docker image is `linux/amd64` only — on Apple Silicon it runs under Rosetta emulation and may be slow to start. Use `4.1` or later for ARM64 support.

## Configuration

`conf/sidecar.yaml` is volume-mounted into the sidecar container and can be
edited without rebuilding the image. Restart the sidecar to pick up changes:

```bash
docker compose restart sidecar
```

CDC and Kafka properties read by the sidecar are stored in Cassandra and seeded
automatically on first boot. To update them after the cluster is running:

```bash
docker exec -it cdc-demo-cassandra-1 cqlsh -e "
  UPDATE sidecar_internal.configs
  SET config = config + {'micro_batch_delay_millis': '500'}
  WHERE service = 'cdc';
"
```

## Persistence

All data is stored in named Docker volumes and survives `docker compose down`.

| Volume             | Contents                                         |
|--------------------|--------------------------------------------------|
| `cassandra-varlib` | All Cassandra data (data/, commitlog/, cdc_raw/) |
| `kafka-data`       | Topic partitions + consumer offsets              |

**To wipe everything and start fresh:**

```bash
docker compose down -v
```

## Stopping

```bash
docker compose down        # stop containers, keep volumes
docker compose down -v     # stop containers AND delete all data
```

## Troubleshooting

**Sidecar keeps restarting**
The sidecar waits for `cassandra-init` to complete successfully. Check its logs:

```bash
docker compose logs cassandra-init
```

**CDC events not arriving in Kafka**
1. Verify configs were seeded: `docker exec cdc-demo-cassandra-1 cqlsh -e "SELECT * FROM sidecar_internal.configs;"`
2. Check sidecar logs for `CDC iterators started successfully`
3. Confirm CDC is enabled on the table: `docker exec cdc-demo-cassandra-1 cqlsh -e "DESCRIBE TABLE cdc_demo.events;"`

**JMX connection refused**
Remote JMX is enabled by the `LOCAL_JMX=no` env var on the Cassandra service in
`docker-compose.yml`, which causes the stock Cassandra Docker entrypoint to set
`jmxremote.local.only=false`. The `JVM_EXTRA_OPTS` env var additionally sets
`-Djava.rmi.server.hostname=cassandra` so RMI binds to the right interface.
If the sidecar still can't connect, verify the flags are active:

```bash
docker exec cdc-demo-cassandra-1 ps aux | grep jmxremote
```
