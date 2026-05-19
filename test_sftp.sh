#!/usr/bin/env bash
set -e

echo "=== SFTPD Integration Test ==="
echo ""

AWS_ENDPOINT="${AWS_ENDPOINT_URL:-http://localhost:9000}"
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-minioadmin}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-minioadmin}"
export AWS_REGION="${AWS_REGION:-us-east-1}"
BUCKET="sftpd-test-bucket"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

MINIO_STARTED=""

cleanup() {
    if [ -n "$MINIO_STARTED" ]; then
        echo ""
        echo -e "${YELLOW}Stopping MinIO...${NC}"
        docker compose down 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

# Step 1: Ensure MinIO is running
echo -e "${YELLOW}Step 1: Checking MinIO...${NC}"

if curl -fsS "$AWS_ENDPOINT/minio/health/live" > /dev/null 2>&1; then
    echo -e "${GREEN}✓ MinIO is already running${NC}"
else
    echo "Starting MinIO via docker-compose..."
    docker compose up -d minio
    MINIO_STARTED="true"

    echo "Waiting for MinIO to be ready..."
    for i in {1..30}; do
        if curl -fsS "$AWS_ENDPOINT/minio/health/live" > /dev/null 2>&1; then
            echo -e "${GREEN}✓ MinIO is ready${NC}"
            break
        fi
        if [ $i -eq 30 ]; then
            echo -e "${RED}✗ MinIO failed to start${NC}"
            exit 1
        fi
        sleep 1
    done
fi
echo ""

# Step 2: Create S3 bucket
echo -e "${YELLOW}Step 2: Creating S3 bucket...${NC}"
aws --endpoint-url="$AWS_ENDPOINT" s3 mb "s3://$BUCKET" 2>/dev/null || true
echo -e "${GREEN}✓ Bucket ready: $BUCKET${NC}"
echo ""

# Step 3: Run the Elixir test
echo -e "${YELLOW}Step 3: Running SFTP upload/download test...${NC}"
echo ""

if MIX_ENV=test AWS_ENDPOINT_URL="$AWS_ENDPOINT" mix run test_manual.exs; then
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}=== All tests passed successfully! ===${NC}"
    echo -e "${GREEN}========================================${NC}"
else
    echo ""
    echo -e "${RED}========================================${NC}"
    echo -e "${RED}=== Test failed! ===${NC}"
    echo -e "${RED}========================================${NC}"
    exit 1
fi
