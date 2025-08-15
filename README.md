# Amazon Macie for Securing CloudWatch Logs

This repository contains a comprehensive AWS CloudFormation solution for implementing Amazon Macie to monitor CloudWatch logs for sensitive data, with automated alerting and data isolation capabilities.

## Overview

The solution creates an end-to-end security workflow that:
- Captures CloudWatch log entries in real-time using Amazon Kinesis Data Firehose
- Stores log data in encrypted Amazon S3 buckets
- Uses Amazon Macie to continuously scan for sensitive data (PII, financial information, etc.)
- Automatically isolates sensitive files and sends alerts via Amazon SNS
- Provides comprehensive testing and cleanup automation

## Architecture Components

### Core Infrastructure
- **CloudWatch Log Group**: Collects application logs
- **Kinesis Data Firehose**: Streams logs to S3 in real-time
- **S3 Buckets**: 
  - Main bucket for log storage with encryption
  - Isolation bucket for sensitive data quarantine
- **KMS Key**: Encrypts all data at rest and in transit

### Security & Monitoring
- **Amazon Macie**: Detects sensitive data using ML and pattern matching
- **Custom Data Identifiers**: Configurable patterns for organization-specific data
- **EventBridge Rules**: Automates responses to Macie findings
- **Lambda Functions**: 
  - Triggers Macie classification jobs
  - Handles data isolation and cleanup
  - Generates test data for validation

### Alerting & Notifications
- **SNS Topic**: Sends email notifications for security events
- **EventBridge Integration**: Real-time event processing
- **CloudWatch Logs**: Comprehensive logging and monitoring

## Prerequisites

- AWS CLI configured with appropriate permissions
- Active AWS account with Macie service available
- Email address for SNS notifications
- CloudFormation deployment permissions
- IAM permissions for creating roles and policies

## Quick Start

### Option 1: Deploy Using Enhanced Script (Recommended)

The enhanced test script now includes deployment functionality with flexible parameter options:

```bash
# Deploy with command-line parameters
./scripts/test-macie-solution.sh --deploy-stack \
  --stack-name my-macie-stack \
  --email your-email@example.com \
  --enable-macie true \
  --region us-east-1

# Deploy using environment variables
export STACK_NAME=my-macie-stack
export SNS_EMAIL=your-email@example.com
export ENABLE_MACIE=true
export REGION=us-east-1
./scripts/test-macie-solution.sh --deploy-stack

# Check deployment status
./scripts/test-macie-solution.sh --deployment-status --stack-name my-macie-stack
```

### Option 2: Deploy Using AWS CLI Directly

```bash
aws cloudformation create-stack \
  --region us-east-1 \
  --stack-name macie-for-securing-cloudwatch-logs \
  --template-body file://app/main.yml \
  --capabilities CAPABILITY_IAM \
  --parameters \
    ParameterKey=ResourceName,ParameterValue=macie-demo \
    ParameterKey=BucketName,ParameterValue=my-unique-bucket-name \
    ParameterKey=LogGroupName,ParameterValue=/aws/lambda/ConfigSetup \
    ParameterKey=SNSTopicEndpointEmail,ParameterValue=your-email@example.com \
    ParameterKey=EnableMacie,ParameterValue=false
```

### 2. Confirm SNS Subscription

Check your email and click the confirmation link to subscribe to security notifications.

### 3. Test the Solution

```bash
# Run comprehensive end-to-end test
./scripts/test-macie-solution.sh --full-test

# Or run individual test steps
./scripts/test-macie-solution.sh --generate-test-data
./scripts/test-macie-solution.sh --verify-pipeline
./scripts/test-macie-solution.sh --trigger-macie-job
./scripts/test-macie-solution.sh --verify-alerts
```

### 4. Clean Up Resources

```bash
# Run complete cleanup
./scripts/cleanup-macie-solution.sh --full-cleanup

# Or run individual cleanup steps
./scripts/cleanup-macie-solution.sh --stop-processes
./scripts/cleanup-macie-solution.sh --empty-buckets
./scripts/cleanup-macie-solution.sh --delete-stack
```

## Testing and Deployment Framework

### Enhanced Test and Deployment Script

The `scripts/test-macie-solution.sh` script now provides comprehensive deployment and testing capabilities:

#### Deployment Functions
- **`--deploy-stack`**: Deploy or update the CloudFormation stack with parameter validation
- **`--validate-params`**: Validate deployment parameters before deployment
- **`--deployment-status`**: Show current stack status, outputs, and recent events

#### Testing Functions
- **`--generate-test-data`**: Creates CloudWatch log entries with sensitive data patterns
- **`--verify-pipeline`**: Confirms data flow through Kinesis Firehose to S3
- **`--trigger-macie-job`**: Manually triggers Macie classification jobs
- **`--verify-alerts`**: Validates SNS notifications and data isolation
- **`--full-test`**: Runs complete end-to-end validation with reporting

#### Flexible Parameter Support

The script supports both command-line parameters and environment variables:

**Command-line Parameters:**
```bash
./scripts/test-macie-solution.sh --deploy-stack \
  --stack-name my-stack \
  --region us-west-2 \
  --resource-name my-resources \
  --bucket-name my-unique-bucket \
  --log-group /my/log/group \
  --email user@example.com \
  --enable-macie true \
  --template-path app/main.yml
```

**Environment Variables:**
```bash
export STACK_NAME=my-stack
export REGION=us-west-2
export RESOURCE_NAME=my-resources
export BUCKET_NAME=my-unique-bucket
export LOG_GROUP_NAME=/my/log/group
export SNS_EMAIL=user@example.com
export ENABLE_MACIE=true
export TEMPLATE_PATH=app/main.yml
```

#### Usage Examples

```bash
# Deploy a new stack with Macie enabled
./scripts/test-macie-solution.sh --deploy-stack \
  --stack-name production-macie \
  --email security-team@company.com \
  --enable-macie true

# Check deployment status
./scripts/test-macie-solution.sh --deployment-status \
  --stack-name production-macie

# Run full test suite on deployed stack
./scripts/test-macie-solution.sh --full-test \
  --stack-name production-macie

# Validate parameters before deployment
./scripts/test-macie-solution.sh --validate-params \
  --email security-team@company.com \
  --region us-east-1
```

#### `scripts/cleanup-macie-solution.sh`
- **`--stop-processes`**: Disables EventBridge rules and stops Macie jobs
- **`--empty-buckets`**: Removes all objects from S3 buckets
- **`--delete-stack`**: Deletes the CloudFormation stack
- **`--cleanup-macie`**: Removes Macie custom data identifiers
- **`--verify-cleanup`**: Confirms complete resource removal
- **`--full-cleanup`**: Runs complete cleanup with user confirmation

### Test Data Patterns

The testing framework generates realistic sensitive data patterns:
- Employee IDs: `AnyCompany-12345678`
- Patent IDs: `patentID: AnyCompany-87654321`
- Credit card numbers: `4532-1234-5678-9012`
- Social Security Numbers: `123-45-6789`
- Email addresses and other PII

### Validation Checks

Tests verify:
- ✅ CloudFormation stack deployment status
- ✅ Log data generation and ingestion
- ✅ Kinesis Firehose data delivery to S3
- ✅ S3 object encryption and storage
- ✅ Macie job execution and findings
- ✅ EventBridge rule triggering
- ✅ SNS notification delivery
- ✅ Sensitive data isolation
- ✅ Complete resource cleanup

## Configuration Options

### CloudFormation Parameters

| Parameter | Description | Default | Required |
|-----------|-------------|---------|----------|
| `ResourceName` | Prefix for all created resources | `default-resource-name` | Yes |
| `BucketName` | Base name for S3 buckets (must be unique) | `default-s3-bucket-name` | Yes |
| `LogGroupName` | CloudWatch log group name | `/aws/lambda/ConfigSetup` | Yes |
| `SNSTopicEndpointEmail` | Email for security notifications | `davguard@amazon.com` | Yes |
| `EnableMacie` | Enable Macie session (only if not already enabled) | `false` | No |

### Script Configuration Options

The enhanced test script supports the following configuration options:

#### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `STACK_NAME` | CloudFormation stack name | `macie-for-securing-cloudwatch-logs-v5` |
| `REGION` | AWS region | `us-east-1` |
| `RESOURCE_NAME` | Resource prefix name | `default-resource-name` |
| `BUCKET_NAME` | S3 bucket base name | `default-s3-bucket-name` (auto-generated if default) |
| `LOG_GROUP_NAME` | CloudWatch log group | `/aws/lambda/ConfigSetup` |
| `SNS_EMAIL` | SNS notification email | (required for deployment) |
| `ENABLE_MACIE` | Enable Macie service | `false` |
| `TEMPLATE_PATH` | CloudFormation template path | `app/main.yml` |

#### Command-line Parameters

All environment variables can be overridden using command-line parameters:
- `--stack-name NAME`
- `--region REGION`
- `--resource-name NAME`
- `--bucket-name NAME`
- `--log-group NAME`
- `--email EMAIL`
- `--enable-macie BOOL`
- `--template-path PATH`

#### Deployment Features

- **Parameter Validation**: Validates AWS credentials, region, email format, and template existence
- **Unique Bucket Names**: Auto-generates unique S3 bucket names to prevent conflicts
- **Stack Updates**: Automatically detects existing stacks and performs updates instead of creation
- **Progress Monitoring**: Waits for stack operations to complete with status updates
- **Error Handling**: Provides detailed error messages and troubleshooting information
- **Output Display**: Shows stack outputs and recent events after successful deployment

## Security Features

### Data Protection
- **Encryption at Rest**: All S3 objects encrypted with KMS
- **Encryption in Transit**: TLS/SSL for all data transfers
- **Access Controls**: Least-privilege IAM policies
- **Secure Transport**: Deny non-HTTPS requests

### Monitoring & Alerting
- **Real-time Detection**: Continuous Macie scanning
- **Automated Response**: Immediate data isolation
- **Audit Trail**: Complete CloudWatch logging
- **Notification System**: Multi-channel alerting

### Compliance Support
- **Data Classification**: Automated sensitive data identification
- **Data Isolation**: Quarantine of sensitive information
- **Retention Policies**: Configurable data lifecycle management
- **Audit Logging**: Comprehensive activity tracking

## Troubleshooting

### Common Issues

1. **Stack Creation Failed**
   - Check CloudFormation events in AWS Console
   - Verify IAM permissions
   - Ensure unique S3 bucket names
   - Confirm Macie service availability in region

2. **Macie Jobs Failing**
   - Verify Macie is enabled in the account
   - Check custom data identifier configuration
   - Ensure S3 bucket permissions are correct

3. **No SNS Notifications**
   - Confirm email subscription
   - Check SNS topic permissions
   - Verify EventBridge rule configuration

4. **Test Script Failures**
   - Ensure AWS CLI is configured
   - Verify script permissions (`chmod +x`)
   - Check CloudFormation stack status

### Debug Commands

```bash
# Check stack status
aws cloudformation describe-stacks --stack-name macie-for-securing-cloudwatch-logs-v3

# View stack events
aws cloudformation describe-stack-events --stack-name macie-for-securing-cloudwatch-logs-v3

# Check Macie status
aws macie2 get-macie-session

# List S3 objects
aws s3 ls s3://your-bucket-name --recursive

# View Lambda logs
aws logs describe-log-groups --log-group-name-prefix "/aws/lambda/"
```

## Cost Optimization

### Resource Lifecycle
- **S3 Lifecycle Policies**: Automatic transition to cheaper storage classes
- **Log Retention**: Configurable CloudWatch log retention (14 days default)
- **Lambda Concurrency**: Reserved concurrency limits to control costs
- **Scheduled Jobs**: Macie jobs run on schedule to optimize scanning costs

### Monitoring Costs
- Use AWS Cost Explorer to monitor spending
- Set up billing alerts for unexpected charges
- Review S3 storage classes and transition policies
- Monitor Lambda execution metrics

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests for new functionality
5. Run the test suite
6. Submit a pull request

## Support

For issues and questions:
1. Check the troubleshooting section above
2. Review AWS service documentation
3. Use the `/reportbug` command in supported environments
4. Contact your AWS support team for service-specific issues

## Additional Resources

- [Amazon Macie User Guide](https://docs.aws.amazon.com/macie/latest/user/)
- [AWS CloudFormation Documentation](https://docs.aws.amazon.com/cloudformation/)
- [Amazon Kinesis Data Firehose Documentation](https://docs.aws.amazon.com/kinesis/latest/dev/)
- [AWS Lambda Developer Guide](https://docs.aws.amazon.com/lambda/latest/dg/)
- [Amazon SNS Developer Guide](https://docs.aws.amazon.com/sns/latest/dg/)
