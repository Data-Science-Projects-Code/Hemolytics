terraform {
  required_version = ">= 1.0.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.91.0"
    }
  }
}

locals {
  environment = "dev"
  name_prefix = "hemolytics-${local.environment}"
}

resource "aws_s3_bucket" "github_data_bucket" {
  bucket = "${local.name_prefix}-github-data"
}

