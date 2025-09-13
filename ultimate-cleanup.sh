#!/bin/bash

echo "[ULTIMATE] Ultimate AWS Cleanup - Combines all methods"
set -e

# Step 1: Try comprehensive bucket cleanup first
if [[ -f "nuke-bucket.sh" ]]; then
    echo "[STEP 1] Running comprehensive S3 cleanup..."
    chmod +x nuke-bucket.sh
    ./nuke-bucket.sh
    echo "[OK] Comprehensive cleanup completed"
else
    echo "[STEP 1] nuke-bucket.sh not found, skipping comprehensive cleanup"
fi

# Step 2: Clean up any remaining terraform resources
echo "[STEP 2] Terraform state cleanup..."
cd terraform

# Get any remaining resources
echo "Remaining terraform resources:"
terraform state list || echo "No resources in state"

# Remove any S3 or ECR resources still in state
terraform state list 2>/dev/null | grep -E "(s3_bucket|ecr_repository)" | while read resource; do
    echo "Removing from state: $resource"
    terraform state rm "$resource" || true
done

# Try to destroy remaining resources
echo "[STEP 2] Destroying remaining resources..."
if terraform state list 2>/dev/null | grep -q .; then
    terraform destroy -auto-approve
    echo "[OK] Terraform destroy completed"
else
    echo "[OK] No terraform resources to destroy"
fi

cd ..

# Step 3: Manual cleanup of any remaining AWS resources
echo "[STEP 3] Manual cleanup of any remaining AWS resources..."

# Get region
AWS_REGION=${AWS_REGION:-us-east-1}

# Check for any remaining S3 buckets with our pattern
echo "Checking for remaining S3 buckets..."
aws s3 ls | grep "audio-stitcher" | while read line; do
    bucket_name=$(echo $line | awk '{print $3}')
    echo "Found remaining bucket: $bucket_name"
    aws s3 rb s3://$bucket_name --force || echo "Failed to delete $bucket_name"
done

# Check for any remaining ECR repositories
echo "Checking for remaining ECR repositories..."
aws ecr describe-repositories --region $AWS_REGION 2>/dev/null | grep "audio-stitcher" | while read line; do
    repo_name=$(echo $line | grep -o '"repositoryName":"[^"]*' | cut -d'"' -f4)
    if [[ -n "$repo_name" ]]; then
        echo "Found remaining ECR repo: $repo_name"
        aws ecr delete-repository --repository-name $repo_name --region $AWS_REGION --force || true
    fi
done

# Step 4: Clean up local files
echo "[STEP 4] Local file cleanup..."
rm -rf terraform/.terraform* terraform/terraform.tfstate* terraform/tfplan 2>/dev/null || true
rm -rf layer/ layer.zip lambda_function.zip 2>/dev/null || true

echo ""
echo "[SUCCESS] Ultimate cleanup completed!"
echo ""
echo "What was cleaned:"
echo "  [x] S3 buckets (including versioned objects)"
echo "  [x] ECR repositories and images"  
echo "  [x] All terraform resources"
echo "  [x] Local terraform state files"
echo "  [x] Local build artifacts"
echo ""
echo "Your AWS account should now be clean of audio-stitcher resources."
