#!/bin/bash

# Nuclear S3 bucket deletion script
set -e

echo "[NUKE] S3 Bucket Nuclear Cleanup Script"

# Get bucket name
cd terraform
BUCKET_NAME=$(terraform output -raw s3_bucket_name 2>/dev/null || echo "audio-stitcher-audio-dev-5d2a5002")
AWS_REGION=$(terraform output -raw aws_region 2>/dev/null || echo "us-east-1")
cd ..

echo "Target bucket: $BUCKET_NAME"
echo "Region: $AWS_REGION"

# Method 1: AWS CLI nuclear option
echo "[NUKE] Method 1: AWS CLI nuclear delete..."
aws s3 rb s3://$BUCKET_NAME --force --region $AWS_REGION || echo "Method 1 failed, trying method 2..."

# Method 2: Manual version deletion
echo "[NUKE] Method 2: Manual version deletion..."

# Delete all object versions
echo "Deleting object versions..."
aws s3api list-object-versions --bucket $BUCKET_NAME --region $AWS_REGION --output json --max-items 1000 | \
jq -r '.Versions[]? | "\(.Key) \(.VersionId)"' | \
while read -r key version_id; do
    if [[ -n "$key" && -n "$version_id" && "$version_id" != "null" ]]; then
        echo "Deleting version: $key ($version_id)"
        aws s3api delete-object --bucket $BUCKET_NAME --key "$key" --version-id "$version_id" --region $AWS_REGION || true
    fi
done

# Delete all delete markers
echo "Deleting delete markers..."
aws s3api list-object-versions --bucket $BUCKET_NAME --region $AWS_REGION --output json --max-items 1000 | \
jq -r '.DeleteMarkers[]? | "\(.Key) \(.VersionId)"' | \
while read -r key version_id; do
    if [[ -n "$key" && -n "$version_id" && "$version_id" != "null" ]]; then
        echo "Deleting marker: $key ($version_id)"
        aws s3api delete-object --bucket $BUCKET_NAME --key "$key" --version-id "$version_id" --region $AWS_REGION || true
    fi
done

# Method 3: Direct AWS CLI batch delete
echo "[NUKE] Method 3: AWS CLI batch delete..."

# Create temporary JSON files for batch deletion
TEMP_DIR="/tmp/s3_cleanup_$$"
mkdir -p "$TEMP_DIR"

# Get all versions and delete markers in JSON format
aws s3api list-object-versions --bucket "$BUCKET_NAME" --region "$AWS_REGION" --output json > "$TEMP_DIR/versions.json" 2>/dev/null || echo "{}" > "$TEMP_DIR/versions.json"

# Extract versions for deletion
cat "$TEMP_DIR/versions.json" | jq -r '.Versions[]? | "{\"Key\": \"" + .Key + "\", \"VersionId\": \"" + .VersionId + "\"}"' > "$TEMP_DIR/version_objects.txt" 2>/dev/null || touch "$TEMP_DIR/version_objects.txt"

# Extract delete markers for deletion  
cat "$TEMP_DIR/versions.json" | jq -r '.DeleteMarkers[]? | "{\"Key\": \"" + .Key + "\", \"VersionId\": \"" + .VersionId + "\"}"' > "$TEMP_DIR/marker_objects.txt" 2>/dev/null || touch "$TEMP_DIR/marker_objects.txt"

# Batch delete versions if any exist
if [[ -s "$TEMP_DIR/version_objects.txt" ]]; then
    echo "Batch deleting object versions..."
    echo "{\"Objects\": [$(tr '\n' ',' < "$TEMP_DIR/version_objects.txt" | sed 's/,$//')], \"Quiet\": false}" > "$TEMP_DIR/delete_versions.json"
    aws s3api delete-objects --bucket "$BUCKET_NAME" --delete "file://$TEMP_DIR/delete_versions.json" --region "$AWS_REGION" || true
fi

# Batch delete markers if any exist
if [[ -s "$TEMP_DIR/marker_objects.txt" ]]; then
    echo "Batch deleting delete markers..."
    echo "{\"Objects\": [$(tr '\n' ',' < "$TEMP_DIR/marker_objects.txt" | sed 's/,$//')], \"Quiet\": false}" > "$TEMP_DIR/delete_markers.json"
    aws s3api delete-objects --bucket "$BUCKET_NAME" --delete "file://$TEMP_DIR/delete_markers.json" --region "$AWS_REGION" || true
fi

# Cleanup temp files
rm -rf "$TEMP_DIR"

# Method 4: Force terraform state removal
echo "[NUKE] Method 4: Terraform state cleanup..."
cd terraform
terraform state rm aws_s3_bucket.audio_bucket || true
terraform state rm aws_s3_bucket_versioning.audio_bucket_versioning || true
terraform state rm aws_s3_bucket_server_side_encryption_configuration.audio_bucket_encryption || true

# Try terraform destroy again
echo "[NUKE] Final terraform destroy..."
terraform destroy -auto-approve

cd ..
echo "[NUKE] Nuclear cleanup complete!"
