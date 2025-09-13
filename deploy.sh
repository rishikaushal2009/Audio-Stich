#!/bin/bash

# Audio Stitcher Complete Deployment Script
# This script handles everything: build, deploy, and test using only bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

print_status() { echo -e "${CYAN}$1${NC}"; }
print_success() { echo -e "${GREEN}$1${NC}"; }
print_error() { echo -e "${RED}$1${NC}"; }
print_warning() { echo -e "${YELLOW}$1${NC}"; }

# Default values
AWS_REGION=${AWS_REGION:-us-east-1}
ENVIRONMENT=${ENVIRONMENT:-dev}
PROJECT_NAME=${PROJECT_NAME:-audio-stitcher}
ENABLE_API_KEY=${ENABLE_API_KEY:-true}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --region)
            AWS_REGION="$2"
            shift 2
            ;;
        --environment)
            ENVIRONMENT="$2"
            shift 2
            ;;
        --project)
            PROJECT_NAME="$2"
            shift 2
            ;;
        --no-api-key)
            ENABLE_API_KEY=false
            shift
            ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo "Options:"
            echo "  --region        AWS region (default: us-east-1)"
            echo "  --environment   Environment name (default: dev)"
            echo "  --project       Project name (default: audio-stitcher)"
            echo "  --no-api-key    Disable API key authentication"
            echo "  --help          Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

print_status "Audio Stitcher Complete Deployment"
print_status "==================================="
echo "Region: $AWS_REGION"
echo "Environment: $ENVIRONMENT"
echo "Project: $PROJECT_NAME"
echo "API Key: $ENABLE_API_KEY"
echo ""

# Check prerequisites
check_prerequisites() {
    print_status "Checking prerequisites..."
    
    # Check if we're in WSL or Linux
    if [[ ! -f /proc/version || ! $(grep -i microsoft /proc/version 2>/dev/null) ]]; then
        print_error "ERROR: Please run this script in WSL or Linux"
        exit 1
    fi
    
    # Check tools
    local tools=("docker" "aws" "terraform")
    for tool in "${tools[@]}"; do
        if ! command -v $tool &> /dev/null; then
            print_error "ERROR: $tool is not installed"
            exit 1
        fi
    done
    
    # Check AWS credentials
    if ! aws sts get-caller-identity &> /dev/null; then
        print_error "ERROR: AWS credentials not configured"
        print_status "Run: aws configure"
        exit 1
    fi
    
    # Check Docker daemon
    if ! docker info &> /dev/null; then
        print_status "Starting Docker..."
        sudo service docker start
        sleep 3
    fi
    
    print_success "All prerequisites met"
}

# Build container image
build_container() {
    print_status "Building Lambda container image..."
    
    # Set environment variables
    export TF_VAR_aws_region=$AWS_REGION
    export TF_VAR_environment=$ENVIRONMENT
    export TF_VAR_project_name=$PROJECT_NAME
    export TF_VAR_enable_api_key=$ENABLE_API_KEY
    
    # Get ECR repository (create if needed)
    cd terraform
    terraform init -input=false
    terraform apply -target=aws_ecr_repository.audio_stitcher -target=aws_ecr_lifecycle_policy.audio_stitcher_policy -auto-approve
    
    ECR_REPOSITORY=$(terraform output -raw ecr_repository_url)
    cd ..
    
    print_status "Repository: $ECR_REPOSITORY"
    
    # Authenticate with ECR
    print_status "Authenticating with ECR..."
    aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $ECR_REPOSITORY
    
    # Build image
    print_status "Building Docker image..."
    DOCKER_BUILDKIT=0 docker build -t $ECR_REPOSITORY:latest . --platform linux/amd64
    
    # Push to ECR
    print_status "Pushing to ECR..."
    docker push $ECR_REPOSITORY:latest
    
    print_success "Container image built and pushed"
}

# Deploy infrastructure
deploy_infrastructure() {
    print_status "Deploying AWS infrastructure..."
    
    cd terraform
    
    # Apply Terraform
    terraform apply -auto-approve \
        -var="aws_region=$AWS_REGION" \
        -var="environment=$ENVIRONMENT" \
        -var="project_name=$PROJECT_NAME" \
        -var="enable_api_key=$ENABLE_API_KEY"
    
    print_success "Infrastructure deployed successfully"
    
    # Show outputs
    print_status "Deployment outputs:"
    terraform output
    
    cd ..
}

# Upload sample files
upload_samples() {
    print_status "[FILE] Uploading sample audio files..."
    
    cd terraform
    BUCKET_NAME=$(terraform output -raw s3_bucket_name)
    cd ..
    
    if [[ -f "audios/hello.wav" && -f "audios/Shreeshail.wav" ]]; then
        aws s3 cp audios/hello.wav s3://$BUCKET_NAME/hello.wav
        aws s3 cp audios/Shreeshail.wav s3://$BUCKET_NAME/Shreeshail.wav
        print_success "[OK] Sample files uploaded"
    else
        print_warning "[INFO] Sample audio files not found in audios/ directory"
    fi
}

# Test the deployment
test_deployment() {
    print_status "[TEST] Testing the deployment..."
    
    cd terraform
    API_URL=$(terraform output -raw api_gateway_url)
    BUCKET_NAME=$(terraform output -raw s3_bucket_name)
    
    # Get API key if enabled
    if [[ "$ENABLE_API_KEY" == "true" ]]; then
        API_KEY=$(aws apigateway get-api-key --api-key $(terraform output -raw api_key_id) --include-value --query 'value' --output text)
        API_KEY_HEADER="-H \"x-api-key: $API_KEY\""
    else
        API_KEY_HEADER=""
    fi
    cd ..
    
    # Test API
    print_status "[CHECK] Testing API endpoint..."
    print_status "API URL: $API_URL"
    print_status "Bucket: $BUCKET_NAME" 
    print_status "API Key Required: $ENABLE_API_KEY"
    
    if [[ "$ENABLE_API_KEY" == "true" ]]; then
        print_status "API Key ID: $(terraform output -raw api_key_id 2>/dev/null || echo 'ERROR: No API key ID')"
        if [[ -n "$API_KEY" ]]; then
            print_status "API Key Length: ${#API_KEY} characters"
            print_status "API Key Preview: ${API_KEY:0:8}..."
        else
            print_error "[ERROR] API_KEY is empty!"
        fi
    fi
    
    # Wait a moment for API Gateway to be fully ready
    print_status "Waiting 10 seconds for API Gateway propagation..."
    sleep 10
    
    if [[ "$ENABLE_API_KEY" == "true" && -n "$API_KEY" ]]; then
        print_status "Testing with API key authentication..."
        RESPONSE=$(curl -s -w "%{http_code}" -X POST "$API_URL" \
            -H "Content-Type: application/json" \
            -H "x-api-key: $API_KEY" \
            -d "{\"message\": \"hello shreeshail\", \"audios\": \"$BUCKET_NAME\", \"output\": \"output/test_$(date +%s).mp3\"}" \
            2>/dev/null)
    else
        print_status "Testing without API key..."
        RESPONSE=$(curl -s -w "%{http_code}" -X POST "$API_URL" \
            -H "Content-Type: application/json" \
            -d "{\"message\": \"hello shreeshail\", \"audios\": \"$BUCKET_NAME\", \"output\": \"output/test_$(date +%s).mp3\"}" \
            2>/dev/null)
    fi
    
    HTTP_CODE="${RESPONSE: -3}"
    BODY="${RESPONSE%???}"
    
    if [[ "$HTTP_CODE" -eq 200 ]]; then
        print_success "[OK] API test successful!"
        print_status "Response: $BODY"
    elif [[ "$HTTP_CODE" -eq 403 ]]; then
        print_error "[ERROR] API test failed (HTTP 403 - Forbidden)"
        print_error "This usually means API key authentication failed"
        print_status "Response: $BODY"
        
        # Debug API key setup
        print_status "[DEBUG] Checking API key configuration..."
        cd terraform
        
        # Check if API key exists
        if terraform state list | grep -q "aws_api_gateway_api_key"; then
            print_status " API key resource exists in Terraform state"
            API_KEY_ID=$(terraform output -raw api_key_id 2>/dev/null)
            if [[ -n "$API_KEY_ID" ]]; then
                print_status " API Key ID: $API_KEY_ID"
                
                # Check if usage plan exists
                if terraform state list | grep -q "aws_api_gateway_usage_plan"; then
                    print_status " Usage plan exists"
                    USAGE_PLAN_ID=$(terraform output -raw usage_plan_id 2>/dev/null || echo "N/A")
                    print_status "Usage Plan ID: $USAGE_PLAN_ID"
                else
                    print_error " Usage plan missing"
                fi
                
                # Try to get API key value again
                NEW_API_KEY=$(aws apigateway get-api-key --api-key "$API_KEY_ID" --include-value --query 'value' --output text 2>/dev/null || echo "")
                if [[ -n "$NEW_API_KEY" ]]; then
                    print_status " API key retrieved successfully"
                    print_status "Retrying API test with fresh API key..."
                    
                    RETRY_RESPONSE=$(curl -s -w "%{http_code}" -X POST "$API_URL" \
                        -H "Content-Type: application/json" \
                        -H "x-api-key: $NEW_API_KEY" \
                        -d "{\"message\": \"hello shreeshail\", \"audios\": \"$BUCKET_NAME\", \"output\": \"output/retry_$(date +%s).mp3\"}" \
                        2>/dev/null)
                    
                    RETRY_HTTP_CODE="${RETRY_RESPONSE: -3}"
                    RETRY_BODY="${RETRY_RESPONSE%???}"
                    
                    if [[ "$RETRY_HTTP_CODE" -eq 200 ]]; then
                        print_success "[OK] Retry successful!"
                    else
                        print_error "[ERROR] Retry also failed (HTTP $RETRY_HTTP_CODE): $RETRY_BODY"
                    fi
                else
                    print_error " Could not retrieve API key value"
                fi
            else
                print_error " Could not get API key ID"
            fi
        else
            print_error " No API key resource in Terraform state"
        fi
        cd ..
    else
        print_error "[ERROR] API test failed (HTTP $HTTP_CODE)"
        print_status "Response: $BODY"
    fi
    
    # Check logs
    print_status "[INFO] Recent Lambda logs:"
    aws logs tail "/aws/lambda/$PROJECT_NAME-$ENVIRONMENT" --since 2m | tail -10
}

# Show final status
show_summary() {
    cd terraform
    API_URL=$(terraform output -raw api_gateway_url)
    BUCKET_NAME=$(terraform output -raw s3_bucket_name)
    ECR_REPO=$(terraform output -raw ecr_repository_url)
    
    if [[ "$ENABLE_API_KEY" == "true" ]]; then
        API_KEY=$(aws apigateway get-api-key --api-key $(terraform output -raw api_key_id) --include-value --query 'value' --output text)
        CURL_EXAMPLE="curl -X POST \"$API_URL\" -H \"Content-Type: application/json\" -H \"x-api-key: $API_KEY\" -d '{\"message\": \"hello shreeshail\", \"audios\": \"$BUCKET_NAME\", \"output\": \"output/my_audio.mp3\"}'"
    else
        CURL_EXAMPLE="curl -X POST \"$API_URL\" -H \"Content-Type: application/json\" -d '{\"message\": \"hello shreeshail\", \"audios\": \"$BUCKET_NAME\", \"output\": \"output/my_audio.mp3\"}'"
    fi
    cd ..
    
    print_success "[DEPLOY] Deployment Complete!"
    echo ""
    print_status "[INFO] Your Audio Stitcher API:"
    echo "API URL: $API_URL"
    echo "S3 Bucket: $BUCKET_NAME"
    echo "ECR Repository: $ECR_REPO"
    echo ""
    print_status "[TEST] Test your API:"
    echo "$CURL_EXAMPLE"
    echo ""
    print_status "[INFO] List created files:"
    echo "aws s3 ls s3://$BUCKET_NAME/output/ --human-readable"
    echo ""
    print_status "[INFO] Download a specific result (replace filename):"
    echo "aws s3 cp s3://$BUCKET_NAME/output/FILENAME_FROM_LIST ./result.mp3"
    echo ""
    print_status "[INFO] Or download latest file:"
    echo "LATEST=\$(aws s3 ls s3://$BUCKET_NAME/output/ --recursive | sort | tail -n 1 | awk '{print \$4}')"
    echo "aws s3 cp s3://\$BUCKET_NAME/\$LATEST ./latest_result.mp3"
    echo ""
    print_status "[CLEAN] Cleanup (when done):"
    echo "./cleanup.sh"
}

# Main execution
main() {
    check_prerequisites
    build_container
    deploy_infrastructure
    upload_samples
    test_deployment
    show_summary
}

# Help message if no arguments and not executable context
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
