terraform {
  required_version = ">= 1.0"
  
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.4"
    }
  }
  
  # We will have to uncomment this and configure for remote state
  # Needed when deploying to multiple environments

  # backend "s3" {
  #   bucket         = "your-terraform-state-bucket"
  #   key            = "atlasco/${var.environment}/terraform.tfstate"
  #   region         = "us-west-2"
  #   dynamodb_table = "terraform-state-lock"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = var.aws_region
  
  # Apply common tags to all resources by default
  default_tags {
    tags = local.common_tags
  }
}

# Get current AWS account and region
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_availability_zones" "available" {
  state = "available"
}
