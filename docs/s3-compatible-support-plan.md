# S3-Compatible Storage Support for Unity Catalog

## Problem

Unity Catalog's S3 support is tightly coupled to AWS:
- Uses AWS STS (role assumption) for credential vending — won't work with non-AWS S3
- S3Client has no custom endpoint configuration
- No path-style access support (required by most S3-compatible services)

## Goal

Support CMC Telecom S3-compatible storage:
- Endpoint: `s3.hcm-3.cloud.cmctelecom.vn`
- Authentication: static access key + secret key (no STS)
- Path-style access required

## Changes Required

### 1. `S3StorageConfig.java`
**Path:** `server/src/main/java/io/unitycatalog/server/service/credential/aws/S3StorageConfig.java`

Add two new fields:
- `endpoint` — custom S3 endpoint URL
- `pathStyleAccess` — boolean to enable path-style access (e.g., `http://endpoint/bucket` instead of `http://bucket.endpoint`)

### 2. `server.properties`
**Path:** `etc/conf/server.properties`

Add new per-bucket config keys:
```properties
s3.endpoint.0=
s3.pathStyleAccess.0=
```

### 3. `ServerProperties.java`
**Path:** `server/src/main/java/io/unitycatalog/server/utils/ServerProperties.java`

Update `getS3Configurations()` to read the new `s3.endpoint.<i>` and `s3.pathStyleAccess.<i>` properties and pass them into `S3StorageConfig.builder()`.

### 4. `FileIOFactory.java`
**Path:** `server/src/main/java/io/unitycatalog/server/service/iceberg/FileIOFactory.java`

Update `getS3FileIO()` and `getS3Client()`:
- Accept endpoint and pathStyleAccess from `S3StorageConfig`
- Call `.endpointOverride(URI.create(endpoint))` on S3Client builder when endpoint is set
- Call `.forcePathStyle(true)` when pathStyleAccess is enabled

### 5. Credential Flow

Use `StaticAwsCredentialGenerator` for non-AWS S3 by providing a `sessionToken` value in config. This bypasses AWS STS role assumption and returns static credentials directly.

Alternatively, consider adding a flag (e.g., `s3.staticCredentials.0=true`) to explicitly use static access/secret keys without requiring a dummy session token.

## Example Configuration

```properties
s3.bucketPath.0=s3://<bucket-name>
s3.region.0=hcm-3
s3.endpoint.0=https://s3.hcm-3.cloud.cmctelecom.vn
s3.pathStyleAccess.0=true
s3.accessKey.0=<access-key>
s3.secretKey.0=<secret-key>
s3.sessionToken.0=unused
```

## Notes

- The `sessionToken` trick (`s3.sessionToken.0=unused`) bypasses STS and uses `StaticAwsCredentialGenerator`, which returns static credentials. This works for server-side Iceberg operations.
- For Spark/client-side access, clients also need the custom endpoint configured in their Hadoop settings (e.g., `fs.s3a.endpoint`).
- `forcePathStyle(true)` is typically required for S3-compatible services that don't support virtual-hosted-style bucket addressing.
