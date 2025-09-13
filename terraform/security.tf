# API Gateway Usage Plan and API Key for security
resource "aws_api_gateway_usage_plan" "audio_api_usage_plan" {
  count = var.enable_api_key ? 1 : 0
  
  name         = "${var.project_name}-usage-plan-${var.environment}"
  description  = "Usage plan for audio stitcher API"

  api_stages {
    api_id = aws_api_gateway_rest_api.audio_api.id
    stage  = aws_api_gateway_deployment.api_deployment.stage_name
  }

  quota_settings {
    limit  = 1000
    period = "DAY"
  }

  throttle_settings {
    rate_limit  = 50
    burst_limit = 100
  }
}

resource "aws_api_gateway_api_key" "audio_api_key" {
  count = var.enable_api_key ? 1 : 0
  
  name        = "${var.project_name}-api-key-${var.environment}"
  description = "API key for audio stitcher"
}

resource "aws_api_gateway_usage_plan_key" "audio_api_usage_plan_key" {
  count = var.enable_api_key ? 1 : 0
  
  key_id        = aws_api_gateway_api_key.audio_api_key[0].id
  key_type      = "API_KEY"
  usage_plan_id = aws_api_gateway_usage_plan.audio_api_usage_plan[0].id
}

# The method is already defined in main.tf, so we just update it conditionally

# WAF Web ACL for additional security (optional)
resource "aws_wafv2_web_acl" "audio_api_waf" {
  count = var.enable_api_key ? 1 : 0
  
  name  = "${var.project_name}-waf-${var.environment}"
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  rule {
    name     = "RateLimitRule"
    priority = 1

    statement {
      rate_based_statement {
        limit              = 2000
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                 = "${var.project_name}-RateLimitRule"
      sampled_requests_enabled    = true
    }

    action {
      block {}
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                 = "${var.project_name}-WAF"
    sampled_requests_enabled    = true
  }
}

# Local values for API Gateway stage ARN
locals {
  api_stage_arn = var.enable_api_key ? "arn:aws:apigateway:${var.aws_region}::/restapis/${aws_api_gateway_rest_api.audio_api.id}/stages/${var.environment}" : null
}

# Associate WAF with existing API Gateway Stage
resource "aws_wafv2_web_acl_association" "audio_api_waf_association" {
  count = var.enable_api_key ? 1 : 0
  
  resource_arn = local.api_stage_arn
  web_acl_arn  = aws_wafv2_web_acl.audio_api_waf[0].arn
  
  depends_on = [aws_api_gateway_deployment.api_deployment]
}
