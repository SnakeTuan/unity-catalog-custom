# S3 Static Credential Support for External Locations

## Current Problem

When auth is ON and a user creates a new external table, UC requires:
1. An **external location** registered for that S3 path
2. The external location must reference a **storage credential**
3. The storage credential only supports **AWS IAM Role** (STS assume-role)

This doesn't work for S3-compatible storage (CMC, MinIO, etc.) because:
- No AWS STS available
- We use static access key + secret key
- We need custom endpoint + path-style access

## Current Flow (AWS IAM Role only)

```
Admin creates credential (aws_iam_role with role_arn)
  → Admin creates external location (s3://bucket → credential)
    → User creates table under that location
      → Spark asks UC for temp credentials
        → UC does STS AssumeRole → returns temp AWS creds
          → Spark uses creds to access S3
```

## Proposed Flow (S3 Static Credentials)

```
Admin creates credential (s3_static with access_key, secret_key, endpoint, region, path_style)
  → Admin creates external location (s3://bucket → credential)
    → User creates table under that location
      → Spark asks UC for temp credentials
        → UC sees it's a static credential → returns static access key/secret key directly
          → Spark uses creds + endpoint config to access CMC S3
```

## What Changes

### 1. API Model — New credential type

Add `s3_static_credential` as an alternative to `aws_iam_role` when creating a credential.

**Create credential request example:**
```json
{
  "name": "cmc-s3-cred",
  "purpose": "STORAGE",
  "s3_static_credential": {
    "access_key": "EVQ4BZA...",
    "secret_key": "3eCCJs...",
    "region": "hcm-3",
    "endpoint": "https://s3.hcm-3.cloud.cmctelecom.vn",
    "path_style_access": true
  }
}
```

**Get credential response** — same but WITHOUT `secret_key` (never expose secrets in GET):
```json
{
  "name": "cmc-s3-cred",
  "purpose": "STORAGE",
  "s3_static_credential": {
    "access_key": "EVQ4BZA...",
    "region": "hcm-3",
    "endpoint": "https://s3.hcm-3.cloud.cmctelecom.vn",
    "path_style_access": true
  }
}
```

**File:** `api/all.yaml` — add `S3StaticCredentialRequest`, `S3StaticCredentialResponse` schemas

### 2. Credential Storage — Store static keys in DB

The `CredentialDAO` already stores credentials as a JSON blob with a `credentialType` discriminator.
We add a new type `S3_STATIC_CREDENTIALS` alongside existing `AWS_IAM_ROLE`.

The JSON blob stored in DB will contain: `access_key`, `secret_key`, `region`, `endpoint`, `path_style_access`.

**File:** `CredentialDAO.java` — add new enum value + serialization/deserialization

### 3. Credential Vending — Return static keys instead of calling STS

Currently in `AwsCredentialVendor.vendAwsCredentials()`:
```
if credentialDAO is present → always use STS master role (breaks for non-AWS)
else → use per-bucket s3.* config (our current workaround)
```

Change to:
```
if credentialDAO is present:
  if credentialType == S3_STATIC_CREDENTIALS → return static keys directly (no STS)
  if credentialType == AWS_IAM_ROLE → use STS master role (existing behavior)
else → use per-bucket s3.* config (existing fallback)
```

**File:** `AwsCredentialVendor.java` — branch on credential type

### 4. Iceberg FileIO — Use endpoint from credential

Currently `FileIOFactory.getS3FileIO()` gets endpoint/pathStyleAccess from per-bucket `s3.*` config only.

When the table's location matches an external location with a static S3 credential, we need to get the endpoint/pathStyleAccess from that credential instead.

**File:** `FileIOFactory.java` — look up external location credential, extract S3 config

### 5. No server.properties changes needed

The per-bucket `s3.*` config in server.properties stays as a fallback, but the primary path for production use will be through external locations + credentials. No new properties needed.

## Full End-to-End Flow After Changes

```bash
# 1. Admin creates a static S3 credential
curl -X POST http://localhost:8080/api/2.1/unity-catalog/credentials \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -d '{
    "name": "cmc-s3-cred",
    "purpose": "STORAGE",
    "s3_static_credential": {
      "access_key": "...",
      "secret_key": "...",
      "region": "hcm-3",
      "endpoint": "https://s3.hcm-3.cloud.cmctelecom.vn",
      "path_style_access": true
    }
  }'

# 2. Admin creates an external location
curl -X POST http://localhost:8080/api/2.1/unity-catalog/external-locations \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -d '{
    "name": "cmc-s3-location",
    "url": "s3://dataplatform-dev-hn1",
    "credential_name": "cmc-s3-cred"
  }'

# 3. Grant user permission on the external location
curl -X PATCH http://localhost:8080/api/2.1/unity-catalog/permissions/external_location/cmc-s3-location \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -d '{"changes": [{"principal": "snaketuan@gmail.com", "add": ["CREATE EXTERNAL TABLE", "READ FILES", "WRITE FILES"]}]}'

# 4. User can now create tables via Spark — credentials are vended automatically
spark.sql("CREATE TABLE unity.default.my_table ... LOCATION 's3://dataplatform-dev-hn1/...'")
```

## Files to Change (in order)

| # | File | What |
|---|------|------|
| 1 | `api/all.yaml` | Add S3StaticCredentialRequest/Response schemas |
| 2 | Run `sbt server/compile` | Auto-generates model Java classes from yaml |
| 3 | `CredentialDAO.java` | Add S3_STATIC_CREDENTIALS type, store/retrieve static keys |
| 4 | `CredentialRepository.java` | Handle update for s3_static_credential |
| 5 | `AwsCredentialVendor.java` | Branch on credential type, use static keys when appropriate |
| 6 | `FileIOFactory.java` | Get endpoint/pathStyle from external location credential |
| 7 | `UnityCatalogServer.java` | Wire ExternalLocationUtils into FileIOFactory |

## What Stays the Same

- `server.properties` per-bucket config — still works as fallback
- AWS IAM Role flow — untouched
- Authorization rules — external location permissions work the same
- Spark connector — no changes needed (it already handles static creds from UC)
