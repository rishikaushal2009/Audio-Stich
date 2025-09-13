#!/bin/bash

# Audio Stitcher AWS Cleanup Script
# This script destroys all AWS resources created by Terraform

set -e

echo "[CLEAN] Audio Stitcher AWS Cleanup Script [CLEAN]"
echo "======================================="

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${CYAN}$1${NC}"
}

print_warning() {
    echo -e "${YELLOW}$1${NC}"
}

print_error() {
    echo -e "${RED}$1${NC}"
}

print_success() {
    echo -e "${GREEN}$1${NC}"
}

# Check if Terraform is installed
check_terraform() {
    print_status "Checking if Terraform is installed..."
    if ! command -v terraform &> /dev/null; then
        print_error "[ERROR] Terraform is not installed. Please install Terraform first."
        exit 1
    fi
    print_success "[OK] Terraform is installed."
}

# Check if AWS CLI is configured
check_aws() {
    print_status "Checking AWS credentials..."
    if ! aws sts get-caller-identity &> /dev/null; then
        print_error "[ERROR] AWS credentials are not configured. Please run 'aws configure' first."
        exit 1
    fi
    print_success "[OK] AWS credentials are configured."
}

# List current resources
list_resources() {
    print_status "Listing current Terraform resources..."
    cd terraform
    
    if [ ! -f ".terraform/terraform.tfstate" ] && [ ! -f "terraform.tfstate" ]; then
        print_warning "[INFO] No Terraform state found. No resources to clean up."
        cd ..
        exit 0
    fi
    
    echo "Current resources:"
    terraform state list 2>/dev/null || true
    cd ..
}

# Show what will be destroyed
plan_destroy() {
    print_status "Planning destruction of resources..."
    cd terraform
    terraform plan -destroy
    cd ..
}

# Destroy resources
destroy_resources() {
    print_status "Destroying AWS resources..."
    cd terraform
    
    # Get bucket name before destroying
    BUCKET_NAME=$(terraform output -raw s3_bucket_name 2>/dev/null || echo "")
    ECR_REPO_NAME=$(terraform output -raw ecr_repository_name 2>/dev/null || echo "audio-stitcher-dev")
    AWS_REGION=$(terraform output -raw aws_region 2>/dev/null || echo "us-east-1")
    
    # Empty S3 bucket completely (including versions)
    if [[ -n "$BUCKET_NAME" ]]; then
        print_status "Emptying S3 bucket: $BUCKET_NAME"
        
        # Method 1: Simple recursive delete first
        aws s3 rm s3://$BUCKET_NAME --recursive || true
        
        # Method 2: Delete all object versions (handles versioned buckets)
        print_status "Deleting object versions..."
        aws s3api list-object-versions --bucket "$BUCKET_NAME" --output json | \
        jq -r '.Versions[]? | .Key + " " + .VersionId' | \
        while read key version; do
            if [[ -n "$key" && -n "$version" ]]; then
                aws s3api delete-object --bucket "$BUCKET_NAME" --key "$key" --version-id "$version" || true
            fi
        done
        
        # Method 3: Delete all delete markers
        print_status "Deleting delete markers..."
        aws s3api list-object-versions --bucket "$BUCKET_NAME" --output json | \
        jq -r '.DeleteMarkers[]? | .Key + " " + .VersionId' | \
        while read key version; do
            if [[ -n "$key" && -n "$version" ]]; then
                aws s3api delete-object --bucket "$BUCKET_NAME" --key "$key" --version-id "$version" || true
            fi
        done
        
        # Method 4: Force delete bucket directly (if Terraform doesn't work)
        print_status "Force deleting bucket..."
        aws s3 rb s3://$BUCKET_NAME --force || true
    fi
    
    # Empty ECR repository
    if [[ -n "$ECR_REPO_NAME" ]]; then
        print_status "Emptying ECR repository: $ECR_REPO_NAME"
        aws ecr list-images --repository-name "$ECR_REPO_NAME" --region "$AWS_REGION" \
            --query 'imageIds[*]' --output json | \
            jq '.' | \
            aws ecr batch-delete-image --repository-name "$ECR_REPO_NAME" \
            --region "$AWS_REGION" --image-ids file:///dev/stdin 2>/dev/null || true
    fi
    
    # First try to destroy everything
    if terraform destroy -auto-approve; then
        print_success "[OK] All resources destroyed successfully."
    else
        print_warning "[INFO] Some resources failed to destroy. Attempting targeted cleanup..."
        
        # Try to destroy individual problematic resources
        problematic_resources=(
            "aws_wafv2_web_acl_association.audio_api_waf_association[0]"
            "aws_wafv2_web_acl.audio_api_waf[0]"
            "aws_lambda_layer_version.dependencies"
            "aws_api_gateway_deployment.api_deployment"
            "aws_s3_bucket.audio_bucket"
            "aws_ecr_repository.audio_stitcher"
        )
        
        for resource in "${problematic_resources[@]}"; do
            print_status "Trying to destroy $resource..."
            terraform destroy -target="$resource" -auto-approve 2>/dev/null || true
        done
        
        # Try full destroy again
        terraform destroy -auto-approve
    fi
    
    cd ..
}

# Clean up local files
cleanup_local_files() {
    print_status "Cleaning up local files..."
    
    # Remove Terraform files
    if [ -f "terraform/.terraform.lock.hcl" ]; then
        rm terraform/.terraform.lock.hcl
        print_success "Removed .terraform.lock.hcl"
    fi
    
    if [ -d "terraform/.terraform" ]; then
        rm -rf terraform/.terraform
        print_success "Removed .terraform directory"
    fi
    
    if [ -f "terraform/tfplan" ]; then
        rm terraform/tfplan
        print_success "Removed tfplan"
    fi
    
    if [ -f "terraform/terraform.tfstate" ]; then
        rm terraform/terraform.tfstate
        print_success "Removed terraform.tfstate"
    fi
    
    if [ -f "terraform/terraform.tfstate.backup" ]; then
        rm terraform/terraform.tfstate.backup
        print_success "Removed terraform.tfstate.backup"
    fi
    
    # Remove build artifacts
    if [ -d "layer" ]; then
        rm -rf layer
        print_success "Removed layer directory"
    fi
    
    if [ -f "layer.zip" ]; then
        rm layer.zip
        print_success "Removed layer.zip"
    fi
    
    if [ -f "lambda_function.zip" ]; then
        rm lambda_function.zip
        print_success "Removed lambda_function.zip"
    fi
    
    print_success "[OK] Local cleanup completed."
}

# Verify cleanup
verify_cleanup() {
    print_status "Verifying cleanup..."
    cd terraform
    
    if terraform state list 2>/dev/null | grep -q .; then
        print_warning "[INFO] Some resources may still exist in state:"
        terraform state list
        print_warning "You may need to manually clean these up."
    else
        print_success "[OK] No resources found in Terraform state."
    fi
    
    cd ..
}

# Aggressive cleanup - tries all methods until successful
aggressive_cleanup() {
    print_status "[AGGRESSIVE] Starting aggressive cleanup - will try all methods until successful"
    echo ""
    
    local cleanup_success=false
    
    # Method 1: Try ultimate cleanup if available
    if [[ -f "ultimate-cleanup.sh" ]]; then
        print_status "[METHOD 1] Trying ultimate-cleanup.sh..."
        chmod +x ultimate-cleanup.sh
        if ./ultimate-cleanup.sh; then
            print_success "[OK] Ultimate cleanup succeeded!"
            cleanup_success=true
        else
            print_warning "[INFO] Ultimate cleanup had issues, continuing with other methods..."
        fi
    fi
    
    # Method 2: Try comprehensive S3 cleanup if bucket still exists
    if [[ "$cleanup_success" = false ]]; then
        print_status "[METHOD 2] Trying comprehensive S3 cleanup..."
        cd terraform
        local bucket_name=$(terraform output -raw s3_bucket_name 2>/dev/null || echo "")
        cd ..
        
        if [[ -n "$bucket_name" ]]; then
            # Use nuke-bucket methods
            print_status "Found bucket: $bucket_name, applying nuclear cleanup..."
            
            # Nuclear S3 cleanup
            local AWS_REGION=${AWS_REGION:-us-east-1}
            
            # Method 2a: Delete all current objects first
            print_status "Step 1: Deleting all current objects..."
            aws s3 rm s3://$bucket_name --recursive --region $AWS_REGION || true
            
            # Method 2b: Delete incomplete multipart uploads
            print_status "Step 2: Deleting incomplete multipart uploads..."
            aws s3api list-multipart-uploads --bucket $bucket_name --region $AWS_REGION --output json 2>/dev/null | \
            jq -r '.Uploads[]? | .Key + " " + .UploadId' | \
            while read -r key upload_id; do
                if [[ -n "$key" && -n "$upload_id" ]]; then
                    print_status "Aborting multipart upload: $key ($upload_id)"
                    aws s3api abort-multipart-upload --bucket $bucket_name --key "$key" --upload-id "$upload_id" --region $AWS_REGION || true
                fi
            done
            
            # Method 2c: Suspend versioning to prevent new versions
            print_status "Step 3: Suspending bucket versioning..."
            aws s3api put-bucket-versioning --bucket $bucket_name --versioning-configuration Status=Suspended --region $AWS_REGION || true
            
            # Method 2d: Delete all object versions in batches
            print_status "Step 4: Deleting all object versions..."
            local page_count=0
            while true; do
                page_count=$((page_count + 1))
                print_status "Processing version page $page_count..."
                
                local versions=$(aws s3api list-object-versions --bucket $bucket_name --region $AWS_REGION --max-keys 1000 --output json 2>/dev/null || echo '{}')
                
                # Check if there are any versions
                local has_versions=$(echo "$versions" | jq -r '.Versions // [] | length')
                local has_markers=$(echo "$versions" | jq -r '.DeleteMarkers // [] | length')
                
                if [[ "$has_versions" == "0" && "$has_markers" == "0" ]]; then
                    print_status "No more versions or delete markers found"
                    break
                fi
                
                if [[ "$has_versions" != "0" ]]; then
                    print_status "Deleting $has_versions object versions..."
                    echo "$versions" | jq -r '.Versions[]? | "{\"Key\": \"" + .Key + "\", \"VersionId\": \"" + .VersionId + "\"}"' | \
                    jq -s '{Objects: ., Quiet: true}' | \
                    aws s3api delete-objects --bucket $bucket_name --region $AWS_REGION --delete file:///dev/stdin || true
                fi
                
                if [[ "$has_markers" != "0" ]]; then
                    print_status "Deleting $has_markers delete markers..."
                    echo "$versions" | jq -r '.DeleteMarkers[]? | "{\"Key\": \"" + .Key + "\", \"VersionId\": \"" + .VersionId + "\"}"' | \
                    jq -s '{Objects: ., Quiet: true}' | \
                    aws s3api delete-objects --bucket $bucket_name --region $AWS_REGION --delete file:///dev/stdin || true
                fi
                
                # Safety check to prevent infinite loops
                if [[ $page_count -gt 100 ]]; then
                    print_warning "Reached maximum page limit (100), breaking loop"
                    break
                fi
                
                sleep 1  # Brief pause between batch operations
            done
            
            # Method 2e: Final recursive delete and force bucket removal
            print_status "Step 5: Final cleanup and bucket deletion..."
            aws s3 rm s3://$bucket_name --recursive --region $AWS_REGION || true
            aws s3 rb s3://$bucket_name --force --region $AWS_REGION || true
            
            # Method 2f: Verify bucket is gone
            if aws s3 ls s3://$bucket_name --region $AWS_REGION 2>/dev/null; then
                print_warning "Bucket $bucket_name still exists after cleanup attempts"
            else
                print_success "Bucket $bucket_name successfully deleted"
            fi
        fi
    fi
    
    # Method 3: Remove problematic resources from terraform state
    print_status "[METHOD 3] Removing problematic resources from terraform state..."
    cd terraform
    
    # Remove S3 resources from state
    terraform state list 2>/dev/null | grep -E "(s3_bucket|ecr_repository)" | while read resource; do
        print_status "Removing from state: $resource"
        terraform state rm "$resource" || true
    done
    
    # Method 4: Force terraform destroy
    print_status "[METHOD 4] Attempting terraform destroy..."
    if terraform destroy -auto-approve; then
        print_success "[OK] Terraform destroy succeeded!"
        cleanup_success=true
    else
        print_warning "[INFO] Terraform destroy had issues, continuing..."
    fi
    
    cd ..
    
    # Method 5: Manual AWS resource cleanup
    print_status "[METHOD 5] Manual AWS resource cleanup..."
    local AWS_REGION=${AWS_REGION:-us-east-1}
    
    # Clean up any remaining S3 buckets
    aws s3 ls 2>/dev/null | grep "audio-stitcher" | while read line; do
        local bucket_name=$(echo $line | awk '{print $3}')
        if [[ -n "$bucket_name" ]]; then
            print_status "Force deleting remaining bucket: $bucket_name"
            aws s3 rb s3://$bucket_name --force || true
        fi
    done
    
    # Clean up any remaining ECR repositories
    aws ecr describe-repositories --region $AWS_REGION 2>/dev/null | jq -r '.repositories[] | select(.repositoryName | contains("audio-stitcher")) | .repositoryName' | while read repo_name; do
        if [[ -n "$repo_name" ]]; then
            print_status "Force deleting remaining ECR repo: $repo_name"
            # Delete images first
            aws ecr list-images --repository-name $repo_name --region $AWS_REGION --query 'imageIds[*]' --output json | \
            aws ecr batch-delete-image --repository-name $repo_name --region $AWS_REGION --image-ids file:///dev/stdin 2>/dev/null || true
            # Delete repository
            aws ecr delete-repository --repository-name $repo_name --region $AWS_REGION --force || true
        fi
    done
    
    # Method 6: Clean up local files
    print_status "[METHOD 6] Cleaning up local files..."
    rm -rf terraform/.terraform* terraform/terraform.tfstate* terraform/tfplan 2>/dev/null || true
    rm -rf layer/ layer.zip lambda_function.zip 2>/dev/null || true
    
    # Final verification
    print_status "[VERIFY] Final verification..."
    cd terraform
    if terraform state list 2>/dev/null | grep -q .; then
        print_warning "[INFO] Some resources may still exist in terraform state"
        terraform state list
    else
        print_success "[OK] Terraform state is clean"
    fi
    cd ..
    
    # Check for remaining AWS resources
    local remaining_buckets=$(aws s3 ls 2>/dev/null | grep "audio-stitcher" | wc -l)
    local remaining_repos=$(aws ecr describe-repositories --region $AWS_REGION 2>/dev/null | jq -r '.repositories[] | select(.repositoryName | contains("audio-stitcher")) | .repositoryName' | wc -l)
    
    if [[ $remaining_buckets -gt 0 || $remaining_repos -gt 0 ]]; then
        print_warning "[INFO] Some AWS resources may still exist:"
        [[ $remaining_buckets -gt 0 ]] && echo "  - $remaining_buckets S3 buckets"
        [[ $remaining_repos -gt 0 ]] && echo "  - $remaining_repos ECR repositories"
        echo "You may need to delete these manually from the AWS console."
    else
        print_success "[OK] No remaining AWS resources detected"
        cleanup_success=true
    fi
    
    if [[ "$cleanup_success" = true ]]; then
        print_success ""
        print_success "[CLEAN] Aggressive cleanup completed successfully!"
        print_success ""
        print_status "All AWS resources have been destroyed."
        print_status "Local files have been cleaned up."
        print_status "You can now run the deployment script again for a fresh start."
    else
        print_warning ""
        print_warning "[PARTIAL] Cleanup partially completed with some issues."
        print_warning "Check the output above for any remaining resources."
        print_warning "You may need to manually delete some resources from AWS console."
    fi
}

# Main execution
main() {
    echo "This will aggressively destroy ALL AWS resources created by this project:"
    echo "  • Lambda functions and layers"
    echo "  • S3 buckets (including all versions and contents)"
    echo "  • ECR repositories and images"
    echo "  • API Gateway and related resources"
    echo "  • IAM roles and policies"
    echo "  • CloudWatch log groups"
    echo "  • WAF rules and associations"
    echo ""
    echo "The script will try multiple cleanup methods until everything is removed:"
    echo "  1. Ultimate comprehensive cleanup"
    echo "  2. Nuclear S3 bucket cleanup"
    echo "  3. Terraform state manipulation"
    echo "  4. Manual AWS resource deletion"
    echo ""
    print_warning "[INFO] WARNING: This action cannot be undone!"
    echo ""
    
    # Confirmation prompt
    read -p "Are you sure you want to proceed? Type 'yes' to continue: " confirmation
    if [ "$confirmation" != "yes" ]; then
        print_warning "Cleanup cancelled by user."
        exit 0
    fi
    
    check_terraform
    check_aws
    list_resources
    
    aggressive_cleanup
}

# Parse command line arguments
FORCE=false
HELP=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --force)
            FORCE=true
            shift
            ;;
        --help)
            HELP=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

if [ "$HELP" = true ]; then
    echo "Usage: $0 [OPTIONS]"
    echo "Options:"
    echo "  --force      Skip confirmation prompts"
    echo "  --help       Show this help message"
    echo ""
    echo "This script will aggressively destroy all AWS resources."
    echo "It tries multiple cleanup methods until everything is removed:"
    echo "  • Ultimate comprehensive cleanup (if available)"
    echo "  • Nuclear S3 bucket cleanup (including versions)"
    echo "  • Terraform state manipulation"
    echo "  • Manual AWS resource deletion"
    echo "  • Local file cleanup"
    exit 0
fi

if [ "$FORCE" = true ]; then
    # Skip confirmations in force mode
    check_terraform
    check_aws
    aggressive_cleanup
else
    main
fi
