#!/bin/bash

# Test API and Download Stitched Audio
# Complete workflow: test API → check success → download audio

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

print_status() { echo -e "${CYAN}$1${NC}"; }
print_success() { echo -e "${GREEN}$1${NC}"; }
print_error() { echo -e "${RED}$1${NC}"; }
print_warning() { echo -e "${YELLOW}$1${NC}"; }

# Get deployment info
cd terraform
API_URL=$(terraform output -raw api_gateway_url)
BUCKET_NAME=$(terraform output -raw s3_bucket_name)
API_KEY_ID=$(terraform output -raw api_key_id 2>/dev/null || echo "")

if [[ -n "$API_KEY_ID" ]]; then
    API_KEY=$(aws apigateway get-api-key --api-key "$API_KEY_ID" --include-value --query 'value' --output text)
    USE_API_KEY=true
else
    USE_API_KEY=false
fi
cd ..

# Test parameters
MESSAGE="${1:-hello shreeshail}"
OUTPUT_FILE="output/test_$(date +%s).mp3"

print_status "[API] Testing Audio Stitching API"
print_status "=================================="
echo "Message: '$MESSAGE'"
echo "Output: $OUTPUT_FILE"
echo "Bucket: $BUCKET_NAME"
echo "API Key: $([ "$USE_API_KEY" = true ] && echo "Yes" || echo "No")"
echo ""

# Step 1: Make API call
print_status "[STEP 1] Calling API to stitch audio..."

if [[ "$USE_API_KEY" == "true" ]]; then
    RESPONSE=$(curl -s -w "%{http_code}" -X POST "$API_URL" \
        -H "Content-Type: application/json" \
        -H "x-api-key: $API_KEY" \
        -d "{
          \"message\": \"$MESSAGE\",
          \"audios\": \"$BUCKET_NAME\",
          \"output\": \"$OUTPUT_FILE\"
        }")
else
    RESPONSE=$(curl -s -w "%{http_code}" -X POST "$API_URL" \
        -H "Content-Type: application/json" \
        -d "{
          \"message\": \"$MESSAGE\",
          \"audios\": \"$BUCKET_NAME\",
          \"output\": \"$OUTPUT_FILE\"
        }")
fi

HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

print_status "HTTP Status: $HTTP_CODE"

# Step 2: Check response and extract audio
if [[ "$HTTP_CODE" -eq 200 ]]; then
    print_success "[OK] API call successful!"
    
    # Parse response
    SUCCESS=$(echo "$BODY" | jq -r '.success // false' 2>/dev/null)
    MESSAGE_RESP=$(echo "$BODY" | jq -r '.message // "No message"' 2>/dev/null)
    AUDIO_DATA=$(echo "$BODY" | jq -r '.audio_data // ""' 2>/dev/null)
    AUDIO_SIZE=$(echo "$BODY" | jq -r '.audio_size_bytes // 0' 2>/dev/null)
    
    print_status "Response: $MESSAGE_RESP"
    print_status "Success: $SUCCESS"
    print_status "Audio size: $AUDIO_SIZE bytes"
    
    if [[ "$SUCCESS" == "true" ]]; then
        print_success "[STEP 2] Audio stitching successful!"
        
        # Check if audio data is in response
        if [[ -n "$AUDIO_DATA" && "$AUDIO_DATA" != "" && "$AUDIO_DATA" != "null" ]]; then
            print_success "[STEP 3] Audio data received in API response!"
            
            # Save audio data from response
            LOCAL_FILE="stitched_$(date +%s).mp3"
            echo "$AUDIO_DATA" | base64 -d > "$LOCAL_FILE"
            
            if [[ -f "$LOCAL_FILE" ]]; then
                FILE_SIZE=$(stat -c%s "$LOCAL_FILE" 2>/dev/null || stat -f%z "$LOCAL_FILE" 2>/dev/null || echo "unknown")
                print_success "[DOWNLOADED] Audio saved from API response: $LOCAL_FILE ($FILE_SIZE bytes)"
                
                # Verify it's a valid audio file
                if command -v file &> /dev/null; then
                    FILE_TYPE=$(file "$LOCAL_FILE")
                    print_status "File type: $FILE_TYPE"
                fi
                
                echo ""
                print_success "COMPLETE SUCCESS!"
                print_status "API call successful"
                print_status "Audio stitching successful" 
                print_status "Audio file downloaded: $LOCAL_FILE"
                exit 0
            else
                print_error "[ERROR] Failed to save audio data from response"
            fi
        else
            print_warning "[INFO] No audio data in response, checking S3..."
        fi
    else
        print_error "[STEP 2] Audio stitching failed!"
        print_error "Reason: $MESSAGE_RESP"
        exit 1
    fi
else
    print_error "[ERROR] API call failed (HTTP $HTTP_CODE)"
    print_error "Response: $BODY"
    exit 1
fi

# Step 3: Fallback - check S3 for the file
print_status "[STEP 3] Checking S3 for generated file..."

# Wait a moment for S3 consistency
sleep 2

# Check if file exists in S3
if aws s3 ls "s3://$BUCKET_NAME/$OUTPUT_FILE" >/dev/null 2>&1; then
    print_success "[S3] File found in S3: $OUTPUT_FILE"
    
    # Download from S3
    LOCAL_FILE="s3_downloaded_$(date +%s).mp3"
    print_status "[DOWNLOAD] Downloading from S3..."
    
    if aws s3 cp "s3://$BUCKET_NAME/$OUTPUT_FILE" "$LOCAL_FILE"; then
        FILE_SIZE=$(stat -c%s "$LOCAL_FILE" 2>/dev/null || stat -f%z "$LOCAL_FILE" 2>/dev/null || echo "unknown")
        print_success "[DOWNLOADED] Audio saved from S3: $LOCAL_FILE ($FILE_SIZE bytes)"
        
        echo ""
        print_success "SUCCESS!"
        print_status " API call successful"
        print_status " Audio stitching successful"
        print_status " Audio file downloaded from S3: $LOCAL_FILE"
    else
        print_error "[ERROR] Failed to download from S3"
        exit 1
    fi
else
    print_error "[ERROR] File not found in S3: $OUTPUT_FILE"
    
    # Show what files do exist
    print_status "[DEBUG] Files in S3 output directory:"
    aws s3 ls "s3://$BUCKET_NAME/output/" --human-readable || print_warning "No files in output directory"
    
    exit 1
fi
