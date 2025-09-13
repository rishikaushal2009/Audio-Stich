variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "dev"
}

variable "project_name" {
  description = "Project name"
  type        = string
  default     = "audio-stitcher"
}

variable "enable_api_key" {
  description = "Enable API key authentication"
  type        = bool
  default     = true
}
