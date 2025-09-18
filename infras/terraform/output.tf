# ============================================================================
# NETWORK OUTPUTS
# ============================================================================

output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.main.id
}

output "vpc_cidr_block" {
  description = "CIDR block of the VPC"
  value       = aws_vpc.main.cidr_block
}

output "public_subnet_ids" {
  description = "IDs of the public subnets"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "IDs of the private subnets"
  value       = aws_subnet.private[*].id
}

output "availability_zones" {
  description = "Availability zones used"
  value       = aws_subnet.private[*].availability_zone
}

# ============================================================================
# SECURITY GROUP OUTPUTS
# ============================================================================

output "aurora_security_group_id" {
  description = "Security group ID for Aurora PostgreSQL"
  value       = aws_security_group.aurora.id
}

output "redshift_security_group_id" {
  description = "Security group ID for Redshift"
  value       = aws_security_group.redshift.id
}

output "application_security_group_id" {
  description = "Security group ID for application services"
  value       = aws_security_group.application.id
}

# ============================================================================
# AURORA POSTGRESQL OUTPUTS
# ============================================================================

output "aurora_cluster_identifier" {
  description = "Aurora cluster identifier"
  value       = aws_rds_cluster.main.cluster_identifier
}

output "aurora_cluster_endpoint" {
  description = "Aurora cluster writer endpoint"
  value       = aws_rds_cluster.main.endpoint
}

output "aurora_cluster_reader_endpoint" {
  description = "Aurora cluster reader endpoint"
  value       = aws_rds_cluster.main.reader_endpoint
}

output "aurora_cluster_port" {
  description = "Aurora cluster port"
  value       = aws_rds_cluster.main.port
}

output "aurora_database_name" {
  description = "Aurora database name"
  value       = aws_rds_cluster.main.database_name
}

output "aurora_master_username" {
  description = "Aurora master username"
  value       = aws_rds_cluster.main.master_username
  sensitive   = true
}

output "aurora_instance_identifiers" {
  description = "Aurora instance identifiers"
  value       = aws_rds_cluster_instance.cluster_instances[*].identifier
}

# ============================================================================
# REDSHIFT OUTPUTS
# ============================================================================

output "redshift_cluster_identifier" {
  description = "Redshift cluster identifier"
  value       = aws_redshift_cluster.main.cluster_identifier
}

output "redshift_cluster_endpoint" {
  description = "Redshift cluster endpoint (host:port)"
  value       = "${aws_redshift_cluster.main.endpoint}:${aws_redshift_cluster.main.port}"
}

output "redshift_cluster_dns_name" {
  description = "Redshift cluster DNS name"
  value       = aws_redshift_cluster.main.dns_name
}

output "redshift_cluster_port" {
  description = "Redshift cluster port"
  value       = aws_redshift_cluster.main.port
}

output "redshift_database_name" {
  description = "Redshift database name"
  value       = aws_redshift_cluster.main.database_name
}

output "redshift_master_username" {
  description = "Redshift master username"
  value       = aws_redshift_cluster.main.master_username
  sensitive   = true
}

# ============================================================================
# ENCRYPTION OUTPUTS
# ============================================================================

output "kms_key_id" {
  description = "KMS key ID used for encryption"
  value       = aws_kms_key.main.key_id
}

output "kms_key_arn" {
  description = "KMS key ARN used for encryption"
  value       = aws_kms_key.main.arn
}

# ============================================================================
# CONNECTION INFORMATION FOR APPLICATIONS
# ============================================================================

output "database_connection_info" {
  description = "Database connection information for applications"
  value = {
    aurora = {
      writer_endpoint = aws_rds_cluster.main.endpoint
      reader_endpoint = aws_rds_cluster.main.reader_endpoint
      port           = aws_rds_cluster.main.port
      database_name  = aws_rds_cluster.main.database_name
    }
    redshift = {
      endpoint      = aws_redshift_cluster.main.endpoint
      port         = aws_redshift_cluster.main.port
      database_name = aws_redshift_cluster.main.database_name
    }
  }
  sensitive = true
}

# ============================================================================
# ENVIRONMENT METADATA
# ============================================================================

output "environment" {
  description = "Environment name"
  value       = var.environment
}

output "aws_region" {
  description = "AWS region"
  value       = var.aws_region
}

output "project_name" {
  description = "Project name"
  value       = var.project_name
}
