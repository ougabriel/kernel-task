locals {
  # Environment-specific configurations
  env_config = {
    dev = {
      # Network
      vpc_cidr           = "10.0.0.0/16"
      enable_nat_gateway = false
      
      # Aurora PostgreSQL
      aurora_instance_class    = "db.r6g.large"
      aurora_min_capacity     = 0.5
      aurora_max_capacity     = 2
      aurora_instance_count   = 1
      
      # Redshift
      redshift_node_type      = "dc2.large"
      redshift_cluster_nodes  = 1
      
      # Operational
      backup_retention_days       = 1
      enable_deletion_protection  = false
      enable_performance_insights = false
      enable_enhanced_monitoring  = false
    }
    
    staging = {
      vpc_cidr           = "10.1.0.0/16"
      enable_nat_gateway = true
      
      aurora_instance_class    = "db.r6g.xlarge"
      aurora_min_capacity     = 1
      aurora_max_capacity     = 4
      aurora_instance_count   = 2
      
      redshift_node_type      = "dc2.large"
      redshift_cluster_nodes  = 2
      
      backup_retention_days       = 3
      enable_deletion_protection  = false
      enable_performance_insights = true
      enable_enhanced_monitoring  = true
    }
    
    prod = {
      vpc_cidr           = "10.2.0.0/16"
      enable_nat_gateway = true
      
      aurora_instance_class    = "db.r6g.2xlarge"
      aurora_min_capacity     = 4
      aurora_max_capacity     = 16
      aurora_instance_count   = 3
      
      redshift_node_type      = "dc2.large"
      redshift_cluster_nodes  = 3
      
      backup_retention_days       = 7
      enable_deletion_protection  = true
      enable_performance_insights = true
      enable_enhanced_monitoring  = true
    }
  }
  
  # Current environment configuration
  config = local.env_config[var.environment]
  
  # Override with variable values if provided
  vpc_cidr = var.vpc_cidr != null ? var.vpc_cidr : local.config.vpc_cidr
  backup_retention_days = var.backup_retention_days != null ? var.backup_retention_days : local.config.backup_retention_days
  enable_deletion_protection = var.enable_deletion_protection != null ? var.enable_deletion_protection : local.config.enable_deletion_protection
  
  # Common resource naming
  name_prefix = "${var.project_name}-${var.environment}"
  
  # Common tags applied to all resources
  common_tags = merge({
    Environment   = var.environment
    Project      = var.project_name
    ManagedBy    = "terraform"
    Owner        = "data-platform-team"
    CostCenter   = "engineering"
    CreatedDate  = formatdate("YYYY-MM-DD", timestamp())
  }, var.tags)
  
  # Security group rules as data structures
  aurora_ingress_rules = [
    {
      description     = "PostgreSQL access from applications"
      from_port       = 5432
      to_port         = 5432
      protocol        = "tcp"
      security_groups = [aws_security_group.application.id]
      cidr_blocks     = []
    },
    {
      description     = "Aurora cluster replication"
      from_port       = 5432
      to_port         = 5432
      protocol        = "tcp"
      security_groups = []
      cidr_blocks     = []
      self            = true
    }
  ]
  
  redshift_ingress_rules = [
    {
      description     = "Redshift access from applications"
      from_port       = 5439
      to_port         = 5439
      protocol        = "tcp"
      security_groups = [aws_security_group.application.id]
      cidr_blocks     = []
    },
    {
      description     = "Redshift access from Aurora (for COPY operations)"
      from_port       = 5439
      to_port         = 5439
      protocol        = "tcp"
      security_groups = [aws_security_group.aurora.id]
      cidr_blocks     = []
    }
  ]
}
