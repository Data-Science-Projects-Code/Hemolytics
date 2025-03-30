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
    environment = local.environment
    project     = "hemolytics"
    datasource  = "crimsoncache"
    managedby   = "terraform"
  }
}

# s3 bucket for landing data from crimsoncache
resource "aws_s3_bucket" "crimson_data_bucket" {
  bucket = "${local.name_prefix}-crimson-data"
  tags   = merge(local.common_tags, { name = "crimsoncache data" })
}

# block public access
resource "aws_s3_bucket_public_access_block" "data_public_access_block" {
  bucket = aws_s3_bucket.crimson_data_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# enable server-side encryption
resource "aws_s3_bucket_server_side_encryption_configuration" "data_encryption" {
  bucket = aws_s3_bucket.crimson_data_bucket.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# enable s3 lifecycle rules to optimize costs
resource "aws_s3_bucket_lifecycle_configuration" "data_lifecycle" {
  bucket = aws_s3_bucket.crimson_data_bucket.id

  rule {
    id     = "transition-to-ia"
    status = "Enabled"

    filter {
      prefix = ""
    }

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 90
      storage_class = "GLACIER"
    }
  }
}

# create the vpc
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, {
    name = "${local.name_prefix}-vpc"
  })
}

# create two private subnets
resource "aws_subnet" "private_1" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "us-east-1a"

  tags = merge(local.common_tags, {
    name = "${local.name_prefix}-private-subnet-1"
  })
}

resource "aws_subnet" "private_2" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "us-east-1b"

  tags = merge(local.common_tags, {
    name = "${local.name_prefix}-private-subnet-2"
  })
}

# create a subnet group for rds
resource "aws_db_subnet_group" "postgres_subnet_group" {
  name       = "${local.name_prefix}-subnet-group"
  subnet_ids = [aws_subnet.private_1.id, aws_subnet.private_2.id]

  lifecycle {
    # Prevent changes to subnet_ids to avoid VPC mismatch errors
    ignore_changes = [subnet_ids]
  }

  tags = merge(local.common_tags, {
    name = "${local.name_prefix}-db-subnet-group"
  })
}

# Secrets Manager for database credentials
resource "aws_secretsmanager_secret" "db_credentials" {
  name = "${local.name_prefix}-db-credentials"

  tags = merge(local.common_tags, {
    name = "database credentials"
  })
}

# IAM Role for Lambda
resource "aws_iam_role" "crimson_fetch_role" {
  name = "${local.name_prefix}-crimson-fetch-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = "sts:AssumeRole",
        Effect = "Allow",
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })

  tags = local.common_tags
}

# Fix IAM Policy using a new policy name to avoid conflicts
resource "aws_iam_policy" "crimson_fetch_policy_v2" {
  name        = "${local.name_prefix}-crimson-fetch-policy-v2"
  description = "Policy for Lambda to fetch CrimsonCache data and put in S3"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = [
          "s3:PutObject",
          "s3:ListBucket"
        ],
        Effect = "Allow",
        Resource = [
          aws_s3_bucket.crimson_data_bucket.arn,
          "${aws_s3_bucket.crimson_data_bucket.arn}/*"
        ]
      },
      {
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        Effect   = "Allow",
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Action = [
          "secretsmanager:GetSecretValue"
        ],
        Effect   = "Allow",
        Resource = aws_secretsmanager_secret.db_credentials.arn
      }
    ]
  })
}

# Attach the new policy to the role
resource "aws_iam_role_policy_attachment" "crimson_fetch_policy_attachment" {
  role       = aws_iam_role.crimson_fetch_role.name
  policy_arn = aws_iam_policy.crimson_fetch_policy_v2.arn
}

# Ensure proper IAM permissions for tags
resource "aws_iam_policy" "additional_permissions" {
  name        = "${local.name_prefix}-additional-permissions"
  description = "Additional permissions for Terraform automation"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action   = ["ssm:AddTagsToResource", "redshift-serverless:TagResource"],
        Effect   = "Allow",
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "additional_permissions_attachment" {
  role       = aws_iam_role.crimson_fetch_role.name
  policy_arn = aws_iam_policy.additional_permissions.arn
}


# Lambda function to fetch data from GitHub
resource "aws_lambda_function" "github_fetch_lambda" {
  function_name    = "${local.name_prefix}-github-fetch"
  filename         = "../src/github_fetch_lambda.zip"
  source_code_hash = filebase64sha256("../src/github_fetch_lambda.zip")
  role             = aws_iam_role.crimson_fetch_role.arn
  handler          = "github_fetch.handler"
  runtime          = "python3.12"
  timeout          = 300 # 5 minutes
  memory_size      = 256 # MB

  environment {
    variables = {
      S3_BUCKET   = aws_s3_bucket.crimson_data_bucket.id
      GITHUB_REPO = "Data-Science-Projects-Code/CrimsonCache"
      GITHUB_PATH = "data"
    }
  }

  tags = merge(local.common_tags, {
    name = "${local.name_prefix}-github-fetch-lambda"
  })
}

# CloudWatch Event Rule - Run once per day
resource "aws_cloudwatch_event_rule" "daily_github_fetch" {
  name                = "${local.name_prefix}-daily-github-fetch"
  description         = "Trigger GitHub fetch Lambda function once per day"
  schedule_expression = "cron(0 0 * * ? *)" # Run at midnight UTC every day

  tags = local.common_tags
}

# CloudWatch Event Target - Connect rule to Lambda
resource "aws_cloudwatch_event_target" "lambda_target" {
  rule      = aws_cloudwatch_event_rule.daily_github_fetch.name
  target_id = "GitHubFetchLambda"
  arn       = aws_lambda_function.github_fetch_lambda.arn
}

# Lambda permission to allow CloudWatch Events to invoke function
resource "aws_lambda_permission" "allow_cloudwatch" {
  statement_id  = "AllowExecutionFromCloudWatch"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.github_fetch_lambda.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.daily_github_fetch.arn
}
