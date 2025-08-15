#!/bin/bash

# Test and Deployment script for Amazon Macie CloudWatch Logs Security Solution
# This script can deploy the CloudFormation stack and validate end-to-end functionality

set -e

# Default Configuration (can be overridden by environment variables or command line)
STACK_NAME="${STACK_NAME:-macie-for-securing-cloudwatch-logs-v5}"
REGION="${REGION:-us-east-1}"
LOG_GROUP_NAME="${LOG_GROUP_NAME:-/aws/lambda/ConfigSetup}"
RESOURCE_NAME="${RESOURCE_NAME:-default-resource-name}"
BUCKET_NAME="${BUCKET_NAME:-default-s3-bucket-name}"
SNS_EMAIL="${SNS_EMAIL:-}"
ENABLE_MACIE="${ENABLE_MACIE:-false}"
TEMPLATE_PATH="${TEMPLATE_PATH:-app/main.yml}"
TEST_LOG_STREAM="macie-test-stream-$(date +%s)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to get stack outputs
get_stack_output() {
    local output_key=$1
    aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query "Stacks[0].Outputs[?OutputKey=='$output_key'].OutputValue" \
        --output text --no-cli-pager 2>/dev/null || echo ""
}

# Function to get stack resources
get_stack_resource() {
    local logical_id=$1
    aws cloudformation describe-stack-resources \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --logical-resource-id "$logical_id" \
        --query "StackResources[0].PhysicalResourceId" \
        --output text --no-cli-pager 2>/dev/null || echo ""
}

# Function to check if stack exists and is complete
check_stack_status() {
    log_info "Checking CloudFormation stack status..."
    
    local stack_status=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query "Stacks[0].StackStatus" \
        --output text --no-cli-pager 2>/dev/null || echo "NOT_FOUND")
    
    if [ "$stack_status" = "NOT_FOUND" ]; then
        log_error "CloudFormation stack '$STACK_NAME' not found"
        return 1
    elif [ "$stack_status" != "CREATE_COMPLETE" ] && [ "$stack_status" != "UPDATE_COMPLETE" ]; then
        log_error "Stack status is '$stack_status', expected CREATE_COMPLETE or UPDATE_COMPLETE"
        return 1
    fi
    
    log_success "Stack status: $stack_status"
    return 0
}

# Function to generate test data with sensitive information
generate_test_data() {
    log_info "Generating test data with sensitive information..."
    
    # Create log stream
    aws logs create-log-stream \
        --log-group-name "$LOG_GROUP_NAME" \
        --log-stream-name "$TEST_LOG_STREAM" \
        --region "$REGION" --no-cli-pager 2>/dev/null || true
    
    # Generate test log entries with sensitive data patterns
    local timestamp=$(date +%s)000
    local test_messages=(
        "User login attempt for employee AnyCompany-12345678 from IP 192.168.1.100"
        "Processing patent application patentID: AnyCompany-87654321 for user john.doe@example.com"
        "Credit card transaction: 4532-1234-5678-9012 amount: \$150.00"
        "SSN verification: 123-45-6789 for account AnyCompany-11223344"
        "Employee patent AnyCompany-99887766 submitted for review"
        "Normal log entry without sensitive data - system startup completed"
        "Database connection established for user admin"
        "API request processed successfully - response time 150ms"
    )
    
    local log_events="["
    for i in "${!test_messages[@]}"; do
        if [ $i -gt 0 ]; then
            log_events+=","
        fi
        log_events+="{\"timestamp\":$((timestamp + i * 1000)),\"message\":\"${test_messages[$i]}\"}"
    done
    log_events+="]"
    
    # Send log events
    aws logs put-log-events \
        --log-group-name "$LOG_GROUP_NAME" \
        --log-stream-name "$TEST_LOG_STREAM" \
        --log-events "$log_events" \
        --region "$REGION" --no-cli-pager >/dev/null
    
    log_success "Generated ${#test_messages[@]} test log entries with sensitive data patterns"
    log_info "Test log stream: $TEST_LOG_STREAM"
}

# Function to verify data pipeline flow
verify_pipeline() {
    log_info "Verifying data pipeline flow..."
    
    # Get S3 bucket name
    local s3_bucket=$(get_stack_resource "CloudWatchLogsBucket")
    if [ -z "$s3_bucket" ]; then
        log_error "Could not find S3 bucket from stack resources"
        return 1
    fi
    
    log_info "Monitoring S3 bucket: $s3_bucket"
    
    # Wait for data to flow through pipeline
    log_info "Waiting for data to flow through Kinesis Data Firehose (this may take 1-2 minutes)..."
    sleep 90
    
    # Check if objects exist in S3
    local object_count=$(aws s3 ls "s3://$s3_bucket/firehose/" --recursive --region "$REGION" --no-cli-pager | wc -l)
    
    if [ "$object_count" -gt 0 ]; then
        log_success "Found $object_count objects in S3 bucket"
        
        # List recent objects
        log_info "Recent objects in S3:"
        aws s3 ls "s3://$s3_bucket/firehose/" --recursive --region "$REGION" --no-cli-pager | tail -5
        
        # Verify encryption
        local sample_object=$(aws s3 ls "s3://$s3_bucket/firehose/" --recursive --region "$REGION" --no-cli-pager | head -1 | awk '{print $4}')
        if [ -n "$sample_object" ]; then
            local encryption=$(aws s3api head-object --bucket "$s3_bucket" --key "$sample_object" --region "$REGION" --query "ServerSideEncryption" --output text --no-cli-pager 2>/dev/null || echo "None")
            log_info "Sample object encryption: $encryption"
        fi
    else
        log_warning "No objects found in S3 bucket yet. Data may still be in transit."
    fi
}

# Function to trigger Macie classification job
trigger_macie_job() {
    log_info "Triggering Macie classification job..."
    
    # Check if Macie is enabled
    local macie_status=$(aws macie2 get-macie-session --region "$REGION" --query "status" --output text --no-cli-pager 2>/dev/null || echo "DISABLED")
    
    if [ "$macie_status" != "ENABLED" ]; then
        log_warning "Macie is not enabled. Skipping Macie job trigger."
        return 0
    fi
    
    # Get Lambda function name for Macie data processing
    local lambda_function=$(get_stack_resource "macieDataLambda")
    if [ -z "$lambda_function" ]; then
        log_error "Could not find Macie data Lambda function"
        return 1
    fi
    
    # Invoke the Lambda function to trigger Macie job
    log_info "Invoking Lambda function: $lambda_function"
    local result=$(aws lambda invoke \
        --function-name "$lambda_function" \
        --region "$REGION" \
        --payload '{}' \
        --no-cli-pager \
        /tmp/lambda-response.json 2>&1)
    
    if [ $? -eq 0 ]; then
        log_success "Macie classification job triggered successfully"
        cat /tmp/lambda-response.json
    else
        log_error "Failed to trigger Macie job: $result"
        return 1
    fi
}

# Function to verify alerts and data isolation
verify_alerts() {
    log_info "Verifying alerting and data isolation mechanisms..."
    
    # Check SNS topic
    local sns_topic=$(get_stack_resource "SNSTopic")
    if [ -n "$sns_topic" ]; then
        log_info "SNS Topic: $sns_topic"
        
        # Check subscriptions
        local subscription_count=$(aws sns list-subscriptions-by-topic \
            --topic-arn "$sns_topic" \
            --region "$REGION" \
            --query "length(Subscriptions)" \
            --output text --no-cli-pager)
        log_info "SNS subscriptions: $subscription_count"
    fi
    
    # Check EventBridge rules
    local event_rule=$(get_stack_resource "MacieEventRule")
    if [ -n "$event_rule" ]; then
        log_info "EventBridge rule: $event_rule"
        
        local rule_state=$(aws events describe-rule \
            --name "$event_rule" \
            --region "$REGION" \
            --query "State" \
            --output text --no-cli-pager 2>/dev/null || echo "NOT_FOUND")
        log_info "Rule state: $rule_state"
    fi
    
    # Check isolation bucket
    local isolation_bucket=$(get_stack_resource "DataIsolationBucket")
    if [ -n "$isolation_bucket" ]; then
        log_info "Data isolation bucket: $isolation_bucket"
        
        local isolation_objects=$(aws s3 ls "s3://$isolation_bucket/" --recursive --region "$REGION" --no-cli-pager | wc -l)
        log_info "Objects in isolation bucket: $isolation_objects"
    fi
    
    log_success "Alert and isolation mechanisms verified"
}

# Function to run full end-to-end test
full_test() {
    log_info "Running comprehensive end-to-end test..."
    
    local test_results=()
    
    # Run all test steps
    if check_stack_status; then
        test_results+=("✓ Stack Status Check")
    else
        test_results+=("✗ Stack Status Check")
    fi
    
    if generate_test_data; then
        test_results+=("✓ Test Data Generation")
    else
        test_results+=("✗ Test Data Generation")
    fi
    
    if verify_pipeline; then
        test_results+=("✓ Pipeline Verification")
    else
        test_results+=("✗ Pipeline Verification")
    fi
    
    if trigger_macie_job; then
        test_results+=("✓ Macie Job Trigger")
    else
        test_results+=("✗ Macie Job Trigger")
    fi
    
    if verify_alerts; then
        test_results+=("✓ Alerts Verification")
    else
        test_results+=("✗ Alerts Verification")
    fi
    
    # Generate test report
    log_info "=== TEST REPORT ==="
    for result in "${test_results[@]}"; do
        if [[ $result == *"✓"* ]]; then
            log_success "$result"
        else
            log_error "$result"
        fi
    done
    
    local passed_tests=$(printf '%s\n' "${test_results[@]}" | grep -c "✓" || echo "0")
    local total_tests=${#test_results[@]}
    
    log_info "=== SUMMARY ==="
    log_info "Tests passed: $passed_tests/$total_tests"
    
    if [ "$passed_tests" -eq "$total_tests" ]; then
        log_success "All tests passed! The Macie security solution is working correctly."
        return 0
    else
        log_error "Some tests failed. Please review the output above."
        return 1
    fi
}

# Function to deploy CloudFormation stack
deploy_stack() {
    log_info "Deploying CloudFormation stack: $STACK_NAME"
    
    # Validate required parameters
    if [ -z "$SNS_EMAIL" ]; then
        log_error "SNS_EMAIL is required for deployment. Set it via environment variable or --email parameter."
        return 1
    fi
    
    if [ ! -f "$TEMPLATE_PATH" ]; then
        log_error "CloudFormation template not found at: $TEMPLATE_PATH"
        return 1
    fi
    
    # Generate unique bucket name if using default
    if [ "$BUCKET_NAME" = "default-s3-bucket-name" ]; then
        BUCKET_NAME="macie-logs-$(date +%s)-$(openssl rand -hex 4)"
        log_info "Generated unique bucket name: $BUCKET_NAME"
    fi
    
    # Check if stack already exists
    local stack_exists=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query "Stacks[0].StackName" \
        --output text --no-cli-pager 2>/dev/null || echo "NOT_FOUND")
    
    local operation="create-stack"
    local operation_text="Creating"
    
    if [ "$stack_exists" != "NOT_FOUND" ]; then
        operation="update-stack"
        operation_text="Updating"
        log_info "Stack already exists, updating instead of creating"
    fi
    
    log_info "$operation_text CloudFormation stack with parameters:"
    log_info "  Stack Name: $STACK_NAME"
    log_info "  Region: $REGION"
    log_info "  Resource Name: $RESOURCE_NAME"
    log_info "  Bucket Name: $BUCKET_NAME"
    log_info "  Log Group Name: $LOG_GROUP_NAME"
    log_info "  SNS Email: $SNS_EMAIL"
    log_info "  Enable Macie: $ENABLE_MACIE"
    log_info "  Template Path: $TEMPLATE_PATH"
    
    # Deploy the stack
    local deploy_result=$(aws cloudformation $operation \
        --stack-name "$STACK_NAME" \
        --template-body "file://$TEMPLATE_PATH" \
        --parameters \
            "ParameterKey=ResourceName,ParameterValue=$RESOURCE_NAME" \
            "ParameterKey=BucketName,ParameterValue=$BUCKET_NAME" \
            "ParameterKey=LogGroupName,ParameterValue=$LOG_GROUP_NAME" \
            "ParameterKey=SNSTopicEndpointEmail,ParameterValue=$SNS_EMAIL" \
            "ParameterKey=EnableMacie,ParameterValue=$ENABLE_MACIE" \
        --capabilities CAPABILITY_IAM \
        --region "$REGION" \
        --no-cli-pager 2>&1)
    
    if [ $? -eq 0 ]; then
        log_success "Stack $operation initiated successfully"
        
        # Wait for stack operation to complete
        log_info "Waiting for stack operation to complete (this may take 5-10 minutes)..."
        
        local wait_condition="stack-create-complete"
        if [ "$operation" = "update-stack" ]; then
            wait_condition="stack-update-complete"
        fi
        
        aws cloudformation wait $wait_condition \
            --stack-name "$STACK_NAME" \
            --region "$REGION" \
            --no-cli-pager
        
        if [ $? -eq 0 ]; then
            log_success "Stack operation completed successfully!"
            
            # Display stack outputs
            log_info "Stack Outputs:"
            aws cloudformation describe-stacks \
                --stack-name "$STACK_NAME" \
                --region "$REGION" \
                --query "Stacks[0].Outputs[*].[OutputKey,OutputValue]" \
                --output table --no-cli-pager
            
            return 0
        else
            log_error "Stack operation failed or timed out"
            
            # Show stack events for debugging
            log_info "Recent stack events:"
            aws cloudformation describe-stack-events \
                --stack-name "$STACK_NAME" \
                --region "$REGION" \
                --query "StackEvents[0:10].[Timestamp,ResourceStatus,ResourceType,LogicalResourceId,ResourceStatusReason]" \
                --output table --no-cli-pager
            
            return 1
        fi
    else
        log_error "Failed to initiate stack $operation: $deploy_result"
        return 1
    fi
}

# Function to validate deployment parameters
validate_deployment_params() {
    log_info "Validating deployment parameters..."
    
    # Check AWS CLI is configured
    if ! aws sts get-caller-identity --no-cli-pager >/dev/null 2>&1; then
        log_error "AWS CLI is not configured or credentials are invalid"
        return 1
    fi
    
    # Check if region is valid
    if ! aws ec2 describe-regions --region-names "$REGION" --no-cli-pager >/dev/null 2>&1; then
        log_error "Invalid AWS region: $REGION"
        return 1
    fi
    
    # Validate email format
    if [ -n "$SNS_EMAIL" ] && ! echo "$SNS_EMAIL" | grep -E '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$' >/dev/null; then
        log_error "Invalid email format: $SNS_EMAIL"
        return 1
    fi
    
    # Check template file exists
    if [ ! -f "$TEMPLATE_PATH" ]; then
        log_error "CloudFormation template not found: $TEMPLATE_PATH"
        return 1
    fi
    
    log_success "Deployment parameters validated successfully"
    return 0
}

# Function to display deployment status
show_deployment_status() {
    log_info "Checking deployment status for stack: $STACK_NAME"
    
    local stack_status=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query "Stacks[0].StackStatus" \
        --output text --no-cli-pager 2>/dev/null || echo "NOT_FOUND")
    
    if [ "$stack_status" = "NOT_FOUND" ]; then
        log_warning "Stack '$STACK_NAME' not found in region '$REGION'"
        return 1
    fi
    
    log_info "Stack Status: $stack_status"
    
    # Show stack outputs if available
    local outputs=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query "Stacks[0].Outputs" \
        --output json --no-cli-pager 2>/dev/null)
    
    if [ "$outputs" != "null" ] && [ "$outputs" != "[]" ]; then
        log_info "Stack Outputs:"
        echo "$outputs" | jq -r '.[] | "  \(.OutputKey): \(.OutputValue)"' 2>/dev/null || \
        aws cloudformation describe-stacks \
            --stack-name "$STACK_NAME" \
            --region "$REGION" \
            --query "Stacks[0].Outputs[*].[OutputKey,OutputValue]" \
            --output table --no-cli-pager
    fi
    
    # Show recent stack events
    log_info "Recent Stack Events (last 5):"
    aws cloudformation describe-stack-events \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query "StackEvents[0:5].[Timestamp,ResourceStatus,ResourceType,LogicalResourceId]" \
        --output table --no-cli-pager
    
    return 0
}

# Function to display help
show_help() {
    echo "Usage: $0 [OPTION] [PARAMETERS]"
    echo ""
    echo "Test and Deployment script for Amazon Macie CloudWatch Logs Security Solution"
    echo ""
    echo "Deployment Options:"
    echo "  --deploy-stack          Deploy the CloudFormation stack"
    echo "  --validate-params       Validate deployment parameters"
    echo "  --deployment-status     Show current deployment status"
    echo ""
    echo "Testing Options:"
    echo "  --generate-test-data    Generate CloudWatch log entries with sensitive data"
    echo "  --verify-pipeline       Verify data flow through Kinesis Firehose to S3"
    echo "  --trigger-macie-job     Trigger Macie classification job"
    echo "  --verify-alerts         Verify SNS notifications and data isolation"
    echo "  --full-test            Run comprehensive end-to-end test"
    echo ""
    echo "General Options:"
    echo "  --help                 Display this help message"
    echo ""
    echo "Parameters (can also be set as environment variables):"
    echo "  --stack-name NAME      CloudFormation stack name (default: $STACK_NAME)"
    echo "  --region REGION        AWS region (default: $REGION)"
    echo "  --resource-name NAME   Resource prefix name (default: $RESOURCE_NAME)"
    echo "  --bucket-name NAME     S3 bucket name (default: auto-generated)"
    echo "  --log-group NAME       CloudWatch log group name (default: $LOG_GROUP_NAME)"
    echo "  --email EMAIL          SNS notification email (required for deployment)"
    echo "  --enable-macie BOOL    Enable Macie service (true/false, default: $ENABLE_MACIE)"
    echo "  --template-path PATH   CloudFormation template path (default: $TEMPLATE_PATH)"
    echo ""
    echo "Environment Variables:"
    echo "  STACK_NAME             CloudFormation stack name"
    echo "  REGION                 AWS region"
    echo "  RESOURCE_NAME          Resource prefix name"
    echo "  BUCKET_NAME            S3 bucket name"
    echo "  LOG_GROUP_NAME         CloudWatch log group name"
    echo "  SNS_EMAIL              SNS notification email"
    echo "  ENABLE_MACIE           Enable Macie service (true/false)"
    echo "  TEMPLATE_PATH          CloudFormation template path"
    echo ""
    echo "Examples:"
    echo "  # Deploy stack with custom parameters"
    echo "  $0 --deploy-stack --stack-name my-macie-stack --email user@example.com --enable-macie true"
    echo ""
    echo "  # Run full test on existing deployment"
    echo "  $0 --full-test --stack-name my-macie-stack"
    echo ""
    echo "  # Deploy using environment variables"
    echo "  export STACK_NAME=my-stack SNS_EMAIL=user@example.com ENABLE_MACIE=true"
    echo "  $0 --deploy-stack"
    echo ""
}

# Function to parse command line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --stack-name)
                STACK_NAME="$2"
                shift 2
                ;;
            --region)
                REGION="$2"
                shift 2
                ;;
            --resource-name)
                RESOURCE_NAME="$2"
                shift 2
                ;;
            --bucket-name)
                BUCKET_NAME="$2"
                shift 2
                ;;
            --log-group)
                LOG_GROUP_NAME="$2"
                shift 2
                ;;
            --email)
                SNS_EMAIL="$2"
                shift 2
                ;;
            --enable-macie)
                ENABLE_MACIE="$2"
                shift 2
                ;;
            --template-path)
                TEMPLATE_PATH="$2"
                shift 2
                ;;
            --deploy-stack)
                ACTION="deploy-stack"
                shift
                ;;
            --validate-params)
                ACTION="validate-params"
                shift
                ;;
            --deployment-status)
                ACTION="deployment-status"
                shift
                ;;
            --generate-test-data)
                ACTION="generate-test-data"
                shift
                ;;
            --verify-pipeline)
                ACTION="verify-pipeline"
                shift
                ;;
            --trigger-macie-job)
                ACTION="trigger-macie-job"
                shift
                ;;
            --verify-alerts)
                ACTION="verify-alerts"
                shift
                ;;
            --full-test)
                ACTION="full-test"
                shift
                ;;
            --help)
                ACTION="help"
                shift
                ;;
            *)
                log_error "Unknown option: $1. Use --help for usage information."
                exit 1
                ;;
        esac
    done
}

# Main script logic
main() {
    # Parse command line arguments
    parse_arguments "$@"
    
    # Execute the requested action
    case "${ACTION:-}" in
        deploy-stack)
            validate_deployment_params && deploy_stack
            ;;
        validate-params)
            validate_deployment_params
            ;;
        deployment-status)
            show_deployment_status
            ;;
        generate-test-data)
            check_stack_status && generate_test_data
            ;;
        verify-pipeline)
            check_stack_status && verify_pipeline
            ;;
        trigger-macie-job)
            check_stack_status && trigger_macie_job
            ;;
        verify-alerts)
            check_stack_status && verify_alerts
            ;;
        full-test)
            full_test
            ;;
        help)
            show_help
            ;;
        "")
            log_error "No action specified. Use --help for usage information."
            exit 1
            ;;
        *)
            log_error "Unknown action: $ACTION. Use --help for usage information."
            exit 1
            ;;
    esac
}

# Run main function with all arguments
main "$@"
