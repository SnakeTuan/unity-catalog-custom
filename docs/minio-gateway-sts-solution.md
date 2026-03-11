# MinIO Gateway + STS Solution for CMC S3 Credential Vending

## Problem

CMC S3 lacks an STS service. Unity Catalog's credential vending needs to issue **temporary, path-scoped credentials** per user/job. We cannot pass full bucket credentials to Spark.

## Solution: MinIO Gateway + MinIO STS as S3 Proxy

Deploy MinIO in **gateway mode** in front of CMC S3. MinIO handles authentication (STS) and authorization (session policies), then proxies all S3 requests to CMC S3 using the root CMC S3 credentials.

A new per-bucket config flag `s3.minioGateway.<i>=true` tells UC to use MinIO STS instead of AWS STS for that bucket. This allows **mixed environments** where some buckets go through MinIO gateway (CMC S3) and others use normal AWS STS.

### Architecture

```
┌─────────┐      ┌──────────────────────────────────────┐      ┌─────────┐
│ UC Server│─────▶│         MinIO (Gateway Mode)          │      │ CMC S3  │
│          │ STS  │                                        │      │         │
│          │Assume│  ┌─────────┐     ┌────────────────┐   │      │         │
│          │Role  │  │ MinIO   │     │ Gateway Layer   │──────▶  │         │
│          │─────▶│  │  STS    │     │ (proxy to CMC)  │  S3 API │         │
│          │      │  └─────────┘     └────────────────┘   │      │         │
└─────────┘      └──────────────────────────────────────┘      └─────────┘
                          ▲
                          │ S3 API (temp creds)
                   ┌──────┴──────┐
                   │  Spark Job  │
                   └─────────────┘
```

### Flow

```
1. UC Server → MinIO STS: AssumeRole(Policy=scoped-to-subpath, DurationSeconds=3600)
                          Auth: CMC S3 root accessKey/secretKey (Signature V4)
                        ← Returns: temp accessKeyId + secretAccessKey + sessionToken

2. UC Server → Spark: here are your temp creds, endpoint = MinIO

3. Spark → MinIO (using temp creds): GetObject s3://bucket/user123/tables/data.parquet
   MinIO validates temp creds + checks session policy allows this path
   MinIO → CMC S3 (using root creds): forwards the request
   CMC S3 → MinIO → Spark: returns the data
```

### Why This Works

1. **MinIO STS `AssumeRole`** supports a `Policy` parameter (inline session policy) — same format as AWS IAM policies
2. **Session policies support subpath scoping** — `Resource: "arn:aws:s3:::bucket/prefix/*"` works in MinIO
3. **MinIO Gateway** transparently proxies all S3 operations to CMC S3 — Spark doesn't know CMC S3 exists
4. **Temp creds authenticate against MinIO**, MinIO forwards to CMC S3 with its own root credentials
5. **No separate MinIO service user needed** — gateway mode doesn't support `mc admin policy attach`, so we use the root CMC S3 creds directly for STS calls. The session policy scopes down permissions per request.

---

## Tested & Verified

The following has been manually tested and confirmed working:

1. MinIO gateway proxies S3 API to CMC S3 (`uzumlukek/minio-gateway:latest`)
2. STS AssumeRole returns temp credentials (using root CMC S3 creds)
3. Temp credentials can list/read objects under the scoped path
4. Temp credentials are **denied** for paths outside the session policy scope
5. Temp credentials are **denied** for actions not in the session policy (e.g., PutObject when only GetObject is granted)

Test scripts: `minio-gateway/test-sts.sh`

---

## MinIO STS AssumeRole Details

### API Endpoint

```
POST http://minio:9000/?Action=AssumeRole&Version=2011-06-15
```

### Request Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `Action` | Yes | `AssumeRole` |
| `Version` | Yes | `2011-06-15` |
| `Policy` | **No** | JSON IAM session policy to scope down permissions |
| `DurationSeconds` | No | 900 to 604800 (7 days), default 3600 |
| `AUTHPARAMS` | Yes | Signature V4 auth using CMC S3 root credentials |

### Session Policy for Subpath Scoping

MinIO follows the AWS IAM policy spec. UC's `AwsPolicyGenerator` already generates the correct format with two statements — one for object operations and one for ListBucket with prefix condition:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetO*"],
      "Resource": [
        "arn:aws:s3:::data-lake/user123/tables/*",
        "arn:aws:s3:::data-lake/user123/tables"
      ]
    },
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket"],
      "Resource": ["arn:aws:s3:::data-lake"],
      "Condition": {
        "StringLike": {
          "s3:prefix": [
            "user123/tables",
            "user123/tables/",
            "user123/tables/*"
          ]
        }
      }
    }
  ]
}
```

**Key point:** MinIO's `AssumeRole` uses the caller's credentials (Signature V4 AUTHPARAMS) to determine the base user identity — there is no `roleArn` concept like AWS. The `roleArn` parameter is accepted but effectively ignored by MinIO. Temp creds inherit the base user's permissions, scoped down by the session `Policy`.

---

## MinIO Gateway Mode

### What It Does

Gateway mode makes MinIO act as an **S3-compatible proxy** to another S3 backend. MinIO doesn't store data — it translates S3 API calls and forwards them to the backend (CMC S3). All MinIO features (STS, policies, encryption, etc.) work on top.

### Deprecation Status

> **Gateway mode was deprecated on Feb 12, 2025** with a 6-month removal timeline (~Aug 2025).
> It is still functional in current releases but will be removed.

Options for long-term use:
1. **Pin to a MinIO version** that includes gateway mode (e.g., via Docker image)
2. **Use `uzumlukek/minio-gateway:latest`** — a community Docker image with gateway mode
3. **Fork MinIO** (AGPL v3 license) and maintain gateway mode

### Gateway Limitations

- **No `mc admin policy attach/set`** — user policy management is not supported in gateway mode
- **No separate MinIO users** — use the root CMC S3 credentials directly for STS calls
- Session policies still scope down permissions per request, so security is maintained

### Docker Compose

```yaml
services:
  minio-gateway:
    image: uzumlukek/minio-gateway:latest
    command: gateway s3 https://s3.hcm-3.cloud.cmctelecom.vn --console-address ":9001"
    ports:
      - "9000:9000"
      - "9001:9001"
    environment:
      MINIO_ROOT_USER: ${CMC_S3_ACCESS_KEY}
      MINIO_ROOT_PASSWORD: ${CMC_S3_SECRET_KEY}
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:9000/minio/health/live"]
      interval: 30s
      timeout: 10s
      retries: 3
```

---

## UC Code Changes

### Overview

| # | File | Change | New/Modified |
|---|------|--------|-------------|
| 1 | `S3StorageConfig.java` | Add `minioGateway` boolean field | Modified |
| 2 | `ServerProperties.java` | Read `s3.minioGateway.<i>` property | Modified |
| 3 | `AwsCredentialVendor.java` | Add minioGateway check before existing logic in `vendAwsCredentials()` | Modified |
| 4 | `AwsCredentialVendor.java` | Update `createPerBucketCredentialGenerator()` to pass `S3StorageConfig` to constructor | Modified |
| 5 | `MinioStsCredentialGenerator.java` | New credential generator that calls MinIO STS with endpoint override | **New** |
| 6 | `server.properties` | Add `s3.minioGateway.0=true` example | Modified |

### 1. `S3StorageConfig.java` — add `minioGateway` field

**File:** `server/src/main/java/io/unitycatalog/server/service/credential/aws/S3StorageConfig.java`

```java
@Getter
@Builder
@ToString
public class S3StorageConfig {
  private final String bucketPath;
  private final String region;
  private final String awsRoleArn;
  private final String accessKey;
  private final String secretKey;
  private final String sessionToken;
  private final String credentialGenerator;
  private final String endpoint;
  private final boolean pathStyleAccess;
  private final boolean minioGateway;       // <-- NEW
}
```

### 2. `ServerProperties.java` — read `s3.minioGateway.<i>`

**File:** `server/src/main/java/io/unitycatalog/server/utils/ServerProperties.java`

In `getS3Configurations()`, add reading the new property:

```java
// Add after the existing pathStyleAccess line:
String minioGateway = getProperty("s3.minioGateway." + i);

// Add to the builder:
.minioGateway(minioGateway != null && minioGateway.equalsIgnoreCase("true"))
```

Also update the **loop break condition**. Currently the loop breaks when `(bucketPath == null || region == null || awsRoleArn == null) && (accessKey == null || secretKey == null || sessionToken == null)`. For MinIO gateway buckets, we won't have `awsRoleArn` or `sessionToken`, but we will have `accessKey`, `secretKey`, and `minioGateway=true`. The current condition already handles this because the right side `(accessKey == null || secretKey == null || sessionToken == null)` — but we don't have `sessionToken` for MinIO buckets. So update:

```java
// Before:
if ((bucketPath == null || region == null || awsRoleArn == null)
    && (accessKey == null || secretKey == null || sessionToken == null)) {
  break;
}

// After:
boolean isMinioGw = minioGateway != null && minioGateway.equalsIgnoreCase("true");
if ((bucketPath == null || region == null || awsRoleArn == null)
    && (accessKey == null || secretKey == null || sessionToken == null)
    && !isMinioGw) {
  break;
}
```

This ensures a MinIO gateway bucket config with `bucketPath + accessKey + secretKey + minioGateway=true` (but no `awsRoleArn` or `sessionToken`) doesn't cause the loop to break early.

### 3. `AwsCredentialVendor.java` — add minioGateway routing

**File:** `server/src/main/java/io/unitycatalog/server/service/credential/aws/AwsCredentialVendor.java`

#### 3a. `vendAwsCredentials()` — add minioGateway check BEFORE existing logic

The key issue: when authorization is enabled, creating a table requires an external location + credential. If an external location matches the table's path, `credentialDAO` will be present, and the existing code routes to the master role STS (AWS). For MinIO gateway buckets, we need to intercept this and route to the per-bucket MinIO STS generator instead.

```java
public Credentials vendAwsCredentials(CredentialContext context) {
    AwsCredentialGenerator generator;

    // NEW: MinIO gateway buckets always use per-bucket generator,
    // even when a CredentialDAO is present (from external location).
    // The credential/external location exist for authorization checks only.
    // Actual credential vending goes through MinIO STS.
    S3StorageConfig minioConfig = perBucketS3Configs.get(context.getStorageBase());
    if (minioConfig != null && minioConfig.isMinioGateway()) {
      generator =
          perBucketCredGenerators.computeIfAbsent(
              context.getStorageBase(),
              storageBase -> createPerBucketCredentialGenerator(minioConfig));
      return generator.generate(context);
    }

    // EXISTING logic below — completely unchanged
    if (context.getCredentialDAO().isPresent()) {
      // Use the master role STS generator
      generator = getAwsS3MasterRoleStsGenerator();
    } else {
      // No credential dao. Use the per bucket config
      S3StorageConfig config = perBucketS3Configs.get(context.getStorageBase());
      if (config == null) {
        throw new BaseException(
            ErrorCode.FAILED_PRECONDITION, "S3 bucket configuration not found.");
      }
      generator =
          perBucketCredGenerators.computeIfAbsent(
              context.getStorageBase(),
              storageBase -> createPerBucketCredentialGenerator(config));
    }
    return generator.generate(context);
}
```

#### 3b. `createPerBucketCredentialGenerator()` — pass `S3StorageConfig` to constructor

The current code only supports no-arg constructors for custom generators. Our `MinioStsCredentialGenerator` needs `S3StorageConfig` for the MinIO endpoint and credentials:

```java
private AwsCredentialGenerator createPerBucketCredentialGenerator(S3StorageConfig config) {
    // NEW: MinIO gateway uses its own generator
    if (config.isMinioGateway()) {
      return new MinioStsCredentialGenerator(config);
    }

    // EXISTING logic below — unchanged
    if (config.getCredentialGenerator() != null) {
      try {
        return (AwsCredentialGenerator)
            Class.forName(config.getCredentialGenerator()).getDeclaredConstructor().newInstance();
      } catch (Exception e) {
        throw new RuntimeException(e);
      }
    }

    if (config.getSessionToken() != null && !config.getSessionToken().isEmpty()) {
      return new AwsCredentialGenerator.StaticAwsCredentialGenerator(config);
    }

    return createStsCredentialGenerator(config);
}
```

### 4. New `MinioStsCredentialGenerator.java`

**File:** `server/src/main/java/io/unitycatalog/server/service/credential/aws/MinioStsCredentialGenerator.java`

This generator calls MinIO's STS `AssumeRole` endpoint with a scoped session policy. Since MinIO's STS is AWS-compatible, we reuse the AWS SDK `StsClient` with an endpoint override pointing to MinIO.

Key differences from `StsAwsCredentialGenerator`:
- **STS endpoint = MinIO endpoint** — uses `endpointOverride` pointing to MinIO gateway
- **`roleArn` is a dummy value** — MinIO ignores it, but the AWS SDK requires it
- **No `externalId`** — not applicable for MinIO
- **Reuses `AwsPolicyGenerator`** — existing policy generation logic works as-is

```java
package io.unitycatalog.server.service.credential.aws;

import io.unitycatalog.server.service.credential.CredentialContext;
import java.net.URI;
import java.util.UUID;
import software.amazon.awssdk.auth.credentials.AwsBasicCredentials;
import software.amazon.awssdk.auth.credentials.StaticCredentialsProvider;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.sts.StsClient;
import software.amazon.awssdk.services.sts.model.AssumeRoleRequest;
import software.amazon.awssdk.services.sts.model.Credentials;

/**
 * Credential generator for MinIO gateway buckets.
 *
 * <p>Calls MinIO's STS AssumeRole endpoint with a scoped session policy.
 * MinIO's STS is AWS-compatible, so we reuse the AWS SDK StsClient with
 * an endpoint override pointing to the MinIO gateway.
 *
 * <p>Key differences from {@link AwsCredentialGenerator.StsAwsCredentialGenerator}:
 * <ul>
 *   <li>STS endpoint = MinIO gateway endpoint (not AWS STS)
 *   <li>roleArn is a dummy value (MinIO ignores it, identifies user from Signature V4)
 *   <li>No externalId (not applicable for MinIO)
 *   <li>Credentials are the CMC S3 root credentials (used to auth with MinIO gateway)
 * </ul>
 */
public class MinioStsCredentialGenerator implements AwsCredentialGenerator {

  private final StsClient stsClient;

  public MinioStsCredentialGenerator(S3StorageConfig config) {
    Region region = (config.getRegion() != null && !config.getRegion().isEmpty())
        ? Region.of(config.getRegion())
        : Region.US_EAST_1;

    this.stsClient = StsClient.builder()
        .region(region)
        .credentialsProvider(
            StaticCredentialsProvider.create(
                AwsBasicCredentials.create(config.getAccessKey(), config.getSecretKey())))
        .endpointOverride(URI.create(config.getEndpoint()))
        .build();
  }

  @Override
  public Credentials generate(CredentialContext ctx) {
    String policy = AwsPolicyGenerator.generatePolicy(
        ctx.getPrivileges(), ctx.getLocations());

    AssumeRoleRequest request = AssumeRoleRequest.builder()
        .roleArn("arn:aws:iam::minio:role/minio-gateway")  // Required by SDK, ignored by MinIO
        .policy(policy)
        .roleSessionName("uc-" + UUID.randomUUID())
        .durationSeconds(3600)
        .build();

    return stsClient.assumeRole(request).credentials();
  }
}
```

### 5. Configuration

**`server.properties`:**

```properties
#### Per-bucket S3 config — supports mixed AWS and MinIO gateway buckets

## Bucket 0: CMC S3 via MinIO gateway
s3.bucketPath.0=s3://dataplatform-dev-hn1
s3.region.0=us-east-1
s3.endpoint.0=http://minio-gateway:9000
s3.pathStyleAccess.0=true
s3.accessKey.0=<CMC_S3_ACCESS_KEY>
s3.secretKey.0=<CMC_S3_SECRET_KEY>
s3.minioGateway.0=true

## Bucket 1: Normal AWS S3 (unchanged, existing flow)
# s3.bucketPath.1=s3://my-aws-bucket
# s3.region.1=ap-southeast-1
# s3.awsRoleArn.1=arn:aws:iam::123456789:role/data-role
```

### UC Setup for Authorization

When authorization is enabled, you still need a credential and external location for table creation to pass auth checks. The credential's `roleArn` is a dummy value — it's never used because `minioGateway=true` routes vending to `MinioStsCredentialGenerator`.

```
1. Create Credential:
   name: "minio-gateway-cred"
   aws_iam_role.role_arn: "arn:aws:iam::minio:role/minio-gateway"  (dummy, never used for STS)

2. Create External Location:
   name: "cmc-s3-dataplatform"
   url: "s3://dataplatform-dev-hn1"
   credential_name: "minio-gateway-cred"

3. Create Table:
   storage_location: "s3://dataplatform-dev-hn1/unity/catalog/schema/table"
   → Auth check passes (external location covers the path)
   → Vending: minioGateway=true → MinioStsCredentialGenerator → MinIO STS
```

---

## Credential Vending Flow (with minioGateway flag)

```
vendAwsCredentials(context):
  │
  ├─ Is per-bucket config minioGateway=true?
  │   YES → MinioStsCredentialGenerator
  │          → calls MinIO STS AssumeRole with session policy
  │          → returns temp creds scoped to the requested paths
  │          → Spark uses temp creds against MinIO gateway
  │
  │   NO  → existing logic (completely unchanged):
  │          ├─ credentialDAO present?
  │          │   YES → master role STS (assumes roleArn from credential via AWS STS)
  │          │
  │          └─ no credentialDAO?
  │              └─ per-bucket fallback (static creds / STS with per-bucket config)
```

---

## Deployment

### Docker Compose

```yaml
services:
  minio-gateway:
    image: uzumlukek/minio-gateway:latest
    command: gateway s3 https://s3.hcm-3.cloud.cmctelecom.vn --console-address ":9001"
    ports:
      - "9000:9000"
      - "9001:9001"
    environment:
      MINIO_ROOT_USER: ${CMC_S3_ACCESS_KEY}
      MINIO_ROOT_PASSWORD: ${CMC_S3_SECRET_KEY}
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:9000/minio/health/live"]
      interval: 30s
      timeout: 10s
      retries: 3

  unity-catalog:
    image: unity-catalog:latest
    depends_on:
      minio-gateway:
        condition: service_healthy
```

### Post-Deploy Verification

```bash
# Verify STS works
source .env
aws sts assume-role \
  --endpoint-url http://localhost:9000 \
  --role-arn "arn:aws:iam::minio:role/ignored" \
  --role-session-name test-session \
  --policy '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["s3:GetO*"],"Resource":["arn:aws:s3:::dataplatform-dev-hn1/unity/*","arn:aws:s3:::dataplatform-dev-hn1/unity"]},{"Effect":"Allow","Action":["s3:ListBucket"],"Resource":["arn:aws:s3:::dataplatform-dev-hn1"],"Condition":{"StringLike":{"s3:prefix":["unity","unity/","unity/*"]}}}]}' \
  --duration-seconds 3600 \
  --output json
```

Full test suite: `minio-gateway/test-sts.sh`

---

## Pros and Cons

### Pros
- **Full STS + subpath scoping** — temporary credentials restricted to specific paths per user/job
- **No code changes to Spark** — it just sees an S3-compatible endpoint with temp creds
- **Reuses `AwsPolicyGenerator`** — existing policy generation logic works as-is with MinIO
- **Mixed environment support** — AWS and MinIO gateway buckets coexist via per-bucket config
- **Non-invasive** — existing AWS flow is completely untouched; new `minioGateway` flag adds a separate code path
- **No separate MinIO user needed** — root CMC S3 creds are used for STS, session policy handles scoping

### Cons
- **Gateway mode is deprecated** (~Aug 2025 removal) — need to pin version or use community fork
- **Extra network hop** — all S3 traffic flows through MinIO
- **MinIO becomes a dependency** — need HA setup (multiple instances behind load balancer)
- **Single point of failure** — if MinIO goes down, Spark can't access storage

### Risk Mitigation
- **Gateway deprecation**: Pin Docker image version. Monitor MinIO releases. Community fork `uzumlukek/minio-gateway` maintains gateway support.
- **HA**: Run multiple MinIO gateway instances behind a load balancer (gateway mode is stateless)
- **Performance**: MinIO gateway adds minimal overhead — it's a thin proxy, no data stored locally

---

## References

- **MinIO Gateway Docker image**: https://hub.docker.com/r/uzumlukek/minio-gateway
- **MinIO Gateway deprecation blog**: https://min.io/blog/deprecation-of-the-minio-gateway
- **MinIO AssumeRole docs**: https://github.com/minio/minio/blob/master/docs/sts/assume-role.md
- **MinIO STS documentation**: https://docs.min.io/enterprise/aistor-object-store/developers/security-token-service/
- **MinIO policy-based access control**: https://docs.min.io/enterprise/aistor-object-store/administration/iam/access/
