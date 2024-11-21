# AWS EC2 Instance Update Script

This bash script automates the process of safely updating AWS EC2 instances by creating EBS volume snapshots before performing system updates.

## Features

- Automatic EBS volume snapshot creation before updates
- Support for both IMDSv2 and IMDSv1 metadata retrieval
- Selective package updates (excludes filebeata and kernel)
- AWS resource tagging for better organization
- Comprehensive error handling and logging

## Prerequisites

- Root/sudo access
- AWS CLI installed and configured
- EC2 instance with appropriate IAM permissions
- Linux-based system with yum package manager

## Functionality Breakdown

### Security & Error Handling

- Requires root privileges
- Uses strict error handling (`set -euo pipefail`)
- Validates AWS CLI installation
- Verifies EC2 instance existence

### Metadata Retrieval

- Implements IMDSv2 token-based security
- Fallbacks to IMDSv1 if necessary
- Retrieves instance ID and region information

### Instance Identification

- Gets instance name from EC2 tags
- Falls back to instance ID if no name tag exists
- Sanitizes instance names for safe usage

### Update Management

- Checks for available system updates
- Excludes filebeat and kernel packages from updates
- Implements safe update procedures

### Snapshot Management

- Creates snapshots of all attached EBS volumes
- Includes volume name tags in snapshot descriptions
- Adds comprehensive tags to snapshots:
  - Name
  - Source Instance
  - Source Instance Name
  - Source Volume
  - Purpose (PreUpdate)
- Waits for snapshot completion
- Provides success/failure count

### Update Process

1. Checks for available updates
2. Creates snapshots if updates are found
3. Performs system updates (excluding filebeat and kernel)

## Usage

```bash
sudo ./script.sh
```

## Exit Codes

- 0: Script completed successfully
- 1: Error occurred during execution

## Tags Applied to Snapshots

- **Name**: `<instance-name>-<volume-name>-<timestamp>`
- **SourceInstance**: Instance ID
- **SourceInstanceName**: Instance Name
- **SourceVolume**: Volume ID
- **Purpose**: PreUpdate

## Notes

- The script excludes filebeat and kernel packages from updates
- All snapshots must complete successfully for updates to proceed
- Instance must have appropriate IAM permissions for AWS API calls

## Error Handling

The script includes comprehensive error handling for:

- AWS CLI availability
- Instance validation
- Metadata retrieval
- Snapshot creation
- Update process

## Dependencies

- AWS CLI
- curl
- yum package manager
- Standard Linux utilities (tr, sed, etc.)
