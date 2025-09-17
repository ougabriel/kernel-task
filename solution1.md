# Kernel Take-Home Complete Guide: EAV at Scale

## Overview & Time Management
- **Total Time**: 2 hours
- **Part A**: 55-65 min (EAV Schema & Queries)
- **Part B**: 30-35 min (Freshness & Replication)
- **Part C**: 20-25 min (Infrastructure as Code)

## Part A: Data Model & Querying (55-65 minutes)

### Step 1: Understand the Requirements (5 minutes)
- 200M entities (assets)
- 10,000 dynamic attribute types
- High write throughput (10k inserts/sec)
- Support both operational (low-latency) and analytical queries
- Multi-tenant system

### Step 2: Design the Core Schema (15 minutes)

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

### Step 3: Partitioning Strategy (10 minutes)

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

### Step 5: Write Example Queries (15 minutes)

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

## Part B: Read Freshness & Replication (30-35 minutes)

### Step 6: Replication Architecture Design (15 minutes)

#### Architecture Components
```
[OLTP Postgres] → [Logical Replication] → [Kafka] → [Stream Processor] → [OLAP Store]
                                             ↓
                                      [Real-time Cache]
```

#### Freshness Budget Matrix
| Query Type | Freshness Requirement | Data Source | Max Lag |
|------------|----------------------|-------------|---------|
| User Dashboard | Immediate (< 1s) | OLTP Primary + Cache | 0-1s |
| Alert Queries | Near Real-time | OLTP Read Replica | 1-5s |
| Operational Reports | Recent (< 30s) | Kafka Stream | 5-30s |
| Analytics Queries | Eventually Consistent | OLAP Store | 1-15 min |
| Historical Analysis | Batch Consistent | OLAP Store | 1-24 hours |

### Step 7: Implementation Details (10 minutes)

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
```python
# API Response Headers
{
    "X-Data-Freshness": "realtime",  # realtime, near-realtime, eventual
    "X-Data-Lag-Seconds": "0.5",
    "X-Data-Source": "primary",       # primary, replica, cache, olap
    "X-Query-Timestamp": "2024-01-15T10:30:00Z"
}
```

### Step 8: ASCII Diagram (5 minutes)

```
┌─────────────┐    ┌──────────────┐    ┌─────────────┐    ┌──────────────┐
│   App/API   │───▶│ OLTP Primary │───▶│   Logical   │───▶│    Kafka     │
└─────────────┘    │  (Postgres)  │    │ Replication │    │   Topics     │
       │           └──────────────┘    └─────────────┘    └──────────────┘
       │                    │                                      │
       │           ┌──────────────┐                                │
       └───────────│ Read Replica │                                │
                   │  (< 5s lag)  │                                │
                   └──────────────┘                                │
                                                                   │
┌─────────────┐    ┌──────────────┐    ┌─────────────┐            │
│   Redis     │◀───│ Stream Proc. │◀───│   Kafka     │◀───────────┘
│   Cache     │    │  (Flink)     │    │  Consumer   │
└─────────────┘    └──────────────┘    └─────────────┘
                            │
                   ┌──────────────┐
                   │    OLAP      │
                   │ (ClickHouse) │
                   └──────────────┘
```

## Part C: Infrastructure as Code (20-25 minutes)

### Step 9: Terraform Implementation (20 minutes)

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

### Step 10: Final Deliverables Structure (5 minutes)

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

## Time-Saving Tips

1. **Focus on the core requirements** - don't over-engineer
2. **Use proven patterns** - EAV with GIN indexes, logical replication
3. **Be explicit about trade-offs** - they want to see your judgment
4. **Keep IaC simple but realistic** - show structure, not every detail
5. **Document assumptions** - tenancy model, data retention, etc.

## Final Checklist

- [ ] Schema handles 200M entities efficiently
- [ ] Partitioning strategy explained
- [ ] Both operational and analytical queries provided
- [ ] Freshness matrix completed
- [ ] Replication architecture documented
- [ ] Terraform code is parameterized
- [ ] Trade-offs explicitly called out
- [ ] TODOs documented in notes.md
