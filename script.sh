#!/bin/bash

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root" 
   echo "Please use sudo to run the script: sudo $0"
   exit 1
fi

set -euo pipefail  # Enable strict error handling

# Function to check AWS CLI is installed
check_aws_cli() {
    if ! command -v aws &> /dev/null; then
        echo "Error: AWS CLI is not installed" >&2
        exit 1
    fi
}

# Function to get metadata using IMDSv2
get_metadata() {
    local METADATA_PATH="$1"
    
    # Get IMDSv2 token
    local TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null)
    
    if [ ! -z "$TOKEN" ]; then
        # Use IMDSv2
        local METADATA=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
            "http://169.254.169.254/latest/meta-data/$METADATA_PATH" 2>/dev/null)
        echo "$METADATA"
    else
        # Fallback to IMDSv1
        local METADATA=$(curl -s "http://169.254.169.254/latest/meta-data/$METADATA_PATH" 2>/dev/null)
        echo "$METADATA"
    fi
}

# Function to get instance name from tags
get_instance_name() {
    
    local instance_id="$1"
    local region="$2"
    
    local INSTANCE_NAME=$(aws ec2 describe-tags \
        --region "$region" \
        --filters "Name=resource-id,Values=$instance_id" "Name=key,Values=Name" \
        --query 'Tags[0].Value' \
        --output text)
    
    # If instance has no name tag, use instance ID
    if [ "$INSTANCE_NAME" = "None" ] || [ -z "$INSTANCE_NAME" ]; then
        echo "$instance_id"
    else
        # Replace spaces with hyphens and remove special characters for safe naming
        echo "$INSTANCE_NAME" | tr ' ' '-' | sed 's/[^a-zA-Z0-9\-]//g'
    fi

}

# Function to check if instance exists
check_instance() {
    local instance_id="$1"
    local region="$2"
    
    if ! aws ec2 describe-instances --instance-ids "$instance_id" --region "$region" &> /dev/null; then
        echo "Error: Instance $instance_id not found in region $region" >&2
        exit 1
    fi
}

# Function to check for available updates excluding filebeat
check_updates() {
    # Create a temporary yum configuration file to exclude filebeat
    echo -e "[main]\nexclude=filebeat*" > /tmp/yum-exclude.conf
    
    # Run yum check-update with the temporary config
    UPDATES=$(yum --config /tmp/yum-exclude.conf check-update -q)
    local EXIT_CODE=$?
    
    # Clean up temporary config file
    rm -f /tmp/yum-exclude.conf
    
    # Exit code 100 means updates are available
    # Exit code 0 means no updates are available
    # Any other exit code indicates an error
    if [ $EXIT_CODE -eq 100 ]; then
        echo "Updates are available"
        return 0
    elif [ $EXIT_CODE -eq 0 ]; then
        echo "No updates are available"
        return 1
    else
        echo "Error checking for updates" >&2
        exit 1
    fi
}

# Function to create snapshots
create_snapshots() {
    local INSTANCE_ID="$1"
    local REGION="$2"
    local DATE="$3"
    local INSTANCE_NAME="$4"
    local DESCRIPTION="Backup-$INSTANCE_NAME-$DATE"
    local SUCCESS_COUNT=0
    local FAILURE_COUNT=0

    # Get all EBS volumes attached to the instance
    VOLUMES=$(aws ec2 describe-volumes \
        --region "$REGION" \
        --filters "Name=attachment.instance-id,Values=$INSTANCE_ID" \
        --query "Volumes[*].VolumeId" \
        --output text)

    if [ -z "$VOLUMES" ]; then
        echo "No volumes found for instance $INSTANCE_ID" >&2
        exit 1
    fi

    for VOLUME_ID in $VOLUMES; do
        echo "Creating snapshot for volume $VOLUME_ID..."
        
        # Get volume name tag if it exists
        VOLUME_NAME=$(aws ec2 describe-volumes \
            --region "$REGION" \
            --volume-ids "$VOLUME_ID" \
            --query 'Volumes[0].Tags[?Key==`Name`].Value' \
            --output text)
        
        # If volume has a name tag, include it in the snapshot description
        if [ -n "$VOLUME_NAME" ] && [ "$VOLUME_NAME" != "None" ]; then
            SNAPSHOT_DESCRIPTION="$DESCRIPTION-$VOLUME_NAME"
            SNAPSHOT_NAME="$INSTANCE_NAME-$VOLUME_NAME-$DATE"
        else
            SNAPSHOT_DESCRIPTION="$DESCRIPTION"
            SNAPSHOT_NAME="$INSTANCE_NAME-vol-${VOLUME_ID##*-}-$DATE"
        fi
        
        # Create snapshot with error handling
        if SNAPSHOT_ID=$(aws ec2 create-snapshot \
            --region "$REGION" \
            --volume-id "$VOLUME_ID" \
            --description "$SNAPSHOT_DESCRIPTION" \
            --tag-specifications "ResourceType=snapshot,Tags=[{Key=Name,Value=$SNAPSHOT_NAME},{Key=SourceInstance,Value=$INSTANCE_ID},{Key=SourceInstanceName,Value=$INSTANCE_NAME},{Key=SourceVolume,Value=$VOLUME_ID},{Key=Purpose,Value=PreUpdate}]" \
            --query 'SnapshotId' \
            --output text 2>/dev/null); then
            
            echo "Successfully created snapshot $SNAPSHOT_ID for volume $VOLUME_ID"
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))

            
            # Wait for snapshot to start
            echo "Waiting for snapshot to initialize..."
            aws ec2 wait snapshot-completed \
                --region "$REGION" \
                --snapshot-ids "$SNAPSHOT_ID"
                
        else
            echo "Failed to create snapshot for volume $VOLUME_ID" >&2
            FAILURE_COUNT=$((FAILURE_COUNT + 1))

        fi
    done

    # Print summary
    echo -e "\nSnapshot creation complete:"
    echo "Successful snapshots: $SUCCESS_COUNT"
    echo "Failed snapshots: $FAILURE_COUNT"

    # Exit with error if any snapshots failed
    if [ "$FAILURE_COUNT" -gt 0 ]; then
        exit 1
    fi
}

# Function to perform system update excluding filebeat and kernel
update_packages() {
    echo "Starting system update (excluding filebeat and kernel updates)..."
    
    # Create temporary yum configuration file
    echo -e "[main]\nexclude=filebeat* kernel*" > /tmp/yum-exclude.conf
    
    # Show what would be updated
    echo "The following packages will be updated:"
    yum --config /tmp/yum-exclude.conf update --assumeno
    
    # Perform the actual update
    echo -e "\nPerforming update..."
    yum --config /tmp/yum-exclude.conf update -y
    UPDATE_EXIT_CODE=$?
    
    # Clean up temporary config file
    rm -f /tmp/yum-exclude.conf
    
    if [ $UPDATE_EXIT_CODE -eq 0 ]; then
        echo "System update completed successfully"
        exit 0
    else
        echo "Error occurred during system update" >&2
        exit 1
    fi
}

# Function to install Kernel update
update_kernel() {
    CURRENT_KERNEL=$(uname -r)
    echo "Current kernel version: $CURRENT_KERNEL"

    # Check for kernel updates
    if yum list kernel | grep -q "Available Packages"; then
        echo "Kernel update available"
        
        # Install kernel update
        if yum update kernel -y; then
            NEW_KERNEL=$(rpm -q --last kernel | head -n 1 | sed 's/kernel-//')
            echo "Kernel updated to: $NEW_KERNEL"
            echo "Rebooting system in 1 minute to apply new kernel..."
            shutdown -r +1 "System rebooting for kernel update"
            exit 0
        else
            echo "Kernel update failed"
            exit 1
        fi
    else
        echo "No kernel update found"
        exit 0
    fi
}


# Main execution starts here
# Get instance ID and region from metadata service
INSTANCE_ID=$(get_metadata "instance-id")
REGION=$(get_metadata "placement/region")
DATE=$(date +%Y-%m-%d-%H-%M-%S)

# Check prerequisites
check_aws_cli
check_instance "$INSTANCE_ID" "$REGION"

# Get instance name
INSTANCE_NAME=$(get_instance_name "$INSTANCE_ID" "$REGION")
echo "Working with instance: $INSTANCE_NAME ($INSTANCE_ID)"

echo "Checking for available updates (excluding filebeat)..."
if check_updates; then
    echo "Updates found. Creating snapshots before proceeding with patch updates..."
    create_snapshots "$INSTANCE_ID" "$REGION" "$DATE" "$INSTANCE_NAME"
    echo "Snapshots created successfully. You can now proceed with system updates."

    update_packages
    update_kernel
    exit 0
else
    echo "No updates available. Skipping snapshot creation."
    exit 0
fi