# MinIO Gateway + STS Solution for CMC S3 Credential Vending

## Problem

CMC S3 lacks an STS service. Unity Catalog's credential vending needs to issue **temporary, path-scoped credentials** per user/job. We cannot pass full bucket credentials to Spark.

## Solution: MinIO Gateway + MinIO STS as S3 Proxy

Deploy MinIO in **gateway mode** in front of CMC S3. MinIO handles authentication (STS) and authorization (session policies), then proxies all S3 requests to CMC S3 using a service account.

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
                          Auth: MinIO admin accessKey/secretKey (Signature V4)
                        ← Returns: temp accessKeyId + secretAccessKey + sessionToken

2. UC Server → Spark: here are your temp creds, endpoint = MinIO

3. Spark → MinIO (using temp creds): GetObject s3://bucket/user123/tables/data.parquet
   MinIO validates temp creds + checks session policy allows this path
   MinIO → CMC S3 (using service account creds): forwards the request
   CMC S3 → MinIO → Spark: returns the data
```

### Why This Works

1. **MinIO STS `AssumeRole`** supports a `Policy` parameter (inline session policy) — same format as AWS IAM policies
2. **Session policies support subpath scoping** — `Resource: "arn:aws:s3:::bucket/prefix/*"` works in MinIO
3. **MinIO Gateway** transparently proxies all S3 operations to CMC S3 — Spark doesn't know CMC S3 exists
4. **Temp creds authenticate against MinIO**, MinIO forwards to CMC S3 with its own service account

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
| `AUTHPARAMS` | Yes | Signature V4 auth using MinIO user credentials |

### Session Policy for Subpath Scoping

MinIO follows the AWS IAM policy spec. A session policy can restrict access to specific prefixes:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject"],
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

The session policy **cannot grant more permissions** than the base MinIO user has — it can only scope down. This is the same behavior as AWS STS session policies.

### Response Format

```xml
<?xml version="1.0" encoding="UTF-8"?>
<AssumeRoleResponse xmlns="https://sts.amazonaws.com/doc/2011-06-15/">
  <AssumeRoleResult>
    <Credentials>
      <AccessKeyId>TEMP_ACCESS_KEY</AccessKeyId>
      <SecretAccessKey>TEMP_SECRET_KEY</SecretAccessKey>
      <SessionToken>eyJhbGciOi...</SessionToken>
      <Expiration>2024-01-01T12:00:00Z</Expiration>
    </Credentials>
  </AssumeRoleResult>
</AssumeRoleResponse>
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
4. **MinIO AIStor (enterprise)** — may continue gateway support (verify with MinIO sales)

### Gateway Startup

```bash
# Start MinIO in S3 gateway mode, proxying to CMC S3
export MINIO_ROOT_USER=minio-admin
export MINIO_ROOT_PASSWORD=minio-secret-key

minio gateway s3 https://s3.hcm-3.cloud.cmctelecom.vn \
  --console-address ":9001"
```

Or with Docker:

```bash
docker run -d \
  --name minio-gateway \
  -p 9000:9000 \
  -p 9001:9001 \
  -e MINIO_ROOT_USER=<CMC_S3_ACCESS_KEY> \
  -e MINIO_ROOT_PASSWORD=<CMC_S3_SECRET_KEY> \
  uzumlukek/minio-gateway:latest \
  gateway s3 https://s3.hcm-3.cloud.cmctelecom.vn \
  --console-address ":9001"
```

> **Note:** In gateway mode, `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD` are set to the CMC S3 service account credentials. MinIO uses these to authenticate to CMC S3 on the backend.

### Create a MinIO User for STS

After gateway is running, create a MinIO user with full S3 access (the session policy will scope it down):

```bash
# Install mc (MinIO Client)
mc alias set mygw http://localhost:9000 minio-admin minio-secret-key

# Create a user for UC Server to call STS with
mc admin user add mygw uc-service-user uc-service-password

# Attach readwrite policy (session policy will scope down per request)
mc admin policy attach mygw readwrite --user uc-service-user
```

---

## UC Code Changes

### 1. Update Plugin Loading to Pass Config

The current plugin system uses a no-arg constructor, but our generator needs `S3StorageConfig` for the MinIO endpoint and credentials. Update `AwsCredentialVendor.createPerBucketCredentialGenerator()` to try the `(S3StorageConfig)` constructor first:

**File:** `AwsCredentialVendor.java` — `createPerBucketCredentialGenerator()`

```java
// Before (no-arg constructor only):
Class.forName(config.getCredentialGenerator()).getDeclaredConstructor().newInstance();

// After (try S3StorageConfig constructor first, fallback to no-arg):
Class<?> clazz = Class.forName(config.getCredentialGenerator());
try {
  return (AwsCredentialGenerator) clazz
      .getDeclaredConstructor(S3StorageConfig.class)
      .newInstance(config);
} catch (NoSuchMethodException e) {
  return (AwsCredentialGenerator) clazz.getDeclaredConstructor().newInstance();
}
```

### 2. New `MinioStsCredentialGenerator`

**File:** `server/src/main/java/io/unitycatalog/server/service/credential/aws/MinioStsCredentialGenerator.java`

This generator calls MinIO's STS `AssumeRole` endpoint with a scoped session policy.

Since MinIO's STS is AWS-compatible, we can reuse the AWS SDK `StsClient` with an endpoint override pointing to MinIO. The key difference from `StsAwsCredentialGenerator`:

- **No `roleArn` needed** — MinIO identifies the base user from Signature V4 auth
- **STS endpoint = MinIO endpoint** — not a separate STS URL
- **Session `Policy` parameter** — used to scope credentials to subpaths (reuses `AwsPolicyGenerator`)

```java
public class MinioStsCredentialGenerator implements AwsCredentialGenerator {

  private final StsClient stsClient;

  public MinioStsCredentialGenerator(S3StorageConfig config) {
    Region region = (config.getRegion() != null && !config.getRegion().isEmpty())
        ? Region.of(config.getRegion())
        : Region.US_EAST_1;

    StsClientBuilder builder = StsClient.builder()
        .region(region)
        .credentialsProvider(
            StaticCredentialsProvider.create(
                AwsBasicCredentials.create(config.getAccessKey(), config.getSecretKey())))
        .endpointOverride(URI.create(config.getEndpoint()));

    this.stsClient = builder.build();
  }

  @Override
  public Credentials generate(CredentialContext ctx) {
    String policy = AwsPolicyGenerator.generatePolicy(
        ctx.getPrivileges(), ctx.getLocations());

    AssumeRoleRequest request = AssumeRoleRequest.builder()
        .roleArn("arn:aws:iam::minio:role/ignored")  // Required by SDK, ignored by MinIO
        .policy(policy)
        .roleSessionName("uc-" + UUID.randomUUID())
        .durationSeconds(3600)
        .build();

    return stsClient.assumeRole(request).credentials();
  }
}
```

### 3. Configuration

**`server.properties`:**

```properties
# MinIO Gateway endpoint (this is where Spark will connect)
s3.bucketPath.0=s3://dataplatform-dev-hn1
s3.region.0=us-east-1
s3.endpoint.0=http://minio-gateway:9000
s3.pathStyleAccess.0=true

# MinIO user credentials for STS calls
s3.accessKey.0=uc-service-user
s3.secretKey.0=uc-service-password

# Use MinIO STS credential generator
s3.credentialGenerator.0=io.unitycatalog.server.service.credential.aws.MinioStsCredentialGenerator
```

---

## Deployment

### Docker Compose Example

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
    environment:
      # These go into server.properties or override them
      S3_ENDPOINT: http://minio-gateway:9000
      S3_ACCESS_KEY: uc-service-user
      S3_SECRET_KEY: uc-service-password
```

### Post-Deploy Setup

```bash
# 1. Set up mc alias
mc alias set mygw http://minio-gateway:9000 $CMC_S3_ACCESS_KEY $CMC_S3_SECRET_KEY

# 2. Create the UC service user for STS
mc admin user add mygw uc-service-user uc-service-password

# 3. Attach readwrite policy (session policies will scope down per-request)
mc admin policy attach mygw readwrite --user uc-service-user

# 4. Verify STS works
aws sts assume-role \
  --endpoint-url http://minio-gateway:9000 \
  --role-arn "arn:aws:iam::minio:role/ignored" \
  --role-session-name test-session \
  --policy '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::dataplatform-dev-hn1/test/*"}]}' \
  --duration-seconds 3600
```

---

## Pros and Cons

### Pros
- **Full STS + subpath scoping** — temporary credentials restricted to specific paths per user/job
- **No code changes to Spark** — it just sees an S3-compatible endpoint with temp creds
- **Reuses `AwsPolicyGenerator`** — existing policy generation logic works as-is with MinIO
- **Battle-tested** — MinIO STS is widely used in production
- **Minimal UC code changes** — one new class + one line change in plugin loading

### Cons
- **Gateway mode is deprecated** (~Aug 2025 removal) — need to pin version or use community fork
- **Extra network hop** — all S3 traffic flows through MinIO
- **MinIO becomes a dependency** — need HA setup (multiple instances behind load balancer)
- **Single point of failure** — if MinIO goes down, Spark can't access storage

### Risk Mitigation
- **Gateway deprecation**: Pin Docker image version. Monitor MinIO releases. Have a migration plan to Solution 2 (custom STS microservice) or Solution 3 (custom S3 proxy) if gateway is fully removed
- **HA**: Run multiple MinIO gateway instances behind a load balancer (gateway mode is stateless)
- **Performance**: MinIO gateway adds minimal overhead — it's a thin proxy, no data stored locally

---

## Comparison with Other Solutions

| Aspect | MinIO Gateway+STS | Custom STS Microservice | Custom S3 Proxy |
|--------|-------------------|------------------------|-----------------|
| Subpath scoping | Yes (session policy) | Yes (user policy) | Yes (JWT claims) |
| Spark direct to CMC S3 | No (through MinIO) | **Yes** | No (through proxy) |
| Extra infra | MinIO cluster | STS microservice | Proxy service |
| Build effort | Low (config only) | Medium (build service) | High (build proxy) |
| STS standard | AWS-compatible | Custom API | Custom (JWT) |
| Dependency risk | Gateway deprecated | CMC S3 admin API | Custom code |
| Data path | Spark→MinIO→CMC S3 | Spark→CMC S3 | Spark→Proxy→CMC S3 |

---

## References

- **MinIO Gateway article**: https://medium.com/picus-security-engineering/on-premises-s3-bucket-object-storage-with-minio-server-gateway-4c44fc321b1c
- **MinIO STS documentation**: https://docs.min.io/enterprise/aistor-object-store/developers/security-token-service/
- **MinIO Gateway Docker image**: https://hub.docker.com/r/uzumlukek/minio-gateway
- **MinIO Gateway deprecation blog**: https://min.io/blog/deprecation-of-the-minio-gateway
- **MinIO AssumeRole docs**: https://github.com/minio/minio/blob/master/docs/sts/assume-role.md
- **MinIO policy-based access control**: https://docs.min.io/enterprise/aistor-object-store/administration/iam/access/
- **CMC S3 credential vending solutions (all options)**: [cmc-s3-credential-vending-solutions.md](./cmc-s3-credential-vending-solutions.md)
