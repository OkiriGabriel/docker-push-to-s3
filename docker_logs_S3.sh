#!/bin/bash

#########################################
# Script to Push Docker Logs to S3
# Uploads ONLY log files (no tar, no config files)
# Usage: ./push-logs-to-s3.sh
#########################################

# ===== CONFIGURATION - EDIT THESE =====
S3_BUCKET="docker-app-logs-staging"
AWS_REGION="eu-west-2"
AWS_ACCESS_KEY_ID="AKIASU566HMVP3DHJ3ON"
AWS_SECRET_ACCESS_KEY="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"
LOG_DAYS=7                                # Number of days of logs to upload (set to "all" for everything)
DELETE_AFTER_UPLOAD="true"                # Delete Docker logs after successful upload (true/false)
# ======================================

export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY}"
export AWS_DEFAULT_REGION="${AWS_REGION}"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
DATE_FOLDER=$(date +%Y/%m/%d)
HOSTNAME=$(hostname)
DOCKER_CONTAINERS_DIR="/var/lib/docker/containers"

echo "=========================================="
echo "Pushing Docker Logs to S3"
echo "Time: $(date)"
if [ "${LOG_DAYS}" == "all" ]; then
    echo "Log Range: All logs"
else
    echo "Log Range: Last ${LOG_DAYS} days"
fi
echo "=========================================="

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo "⚠ WARNING: Please run with: sudo ./push-logs-to-s3.sh"
    exit 1
fi

# Test AWS connection
echo "Testing AWS connection..."
aws s3 ls s3://${S3_BUCKET} --region ${AWS_REGION} > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "✗ ERROR: Cannot connect to S3 bucket: ${S3_BUCKET}"
    exit 1
fi
echo "✓ AWS connection successful"
echo ""

# Collect and upload logs from all running containers
echo "Collecting and uploading logs from Docker containers..."
echo ""
CONTAINER_COUNT=0
UPLOAD_COUNT=0
TOTAL_SIZE=0

for container_id in $(docker ps -q); do
    container_name=$(docker inspect --format='{{.Name}}' ${container_id} | sed 's/\///')
    
    echo "📦 Container: ${container_name}"
    
    # Get the full container ID
    FULL_CONTAINER_ID=$(docker inspect --format='{{.Id}}' ${container_id})
    CONTAINER_LOG_DIR="${DOCKER_CONTAINERS_DIR}/${FULL_CONTAINER_ID}"
    
    if [ -d "${CONTAINER_LOG_DIR}" ]; then
        # Main log file
        MAIN_LOG="${CONTAINER_LOG_DIR}/${FULL_CONTAINER_ID}-json.log"
        
        if [ -f "${MAIN_LOG}" ]; then
            LOG_SIZE=$(stat -c%s "${MAIN_LOG}")
            LOG_SIZE_MB=$(echo "scale=2; ${LOG_SIZE}/1048576" | bc)
            
            if [ ${LOG_SIZE} -gt 0 ]; then
                echo "   ├─ Main log: ${LOG_SIZE_MB} MB"
                
                # Upload directly to S3 (no tar)
                S3_PATH="s3://${S3_BUCKET}/docker-logs/${container_name}/${DATE_FOLDER}/${container_name}-${TIMESTAMP}.log"
                
                echo "   ├─ Uploading to S3..."
                aws s3 cp "${MAIN_LOG}" "${S3_PATH}" \
                    --region "${AWS_REGION}" \
                    --storage-class STANDARD_IA \
                    --metadata "container=${container_name},hostname=${HOSTNAME},timestamp=${TIMESTAMP}"
                
                if [ $? -eq 0 ]; then
                    echo "   └─ ✓ Uploaded successfully"
                    UPLOAD_COUNT=$((UPLOAD_COUNT + 1))
                    TOTAL_SIZE=$((TOTAL_SIZE + LOG_SIZE))
                else
                    echo "   └─ ✗ Upload failed"
                fi
            else
                echo "   └─ ⚠ Log file is empty (0 bytes)"
            fi
        else
            echo "   └─ ✗ Log file not found"
        fi
        
        # Upload rotated logs if they exist
        for logfile in "${CONTAINER_LOG_DIR}"/*.log.[0-9]*; do
            if [ -f "$logfile" ]; then
                BASENAME=$(basename "$logfile")
                SIZE=$(stat -c%s "$logfile")
                SIZE_MB=$(echo "scale=2; ${SIZE}/1048576" | bc)
                
                if [ ${SIZE} -gt 0 ]; then
                    echo "   ├─ Rotated log: ${SIZE_MB} MB"
                    
                    S3_PATH="s3://${S3_BUCKET}/docker-logs/${container_name}/${DATE_FOLDER}/${container_name}-${BASENAME}"
                    
                    aws s3 cp "$logfile" "${S3_PATH}" \
                        --region "${AWS_REGION}" \
                        --storage-class STANDARD_IA \
                        --metadata "container=${container_name},hostname=${HOSTNAME}" > /dev/null 2>&1
                    
                    if [ $? -eq 0 ]; then
                        echo "   └─ ✓ Uploaded"
                        TOTAL_SIZE=$((TOTAL_SIZE + SIZE))
                    fi
                fi
            fi
        done
    else
        echo "   └─ ✗ Container directory not found"
    fi
    
    CONTAINER_COUNT=$((CONTAINER_COUNT + 1))
    echo ""
done

if [ ${CONTAINER_COUNT} -eq 0 ]; then
    echo "✗ No running containers found!"
    exit 1
fi

TOTAL_SIZE_MB=$(echo "scale=2; ${TOTAL_SIZE}/1048576" | bc)

echo ""
echo "=========================================="
echo "✓ SUCCESS - Logs pushed to S3"
echo "=========================================="
echo "Containers processed: ${CONTAINER_COUNT}"
echo "Logs uploaded: ${UPLOAD_COUNT}"
echo "Total data uploaded: ${TOTAL_SIZE_MB} MB"
echo "S3 Bucket: ${S3_BUCKET}"
echo "Region: ${AWS_REGION}"
echo ""
echo "S3 Structure:"
echo "  s3://${S3_BUCKET}/docker-logs/"
for container_id in $(docker ps -q); do
    container_name=$(docker inspect --format='{{.Name}}' ${container_id} | sed 's/\///')
    echo "    └── ${container_name}/"
    echo "        └── ${DATE_FOLDER}/"
    echo "            └── ${container_name}-${TIMESTAMP}.log"
done
echo ""
echo "Commands:"
echo "  List all logs:"
echo "    aws s3 ls s3://${S3_BUCKET}/docker-logs/ --recursive --human-readable"
echo ""
echo "  Download specific container log:"
echo "    aws s3 cp s3://${S3_BUCKET}/docker-logs/CONTAINER_NAME/${DATE_FOLDER}/${container_name}-${TIMESTAMP}.log ."
echo ""
echo "  Download all logs for a container:"
echo "    aws s3 sync s3://${S3_BUCKET}/docker-logs/CONTAINER_NAME/ ./CONTAINER_NAME/"
echo "=========================================="