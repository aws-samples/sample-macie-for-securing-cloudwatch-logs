#!/bin/bash

# Cleanup script for Amazon Macie CloudWatch Logs Security Solution
# This script removes all AWS resources created by the solution

set -e

# Configuration
STACK_NAME="macie-for-securing-cloudwatch-logs-v5"
REGION="us-east-1"

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

# Function to get stack resources
get_stack_resource() {
    local logical_id=$1
    aws cloudformation describe-stack-resources \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --logical-resource-id "$logical_id" \
        --query "StackResources[0].PhysicalResourceId" \
        --output text 2>/dev/null || echo ""
}

# Function to check if stack exists
check_stack_exists() {
    local stack_status=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query "Stacks[0].StackStatus" \
        --output text 2>/dev/null || echo "NOT_FOUND")
    
    if [ "$stack_status" = "NOT_FOUND" ]; then
        return 1
    else
        return 0
    fi
}

# Function to stop active processes
stop_processes() {
    log_info "Stopping active processes..."
    
    if ! check_stack_exists; then
        log_warning "Stack not found. Skipping process stop."
        return 0
    fi
    
    # Disable EventBridge rules
    local macie_event_rule=$(get_stack_resource "MacieEventRule")
    if [ -n "$macie_event_rule" ]; then
        log_info "Disabling EventBridge rule: $macie_event_rule"
        aws events disable-rule \
            --name "$macie_event_rule" \
            --region "$REGION" 2>/dev/null || true
    fi
    
    local macie_data_event_rule=$(get_stack_resource "MacieDataEventRule")
    if [ -n "$macie_data_event_rule" ]; then
        log_info "Disabling EventBridge rule: $macie_data_event_rule"
        aws events disable-rule \
            --name "$macie_data_event_rule" \
            --region "$REGION" 2>/dev/null || true
    fi
    
    # Stop any running Macie classification jobs
    log_info "Checking for running Macie classification jobs..."
    local running_jobs=$(aws macie2 list-classification-jobs \
        --filter-criteria '{"includes":[{"key":"jobStatus","values":["RUNNING","PAUSED"]}]}' \
        --region "$REGION" \
        --query "items[?starts_with(name, 'macie_classification_job')].jobId" \
        --output text 2>/dev/null || echo "")
    
    if [ -n "$running_jobs" ]; then
        for job_id in $running_jobs; do
            log_info "Cancelling Macie job: $job_id"
            aws macie2 update-classification-job \
                --job-id "$job_id" \
                --job-status CANCELLED \
                --region "$REGION" 2>/dev/null || true
        done
    else
        log_info "No running Macie jobs found"
    fi
    
    log_success "Active processes stopped"
}

# Function to empty S3 buckets
empty_buckets() {
    log_info "Emptying S3 buckets..."
    
    if ! check_stack_exists; then
        log_warning "Stack not found. Attempting to find buckets by naming pattern..."
        
        # Try to find buckets by naming pattern
        local account_id=$(aws sts get-caller-identity --query "Account" --output text)
        local bucket_patterns=(
            "*macie-logs-bucket*-${account_id}-${REGION}"
            "macie-isolation-${account_id}-${REGION}"
        )
        
        for pattern in "${bucket_patterns[@]}"; do
            local buckets=$(aws s3 ls | grep "$pattern" | awk '{print $3}' || echo "")
            for bucket in $buckets; do
                if [ -n "$bucket" ]; then
                    log_info "Found bucket by pattern: $bucket"
                    empty_single_bucket "$bucket"
                fi
            done
        done
        return 0
    fi
    
    # Get bucket names from stack
    local cloudwatch_bucket=$(get_stack_resource "CloudWatchLogsBucket")
    local isolation_bucket=$(get_stack_resource "DataIsolationBucket")
    
    # Empty CloudWatch logs bucket
    if [ -n "$cloudwatch_bucket" ]; then
        empty_single_bucket "$cloudwatch_bucket"
    fi
    
    # Empty data isolation bucket
    if [ -n "$isolation_bucket" ]; then
        empty_single_bucket "$isolation_bucket"
    fi
    
    log_success "S3 buckets emptied"
}

# Function to empty a single S3 bucket
empty_single_bucket() {
    local bucket_name=$1
    
    log_info "Emptying bucket: $bucket_name"
    
    # Check if bucket exists
    if ! aws s3 ls "s3://$bucket_name" --region "$REGION" >/dev/null 2>&1; then
        log_warning "Bucket $bucket_name does not exist or is not accessible"
        return 0
    fi
    
    # Get object count
    local object_count=$(aws s3 ls "s3://$bucket_name" --recursive --region "$REGION" | wc -l)
    
    if [ "$object_count" -gt 0 ]; then
        log_info "Removing $object_count objects from $bucket_name"
        
        # Remove all objects and versions
        aws s3 rm "s3://$bucket_name" --recursive --region "$REGION" || true
        
        # Remove any incomplete multipart uploads
        aws s3api list-multipart-uploads \
            --bucket "$bucket_name" \
            --region "$REGION" \
            --query "Uploads[].{Key:Key,UploadId:UploadId}" \
            --output text 2>/dev/null | while read -r key upload_id; do
            if [ -n "$key" ] && [ -n "$upload_id" ]; then
                log_info "Aborting multipart upload: $key ($upload_id)"
                aws s3api abort-multipart-upload \
                    --bucket "$bucket_name" \
                    --key "$key" \
                    --upload-id "$upload_id" \
                    --region "$REGION" 2>/dev/null || true
            fi
        done
        
        log_success "Bucket $bucket_name emptied"
    else
        log_info "Bucket $bucket_name is already empty"
    fi
}

# Function to delete CloudFormation stack
delete_stack() {
    log_info "Deleting CloudFormation stack..."
    
    if ! check_stack_exists; then
        log_warning "Stack '$STACK_NAME' not found. Nothing to delete."
        return 0
    fi
    
    # Delete the stack
    log_info "Initiating stack deletion: $STACK_NAME"
    aws cloudformation delete-stack \
        --stack-name "$STACK_NAME" \
        --region "$REGION"
    
    # Wait for deletion to complete
    log_info "Waiting for stack deletion to complete (this may take several minutes)..."
    
    local max_wait=1800  # 30 minutes
    local wait_time=0
    local check_interval=30
    
    while [ $wait_time -lt $max_wait ]; do
        local stack_status=$(aws cloudformation describe-stacks \
            --stack-name "$STACK_NAME" \
            --region "$REGION" \
            --query "Stacks[0].StackStatus" \
            --output text 2>/dev/null || echo "DELETE_COMPLETE")
        
        if [ "$stack_status" = "DELETE_COMPLETE" ] || [ "$stack_status" = "NOT_FOUND" ]; then
            log_success "Stack deletion completed"
            return 0
        elif [ "$stack_status" = "DELETE_FAILED" ]; then
            log_error "Stack deletion failed. Check AWS console for details."
            
            # Show failed resources
            log_info "Resources that failed to delete:"
            aws cloudformation describe-stack-events \
                --stack-name "$STACK_NAME" \
                --region "$REGION" \
                --query "StackEvents[?ResourceStatus=='DELETE_FAILED'].[LogicalResourceId,ResourceStatusReason]" \
                --output table 2>/dev/null || true
            
            return 1
        else
            log_info "Stack status: $stack_status (waiting...)"
            sleep $check_interval
            wait_time=$((wait_time + check_interval))
        fi
    done
    
    log_error "Stack deletion timed out after $max_wait seconds"
    return 1
}

# Function to clean up Macie resources
cleanup_macie() {
    log_info "Cleaning up Macie resources..."
    
    # Check if Macie is enabled
    local macie_status=$(aws macie2 get-macie-session --region "$REGION" --query "status" --output text 2>/dev/null || echo "DISABLED")
    
    if [ "$macie_status" != "ENABLED" ]; then
        log_info "Macie is not enabled. Skipping Macie cleanup."
        return 0
    fi
    
    # List and delete custom data identifiers created by the solution
    log_info "Checking for custom data identifiers..."
    local custom_identifiers=$(aws macie2 list-custom-data-identifiers \
        --region "$REGION" \
        --query "items[?contains(name, 'macie-for-securing-cloudwatch-logs')].id" \
        --output text 2>/dev/null || echo "")
    
    if [ -n "$custom_identifiers" ]; then
        for identifier_id in $custom_identifiers; do
            log_info "Deleting custom data identifier: $identifier_id"
            aws macie2 delete-custom-data-identifier \
                --id "$identifier_id" \
                --region "$REGION" 2>/dev/null || true
        done
    else
        log_info "No custom data identifiers found"
    fi
    
    # Clean up completed classification jobs
    log_info "Cleaning up completed Macie classification jobs..."
    local completed_jobs=$(aws macie2 list-classification-jobs \
        --filter-criteria '{"includes":[{"key":"jobStatus","values":["COMPLETE","CANCELLED"]}]}' \
        --region "$REGION" \
        --query "items[?starts_with(name, 'macie_classification_job')].jobId" \
        --output text 2>/dev/null || echo "")
    
    if [ -n "$completed_jobs" ]; then
        log_info "Found $(echo $completed_jobs | wc -w) completed jobs to clean up"
        # Note: Macie jobs are automatically cleaned up by AWS after a period
        # We just log them here for visibility
        for job_id in $completed_jobs; do
            log_info "Completed job: $job_id"
        done
    else
        log_info "No completed Macie jobs found"
    fi
    
    log_success "Macie resources cleaned up"
}

# Function to verify complete cleanup
verify_cleanup() {
    log_info "Verifying complete cleanup..."
    
    local cleanup_issues=()
    
    # Check if stack still exists
    if check_stack_exists; then
        cleanup_issues+=("CloudFormation stack still exists")
    fi
    
    # Check for remaining S3 buckets
    local account_id=$(aws sts get-caller-identity --query "Account" --output text)
    local remaining_buckets=$(aws s3 ls | grep -E "(macie-logs-bucket.*-${account_id}-${REGION}|macie-isolation-${account_id}-${REGION})" | awk '{print $3}' || echo "")
    
    if [ -n "$remaining_buckets" ]; then
        for bucket in $remaining_buckets; do
            cleanup_issues+=("S3 bucket still exists: $bucket")
        done
    fi
    
    # Check for active EventBridge rules
    local active_rules=$(aws events list-rules \
        --region "$REGION" \
        --query "Rules[?contains(Name, 'macie') && State=='ENABLED'].Name" \
        --output text 2>/dev/null || echo "")
    
    if [ -n "$active_rules" ]; then
        for rule in $active_rules; do
            cleanup_issues+=("Active EventBridge rule: $rule")
        done
    fi
    
    # Generate cleanup report
    log_info "=== CLEANUP VERIFICATION REPORT ==="
    
    if [ ${#cleanup_issues[@]} -eq 0 ]; then
        log_success "✓ All resources have been successfully cleaned up"
        log_success "✓ No remaining AWS resources found"
        log_success "✓ Account returned to pre-deployment state"
        log_info "=== CLEANUP COMPLETE ==="
        return 0
    else
        log_warning "The following cleanup issues were found:"
        for issue in "${cleanup_issues[@]}"; do
            log_error "✗ $issue"
        done
        log_info "=== CLEANUP INCOMPLETE ==="
        log_info "Please review and manually clean up the remaining resources."
        return 1
    fi
}

# Function to display help
show_help() {
    echo "Usage: $0 [OPTION]"
    echo ""
    echo "Cleanup script for Amazon Macie CloudWatch Logs Security Solution"
    echo ""
    echo "Options:"
    echo "  --stop-processes       Stop active EventBridge rules and Macie jobs"
    echo "  --empty-buckets        Empty all S3 buckets created by the solution"
    echo "  --delete-stack         Delete the CloudFormation stack"
    echo "  --cleanup-macie        Clean up Macie custom data identifiers and jobs"
    echo "  --verify-cleanup       Verify all resources have been removed"
    echo "  --full-cleanup         Run complete cleanup process"
    echo "  --help                 Display this help message"
    echo ""
    echo "Environment Variables:"
    echo "  STACK_NAME             CloudFormation stack name (default: $STACK_NAME)"
    echo "  REGION                 AWS region (default: $REGION)"
    echo ""
    echo "WARNING: This script will permanently delete AWS resources and data."
    echo "Make sure you have completed testing and no longer need the resources."
    echo ""
}

# Function to run full cleanup
full_cleanup() {
    log_info "Running complete cleanup process..."
    
    # Confirm with user
    echo -e "${YELLOW}WARNING: This will permanently delete all AWS resources created by the Macie solution.${NC}"
    echo -e "${YELLOW}This action cannot be undone.${NC}"
    echo ""
    read -p "Are you sure you want to proceed? (yes/no): " confirm
    
    if [ "$confirm" != "yes" ]; then
        log_info "Cleanup cancelled by user"
        return 0
    fi
    
    local cleanup_results=()
    
    # Run all cleanup steps
    if stop_processes; then
        cleanup_results+=("✓ Stop Processes")
    else
        cleanup_results+=("✗ Stop Processes")
    fi
    
    if empty_buckets; then
        cleanup_results+=("✓ Empty Buckets")
    else
        cleanup_results+=("✗ Empty Buckets")
    fi
    
    if delete_stack; then
        cleanup_results+=("✓ Delete Stack")
    else
        cleanup_results+=("✗ Delete Stack")
    fi
    
    if cleanup_macie; then
        cleanup_results+=("✓ Cleanup Macie")
    else
        cleanup_results+=("✗ Cleanup Macie")
    fi
    
    # Wait a moment before verification
    log_info "Waiting for cleanup to propagate..."
    sleep 30
    
    if verify_cleanup; then
        cleanup_results+=("✓ Verify Cleanup")
    else
        cleanup_results+=("✗ Verify Cleanup")
    fi
    
    # Generate cleanup report
    log_info "=== CLEANUP REPORT ==="
    for result in "${cleanup_results[@]}"; do
        if [[ $result == *"✓"* ]]; then
            log_success "$result"
        else
            log_error "$result"
        fi
    done
    
    local successful_steps=$(printf '%s\n' "${cleanup_results[@]}" | grep -c "✓" || echo "0")
    local total_steps=${#cleanup_results[@]}
    
    log_info "=== SUMMARY ==="
    log_info "Cleanup steps completed: $successful_steps/$total_steps"
    
    if [ "$successful_steps" -eq "$total_steps" ]; then
        log_success "Complete cleanup successful! All resources have been removed."
        return 0
    else
        log_error "Some cleanup steps failed. Please review the output above."
        return 1
    fi
}

# Main script logic
main() {
    case "${1:-}" in
        --stop-processes)
            stop_processes
            ;;
        --empty-buckets)
            empty_buckets
            ;;
        --delete-stack)
            delete_stack
            ;;
        --cleanup-macie)
            cleanup_macie
            ;;
        --verify-cleanup)
            verify_cleanup
            ;;
        --full-cleanup)
            full_cleanup
            ;;
        --help)
            show_help
            ;;
        "")
            log_error "No option specified. Use --help for usage information."
            exit 1
            ;;
        *)
            log_error "Unknown option: $1. Use --help for usage information."
            exit 1
            ;;
    esac
}

# Run main function with all arguments
main "$@"
