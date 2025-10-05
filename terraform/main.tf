terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
  
  default_tags {
    tags = {
      Project     = "audio-stitcher"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

# S3 bucket for audio files
resource "aws_s3_bucket" "audio_bucket" {
  bucket        = "${var.project_name}-audio-${var.environment}-${random_id.bucket_suffix.hex}"
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "audio_bucket_versioning" {
  bucket = aws_s3_bucket.audio_bucket.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "audio_bucket_encryption" {
  bucket = aws_s3_bucket.audio_bucket.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "random_id" "bucket_suffix" {
  byte_length = 4
}

# Lambda function using container image
resource "aws_lambda_function" "audio_stitcher" {
  function_name = "${var.project_name}-${var.environment}"
  role          = aws_iam_role.lambda_role.arn
  package_type  = "Image"
  image_uri     = local.full_image_uri
  timeout       = 300
  memory_size   = 1024

  environment {
    variables = {
      BUCKET_NAME  = aws_s3_bucket.audio_bucket.bucket
      DEBUG_LEVEL  = "INFO"
      LOGGER_NAME  = "audio-stitcher"
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.lambda_logs,
    aws_cloudwatch_log_group.lambda_logs,
    aws_ecr_repository.audio_stitcher,
  ]
}

# Container image resources are defined in ecr.tf
# The Lambda function now uses a container image instead of zip packages

# CloudWatch Log Group
resource "aws_cloudwatch_log_group" "lambda_logs" {
  name              = "/aws/lambda/${var.project_name}-${var.environment}"
  retention_in_days = 14
}

# API Gateway
resource "aws_api_gateway_rest_api" "audio_api" {
  name        = "${var.project_name}-api-${var.environment}"
  description = "Audio Stitcher API"
  
  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

resource "aws_api_gateway_resource" "stitch" {
  rest_api_id = aws_api_gateway_rest_api.audio_api.id
  parent_id   = aws_api_gateway_rest_api.audio_api.root_resource_id
  path_part   = "stitch"
}

resource "aws_api_gateway_method" "stitch_post" {
  rest_api_id      = aws_api_gateway_rest_api.audio_api.id
  resource_id      = aws_api_gateway_resource.stitch.id
  http_method      = "POST"
  authorization    = "NONE"
  api_key_required = var.enable_api_key
}

resource "aws_api_gateway_integration" "lambda_integration" {
  rest_api_id = aws_api_gateway_rest_api.audio_api.id
  resource_id = aws_api_gateway_resource.stitch.id
  http_method = aws_api_gateway_method.stitch_post.http_method

  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.audio_stitcher.invoke_arn
}

resource "aws_api_gateway_deployment" "api_deployment" {
  rest_api_id = aws_api_gateway_rest_api.audio_api.id

  depends_on = [
    aws_api_gateway_method.stitch_post,
    aws_api_gateway_integration.lambda_integration,
  ]

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "api_stage" {
  rest_api_id   = aws_api_gateway_rest_api.audio_api.id
  deployment_id = aws_api_gateway_deployment.api_deployment.id
  stage_name    = var.environment
}

# Lambda permission for API Gateway
resource "aws_lambda_permission" "api_gateway_invoke" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.audio_stitcher.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.audio_api.execution_arn}/*/*"
}
