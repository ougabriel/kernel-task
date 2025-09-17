
# main.tf
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
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
