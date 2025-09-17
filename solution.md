# Atlas Telemetry Platform - Senior Engineer Take-Home Solution

## Executive Summary

This solution provides a pragmatic, scalable architecture for AtlasCo's telemetry ingestion platform, targeting 10k inserts/sec with 200M entities and 10k dynamic attributes. The design balances operational performance with analytical flexibility through a hybrid EAV approach, clear data freshness boundaries, and infrastructure automation.

## Part A: Data Model & Querying Strategy

### Schema Design Philosophy

**Hybrid EAV + Columnar Approach**: Rather than pure EAV (which becomes a performance bottleneck) or pure columnar (which lacks flexibility), I've implemented a three-table design:

1. **`entities`** - Core entity metadata with tenant isolation
2. **`entity_hot_attributes`** - Pre-defined columns for frequently queried attributes  
3. **`entity_attributes`** - Pure EAV for dynamic/sparse attributes

This approach provides:
- **Fast operational queries** via hot attributes table with proper indexes
- **Flexible analytical queries** via EAV attributes table
- **Tenant isolation** built into the partition key
- **Time-based archiving** capability for compliance/cost management

### Partitioning & Scaling Strategy

**Multi-Level Partitioning:**
```
entities/hot_attributes: PARTITION BY HASH (tenant_id) -- 10+ partitions
entity_attributes: PARTITION BY HASH (tenant_id) 
                   SUB-PARTITION BY RANGE (created_at) -- Monthly/weekly
```

**Scaling Strategy:**
- **Horizontal**: Hash partitioning by tenant_id enables easy shard distribution
- **Vertical**: Time-based sub-partitioning enables hot/cold data separation
- **Read Scaling**: Dedicated read replicas for different workload patterns
- **Write Scaling**: Connection pooling + async batch inserts

### Indexing Strategy

**Operational Indexes (Low Latency):**
- Composite indexes on tenant_id + frequently filtered hot attributes
- Partial indexes on recent data (last 7 days) for operational queries
- GIN indexes for flexible multi-attribute searches

**Analytical Indexes (Throughput):**
- Covering indexes for common aggregation patterns
- Expression indexes for computed values
- Minimal indexing on cold partitions to reduce maintenance overhead

### Query Performance Analysis

**Operational Query Pattern:**
- Target: <100ms response time
- Strategy: Leverage hot attributes + recent data partial indexes
- Partition pruning reduces scan scope by 10x+
- Expected performance: 50-200ms for complex multi-attribute filters

**Analytical Query Pattern:**
- Target: 1-30 second response time
- Strategy: Parallel partition scans + aggregation pushdown
- Time-based partition pruning for historical analysis
- Expected performance: 2-15 seconds for large aggregations

## Part B: Read Freshness & Replication Architecture

### Architecture Overview

```
┌─────────────┐    ┌──────────────┐    ┌─────────────┐    ┌─────────────┐
│   App       │    │  PostgreSQL  │    │   Kafka     │    │ ClickHouse  │
│ Writes      │───▶│   Primary    │───▶│  (Debezium) │───▶│   OLAP      │
└─────────────┘    │              │    └─────────────┘    └─────────────┘
                   │              │
                   ▼              
                ┌─────────────────┐
                │   Read Replica  │
                │  (Sync/Async)   │
                └─────────────────┘
```

### Freshness Budget Matrix

| Use Case | Freshness SLA | Target System | Acceptable Lag | Fallback |
|----------|--------------|---------------|----------------|----------|
| Real-time alerts | <100ms | Primary DB | 0ms | None |
| Dashboard status | <1s | Read Replica | 100-500ms | Primary |
| Operational reports | <30s | Read Replica | 1-10s | Primary |
| Analytics dashboards | <5min | OLAP | 30s-300s | Read Replica |
| Historical analysis | <1hr | OLAP | 5-60min | Batch export |
| ML training | <24hr | Data Lake | 1-24hr | OLAP export |

### Replication Implementation

**PostgreSQL Logical Replication → Kafka:**
```yaml
debezium_config:
  name: "atlas-postgres-connector"
  connector_class: "io.debezium.connector.postgresql.PostgresConnector"
  database_hostname: "atlas-postgres-primary"
  database_port: 5432
  database_user: "debezium_user"
  database_dbname: "atlas_telemetry"
  table_include_list: "public.entities,public.entity_hot_attributes,public.entity_attributes"
  plugin_name: "pgoutput"
  slot_name: "debezium_atlas_slot"
  transforms: "route,flatten"
  transforms_route_type: "org.apache.kafka.connect.transforms.RegexRouter"
  transforms_route_regex: "public.entity_(.*)"
  transforms_route_replacement: "atlas.entity_$1"
```

**Kafka Topics Strategy:**
- `atlas.entities` - partitioned by tenant_id (10 partitions)
- `atlas.entity_hot_attributes` - partitioned by tenant_id 
- `atlas.entity_attributes` - partitioned by tenant_id

**ClickHouse Sink Configuration:**
```sql
-- Denormalized analytics table in ClickHouse
CREATE TABLE entity_analytics_events (
    entity_id UInt64,
    tenant_id UInt32,
    asset_type String,
    attribute_key String,
    attribute_value String,
    attribute_type String,
    event_timestamp DateTime64(3),
    ingestion_timestamp DateTime64(3) DEFAULT now64()
) ENGINE = ReplacingMergeTree(ingestion_timestamp)
PARTITION BY toYYYYMM(event_timestamp)
ORDER BY (tenant_id, entity_id, attribute_key, event_timestamp);
```

### Freshness Detection & API Design

**API Freshness Headers:**
```http
GET /api/v1/entities/123/status
X-Data-Source: primary|replica|olap
X-Data-Freshness-Ms: 150
X-Data-Timestamp: 2024-12-10T15:30:45.123Z
X-Replication-Lag-Ms: 45
```

**Lag Detection Logic:**
```python
def get_data_freshness_info(query_type: str, tenant_id: int):
    if query_type == "realtime":
        return {
            "source": "primary",
            "max_acceptable_lag_ms": 100,
            "fallback_source": None
        }
    elif query_type == "operational":
        replica_lag = get_replica_lag_ms()
        if replica_lag < 1000:
            return {"source": "replica", "lag_ms": replica_lag}
        else:
            return {"source": "primary", "lag_ms": 0}
    elif query_type == "analytical":
        olap_lag = get_olap_lag_ms(tenant_id)
        if olap_lag < 300000:  # 5 minutes
            return {"source": "olap", "lag_ms": olap_lag}
        else:
            return {"source": "replica", "lag_ms": get_replica_lag_ms()}
```

**Lag Monitoring:**
- PostgreSQL: `pg_stat_replication` for replica lag
- Kafka: Consumer group lag monitoring via JMX
- ClickHouse: Watermark tracking via ingestion timestamps

## Part C: Infrastructure as Code

### Terraform Structure

The infrastructure is organized into reusable modules with environment-specific parameterization:

```
infra/
├── main.tf           # Main resource definitions
├── variables.tf      # Input variables and validation
├── outputs.tf        # Resource outputs
├── environments/
│   ├── dev.tfvars   # Development configuration
│   └── prod.tfvars  # Production configuration
```

### Key Design Decisions

**Multi-AZ Deployment:**
- Aurora PostgreSQL with cross-AZ read replicas
- Redshift in multiple AZs for high availability
- VPC subnets across 2+ availability zones

**Security:**
- Private subnets for database resources
- Security groups with principle of least privilege
- RDS encryption at rest and in transit
- Parameter Store for sensitive configuration

**Monitoring & Observability:**
- CloudWatch logs integration for both RDS and Redshift
- Performance Insights for PostgreSQL query analysis
- Custom CloudWatch metrics for application-level monitoring

### Environment Parameterization Example

```hcl
# Development environment
rds_instance_class    = "db.r6g.large"      # 2 vCPU, 16GB RAM
rds_allocated_storage = 100                 # 100GB storage
redshift_node_type    = "dc2.large"         # 2 vCPU, 15GB RAM
redshift_cluster_size = 1                   # Single node

# Production environment  
rds_instance_class    = "db.r6g.2xlarge"   # 8 vCPU, 64GB RAM
rds_allocated_storage = 1000                # 1TB storage
redshift_node_type    = "ra3.xlplus"       # 4 vCPU, 32GB RAM, managed storage
redshift_cluster_size = 3                   # Multi-node for performance
```

## Trade-offs & Operational Considerations

### Design Strengths

✅ **High Write Throughput**: Partitioned tables + batch inserts achieve 10k+/sec target
✅ **Flexible Querying**: Hybrid EAV enables both operational and analytical workloads  
✅ **Tenant Isolation**: Hash partitioning by tenant_id provides natural boundaries
✅ **Clear Freshness Boundaries**: Explicit SLAs for different query types
✅ **Operational Maturity**: Comprehensive monitoring and alerting built-in

### Design Limitations & Mitigations

⚠️ **Complex Query Planning**: 
- *Issue*: EAV joins can confuse PostgreSQL query planner
- *Mitigation*: Hot attributes table, query hints, pg_stat_statements monitoring

⚠️ **Index Maintenance Overhead**:
- *Issue*: Many indexes on high-write tables cause maintenance overhead  
- *Mitigation*: Partial indexes, regular REINDEX scheduling, index usage monitoring

⚠️ **Cross-Tenant Analytics Complexity**:
- *Issue*: Hash partitioning by tenant makes cross-tenant queries expensive
- *Mitigation*: Dedicated OLAP system for cross-tenant analytics, materialized views

⚠️ **Hot Partition Risk**:
- *Issue*: Large tenants could create hot partitions
- *Mitigation*: Monitor partition sizes, consider composite partitioning for largest tenants

### Fallback Strategies

**Scale Break Points:**
- **1B+ entities**: Consider PostgreSQL clustering (Citus) or migration to distributed system
- **100k+ inserts/sec**: Move to event streaming architecture (Kafka + KSQL)  
- **Complex analytics**: Add specialized OLAP engine (ClickHouse, BigQuery)
- **Global scale**: Add read replicas in multiple regions

**Operational Playbooks:**
- **High replica lag**: Automatic failover to primary for critical queries
- **Partition key hotspots**: Dynamic partition splitting via pg_partman
- **Index bloat**: Automated REINDEX scheduling based on bloat percentage
- **Query performance regression**: Automatic query plan analysis and alerting

## Monitoring & Alerting Strategy

### Key Metrics

**Throughput Metrics:**
- Insert rate per second (target: >10k/sec)
- Query latency p95/p99 by query type
- Partition pruning effectiveness rate

**Health Metrics:**  
- Replication lag (PostgreSQL, Kafka, ClickHouse)
- Index bloat percentage
- Partition size distribution
- Connection pool utilization

**Business Metrics:**
- Data freshness SLA compliance by use case
- Query success rate by tenant
- Attribute cardinality trends (for hot attribute candidates)

### Operational Runbooks

**High Write Latency:**
1. Check connection pool saturation
2. Analyze slow query log for lock contention  
3. Verify partition pruning is working
4. Scale write capacity if needed

**Replication Lag Spike:**
1. Check Kafka consumer lag
2. Verify ClickHouse ingestion rate
3. Scale Kafka partitions or ClickHouse nodes
4. Implement backpressure if needed

**Query Performance Degradation:**
1. Run EXPLAIN ANALYZE on affected queries
2. Check for missing/unused indexes
3. Update table statistics if needed
4. Consider query rewriting or new indexes

This architecture provides a solid foundation for AtlasCo's telemetry platform with clear scaling paths and operational maturity built-in from day one.
