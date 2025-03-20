# main.tf

locals {
  environment = "dev" # Change to "prod" for production
  name_prefix = "crimson-cache-${local.environment}"
  common_tags = {
    Environment = local.environment
    Project     = "CrimsonCache"
    ManagedBy   = "Terraform"
  }
}

# S3 bucket for GitHub SQLite files
resource "aws_s3_bucket" "github_data_bucket" {
  bucket = "${local.name_prefix}-github-data"

  tags = merge(local.common_tags, {
    Name = "GitHub SQLite Data"
  })
}

# Block public access for the S3 bucket
resource "aws_s3_bucket_public_access_block" "github_data_public_access_block" {
  bucket = aws_s3_bucket.github_data_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Enable server-side encryption for the S3 bucket
resource "aws_s3_bucket_server_side_encryption_configuration" "github_data_encryption" {
  bucket = aws_s3_bucket.github_data_bucket.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Minimal VPC for our resources
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-vpc"
  })
}

# Create two private subnets for RDS
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

# Create a subnet group for RDS
resource "aws_db_subnet_group" "postgres_subnet_group" {
  name       = "${local.name_prefix}-subnet-group"
  subnet_ids = [aws_subnet.private_1.id, aws_subnet.private_2.id]

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-db-subnet-group"
  })
}

# Create a security group for RDS
resource "aws_security_group" "postgres_sg" {
  name        = "${local.name_prefix}-postgres-sg"
  description = "Security group for PostgreSQL RDS instance"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"] # Only allow connections from within the VPC
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-postgres-sg"
  })
}

# Create a secret for the database password
resource "aws_secretsmanager_secret" "db_password" {
  name = "${local.name_prefix}-db-password"

  tags = merge(local.common_tags, {
    Name = "Database Password"
  })
}

resource "aws_secretsmanager_secret_version" "db_password" {
  secret_id = aws_secretsmanager_secret.db_password.id
  secret_string = jsonencode({
    username = "admin"
    password = "REPLACE_WITH_SECURE_PASSWORD" # Replace this with a secure password before applying
  })
}

# Create the RDS PostgreSQL instance
resource "aws_db_instance" "postgres" {
  identifier             = "${local.name_prefix}-postgres"
  allocated_storage      = 20
  storage_type           = "gp3"
  engine                 = "postgres"
  engine_version         = "15.4" # Updated to a supported version
  instance_class         = "db.t3.micro"
  db_name                = "CrimsonCacheIngest"
  username               = jsondecode(aws_secretsmanager_secret_version.db_password.secret_string)["username"]
  password               = jsondecode(aws_secretsmanager_secret_version.db_password.secret_string)["password"]
  db_subnet_group_name   = aws_db_subnet_group.postgres_subnet_group.name
  vpc_security_group_ids = [aws_security_group.postgres_sg.id]
  skip_final_snapshot    = local.environment == "dev" ? true : false
  deletion_protection    = local.environment == "prod" ? true : false

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-postgres"
  })
}

# IAM Role for Glue
resource "aws_iam_role" "glue_role" {
  name = "${local.name_prefix}-glue-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "glue.amazonaws.com"
        }
      }
    ]
  })

  tags = local.common_tags
}

# Attach policies to the Glue role
resource "aws_iam_role_policy_attachment" "glue_service" {
  role       = aws_iam_role.glue_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

resource "aws_iam_policy" "s3_access" {
  name        = "${local.name_prefix}-glue-s3-access"
  description = "Policy for Glue to access S3 bucket"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket"
        ]
        Effect = "Allow"
        Resource = [
          aws_s3_bucket.github_data_bucket.arn,
          "${aws_s3_bucket.github_data_bucket.arn}/*"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "s3_access" {
  role       = aws_iam_role.glue_role.name
  policy_arn = aws_iam_policy.s3_access.arn
}

# IAM Role for GitHub data fetching
resource "aws_iam_role" "github_fetch_role" {
  name = "${local.name_prefix}-github-fetch-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_policy" "github_fetch_policy" {
  name        = "${local.name_prefix}-github-fetch-policy"
  description = "Policy for Lambda to fetch GitHub data and put in S3"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "s3:PutObject",
          "s3:ListBucket"
        ]
        Effect = "Allow"
        Resource = [
          aws_s3_bucket.github_data_bucket.arn,
          "${aws_s3_bucket.github_data_bucket.arn}/*"
        ]
      },
      {
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Effect   = "Allow"
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "github_fetch_policy" {
  role       = aws_iam_role.github_fetch_role.name
  policy_arn = aws_iam_policy.github_fetch_policy.arn
}

# Lambda function and related resources are commented out until I'm ready to implement them
# Will need to create the github_fetch_lambda.zip file manually before uncommenting

# resource "aws_lambda_function" "github_fetch" {
#   filename      = "github_fetch_lambda.zip"  # You'll need to create this deployment package
#   function_name = "${local.name_prefix}-github-fetch"
#   role          = aws_iam_role.github_fetch_role.arn
#   handler       = "github_fetch.handler"
#   runtime       = "python3.9"
#   timeout       = 300  # 5 minutes
#   memory_size   = 256
#
#   environment {
#     variables = {
#       S3_BUCKET      = aws_s3_bucket.github_data_bucket.bucket
#       GITHUB_REPO    = "Data-Science-Projects-Code/CrimsonCache"
#       GITHUB_PATH    = "tree/main/data"
#     }
#   }
#   
#   tags = local.common_tags
# }
#
# # EventBridge rule to trigger Lambda daily
# resource "aws_cloudwatch_event_rule" "daily_trigger" {
#   name                = "${local.name_prefix}-daily-github-fetch"
#   description         = "Triggers GitHub data fetch Lambda function daily"
#   schedule_expression = "cron(0 0 * * ? *)"  # Run at midnight UTC every day
#   
#   tags = local.common_tags
# }
#
# resource "aws_cloudwatch_event_target" "lambda_target" {
#   rule      = aws_cloudwatch_event_rule.daily_trigger.name
#   target_id = "TriggerLambda"
#   arn       = aws_lambda_function.github_fetch.arn
# }
#
# resource "aws_lambda_permission" "allow_eventbridge" {
#   statement_id  = "AllowExecutionFromEventBridge"
#   action        = "lambda:InvokeFunction"
#   function_name = aws_lambda_function.github_fetch.function_name
#   principal     = "events.amazonaws.com"
#   source_arn    = aws_cloudwatch_event_rule.daily_trigger.arn
# }

# Create a Glue database
resource "aws_glue_catalog_database" "sqlite_db" {
  name = "${local.name_prefix}-sqlite-db"
}

# Create a Glue crawler to discover schema
resource "aws_glue_crawler" "sqlite_crawler" {
  name          = "${local.name_prefix}-sqlite-crawler"
  role          = aws_iam_role.glue_role.arn
  database_name = aws_glue_catalog_database.sqlite_db.name

  s3_target {
    path = "s3://${aws_s3_bucket.github_data_bucket.bucket}/data"
  }

  schedule = "cron(30 0 * * ? *)" # Run at 00:30 UTC every day (after data is fetched)

  tags = local.common_tags
}

# Create a Glue connection to RDS
resource "aws_glue_connection" "postgres_connection" {
  name            = "${local.name_prefix}-postgres-connection"
  connection_type = "JDBC"

  connection_properties = {
    JDBC_CONNECTION_URL = "jdbc:postgresql://${aws_db_instance.postgres.endpoint}/${aws_db_instance.postgres.db_name}"
    USERNAME            = aws_db_instance.postgres.username
    PASSWORD            = aws_db_instance.postgres.password
  }

  physical_connection_requirements {
    availability_zone      = aws_subnet.private_1.availability_zone
    security_group_id_list = [aws_security_group.postgres_sg.id]
    subnet_id              = aws_subnet.private_1.id
  }
}

# Output important resource information
output "s3_bucket_name" {
  value = aws_s3_bucket.github_data_bucket.bucket
}

output "rds_endpoint" {
  value = aws_db_instance.postgres.endpoint
}

output "rds_database_name" {
  value = aws_db_instance.postgres.db_name
}
