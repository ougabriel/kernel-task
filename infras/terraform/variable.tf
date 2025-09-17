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
