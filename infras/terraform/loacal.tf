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
