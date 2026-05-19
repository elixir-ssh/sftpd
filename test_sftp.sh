#!/usr/bin/env bash
set -e

echo "=== SFTPD Integration Test ==="
echo ""

AWS_ENDPOINT="http://localhost:4566"
BUCKET="sftpd-test-bucket"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

LOCALSTACK_STARTED=""

cleanup() {
    if [ -n "$LOCALSTACK_STARTED" ]; then
        echo ""
        echo -e "${YELLOW}Stopping LocalStack...${NC}"
        docker compose down 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

# Step 1: Ensure LocalStack is running
echo -e "${YELLOW}Step 1: Checking LocalStack...${NC}"

if curl -s "$AWS_ENDPOINT/_localstack/health" > /dev/null 2>&1; then
    echo -e "${GREEN}✓ LocalStack is already running${NC}"
else
    echo "Starting LocalStack via docker-compose..."
    docker compose up -d
    LOCALSTACK_STARTED="true"

    echo "Waiting for LocalStack to be ready..."
    for i in {1..30}; do
        if curl -s "$AWS_ENDPOINT/_localstack/health" > /dev/null 2>&1; then
            echo -e "${GREEN}✓ LocalStack is ready${NC}"
            break
        fi
        if [ $i -eq 30 ]; then
            echo -e "${RED}✗ LocalStack failed to start${NC}"
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

if MIX_ENV=test mix run test_manual.exs; then
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
