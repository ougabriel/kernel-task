# ============================================================================
# VPC AND NETWORKING
# ============================================================================

resource "aws_vpc" "main" {
  cidr_block           = local.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${local.name_prefix}-vpc"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-igw"
  }
}

# Public subnets for NAT gateways
resource "aws_subnet" "public" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(local.vpc_cidr, 8, count.index)
  availability_zone = data.aws_availability_zones.available.names[count.index]
  
  map_public_ip_on_launch = true

  tags = {
    Name = "${local.name_prefix}-public-${count.index + 1}"
    Type = "public"
  }
}

# Private subnets for databases
resource "aws_subnet" "private" {
  count             = 3
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(local.vpc_cidr, 8, count.index + 10)
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name = "${local.name_prefix}-private-${count.index + 1}"
    Type = "private"
  }
}

# NAT Gateway for outbound internet access from private subnets
resource "aws_eip" "nat" {
  count  = local.config.enable_nat_gateway ? 1 : 0
  domain = "vpc"

  tags = {
    Name = "${local.name_prefix}-nat-eip"
  }
}

resource "aws_nat_gateway" "main" {
  count         = local.config.enable_nat_gateway ? 1 : 0
  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[0].id

  tags = {
    Name = "${local.name_prefix}-nat"
  }

  depends_on = [aws_internet_gateway.main]
}

# Route tables
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${local.name_prefix}-public-rt"
  }
}

resource "aws_route_table" "private" {
  count  = local.config.enable_nat_gateway ? 1 : 0
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[0].id
  }

  tags = {
    Name = "${local.name_prefix}-private-rt"
  }
}

# Route table associations
resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count          = local.config.enable_nat_gateway ? length(aws_subnet.private) : 0
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[0].id
}

# ============================================================================
# SECURITY GROUPS
# ============================================================================

resource "aws_security_group" "aurora" {
  name_prefix = "${local.name_prefix}-aurora-"
  vpc_id      = aws_vpc.main.id
  description = "Security group for Aurora PostgreSQL cluster"

  dynamic "ingress" {
    for_each = local.aurora_ingress_rules
    content {
      description     = ingress.value.description
      from_port       = ingress.value.from_port
      to_port         = ingress.value.to_port
      protocol        = ingress.value.protocol
      security_groups = ingress.value.security_groups
      cidr_blocks     = ingress.value.cidr_blocks
      self            = lookup(ingress.value, "self", null)
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "All outbound traffic"
  }

  tags = {
    Name = "${local.name_prefix}-aurora-sg"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "redshift" {
  name_prefix = "${local.name_prefix}-redshift-"
  vpc_id      = aws_vpc.main.id
  description = "Security group for Redshift cluster"

  dynamic "ingress" {
    for_each = local.redshift_ingress_rules
    content {
      description     = ingress.value.description
      from_port       = ingress.value.from_port
      to_port         = ingress.value.to_port
      protocol        = ingress.value.protocol
      security_groups = ingress.value.security_groups
      cidr_blocks     = ingress.value.cidr_blocks
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "All outbound traffic"
  }

  tags = {
    Name = "${local.name_prefix}-redshift-sg"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "application" {
  name_prefix = "${local.name_prefix}-app-"
  vpc_id      = aws_vpc.main.id
  description = "Security group for application services"

  # Application ingress rules would go here
  # (HTTP, HTTPS, etc. - depends on your application architecture)

  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS outbound"
  }

  egress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTP outbound"
  }

  tags = {
    Name = "${local.name_prefix}-app-sg"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ============================================================================
# KMS KEY FOR ENCRYPTION
# ============================================================================

resource "aws_kms_key" "main" {
  description             = "KMS key for ${var.project_name} ${var.environment} encryption"
  deletion_window_in_days = 7

  tags = {
    Name = "${local.name_prefix}-kms"
  }
}

resource "aws_kms_alias" "main" {
  name          = "alias/${local.name_prefix}"
  target_key_id = aws_kms_key.main.key_id
}

# ============================================================================
# AURORA POSTGRESQL CLUSTER
# ============================================================================

resource "random_password" "aurora_master_password" {
  length  = 32
  special = true
}

resource "aws_db_subnet_group" "aurora" {
  name       = "${local.name_prefix}-aurora-subnet-group"
  subnet_ids = aws_subnet.private[*].id

  tags = {
    Name = "${local.name_prefix}-aurora-subnet-group"
  }
}

resource "aws_rds_cluster_parameter_group" "aurora" {
  family = "aurora-postgresql15"
  name   = "${local.name_prefix}-aurora-cluster-pg"

  # EAV optimization parameters
  parameter {
    name  = "shared_preload_libraries"
    value = "pg_stat_statements"
  }

  parameter {
    name  = "max_connections"
    value = "2000"
  }

  parameter {
    name  = "work_mem"
    value = "32768"  # 32MB
  }

  parameter {
    name  = "maintenance_work_mem"
    value = "1048576"  # 1GB
  }

  # Logical replication for Debezium
  parameter {
    name  = "wal_level"
    value = "logical"
  }

  parameter {
    name  = "max_replication_slots"
    value = "10"
  }

  parameter {
    name  = "max_wal_senders"
    value = "10"
  }
}

resource "aws_rds_cluster" "main" {
  cluster_identifier     = "${local.name_prefix}-aurora"
  engine                = "aurora-postgresql"
  engine_version        = "15.4"
  database_name         = replace(var.project_name, "-", "")
  master_username       = "atlasco_admin"
  master_password       = random_password.aurora_master_password.result

  db_subnet_group_name            = aws_db_subnet_group.aurora.name
  vpc_security_group_ids          = [aws_security_group.aurora.id]
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.aurora.name

  backup_retention_period      = local.backup_retention_days
  preferred_backup_window      = "03:00-04:00"
  preferred_maintenance_window = "sun:04:00-sun:05:00"
  
  enabled_cloudwatch_logs_exports = ["postgresql"]
  
  serverlessv2_scaling_configuration {
    max_capacity = local.config.aurora_max_capacity
    min_capacity = local.config.aurora_min_capacity
  }

  storage_encrypted   = true
  kms_key_id         = aws_kms_key.main.arn
  deletion_protection = local.enable_deletion_protection
  skip_final_snapshot = !local.enable_deletion_protection

  tags = {
    Name = "${local.name_prefix}-aurora"
  }
}

resource "aws_rds_cluster_instance" "cluster_instances" {
  count              = local.config.aurora_instance_count
  identifier         = "${local.name_prefix}-aurora-${count.index}"
  cluster_identifier = aws_rds_cluster.main.id
  instance_class     = local.config.aurora_instance_class
  engine             = aws_rds_cluster.main.engine
  engine_version     = aws_rds_cluster.main.engine_version

  performance_insights_enabled = local.config.enable_performance_insights
  monitoring_interval         = local.config.enable_enhanced_monitoring ? 60 : 0

  tags = {
    Name = "${local.name_prefix}-aurora-${count.index}"
  }
}

# ============================================================================
# REDSHIFT CLUSTER
# ============================================================================

resource "random_password" "redshift_master_password" {
  length  = 32
  special = false  # Redshift doesn't support all special characters
}

resource "aws_redshift_subnet_group" "main" {
  name       = "${local.name_prefix}-redshift-subnet-group"
  subnet_ids = aws_subnet.private[*].id

  tags = {
    Name = "${local.name_prefix}-redshift-subnet-group"
  }
}

resource "aws_redshift_cluster" "main" {
  cluster_identifier = "${local.name_prefix}-redshift"
  
  database_name   = replace(var.project_name, "-", "")
  master_username = "atlasco_analytics"
  master_password = random_password.redshift_master_password.result
  
  node_type       = local.config.redshift_node_type
  number_of_nodes = local.config.redshift_cluster_nodes
  
  cluster_subnet_group_name = aws_redshift_subnet_group.main.name
  vpc_security_group_ids    = [aws_security_group.redshift.id]
  publicly_accessible       = false
  
  encrypted  = true
  kms_key_id = aws_kms_key.main.arn
  
  automated_snapshot_retention_period = local.backup_retention_days
  preferred_maintenance_window         = "sun:05:00-sun:06:00"
  
  skip_final_snapshot = !local.enable_deletion_protection

  tags = {
    Name = "${local.name_prefix}-redshift"
  }
}
