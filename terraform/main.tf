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

# ... and block public access because folks don't need to seeing this. 
resource "aws_s3_bucket_public_access_block" "github_data_public_access_block" {
  bucket = aws_s3_bucket.github_data_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Enable Server-Side Encryption - AWS is handeling with key storage 
resource "aws_s3_bucket_server_side_encryption_configuration" "github_data_encryption" {
  bucket = aws_s3_bucket.github_data_bucket.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}
# Create the VPC
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-vpc"
  })
}

# Create two private subnets in different availability zones
resource "aws_subnet" "private_1" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "us-east-1a"

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-private-subnet-1"
  })
}

resource "aws_subnet" "private_2" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "us-east-1b"

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-private-subnet-2"
  })
}

