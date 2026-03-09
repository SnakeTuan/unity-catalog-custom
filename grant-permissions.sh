#!/bin/bash

UC_ADMIN_TOKEN=$(cat etc/conf/token.txt)

echo "=== Getting metastore ID ==="
METASTORE_ID=$(curl -s -H "Authorization: Bearer $UC_ADMIN_TOKEN" \
  http://localhost:8080/api/2.1/unity-catalog/metastore_summary \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['metastore_id'])")
echo "Metastore ID: $METASTORE_ID"

echo ""
echo "=== Granting USE CATALOG on unity ==="
curl -s -X PATCH "http://localhost:8080/api/2.1/unity-catalog/permissions/catalog/unity" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $UC_ADMIN_TOKEN" \
  -d '{"changes": [{"principal": "snaketuan@gmail.com", "add": ["USE CATALOG"]}]}' | python3 -m json.tool

echo ""
echo "=== Granting USE SCHEMA + CREATE TABLE on unity.default ==="
curl -s -X PATCH "http://localhost:8080/api/2.1/unity-catalog/permissions/schema/unity.default" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $UC_ADMIN_TOKEN" \
  -d '{"changes": [{"principal": "snaketuan@gmail.com", "add": ["USE SCHEMA", "CREATE TABLE"]}]}' | python3 -m json.tool

echo ""
echo "=== Granting SELECT + MODIFY on unity.default.orders_test ==="
curl -s -X PATCH "http://localhost:8080/api/2.1/unity-catalog/permissions/table/unity.default.orders_test" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $UC_ADMIN_TOKEN" \
  -d '{"changes": [{"principal": "snaketuan@gmail.com", "add": ["SELECT", "MODIFY"]}]}' | python3 -m json.tool

echo ""
echo "=== Done ==="
