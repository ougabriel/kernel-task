# Kernel Take-Home Complete Guide: EAV at Scale


## Part A: Data Model & Querying

### Step 1: Understand the RequirementS
- 200M entities (assets)
- 10,000 dynamic attribute types
- High write throughput (10k inserts/sec)
- Support both operational (low-latency) and analytical queries
- Multi-tenant system

### Step 2: Design the Core Schema
 this is a logical design for scalable, multi-tenant, flexible schemas.
- Entity table: provides the core entity storage, tenant isolation wth tenant_id, type and timestamps.
- Entity_attributes: implements the EAV model that wil help scale: partitioning by tenant_id, composite pk to enforce uniqueness at scale, as well as numeric_value
   which allows pre-computed indecing/search for numbers there by helping to optimize queries.

#### Logical Schema Design
Please CLICK HERE for the actual schema design

---

### a. Schema Summary

* **`attr_type`** → small, reference table (hundreds or thousands of rows). No partitioning needed.
* **`entity`** → very large (200M+ rows), must be partitioned/sharded carefully.
* **`entity_attribute`** → *fact-like* table, extremely wide in terms of rows (billions+ possible). Needs the most careful design.

---

### b. Partitioning vs. Sharding

* **Partitioning** → dividing a single logical table into smaller, physical chunks within *one database instance*.
* **Sharding** → distributing data across multiple *database servers or clusters*.
  In practice, you’ll usually **partition within a shard**, and then shard across servers for scale.

---

c. Partitioning Strategy

Tenant-based Hash Partitioning: Isolate tenants and distribute load
Time-based Sub-partitioning: For hot/cold data separation
Entity ID range partitioning: For very large tenants

#### `entity_attribute` (core table)

  ```sql
  PARTITION BY HASH (attribute_id)
  ```

This makes sense because:

  * Queries are often scoped by *attribute* (e.g., "get all entities with `status=active`").
  * Hash partitioning evenly spreads load across partitions.
  * Keeps each partition smaller, improving index and vacuum performance.

* Within each **attribute\_id partition**, you can further **sub-partition by range on entity\_id** or **created\_at**, depending on query patterns:

  * **Range on `entity_id`**: good for evenly distributed IDs (e.g., 1–10M, 10M–20M).
  * **Range on `created_at`**: good if queries are mostly time-based ("recent events").

#### `entity` table

* Partition by **range on entity\_id** or **created\_at**.
* If `entity_id` is sequential, range partitioning will keep hot inserts localized.

#### `attr_type` table

* Small dimension table, no partitioning. Keep replicated to all shards.

---

d. Sharding Strategy

Once a single DB instance can’t handle the scale, introduce sharding:

* **Shard key: `entity_id`** → ensures all attributes of an entity live on the same shard.
* This avoids cross-shard joins when reconstructing entity views.

So the global picture is:

* **Shards** distributed by `entity_id` (shard per range/hash of IDs).
* **Inside each shard**:

  * `entity_attribute` partitioned by `attribute_id` (and maybe sub-partitioned by time or entity ranges).
  * `entity` partitioned by `entity_id` or time.

---

e. Example Layout

* **Shard 1**: entity\_id 1–50M

  * entity\_attribute → hash partitions on `attribute_id`, sub-partitioned by created\_at (monthly)
* **Shard 2**: entity\_id 50M–100M

  * same partitioning scheme
* …and so on.

---

f. Benefits of this Strategy

* **Scalability**: both horizontally (shards) and vertically (partitions).
* **Locality**: all attributes for an entity are on one shard.
* **Query optimization**: attribute-based partitions speed up lookups like `WHERE attribute_id=123`.
* **Manageability**: partitions can be pruned/dropped by time range if old data expires.

---
 In short:

* **Sharding** → by `entity_id` (all attributes for an entity stick together).
* **Partitioning** → within each shard:

  * `entity_attribute` → hash by `attribute_id`, optional sub-partition by time/entity\_id range.
  * `entity` → range by `entity_id` or time.
  * `attr_type` → replicated.

---
##Keeping queries fast at 200M entities

a. First we'd want to know my query patterns(first, always)
   finding entities where `attribute_id = x` and `value_text` = `y1 
   desigining everything around the hot queries
b. Make reads local: shard by entity_id
   Keeping all attributes for an entity on the same shard so single-entity reads never need cross-shard joins. 
   Sharding also reduces per-node dataset size, improving cache hit rate.
c. Using partition-wise indexes (each partition has its own local index). 
   PostgreSQL will do partition pruning at query time if predicates reference the partition key.
   We may consider sub-partitioning when attribute cardinality or time is important
d. Indexing strategy (the most important)
   Create indexes tailored to frequent queries. For EAV we will often want many narrow indexes rather than one giant composite index.
   Examples:
   Lookup by entity (get all attributes for an entity):
   ```CREATE INDEX ON entity_attribute (entity_id);```
   -- or if partitioned, create on each partition (or use CREATE INDEX ... ON ONLY partition)


   Lookups by attribute + typed value (cover hot types):

   ```-- for text attributes
  CREATE INDEX ON entity_attribute (attribute_id, value_text) WHERE value_text IS NOT NULL;
   ```

   ```-- for numeric attributes
   ``CREATE INDEX ON entity_attribute (attribute_id, value_number) WHERE value_number IS NOT NULL;
   ```

   ```
   -- for timestamps
   CREATE INDEX ON entity_attribute (attribute_id, value_ts) WHERE value_ts IS NOT NULL;
  ```

  Those are partial indexes and dramatically reduce index size (and maintenance cost) because they only cover rows where the typed column is used.

  ## For JSONB queries:

  ```
  CREATE INDEX ON entity_attribute USING gin (value_jsonb);
  ```

  For low-cardinality, large-range entity_id scans we may want to consider BRIN indexes:

  ```
  CREATE INDEX ON entity_attribute USING brin (entity_id);
  ```

  BRIN is very compact and great if `entity_id` is roughly clustered.

  We may also consider covering indexes for top queries so the planner can do index-only scans (i.e., include created_at if needed):

 ```
 CREATE INDEX ON entity_attribute (attribute_id, value_text, entity_id) WHERE value_text IS NOT NULL;
 ```
e. Denormalize / materialized projections for hot access patterns

 Entity snapshot table (one row per entity with columns for hottest attributes). Keep updated via triggers or async job.
 Materialized views for attribute-centric queries (refresh periodically or incrementally).
 Example:
 ```
 CREATE TABLE entity_snapshot (
  entity_id bigint PRIMARY KEY,
  status text,
  last_seen timestamptz,
  score double precision,
  updated_at timestamptz
);
 ```
 Query entity_snapshot for fast reads instead of scanning entity_attribute.
 
f. Cache aggressively

 Using Redis or in-memory caches for hot entities and query results (entity snapshots, attribute lookups).
 Cache invalidation: update cache on write or use TTLs for slightly stale reads.
g. Read replicas / connection routing
  Offloading OLAP/analytic queries to read replicas.
  Route heavy analytical queries to replicas or a separate analytics cluster (e.g., ClickHouse, Redshift) that ingests EAV data periodically.
h. Compression & storage choices
 Using SSD-backed storage, fast disks, and sufficient RAM to keep indexes hot.
 When we use huge JSON, we may consider compressing it or move large JSONB to a separate table (to keep the hot index/tiny row small).


3. Showing 2 example SQL queries

   1. Operational query (multi-attribute filter)

Example: “Find all active users in the US whose score > 80”
Here, we need entities with multiple attributes: status, country, and score.

SELECT e.entity_id
FROM entity e
JOIN entity_attribute a1 
  ON e.entity_id = a1.entity_id 
 AND a1.attribute_id = 101   -- status
 AND a1.value_text = 'active'
JOIN entity_attribute a2
  ON e.entity_id = a2.entity_id
 AND a2.attribute_id = 102   -- country
 AND a2.value_text = 'US'
JOIN entity_attribute a3
  ON e.entity_id = a3.entity_id
 AND a3.attribute_id = 103   -- score
 AND a3.value_number > 80;

Why this works fast

Partition pruning: each join touches only partitions for the given attribute_id.

Indexes: (attribute_id, value_text) and (attribute_id, value_number) allow narrow lookups.

Entity locality: since all attributes for an entity_id live in the same shard, joins are intra-shard only.

2. Analytical query (aggregation / distribution)

Example: “Distribution of user scores (attribute_id=103) by country (attribute_id=102)”
```
SELECT a2.value_text AS country,
       width_bucket(a1.value_number, 0, 100, 10) AS score_bucket,
       COUNT(DISTINCT e.entity_id) AS entity_count
FROM entity e
JOIN entity_attribute a1
  ON e.entity_id = a1.entity_id
 AND a1.attribute_id = 103   -- score
JOIN entity_attribute a2
  ON e.entity_id = a2.entity_id
 AND a2.attribute_id = 102   -- country
GROUP BY a2.value_text,
         width_bucket(a1.value_number, 0, 100, 10)
ORDER BY a2.value_text, score_bucket;
```
Partition pruning again: only partitions for attributes 103 (score) and 102 (country) are scanned.

Indexes: (attribute_id, value_number) and (attribute_id, value_text) speed up attribute filtering before aggregation.

`width_bucket` bins numeric values efficiently (Postgres built-in).

- The operational query shows how we can filter by multiple attributes to return entity IDs quickly.
-  The analytical query shows we can aggregate attributes across entities for distribution/statistics


##4. Trade-Offs Summary
 Where this design excels includes the following
   i. Flexibility: We can add new attributes without schema changes; also good for metadata-driven or dynamic domains 
   ii. Sparse storage efficiency: Only store values for attributes that exist (vs. wide nullable columns).
   iii. Scales with partitioning
       - Hash partitioning on attribute_id prunes scans by attribute, keeping queries bounded
       - Sharding by entity_id ensures `entity-local` operations don’t cross nodes.
   iv. Operational queries (narrow filters): Queries like “find entities with attribute X = value” are fast with (attribute_id, value_*) indexes.
       Multi-attribute filters work decently with joins inside a shard.

 Where it degrades
    i. Multi-attribute joins explode: Each additional attribute requires a self-join on entity_attribute.
    ii. Analytics across many attributes
    iii. Index bloat & maintenance
    iv. Write amplification: Inserts require updating multiple indexes (potentially on large partitions); also ...
        hot attributes can skew distribution and overload certain partitions.
    v. Query complexity: Queries are verbose and hard to optimize automatically.

If scale breaks (fallback approaches)

When a single Postgres shard/partition scheme starts to degrade:

  i. Denormalization / projections: Build “entity snapshots” with key attributes as columns; also store pre-joined attribute sets for the 80% of hot queries. We can also query snapshots for speed; keep EAV for flexibility.

 2. Hybrid storage: Move hot or structured attributes into regular columns, keeping rare or long-tail attributes in EAV.
    Example: entity_main with status, country, score as columns; rest stay in entity_attribute.
 3. Columnar / OLAP system for analytics: Push analytical workloads (distribution queries, aggregates across billions of rows) to systems like ClickHouse, DuckDB, Redshift, or BigQuery, keeping Postgres for transactional, operational queries.

 4. Cache layer (Redis / ElasticSearch): Cache entity views or attribute filters, Use ElasticSearch for full-text or complex attribute queries.
 5. Data lake / event sourcing: Offload historical or less-used attributes into cheaper storage (S3, Delta Lake), keeping only recent/active entities in Postgres.

## Part B: Read Freshness & Replication

### Step 6: Replication Architecture Design

# Part B: Read Freshness & Replication Architecture

## 1. Replication Architecture

### System Flow Diagram
```
┌─────────────┐    ┌──────────────────┐    ┌─────────────────┐
│   AtlasCo   │    │   PostgreSQL     │    │   Debezium      │
│Application  │───▶│   Primary        │───▶│   Connector     │
│(10k writes/s│    │   (OLTP)         │    │   (CDC)         │
└─────────────┘    └──────────────────┘    └─────────────────┘
       │                     │                        │
       │                     ▼                        ▼
       │           ┌──────────────────┐    ┌─────────────────┐
       │           │   PostgreSQL     │    │     Kafka       │
       │◄──────────│   Read Replica   │    │   3 Brokers     │
       │           │   (Near RT)      │    │   6 Partitions  │
       │           └──────────────────┘    └─────────────────┘
       │                     │                        │
       │                     │                        ▼
       │                     │             ┌─────────────────┐
       │                     │             │   ClickHouse    │
       │◄────────────────────┼─────────────│   Cluster       │
       │                     │             │   (OLAP)        │
       │                     │             └─────────────────┘
       │                     │                        │
       ▼                     ▼                        ▼
┌─────────────────────────────────────────────────────────────┐
│              Application Router Layer                        │
│  • Route based on freshness requirements                    │
│  • Monitor lag across all systems                           │
│  • Implement fallback logic                                 │
└─────────────────────────────────────────────────────────────┘
```

### Component Details

**PostgreSQL Logical Replication:**
```sql
-- Enable logical replication
ALTER SYSTEM SET wal_level = logical;
ALTER SYSTEM SET max_replication_slots = 10;
ALTER SYSTEM SET max_wal_senders = 10;

-- Create replication slot for Debezium
SELECT pg_create_logical_replication_slot('atlas_debezium_slot', 'pgoutput');

-- Create publication for tracked tables
CREATE PUBLICATION atlas_publication FOR TABLE 
    entities, entity_hot_attributes, entity_attributes;
```

**Debezium Configuration:**
```json
{
  "name": "atlas-postgres-connector",
  "config": {
    "connector.class": "io.debezium.connector.postgresql.PostgresConnector",
    "database.hostname": "atlas-postgres-primary.cluster-xyz.amazonaws.com",
    "database.port": "5432",
    "database.user": "debezium_user",
    "database.password": "${vault:secret:debezium-password}",
    "database.dbname": "atlas_telemetry",
    "table.include.list": "public.entities,public.entity_hot_attributes,public.entity_attributes",
    "plugin.name": "pgoutput",
    "slot.name": "atlas_debezium_slot",
    "publication.name": "atlas_publication",
    "transforms": "route,addMetadata",
    "transforms.route.type": "org.apache.kafka.connect.transforms.RegexRouter",
    "transforms.route.regex": "public\\.(.*)",
    "transforms.route.replacement": "atlas.$1",
    "transforms.addMetadata.type": "org.apache.kafka.connect.transforms.InsertField$Value",
    "transforms.addMetadata.timestamp.field": "db_event_timestamp",
    "key.converter": "org.apache.kafka.connect.json.JsonConverter",
    "value.converter": "org.apache.kafka.connect.json.JsonConverter",
    "snapshot.mode": "initial",
    "decimal.handling.mode": "string"
  }
}
```

**Kafka Topic Strategy:**
```yaml
topics:
  atlas.entities:
    partitions: 6
    replication_factor: 3
    partition_key: tenant_id
    retention_ms: 604800000  # 7 days
    
  atlas.entity_hot_attributes:
    partitions: 6
    replication_factor: 3
    partition_key: tenant_id
    retention_ms: 604800000
    
  atlas.entity_attributes:
    partitions: 12  # Higher partition count for volume
    replication_factor: 3
    partition_key: tenant_id
    retention_ms: 259200000  # 3 days (higher volume)
```

**ClickHouse Sink Configuration:**
```sql
-- ClickHouse target tables (denormalized for analytics)
CREATE TABLE atlas_analytics.entity_events_queue (
    entity_id UInt64,
    tenant_id UInt32,
    event_type String,
    entity_type String,
    attribute_key String,
    attribute_value String,
    attribute_numeric Float64,
    event_timestamp DateTime64(3),
    db_event_timestamp DateTime64(3),
    kafka_timestamp DateTime64(3) DEFAULT now64(),
    _partition_id UInt16
) ENGINE = Kafka('kafka1:9092,kafka2:9092,kafka3:9092', 
                 'atlas.entity_attributes', 
                 'clickhouse_consumer_group',
                 'JSONEachRow');

CREATE TABLE atlas_analytics.entity_events (
    entity_id UInt64,
    tenant_id UInt32,
    event_type String,
    entity_type String,
    attribute_key String,
    attribute_value String,
    attribute_numeric Float64,
    event_timestamp DateTime64(3),
    db_event_timestamp DateTime64(3),
    ingestion_timestamp DateTime64(3) DEFAULT now64()
) ENGINE = ReplacingMergeTree(ingestion_timestamp)
PARTITION BY toYYYYMM(event_timestamp)
ORDER BY (tenant_id, entity_id, attribute_key, event_timestamp);

-- Materialized view for real-time ingestion
CREATE MATERIALIZED VIEW atlas_analytics.entity_events_mv TO entity_events AS
SELECT * FROM entity_events_queue;
```

## 2. Freshness Budget Matrix
<img width="526" height="346" alt="image" src="https://github.com/user-attachments/assets/a4924aa9-a456-470e-b230-69f97dcd50c4" />


### Freshness Categories
```python
class FreshnessClass(Enum):
    REALTIME = "realtime"      # <100ms - Primary DB only
    INTERACTIVE = "interactive" # <1s - Read Replica preferred  
    OPERATIONAL = "operational" # <30s - Read Replica acceptable
    ANALYTICAL = "analytical"   # <5min - OLAP preferred
    BATCH = "batch"            # <1hr - OLAP only
```

## 3. Application Freshness Interface

### API Headers & Metadata
```python
# Request headers (client can specify requirements)
GET /api/v1/entities/12345/status
X-Freshness-Requirement: realtime|interactive|operational|analytical
X-Max-Acceptable-Lag-Ms: 500
X-Fallback-Strategy: fail|primary|replica

# Response headers (server reports actual freshness)
HTTP/1.1 200 OK
X-Data-Source: replica
X-Data-Freshness: interactive
X-Actual-Lag-Ms: 245
X-Data-Timestamp: 2024-12-10T15:30:45.123Z
X-Source-Timestamp: 2024-12-10T15:30:44.878Z
X-Replication-Health: healthy
```

### Freshness-Aware Routing Logic
```python
class FreshnessRouter:
    def __init__(self):
        self.primary_db = PrimaryDatabase()
        self.replica_db = ReadReplica()
        self.clickhouse = ClickHouse()
        self.lag_monitor = LagMonitor()
    
    def route_query(self, query_type: str, freshness_req: FreshnessClass) -> DatabaseConnection:
        current_lags = self.lag_monitor.get_current_lags()
        
        if freshness_req == FreshnessClass.REALTIME:
            return self.primary_db
            
        elif freshness_req == FreshnessClass.INTERACTIVE:
            if current_lags.replica_lag_ms < 1000:
                return self.replica_db
            else:
                logger.warning(f"Replica lag too high ({current_lags.replica_lag_ms}ms), falling back to primary")
                return self.primary_db
                
        elif freshness_req == FreshnessClass.OPERATIONAL:
            if current_lags.replica_lag_ms < 30000:
                return self.replica_db
            else:
                return self.primary_db
                
        elif freshness_req in [FreshnessClass.ANALYTICAL, FreshnessClass.BATCH]:
            if current_lags.clickhouse_lag_ms < 300000:  # 5 minutes
                return self.clickhouse
            else:
                logger.info("ClickHouse lag too high, using replica for analytics")
                return self.replica_db
```

### Lag Detection & Monitoring
```python
class LagMonitor:
    def get_current_lags(self) -> LagMetrics:
        return LagMetrics(
            replica_lag_ms=self._get_postgres_replica_lag(),
            clickhouse_lag_ms=self._get_clickhouse_lag(),
            kafka_lag_messages=self._get_kafka_consumer_lag()
        )
    
    def _get_postgres_replica_lag(self) -> float:
        # Query pg_stat_replication on primary
        result = self.primary_db.query("""
            SELECT EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp())) * 1000 
            FROM pg_stat_replication 
            WHERE application_name = 'atlas_replica'
        """)
        return result[0][0] if result else float('inf')
    
    def _get_clickhouse_lag(self) -> float:
        # Check watermark table in ClickHouse
        result = self.clickhouse.query("""
            SELECT (now64() - max(ingestion_timestamp)) * 1000
            FROM atlas_analytics.entity_events
            WHERE ingestion_timestamp > now64() - INTERVAL 1 HOUR
        """)
        return result[0][0] if result else float('inf')
    
    def _get_kafka_consumer_lag(self) -> int:
        # Query Kafka consumer group lag via JMX or Admin API
        consumer_group = 'clickhouse_consumer_group'
        return kafka_admin.get_consumer_lag(consumer_group, 'atlas.entity_attributes')
```

## 4. Lag Detection & Handling Flow

### Detailed ASCII Flow
```
Time: T0      T1         T2          T3          T4
      │       │          │           │           │
      ▼       ▼          ▼           ▼           ▼
┌─────────────────────────────────────────────────────┐
│             PostgreSQL Primary                      │
│  INSERT → WAL → Logical Decode → Publication        │
└─────────────────────────────────────────────────────┘
      │       │          │           │           │
      ▼       ▼          ▼           ▼           ▼
┌─────────────────────────────────────────────────────┐
│             Read Replica                            │
│  ← Stream ← Apply → Query Available                 │  Lag: ~100-500ms
└─────────────────────────────────────────────────────┘
      │       │          │           │           │
      ▼       ▼          ▼           ▼           ▼
┌─────────────────────────────────────────────────────┐
│             Debezium → Kafka                        │
│  ← CDC ← Transform → Publish → Partition            │  Lag: ~200-1000ms
└─────────────────────────────────────────────────────┘
      │       │          │           │           │
      ▼       ▼          ▼           ▼           ▼
┌─────────────────────────────────────────────────────┐
│             ClickHouse                              │
│  ← Consume ← Transform → Merge → Query Available    │  Lag: ~1-5 minutes
└─────────────────────────────────────────────────────┘

Monitoring Points:
• T1: pg_stat_replication.replay_lag
• T2: Kafka consumer group lag  
• T3: ClickHouse ingestion timestamp delta
```

### Health Check Endpoints
```python
@app.route('/health/replication')
def replication_health():
    lag_monitor = LagMonitor()
    lags = lag_monitor.get_current_lags()
    
    health_status = {
        'timestamp': datetime.utcnow().isoformat(),
        'overall_status': 'healthy',
        'components': {
            'postgres_replica': {
                'status': 'healthy' if lags.replica_lag_ms < 5000 else 'degraded',
                'lag_ms': lags.replica_lag_ms,
                'threshold_ms': 5000
            },
            'clickhouse': {
                'status': 'healthy' if lags.clickhouse_lag_ms < 600000 else 'degraded',
                'lag_ms': lags.clickhouse_lag_ms,
                'threshold_ms': 600000
            },
            'kafka': {
                'status': 'healthy' if lags.kafka_lag_messages < 10000 else 'degraded',
                'lag_messages': lags.kafka_lag_messages,
                'threshold_messages': 10000
            }
        }
    }
    
    # Determine overall status
    if any(comp['status'] == 'degraded' for comp in health_status['components'].values()):
        health_status['overall_status'] = 'degraded'
    
    status_code = 200 if health_status['overall_status'] == 'healthy' else 503
    return jsonify(health_status), status_code
```

### Alerting & Automatic Fallback
```yaml
# CloudWatch Alarms
alerts:
  postgres_replica_lag:
    metric: custom.atlas.replica_lag_ms
    threshold: 5000
    duration: 2_minutes
    action: switch_to_primary_for_interactive_queries
    
  clickhouse_lag:
    metric: custom.atlas.clickhouse_lag_ms  
    threshold: 900000  # 15 minutes
    duration: 5_minutes
    action: switch_analytics_to_replica
    
  kafka_consumer_lag:
    metric: kafka.consumer.lag.sum
    threshold: 50000
    duration: 3_minutes  
    action: scale_clickhouse_consumers
```

This architecture provides clear data freshness boundaries with automatic fallback strategies, comprehensive monitoring, and explicit client contracts for different use cases.
## Part C: Infrastructure as Code 

### Step 9: Terraform Implementation
Please check here for the terraform, main.tf, variable.tf, output.tf scripts
[infras/terraform](https://github.com/ougabriel/kernel-task/tree/main/infras/terraform)

### Step 10: Final Deliverables Structure

```
kernel-takehome/
├── solution1.md          # Main design document
├── schema.sql          # PostgreSQL DDL and queries
├── infra/
│   ├── main.tf
│   ├── variables.tf
│   └── outputs.tf

```

## Key Trade-offs to Address

### Part A Trade-offs:
- **Pros**: Flexible schema, handles dynamic attributes, good for mixed workloads
- **Cons**: Complex queries, potential performance issues with large scans
- **Fallbacks**: Hybrid row-columnar storage, attribute-specific tables for hot data

### Part B Trade-offs:
- **Pros**: Clear separation of concerns, scalable replication
- **Cons**: Complexity in managing freshness, potential data inconsistency
- **Monitoring**: Replication lag metrics, freshness SLAs

### Part C Trade-offs:
- **Environment Parameterization**: Different instance sizes, backup policies
- **Cost Optimization**: Serverless scaling, reserved instances for prod


