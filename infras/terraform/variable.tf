# variables.tf
variable "environment" {
  type        = string
  description = "Deployment environment (dev, prod, etc.)"
}


variable "postgres_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.r6g.xlarge"
}
