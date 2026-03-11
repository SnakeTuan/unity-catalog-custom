#!/bin/bash
set -euo pipefail

source "$(dirname "$0")/.env"

MINIO_ENDPOINT="http://localhost:9000"
BUCKET="dataplatform-dev-hn1"
SCOPED_PATH="unity"

echo "============================================"
echo "  MinIO STS AssumeRole Test"
echo "============================================"
echo ""

# --------------------------------------------------
# Step 1: AssumeRole with policy scoped to unity/
# --------------------------------------------------
echo "--- Step 1: AssumeRole scoped to $SCOPED_PATH/ ---"

export AWS_ACCESS_KEY_ID="$CMC_S3_ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$CMC_S3_SECRET_KEY"
unset AWS_SESSION_TOKEN 2>/dev/null || true

SESSION_POLICY=$(cat <<'POLICY'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetO*"],
      "Resource": [
        "arn:aws:s3:::dataplatform-dev-hn1/unity/*",
        "arn:aws:s3:::dataplatform-dev-hn1/unity"
      ]
    },
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket"],
      "Resource": ["arn:aws:s3:::dataplatform-dev-hn1"],
      "Condition": {
        "StringLike": {
          "s3:prefix": ["unity", "unity/", "unity/*"]
        }
      }
    }
  ]
}
POLICY
)

STS_RESULT=$(aws sts assume-role \
  --endpoint-url "$MINIO_ENDPOINT" \
  --role-arn "arn:aws:iam::minio:role/ignored" \
  --role-session-name "test-$(date +%s)" \
  --policy "$SESSION_POLICY" \
  --duration-seconds 3600 \
  --output json)

echo "$STS_RESULT" | python3 -m json.tool
echo ""

# Extract temp creds
export AWS_ACCESS_KEY_ID=$(echo "$STS_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['Credentials']['AccessKeyId'])")
export AWS_SECRET_ACCESS_KEY=$(echo "$STS_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['Credentials']['SecretAccessKey'])")
export AWS_SESSION_TOKEN=$(echo "$STS_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['Credentials']['SessionToken'])")

echo "Using temp AccessKeyId: ${AWS_ACCESS_KEY_ID:0:10}..."
echo ""

# --------------------------------------------------
# Test 1: List objects under unity/ (should SUCCEED)
# --------------------------------------------------
echo "--- Test 1: List unity/ (should SUCCEED) ---"
aws s3api list-objects-v2 \
  --endpoint-url "$MINIO_ENDPOINT" \
  --bucket "$BUCKET" \
  --prefix "unity/" \
  --max-keys 5 \
  --output json \
  2>&1 && echo "PASS: listing unity/ works" || echo "FAIL: listing unity/ denied"
echo ""

# --------------------------------------------------
# Test 2: List objects under external/ (should FAIL)
# --------------------------------------------------
echo "--- Test 2: List external/ (should FAIL - AccessDenied) ---"
aws s3api list-objects-v2 \
  --endpoint-url "$MINIO_ENDPOINT" \
  --bucket "$BUCKET" \
  --prefix "external/" \
  --max-keys 5 \
  --output json \
  2>&1 && echo "WARN: listing external/ succeeded (policy not enforced)" || echo "PASS: listing external/ correctly denied"
echo ""

# --------------------------------------------------
# Test 3: GetObject under unity/ (should SUCCEED if file exists)
# --------------------------------------------------
echo "--- Test 3: GetObject under unity/ (should SUCCEED) ---"
FIRST_KEY=$(aws s3api list-objects-v2 \
  --endpoint-url "$MINIO_ENDPOINT" \
  --bucket "$BUCKET" \
  --prefix "unity/" \
  --max-keys 1 \
  --output json 2>/dev/null | python3 -c "import sys,json; contents=json.load(sys.stdin).get('Contents',[]); print(contents[0]['Key'] if contents else '')" 2>/dev/null)

if [ -n "$FIRST_KEY" ]; then
  aws s3api head-object \
    --endpoint-url "$MINIO_ENDPOINT" \
    --bucket "$BUCKET" \
    --key "$FIRST_KEY" \
    --output json \
    2>&1 && echo "PASS: GetObject on $FIRST_KEY works" || echo "FAIL: GetObject denied"
else
  echo "SKIP: no objects found under unity/"
fi
echo ""

# --------------------------------------------------
# Test 4: PutObject under unity/ (should FAIL - read-only policy)
# --------------------------------------------------
echo "--- Test 4: PutObject under unity/ (should FAIL - no write perm) ---"
echo "test-content" | aws s3 cp - \
  "s3://$BUCKET/unity/test-deny-upload.txt" \
  --endpoint-url "$MINIO_ENDPOINT" \
  2>&1 && echo "WARN: PutObject succeeded (policy not enforced)" || echo "PASS: PutObject correctly denied"
echo ""

# --------------------------------------------------
# Test 5: List bucket root without prefix (should FAIL)
# --------------------------------------------------
echo "--- Test 5: List bucket root (should FAIL - no prefix match) ---"
aws s3api list-objects-v2 \
  --endpoint-url "$MINIO_ENDPOINT" \
  --bucket "$BUCKET" \
  --max-keys 5 \
  --output json \
  2>&1 && echo "WARN: root listing succeeded (policy not enforced)" || echo "PASS: root listing correctly denied"
echo ""

echo "============================================"
echo "  STS test complete!"
echo "============================================"
