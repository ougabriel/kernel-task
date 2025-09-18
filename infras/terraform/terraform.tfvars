

# Basic Configuration
environment  = "dev"
project_name = "atlasco"
aws_region   = "us-west-2"

# Network Configuration (optional - will use environment defaults if not specified)
# vpc_cidr = "10.0.0.0/16"

# Database Configuration (optional)
# backup_retention_days = 1
# enable_deletion_protection = false

# Additional Tags
tags = {
  Owner      = "data-platform-team"
  CostCenter = "engineering"
  Purpose    = "kernel-tasks"
}
