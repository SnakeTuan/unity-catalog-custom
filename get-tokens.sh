#!/bin/bash

# === Step 1: Get Keycloak token ===
KC_TOKEN=$(curl -s -X POST \
  http://127.0.0.1:8090/realms/data-platform/protocol/openid-connect/token \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password" \
  -d "client_id=unity-catalog" \
  -d "client_secret=lF3C8xyYiHShkQVxHzI6RAKgmccpa5Ig" \
  -d "username=tuantm" \
  -d "password=tuantm" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

echo "KC_TOKEN=$KC_TOKEN"

# === Step 2: Exchange for UC token ===
export UC_TOKEN=$(curl -s -X POST \
  http://localhost:8080/api/1.0/unity-control/auth/tokens \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
  -d "subject_token=$KC_TOKEN" \
  -d "subject_token_type=urn:ietf:params:oauth:token-type:access_token" \
  -d "requested_token_type=urn:ietf:params:oauth:token-type:access_token" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

echo "UC_TOKEN=$UC_TOKEN"

# === Step 3: Test API ===
echo ""
echo "=== Testing API with UC token ==="
curl -s -H "Authorization: Bearer $UC_TOKEN" http://localhost:8080/api/2.1/unity-catalog/catalogs | python3 -m json.tool
