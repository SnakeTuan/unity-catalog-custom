#!/bin/bash
set -euo pipefail

# Load .env
source "$(dirname "$0")/.env"

MINIO_ENDPOINT="http://localhost:9000"
BUCKET="dataplatform-dev-hn1"

echo "============================================"
echo "  MinIO Gateway + STS Test Suite (API-based)"
echo "============================================"
echo ""

# --------------------------------------------------
# Test 1: Health Check
# --------------------------------------------------
echo "--- Test 1: Health Check ---"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$MINIO_ENDPOINT/minio/health/live")
if [ "$HTTP_CODE" = "200" ]; then
  echo "PASS: MinIO gateway is healthy (HTTP $HTTP_CODE)"
else
  echo "FAIL: MinIO gateway health check failed (HTTP $HTTP_CODE)"
  exit 1
fi
echo ""

# --------------------------------------------------
# Test 2: List Buckets via AWS CLI (verifies CMC S3 proxy works)
# --------------------------------------------------
echo "--- Test 2: List Buckets (verify CMC S3 proxy) ---"
AWS_ACCESS_KEY_ID="$CMC_S3_ACCESS_KEY" \
AWS_SECRET_ACCESS_KEY="$CMC_S3_SECRET_KEY" \
aws s3 ls \
  --endpoint-url "$MINIO_ENDPOINT" \
  --no-sign-request=false \
  2>&1 && echo "PASS: Bucket listing works through gateway" || echo "FAIL: Bucket listing failed"
echo ""

# --------------------------------------------------
# Test 3: List objects in bucket (verify data access)
# --------------------------------------------------
echo "--- Test 3: List Objects in $BUCKET (first 5) ---"
AWS_ACCESS_KEY_ID="$CMC_S3_ACCESS_KEY" \
AWS_SECRET_ACCESS_KEY="$CMC_S3_SECRET_KEY" \
aws s3api list-objects-v2 \
  --endpoint-url "$MINIO_ENDPOINT" \
  --bucket "$BUCKET" \
  --max-keys 5 \
  2>&1 && echo "PASS: Object listing works" || echo "FAIL: Object listing failed"
echo ""