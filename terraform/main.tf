terraform {
  required_version = ">= 1.0.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.91.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

locals {
  environment = "dev"
  name_prefix = "hemolytics-${local.environment}"
  common_tags = {
    Environment = local.environment
    Project     = "Hemolytics"
    ManagedBy   = "Terraform"
  }
}

# S3 Bucket
resource "aws_s3_bucket" "github_data_bucket" {
  bucket = "${local.name_prefix}-github-data"
  tags   = merge(local.common_tags, { Name = "GitHub SQLite Data" })
}

# Block Public Access
resource "aws_s3_bucket_public_access_block" "github_data_public_access_block" {
  bucket = aws_s3_bucket.github_data_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Enable Server-Side Encryption
resource "aws_s3_bucket_server_side_encryption_configuration" "github_data_encryption" {
  bucket = aws_s3_bucket.github_data_bucket.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256" # AWS Managed KMS Key
    }
  }
}

