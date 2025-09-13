output "api_gateway_url" {
  description = "API Gateway URL"
  value       = "${aws_api_gateway_deployment.api_deployment.invoke_url}/stitch"
}

output "api_key_id" {
  description = "API Gateway API Key ID"
  value       = try(aws_api_gateway_api_key.audio_api_key[0].id, null)
}

output "api_key_value" {
  description = "API Gateway API Key Value"
  sensitive   = true
  value       = try(aws_api_gateway_api_key.audio_api_key[0].value, null)
}

output "s3_bucket_name" {
  description = "S3 bucket name for audio files"
  value       = aws_s3_bucket.audio_bucket.bucket
}

output "lambda_function_name" {
  description = "Lambda function name"
  value       = aws_lambda_function.audio_stitcher.function_name
}

output "cloudwatch_log_group" {
  description = "CloudWatch log group name"
  value       = aws_cloudwatch_log_group.lambda_logs.name
}

output "curl_example" {
  description = "Example curl command to test the API"
  sensitive   = true
  value = <<-EOT
# Basic test (use unique timestamped filenames)
curl -X POST ${aws_api_gateway_deployment.api_deployment.invoke_url}/stitch \
  -H "Content-Type: application/json" \
  -H "x-api-key: ${try(aws_api_gateway_api_key.audio_api_key[0].value, "NOT_REQUIRED")}" \
  -d '{
    "message": "hello shreeshail",
    "audios": "${aws_s3_bucket.audio_bucket.bucket}",
    "output": "output/test_$(date +%s).mp3"
  }'

# Or save to a specific filename
curl -X POST ${aws_api_gateway_deployment.api_deployment.invoke_url}/stitch \
  -H "Content-Type: application/json" \
  -H "x-api-key: ${try(aws_api_gateway_api_key.audio_api_key[0].value, "NOT_REQUIRED")}" \
  -d '{
    "message": "hello shreeshail", 
    "audios": "${aws_s3_bucket.audio_bucket.bucket}",
    "output": "output/my_custom_audio.mp3"
  }' | jq '.'
EOT
}

output "ecr_repository_url" {
  description = "ECR repository URL for Lambda container"
  value       = aws_ecr_repository.audio_stitcher.repository_url
}

output "container_image_uri" {
  description = "Full container image URI used by Lambda"
  value       = local.full_image_uri
}

output "aws_region" {
  description = "AWS region"
  value       = var.aws_region
}

output "download_examples" {
  description = "Commands to list and download generated audio files"
  value = <<-EOT
# List all generated files
aws s3 ls s3://${aws_s3_bucket.audio_bucket.bucket}/output/ --human-readable

# Download latest file
LATEST=$(aws s3 ls s3://${aws_s3_bucket.audio_bucket.bucket}/output/ --recursive | sort | tail -n 1 | awk '{print $4}')
aws s3 cp s3://${aws_s3_bucket.audio_bucket.bucket}/$LATEST ./latest_audio.mp3

# Download specific file (replace FILENAME with actual name from list)
aws s3 cp s3://${aws_s3_bucket.audio_bucket.bucket}/output/FILENAME ./my_audio.mp3

# Helper scripts (if available)
./list-files.sh          # See all files in bucket
./download-latest.sh     # Download newest file automatically
EOT
}

output "usage_plan_id" {
  description = "API Gateway usage plan ID"
  value       = try(aws_api_gateway_usage_plan.audio_api_usage_plan[0].id, null)
}

output "ecr_repository_name" {
  description = "ECR repository name"
  value       = aws_ecr_repository.audio_stitcher.name
}
