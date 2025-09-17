# Kernel Take-Home Complete Guide: EAV at Scale


## Part A: Data Model & Querying (55-65 minutes)

### Step 1: Understand the Requirements (5 minutes)
- 200M entities (assets)
- 10,000 dynamic attribute types
- High write throughput (10k inserts/sec)
- Support both operational (low-latency) and analytical queries
- Multi-tenant system

### Step 2: Design the Core Schema (15 minutes)
 this is a logical design for scalable, multi-tenant, flexible schemas.
- Entity table: provides the core entity storage, tenant isolation wth tenant_id, type and timestamps.
- Entity_attributes: implements the EAV model that wil help scale: partitioning by tenant_id, composite pk to enforce uniqueness at scale, as well as numeric_value
   which allows pre-computed indecing/search for numbers there by helping to optimize queries.

#### Logical Schema Design
```sql
-- Core entity table
CREATE TABLE entities (
    entity_id BIGSERIAL PRIMARY KEY,
    tenant_id INTEGER NOT NULL,
    entity_type VARCHAR(50) NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- EAV attributes table (main workhorse)
CREATE TABLE entity_attributes (
    tenant_id INTEGER NOT NULL,
    entity_id BIGINT NOT NULL,
    attribute_name VARCHAR(255) NOT NULL,
    attribute_value TEXT NOT NULL,
    value_type VARCHAR(20) NOT NULL, -- 'string', 'number', 'boolean', 'timestamp'
    numeric_value DECIMAL(20,6), -- Pre-computed for numeric attributes
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    PRIMARY KEY (tenant_id, entity_id, attribute_name)
) PARTITION BY HASH (tenant_id);

-- Attribute metadata for optimization
CREATE TABLE attribute_metadata (
    tenant_id INTEGER NOT NULL,
    attribute_name VARCHAR(255) NOT NULL,
    value_type VARCHAR(20) NOT NULL,
    is_indexed BOOLEAN DEFAULT FALSE,
    cardinality_estimate BIGINT,
    last_analyzed TIMESTAMP WITH TIME ZONE,
    
    PRIMARY KEY (tenant_id, attribute_name)
);
```

### Step 3: Partitioning Strategy 

#### Multi-Level Partitioning Approach
1. **Tenant-based Hash Partitioning**: Isolate tenants and distribute load
2. **Time-based Sub-partitioning**: For hot/cold data separation
3. **Entity ID range partitioning**: For very large tenants

#### Partition Creation Strategy
```sql
-- Create 16 tenant-based partitions
CREATE TABLE entity_attributes_p00 PARTITION OF entity_attributes 
FOR VALUES WITH (modulus 16, remainder 0);
-- ... repeat for p01 through p15

-- For large tenants, create dedicated partitions
CREATE TABLE entity_attributes_tenant_1001 PARTITION OF entity_attributes 
FOR VALUES WITH (modulus 1, remainder 0) 
WHERE tenant_id = 1001;
```

### Step 4: Indexing Strategy (10 minutes)

#### Core Indexes
```sql
-- Primary lookup indexes
CREATE INDEX CONCURRENTLY idx_entity_attributes_entity_lookup 
ON entity_attributes (tenant_id, entity_id);

-- Multi-attribute filtering (GIN for array operations)
CREATE INDEX CONCURRENTLY idx_entity_attributes_gin 
ON entity_attributes USING GIN (
    tenant_id, 
    (ARRAY[attribute_name, attribute_value])
);

-- Numeric value index for range queries
CREATE INDEX CONCURRENTLY idx_entity_attributes_numeric 
ON entity_attributes (tenant_id, attribute_name, numeric_value) 
WHERE numeric_value IS NOT NULL;

-- Hot attributes get dedicated indexes
CREATE INDEX CONCURRENTLY idx_entity_attributes_hot_attr 
ON entity_attributes (tenant_id, attribute_value) 
WHERE attribute_name IN ('status', 'priority', 'region');
```

### Step 5: Example Queries

#### Operational Query (Multi-attribute Filter)
```sql
-- Find entities with specific attribute combinations
WITH filtered_entities AS (
    SELECT entity_id, COUNT(*) as match_count
    FROM entity_attributes 
    WHERE tenant_id = 1001
      AND (
        (attribute_name = 'status' AND attribute_value = 'active') OR
        (attribute_name = 'region' AND attribute_value = 'us-west-2') OR
        (attribute_name = 'priority' AND numeric_value > 5)
      )
    GROUP BY entity_id
    HAVING COUNT(*) >= 2  -- Match at least 2 conditions
)
SELECT e.entity_id, e.entity_type, ea.attribute_name, ea.attribute_value
FROM filtered_entities fe
JOIN entities e ON e.entity_id = fe.entity_id
JOIN entity_attributes ea ON ea.entity_id = fe.entity_id AND ea.tenant_id = 1001
ORDER BY e.updated_at DESC
LIMIT 100;
```

#### Analytical Query (Aggregation)
```sql
-- Distribution of numeric attributes across entity types
SELECT 
    e.entity_type,
    ea.attribute_name,
    COUNT(*) as entity_count,
    AVG(ea.numeric_value) as avg_value,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY ea.numeric_value) as median_value,
    MAX(ea.numeric_value) as max_value
FROM entity_attributes ea
JOIN entities e ON e.entity_id = ea.entity_id
WHERE ea.tenant_id = 1001
  AND ea.numeric_value IS NOT NULL
  AND ea.created_at >= NOW() - INTERVAL '7 days'
GROUP BY e.entity_type, ea.attribute_name
HAVING COUNT(*) > 1000
ORDER BY entity_count DESC;
```


###Summary 

This design works very well when flexibility and tenant isolation are key. The EAV model allows to add attributes without schema changes, and the multi-level partitioning strategy (tenant hash, time ranges, and entity ID splits) keeps data distributed and manageable. Operational queries that filter on indexed attributes perform efficiently, especially when targeting hot data in recent partitions. Analytical queries also benefit from partition pruning and numeric indexing, making counts and averages on recent data feasible.

The weaknesses appear when queries require joining many attributes, since the EAV model leads to join or grouping overhead. High-cardinality attributes can make indexes very large, and analytical workloads that need window functions or full scans degrade as the dataset grows. Hot partitions can also become a bottleneck if a tenant or time window attracts disproportionate load.

If scale breaks, the system can fall back to denormalized or precomputed indexes for frequent filters, caching layers for repeated queries, and columnar or OLAP databases for large analytical workloads. For write or read hotspots, sub-partitioning and sharding tenants across nodes, or using streaming pipelines to absorb spikes, help maintain performance.

## Part B: Read Freshness & Replication

### Step 6: Replication Architecture Design

#### Architecture Components

Core Components

OLTP: PostgreSQL Aurora cluster (primary + read replicas)
OLAP: ClickHouse cluster (chosen over Redshift for real-time analytics)
Streaming: Kafka + Kafka Connect with Debezium
Cache Layer: Redis cluster for sub-second reads
Stream Processing: Apache Flink for real-time aggregations

#[OLTP Postgres] → [Logical Replication] → [Kafka] → [Stream Processor] → [OLAP Store]
#                                             ↓
#                                     [Real-time Cache]
#

┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│   Application   │───▶│  PostgreSQL      │───▶│ Logical Decode  │
│     Layer       │    │   (Aurora)       │    │  (Debezium)     │
└─────────────────┘    │                  │    └─────────────────┘
         │              │  Primary + 2x    │             │
         │              │  Read Replicas   │             │
         │              └──────────────────┘             │
         │                       │                       │
         │              ┌──────────────────┐             │
         └──────────────│  Read Replica    │             │
                        │   (< 3s lag)     │             │
                        └──────────────────┘             │
                                                          │
┌─────────────────┐    ┌──────────────────┐             │
│  Redis Cluster  │◀───│  Apache Flink    │◀────────────┘
│   (< 500ms)     │    │ Stream Processor │             │
└─────────────────┘    └──────────────────┘             │
         ▲                       │                       │
         │                       │                       ▼
         │                       ▼              ┌─────────────────┐
┌─────────────────┐    ┌──────────────────┐    │  Kafka Cluster  │
│   API Gateway   │    │   ClickHouse     │◀───│  (3 brokers)    │
│ Freshness Logic │    │ (Analytics OLAP) │    │                 │
└─────────────────┘    └──────────────────┘    └─────────────────┘
                                │
                       ┌──────────────────┐
                       │  Materialized    │
                       │     Views        │
                       │ (5min - 1hr lag) │
                       └──────────────────┘

#### Freshness Budget Matrix

| Query Type            | Use Case                     | Freshness SLA | Data Source  | Max Lag     | Fallback Strategy                 |
| --------------------- | ---------------------------- | ------------- | ------------ | ----------- | --------------------------------- |
| Critical User Actions | Asset status updates, alerts | < 1 second    | OLTP Primary | 0–500 ms    | Synchronous write + cache         |
| Dashboard Queries     | Real-time asset monitoring   | < 5 seconds   | Redis Cache  | 0.5–3 s     | Read replica if cache miss        |
| Operational Queries   | Multi-attribute filtering    | < 10 seconds  | Read Replica | 1–5 s       | Query primary if replica lag > 5s |
| Alert Evaluation      | Threshold monitoring         | < 30 seconds  | Flink Stream | 5–15 s      | Cached aggregates                 |
| Reporting Queries     | Hourly/daily reports         | < 5 minutes   | ClickHouse   | 1–5 min     | Pre-computed materialized views   |
| Analytics Queries     | Business intelligence        | < 30 minutes  | ClickHouse   | 5–30 min    | Batch-computed aggregates         |
| Historical Analysis   | Trend analysis, ML training  | < 2 hours     | ClickHouse   | 30 min–2 hr | Data lake backup                  |
| Compliance Reports    | Audit trails, compliance     | Best effort   | Data Lake    | 2–24 hr     | Archive storage                   |

### Step 7: Implementation Details
#### Replication Flow
```yaml
# Logical Replication Setup
postgresql.conf:
  - wal_level: logical
  - max_replication_slots: 10
  - max_wal_senders: 10

# Debezium Kafka Connect Configuration
debezium:
  connector: postgresql
  slot_name: "atlasco_replication"
  publication: "atlasco_publication"
  transforms:
    - type: "io.debezium.transforms.ExtractNewRecordState"
    - type: "org.apache.kafka.connect.transforms.TimestampRouter"
```

#### Freshness Detection
```
# API Response Headers
HTTP/1.1 200 OK
Content-Type: application/json
X-Data-Freshness: near-realtime
X-Data-Lag-Seconds: 2.3
X-Data-Source: read-replica
X-Query-Timestamp: 2024-01-15T14:30:45.123Z
X-Replication-Lag: 1.8
X-Cache-Hit: false
X-Freshness-Tier: NEAR_REALTIME
X-SLA-Met: true

{
  "entities": [...],
  "metadata": {
    "total_count": 1247,
    "freshness": {
      "tier": "NEAR_REALTIME",
      "lag_seconds": 2.3,
      "source": "read-replica",
      "sla_target": 10,
      "sla_met": true
    }
  }
}
```

### Step 8: ASCII Diagram

```
┌─ LAG DETECTION POINTS ─┐
                              │                        │
                              │ ①  ②   ③      ④    ⑤ │
                              └────────────────────────┘

┌─────────────────┐    [①]   ┌──────────────────┐    [②]   ┌─────────────────┐
│   Application   │──────────▶│  PostgreSQL      │──────────▶│ Logical Decode  │
│     Layer       │ Write     │   (Aurora)       │ WAL      │  (Debezium)     │
│                 │ Confirm   │                  │ Stream   │                 │
│ ┌─────────────┐ │           │  Primary + 2x    │          └─────────────────┘
│ │ Freshness   │ │           │  Read Replicas   │                    │
│ │ Router      │ │           └──────────────────┘                    │
│ └─────────────┘ │                    │                              │
│       │         │           [③]      │                              │
│       │         │   ┌──────────────────┐         [④]               │
│       │         └───│  Read Replica    │◀─────────────────┬─────────┘
│       │             │   Lag: 0.8s      │ Heartbeat        │
│       │             └──────────────────┘ Monitor          │
│       │                      │                           │
│       │                      │                           ▼
│       │             ┌──────────────────┐         ┌─────────────────┐
│       │             │  Lag Monitor     │         │  Kafka Cluster  │
│       │             │  Dashboard       │         │  (3 brokers)    │
│       │             └──────────────────┘         │                 │
│       │                                          │ Topic: entities │
│       │                                          └─────────────────┘
│       │                                                   │
│       │             ┌──────────────────┐                 │
│       └─────────────│  Redis Cluster   │◀────────────────┤
│      Cache          │   Lag: 0.3s      │ Stream          │
│      Fallback       │                  │ Process         │
│                     └──────────────────┘ (Hot Path)      │
│                              ▲                           │
│                              │          [⑤]             │
│                              │ ┌──────────────────┐     │
└──────────────────────────────┼─│  Apache Flink    │◀────┤
       Query Route             │ │ Stream Processor │     │
       Decision                │ │ Lag: 2.1s        │     │
                               │ └──────────────────┘     │
                               │          │               │
                               │          │               │
┌─────────────────┐            │          ▼               │
│   Alerting      │            │ ┌──────────────────┐     │
│   System        │◀───────────┘ │   ClickHouse     │◀────┘
│                 │              │ (Analytics OLAP) │ Stream
│ • Lag > 30s     │              │ Lag: 45s         │ Process
│ • SLA Breach    │              └──────────────────┘ (Cold Path)
│ • Source Down   │                       │
└─────────────────┘                       │
                                          ▼
                                 ┌──────────────────┐
                                 │  Materialized    │
                                 │     Views        │
                                 │ Lag: 5min-1hr    │
                                 └──────────────────┘

═══════════════════════════════════════════════════════════════════════════

LAG DETECTION & HANDLING FLOW:

① PRIMARY WRITE LAG (0-100ms)
  │ 
  ├─ INSERT heartbeat(id, timestamp)
  └─ Measure: write_confirm_time - request_time

② WAL DECODE LAG (100ms-2s)  
  │
  ├─ Monitor: pg_stat_replication.replay_lag
  └─ Alert if > 5s

③ REPLICA LAG (0.5s-10s)
  │
  ├─ SELECT heartbeat WHERE id=X (every 5s)
  └─ Measure: found_time - inserted_time
  
④ KAFKA LAG (1s-30s)
  │
  ├─ Monitor: kafka_consumer_lag_seconds metric
  └─ Circuit breaker if lag > 60s

⑤ STREAM PROCESSING LAG (2s-60s)
  │
  ├─ Flink watermarks + event time processing
  └─ Measure: processing_time - event_timestamp

ROUTING DECISION TREE:
┌─ Query arrives with freshness requirement
│
├─ REALTIME (<1s): 
│  ├─ Primary available? → Primary
│  ├─ Cache fresh (<5s)? → Redis  
│  └─ Else → Primary (force)
│
├─ NEAR_REALTIME (<10s):
│  ├─ Replica lag <5s? → Replica
│  ├─ Cache fresh? → Redis
│  └─ Else → Primary
│
└─ EVENTUAL (>10s):
   ├─ ClickHouse lag <60s? → ClickHouse
   └─ Else → Replica

FAILURE HANDLING:
┌─ Source Unavailable ─┐    ┌─ High Lag Detected ─┐
│                      │    │                     │
│ Primary Down         │    │ Replica lag > 10s   │
│ ├─ Route to Replica  │    │ ├─ Route to Primary │
│ └─ Alert Ops         │    │ └─ Update SLA       │
│                      │    │                     │
│ Replica Down         │    │ Kafka lag > 60s     │
│ ├─ Route to Primary  │    │ ├─ Circuit Breaker  │
│ └─ Scale up          │    │ └─ Route to Replica │
└──────────────────────┘    └─────────────────────┘
```

## Part C: Infrastructure as Code 

### Step 9: Terraform Implementation

```hcl
# variables.tf
variable "environment" {
  description = "Environment name"
  type        = string
  default     = "dev"
}

variable "postgres_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.r6g.xlarge"
}

# main.tf
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# VPC and Networking
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name        = "atlasco-${var.environment}"
    Environment = var.environment
  }
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.${count.index + 1}.0/24"
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name = "atlasco-private-${count.index + 1}"
  }
}

# Security Groups
resource "aws_security_group" "postgres" {
  name_prefix = "atlasco-postgres-"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# RDS PostgreSQL
resource "aws_db_subnet_group" "postgres" {
  name       = "atlasco-postgres-${var.environment}"
  subnet_ids = aws_subnet.private[*].id

  tags = {
    Name = "Atlasco Postgres DB subnet group"
  }
}

resource "aws_rds_cluster" "postgres" {
  cluster_identifier     = "atlasco-postgres-${var.environment}"
  engine                = "aurora-postgresql"
  engine_version        = "15.4"
  database_name         = "atlasco"
  master_username       = "atlasco_admin"
  manage_master_user_password = true
  
  db_subnet_group_name   = aws_db_subnet_group.postgres.name
  vpc_security_group_ids = [aws_security_group.postgres.id]
  
  backup_retention_period = var.environment == "prod" ? 7 : 1
  preferred_backup_window = "03:00-04:00"
  
  enabled_cloudwatch_logs_exports = ["postgresql"]
  
  # Performance and scaling settings
  serverlessv2_scaling_configuration {
    max_capacity = var.environment == "prod" ? 64 : 8
    min_capacity = var.environment == "prod" ? 8 : 0.5
  }

  tags = {
    Environment = var.environment
  }
}

# Redshift Cluster
resource "aws_redshift_cluster" "analytics" {
  cluster_identifier = "atlasco-analytics-${var.environment}"
  database_name      = "analytics"
  master_username    = "atlasco_analytics"
  manage_master_password = true
  
  node_type       = var.environment == "prod" ? "dc2.large" : "dc2.large"
  number_of_nodes = var.environment == "prod" ? 3 : 1
  
  cluster_subnet_group_name = aws_redshift_subnet_group.analytics.name
  vpc_security_group_ids    = [aws_security_group.redshift.id]
  
  skip_final_snapshot = var.environment != "prod"
  
  tags = {
    Environment = var.environment
  }
}

# Environment-specific configurations
locals {
  env_configs = {
    dev = {
      postgres_instance_class = "db.r6g.large"
      postgres_allocated_storage = 100
      redshift_node_type = "dc2.large"
      redshift_number_of_nodes = 1
    }
    prod = {
      postgres_instance_class = "db.r6g.2xlarge"
      postgres_allocated_storage = 1000
      redshift_node_type = "dc2.large"
      redshift_number_of_nodes = 3
    }
  }
}
```

### Step 10: Final Deliverables Structure

```
kernel-takehome/
├── solution.md          # Main design document
├── schema.sql          # PostgreSQL DDL and queries
├── infra/
│   ├── main.tf
│   ├── variables.tf
│   └── outputs.tf
└── notes.md            # TODOs and assumptions
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


