# main.tf - Atlas Telemetry Platform Infrastructure
# Provisions Aurora PostgreSQL + Redshift + VPC for high-scale OLTP/OLAP workloads

terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
  
  default_tags {
    tags = var.common_tags
  }
}

# Data sources
data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

# Local values for environment-specific configuration
locals {
  # Subnet CIDR calculations
  private_subnet_cidrs = [for i in range(3) : cidrsubnet(var.vpc_cidr, 4, i + 1)]
  public_subnet_cidrs  = [for i in range(2) : cidrsubnet(var.vpc_cidr, 4, i + 10)]
  
  # Environment-specific settings
  is_production = var.environment == "prod"
  nat_gateway_count = local.is_production ? 2 : 1
  
  # Resource naming
  name_prefix = "${var.project_name}-${var.environment}"
}

#------------------------------------------------------------------------------
# VPC and Networking
#------------------------------------------------------------------------------

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
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

# Private subnets for databases (multi-AZ)
resource "aws_subnet" "private" {
  count = 3
  
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.private_subnet_cidrs[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]
  
  tags = {
    Name = "${local.name_prefix}-private-subnet-${count.index + 1}"
    Type = "private"
  }
}

# Public subnets for NAT gateways
resource "aws_subnet" "public" {
  count = 2
  
  vpc_id                  = aws_vpc.main.id
  cidr_block              = local.public_subnet_cidrs[count.index]
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true
  
  tags = {
    Name = "${local.name_prefix}-public-subnet-${count.index + 1}"
    Type = "public"
  }
}

# Elastic IPs for NAT gateways
resource "aws_eip" "nat" {
  count  = local.nat_gateway_count
  domain = "vpc"
  
  depends_on = [aws_internet_gateway.main]
  
  tags = {
    Name = "${local.name_prefix}-nat-eip-${count.index + 1}"
  }
}

# NAT gateways for outbound connectivity
resource "aws_nat_gateway" "main" {
  count = local.nat_gateway_count
  
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  
  depends_on = [aws_internet_gateway.main]
  
  tags = {
    Name = "${local.name_prefix}-nat-${count.index + 1}"
  }
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
  count  = local.nat_gateway_count
  vpc_id = aws_vpc.main.id
  
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[count.index].id
  }
  
  tags = {
    Name = "${local.name_prefix}-private-rt-${count.index + 1}"
  }
}

# Route table associations
resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)
  
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count = length(aws_subnet.private)
  
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index % local.nat_gateway_count].id
}

#------------------------------------------------------------------------------
# Security Groups
#------------------------------------------------------------------------------

# Application security group
resource "aws_security_group" "app" {
  name_prefix = "${local.name_prefix}-app"
  vpc_id      = aws_vpc.main.id
  description = "Security group for Atlas application servers"
  
  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  egress {
    description = "All outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  tags = {
    Name = "${local.name_prefix}-app-sg"
  }
}

# Aurora PostgreSQL security group
resource "aws_security_group" "aurora" {
  name_prefix = "${local.name_prefix}-aurora"
  vpc_id      = aws_vpc.main.id
  description = "Security group for Aurora PostgreSQL cluster"

  ingress {
    description     = "PostgreSQL from application"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }
  
  egress {
    description = "All outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  tags = {
    Name = "${local.name_prefix}-aurora-sg"
  }
}

# Redshift security group
resource "aws_security_group" "redshift" {
  name_prefix = "${local.name_prefix}-redshift"
  vpc_id      = aws_vpc.main.id
  description = "Security group for Redshift cluster"

  ingress {
    description     = "Redshift from application"
    from_port       = 5439
    to_port         = 5439
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }
  
  # Allow Aurora to connect for data transfers
  ingress {
    description     = "Redshift from Aurora"
    from_port       = 5439
    to_port         = 5439
    protocol        = "tcp"
    security_groups = [aws_security_group.aurora.id]
  }
  
  egress {
    description = "All outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  tags = {
    Name = "${local.name_prefix}-redshift-sg"
  }
}

#------------------------------------------------------------------------------
# Database Subnet Groups
#------------------------------------------------------------------------------

resource "aws_db_subnet_group" "aurora" {
  name       = "${local.name_prefix}-aurora-subnet-group"
  subnet_ids = aws_subnet.private[*].id
  
  tags = {
    Name = "${local.name_prefix}-aurora-subnet-group"
  }
}

resource "aws_redshift_subnet_group" "main" {
  name       = "${local.name_prefix}-redshift-subnet-group"
  subnet_ids = aws_subnet.private[*].id
  
  tags = {
    Name = "${local.name_prefix}-redshift-subnet-group"
  }
}

#------------------------------------------------------------------------------
# IAM Roles
#------------------------------------------------------------------------------

# IAM role for RDS enhanced monitoring
resource "aws_iam_role" "rds_monitoring" {
  name = "${local.name_prefix}-rds-monitoring-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "monitoring.rds.amazonaws.com"
        }
      }
    ]
  })
  
  tags = {
    Name = "${local.name_prefix}-rds-monitoring-role"
  }
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

#------------------------------------------------------------------------------
# Aurora PostgreSQL Cluster
#------------------------------------------------------------------------------

resource "aws_rds_cluster" "aurora" {
  cluster_identifier     = "${local.name_prefix}-aurora"
  engine                = "aurora-postgresql"
  engine_version        = var.aurora_engine_version
  database_name         = var.database_name
  master_username       = var.database_username
  manage_master_user_password = true
  
  # Network configuration
  vpc_security_group_ids = [aws_security_group.aurora.id]
  db_subnet_group_name   = aws_db_subnet_group.aurora.name
  
  # Backup and maintenance
  backup_retention_period   = var.backup_retention_days
  preferred_backup_window   = var.backup_window
  preferred_maintenance_window = var.maintenance_window
  
  # Performance and monitoring
  enabled_cloudwatch_logs_exports = ["postgresql"]
  storage_encrypted              = true
  deletion_protection           = var.enable_deletion_protection
  
  # Serverless v2 scaling
  serverlessv2_scaling_configuration {
    max_capacity = var.aurora_max_capacity
    min_capacity = var.aurora_min_capacity
  }
  
  tags = {
    Name = "${local.name_prefix}-aurora-cluster"
    Type = "oltp"
  }
}

# Aurora cluster instances
resource "aws_rds_cluster_instance" "aurora" {
  count              = var.aurora_instance_count
  identifier         = "${local.name_prefix}-aurora-${count.index}"
  cluster_identifier = aws_rds_cluster.aurora.id
  instance_class     = var.aurora_instance_class
  engine             = aws_rds_cluster.aurora.engine
  engine_version     = aws_rds_cluster.aurora.engine_version
  
  # Performance monitoring
  performance_insights_enabled = var.enable_performance_insights
  performance_insights_retention_period = var.performance_insights_retention
  monitoring_interval         = var.monitoring_interval
  monitoring_role_arn        = var.monitoring_interval > 0 ? aws_iam_role.rds_monitoring.arn : null
  
  # Instance role (first is writer, rest are readers)
  promotion_tier = count.index == 0 ? 0 : 1
  
  tags = {
    Name = "${local.name_prefix}-aurora-${count.index}"
    Role = count.index == 0 ? "writer" : "reader"
  }
}

#------------------------------------------------------------------------------
# Redshift Cluster
#------------------------------------------------------------------------------

resource "aws_redshift_cluster" "main" {
  cluster_identifier        = "${local.name_prefix}-redshift"
  database_name            = var.redshift_database_name
  master_username          = var.redshift_username
  manage_master_password   = true
  node_type                = var.redshift_node_type
  number_of_nodes          = var.redshift_node_count > 1 ? var.redshift_node_count : null
  
  # Network configuration
  vpc_security_group_ids    = [aws_security_group.redshift.id]
  cluster_subnet_group_name = aws_redshift_subnet_group.main.name
  publicly_accessible      = false
  
  # Security and compliance
  encrypted                = true
  enhanced_vpc_routing     = true
  skip_final_snapshot     = !var.enable_final_snapshot
  final_snapshot_identifier = var.enable_final_snapshot ? "${local.name_prefix}-redshift-final-${formatdate("YYYY-MM-DD-hhmm", timestamp())}" : null
  
  # Maintenance and backup
  preferred_maintenance_window = var.redshift_maintenance_window
  automated_snapshot_retention_period = var.redshift_snapshot_retention
  
  tags = {
    Name = "${local.name_prefix}-redshift-cluster"
    Type = "olap"
  }
}
