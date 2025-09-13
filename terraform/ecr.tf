# ECR repository for Lambda container images
resource "aws_ecr_repository" "audio_stitcher" {
  name = "${var.project_name}-${var.environment}"

  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = {
    Name        = "${var.project_name}-${var.environment}"
    Environment = var.environment
    Project     = var.project_name
  }
}

# ECR lifecycle policy to manage image retention
resource "aws_ecr_lifecycle_policy" "audio_stitcher_policy" {
  repository = aws_ecr_repository.audio_stitcher.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 5 images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v"]
          countType     = "imageCountMoreThan"
          countNumber   = 5
        }
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 2
        description  = "Delete untagged images older than 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

# Data source to get current AWS account ID and region
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# Local values for container image
locals {
  account_id    = data.aws_caller_identity.current.account_id
  region        = data.aws_region.current.name
  ecr_url       = "${local.account_id}.dkr.ecr.${local.region}.amazonaws.com"
  image_tag     = "latest"
  full_image_uri = "${aws_ecr_repository.audio_stitcher.repository_url}:${local.image_tag}"
}
