#!/bin/bash

# Run API tests from test_api.json file
# This script reads the test cases from test_api.json and executes them

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
get_deployment_info() {
    cd terraform
    
    if [[ ! -f terraform.tfstate ]]; then
        print_error "[ERROR] No Terraform state found. Run ./deploy.sh first"
        exit 1
    fi
    
    API_URL=$(terraform output -raw api_gateway_url)
    BUCKET_NAME=$(terraform output -raw s3_bucket_name)
    
    # Check if API key is enabled
    if terraform state list | grep -q "aws_api_gateway_api_key"; then
        API_KEY_ID=$(terraform output -raw api_key_id 2>/dev/null || echo "")
        if [[ -n "$API_KEY_ID" ]]; then
            print_status "Found API Key ID: $API_KEY_ID"
            API_KEY=$(aws apigateway get-api-key --api-key "$API_KEY_ID" --include-value --query 'value' --output text 2>/dev/null)
            if [[ -n "$API_KEY" && "$API_KEY" != "None" ]]; then
                USE_API_KEY=true
                print_status "API Key retrieved successfully (${#API_KEY} characters)"
            else
                print_error "Failed to retrieve API key value"
                USE_API_KEY=false
            fi
        else
            print_warning "No API Key ID found in terraform outputs"
            USE_API_KEY=false
        fi
    else
        print_status "No API key resources found - API will be tested without authentication"
        USE_API_KEY=false
    fi
    
    cd ..
}

# Run a single test case
run_test_case() {
    local test_name="$1"
    local test_description="$2"
    local message="$3"
    local audios="$4"
    local output="$5"
    local expected_success="$6"
    local should_have_audio="$7"
    
    print_status ""
    print_status "=== Running Test: $test_name ==="
    print_status "Description: $test_description"
    print_status "Message: '$message'"
    print_status "Output: $output"
    
    # Replace bucket placeholder with actual bucket name
    local actual_audios="${audios/audio-stitcher-audio-dev-5d2a5002/$BUCKET_NAME}"
    
    # Prepare request
    local json_body=$(jq -nc --arg msg "$message" --arg bucket "$actual_audios" --arg output "$output" \
        '{message: $msg, audios: $bucket, output: $output}')
    
    # Make request
    if [[ "$USE_API_KEY" == "true" ]]; then
        local response=$(curl -s -w "%{http_code}" -X POST "$API_URL" \
            -H "Content-Type: application/json" \
            -H "x-api-key: $API_KEY" \
            -d "$json_body" 2>/dev/null)
    else
        local response=$(curl -s -w "%{http_code}" -X POST "$API_URL" \
            -H "Content-Type: application/json" \
            -d "$json_body" 2>/dev/null)
    fi
    
    local http_code="${response: -3}"
    local body="${response%???}"
    
    # Analyze response
    if [[ "$http_code" -eq 200 ]]; then
        # Parse the response (body is now a JSON string)
        local success=$(echo "$body" | jq -r '.success // false' 2>/dev/null)
        local response_message=$(echo "$body" | jq -r '.message // "No message"' 2>/dev/null)
        local audio_data=$(echo "$body" | jq -r '.audio_data // ""' 2>/dev/null)
        local audio_size=$(echo "$body" | jq -r '.audio_size_bytes // 0' 2>/dev/null)
        local output_s3_file=$(echo "$body" | jq -r '.output_file // ""' 2>/dev/null)
        
        print_status "Response - Success: $success, Message: $response_message"
        
        # Validate expectations
        local test_passed=true
        
        # Check success expectation
        if [[ "$success" != "$expected_success" ]]; then
            print_error " Expected success=$expected_success, got success=$success"
            test_passed=false
        else
            print_success " Success status matches expectation ($expected_success)"
        fi
        
        # Check audio data expectation
        if [[ "$should_have_audio" == "true" ]]; then
            if [[ -n "$audio_data" && "$audio_data" != "" && "$audio_data" != "null" ]]; then
                print_success " Audio data present as expected ($audio_size bytes)"
                
                # Save the audio file
                local local_filename="test_$(basename "$output")"
                mkdir -p test_results
                echo "$audio_data" | base64 -d > "test_results/$local_filename" 2>/dev/null
                
                if [[ -f "test_results/$local_filename" ]]; then
                    local file_size=$(stat -c%s "test_results/$local_filename" 2>/dev/null || stat -f%z "test_results/$local_filename" 2>/dev/null || echo "unknown")
                    print_success " Audio saved to: test_results/$local_filename ($file_size bytes)"
                else
                    print_error " Failed to save audio file locally"
                    test_passed=false
                fi
            else
                print_error " Expected audio data but none received"
                test_passed=false
            fi
        else
            if [[ -z "$audio_data" || "$audio_data" == "" || "$audio_data" == "null" ]]; then
                print_success " No audio data as expected"
            else
                print_warning "! Got unexpected audio data, but test expected none"
            fi
        fi
        
        # Overall result
        if [[ "$test_passed" == "true" ]]; then
            print_success " TEST PASSED: $test_name"
            return 0
        else
            print_error " TEST FAILED: $test_name"
            return 1
        fi
        
    else
        print_error " HTTP Error $http_code: $body"
        if [[ "$expected_success" == "false" ]]; then
            print_warning "! Expected failure, so this might be correct behavior"
            return 0
        else
            print_error " TEST FAILED: $test_name (expected success but got HTTP error)"
            return 1
        fi
    fi
}

# Main execution
main() {
    print_status "[JSON-TESTS] Audio Stitcher API Tests from test_api.json"
    print_status "========================================================="
    
    # Check if test_api.json exists
    if [[ ! -f "test_api.json" ]]; then
        print_error "[ERROR] test_api.json not found"
        exit 1
    fi
    
    # Get deployment info
    get_deployment_info
    
    echo "API URL: $API_URL"
    echo "S3 Bucket: $BUCKET_NAME"
    echo "API Key Required: $USE_API_KEY"
    echo ""
    
    # Read test cases from JSON
    local test_count=$(jq '.tests | length' test_api.json)
    print_status "Found $test_count test cases"
    
    # Debug: Show all test names
    print_status "Test cases to run:"
    jq -r '.tests[].name' test_api.json | while read test_name; do
        print_status "  - $test_name"
    done
    echo ""
    
    local passed=0
    local failed=0
    
    # Disable exit on error for the test loop to ensure all tests run
    set +e
    
    # Run each test
    for (( i=0; i<test_count; i++ )); do
        print_status "[TEST $((i+1))/$test_count] Preparing test case $i..."
        
        local test_name=$(jq -r ".tests[$i].name" test_api.json)
        local test_description=$(jq -r ".tests[$i].description" test_api.json)
        local message=$(jq -r ".tests[$i].request.message" test_api.json)
        local audios=$(jq -r ".tests[$i].request.audios" test_api.json)
        local output=$(jq -r ".tests[$i].request.output" test_api.json)
        local expected_success=$(jq -r ".tests[$i].expected.success" test_api.json)
        local should_have_audio=$(jq -r ".tests[$i].expected.should_have_audio_data" test_api.json)
        
        print_status "Executing: $test_name"
        
        run_test_case "$test_name" "$test_description" "$message" "$audios" "$output" "$expected_success" "$should_have_audio"
        local test_result=$?
        
        if [[ $test_result -eq 0 ]]; then
            ((passed++))
            print_success " Test $((i+1)) PASSED: $test_name"
        else
            ((failed++))
            print_error " Test $((i+1)) FAILED: $test_name"
        fi
        
        echo "----------------------------------------"
        print_status "Completed test $((i+1))/$test_count. Moving to next test..."
        sleep 1  # Brief pause between tests
    done
    
    # Re-enable exit on error for final results
    set -e
    
    print_status "All tests completed. Preparing final results..."
    
    # Final results
    print_status ""
    print_status "========================================================="
    print_status "Test Results Summary:"
    print_success " Passed: $passed"
    print_error " Failed: $failed"
    print_status "Total: $((passed + failed))"
    
    if [[ $failed -eq 0 ]]; then
        print_success " ALL TESTS PASSED!"
        return 0
    else
        print_error " SOME TESTS FAILED"
        return 1
    fi
}

# Install jq if not present
if ! command -v jq &> /dev/null; then
    print_status "[INFO] Installing jq..."
    sudo apt-get update && sudo apt-get install -y jq
fi

main "$@"