# Credential Vending for CMC S3 (No STS Service)

## Problem

Unity Catalog's credential vending calls AWS STS `AssumeRole` to generate temporary, path-scoped credentials. CMC S3 is an S3-compatible object store but **does not have an STS service**, so the default flow breaks.

**Requirements:**
- Cannot pass full bucket credentials to Spark jobs
- Credentials must be scoped by user and subpath
- Must work with CMC S3 (S3-compatible, no STS)

## Current UC Credential Vending Flow

```
Spark → UC Server → AWS STS AssumeRole (roleArn + scoped IAM policy) → temp creds
Spark → S3 (using temp creds, restricted to specific paths + actions)
```

Key files:
- `AwsCredentialGenerator.java` — interface with `StaticAwsCredentialGenerator` and `StsAwsCredentialGenerator`
- `AwsCredentialVendor.java` — selects generator mode
- `AwsPolicyGenerator.java` — generates scoped IAM policies
- `CloudCredentialVendor.java` — routes by storage scheme (s3://, abfss://, gs://)
- Plugin hook: `s3.credentialGenerator.<idx>` in `server.properties` loads a custom class

## Why MinIO Gateway + STS Won't Work As-Is

**Initial idea:** CMC S3 token → MinIO STS → MinIO Gateway → CMC S3

**Issues:**
1. **MinIO Gateway is deprecated/removed** — removed after `RELEASE.2022-10-29`. The enterprise product (AIStor) may still have it, but it's not a supported path going forward.
2. **MinIO STS doesn't support `AssumeRole`** — MinIO STS only supports:
   - `AssumeRoleWithWebIdentity` (OIDC tokens)
   - `AssumeRoleWithLDAPIdentity` (LDAP/AD)
   - `AssumeRoleWithCustomToken` (custom identity plugin)

   Unity Catalog calls plain `AssumeRole`, which MinIO doesn't implement.
3. **MinIO STS credentials only work against MinIO** — temp creds from MinIO authenticate against *that MinIO instance*, not against CMC S3 directly. So the flow would need to be: `Spark → MinIO (temp creds) → MinIO proxies to CMC S3 (service account)`. Without gateway mode, MinIO can't transparently proxy to CMC S3.

---

## Solution 1: Custom `AwsCredentialGenerator` + MinIO as the Storage Layer

**Not gateway mode** — MinIO becomes the primary S3 endpoint.

### Architecture

```
UC Server → MinIO STS (AssumeRoleWithCustomToken) → scoped temp creds
Spark → MinIO (using temp creds) → MinIO stores data on local/network disk
CMC S3 ← MinIO bucket replication (async sync)
```

### How It Works

1. Deploy MinIO as the **primary S3 endpoint** for Spark (not as a gateway)
2. Configure MinIO with an OIDC provider or custom identity plugin for STS
3. Set up MinIO bucket policies to enforce per-user, per-path scoping
4. Write a custom `AwsCredentialGenerator` that calls MinIO's STS `AssumeRoleWithCustomToken` endpoint
5. UC returns MinIO temp creds → Spark reads/writes to MinIO
6. Use MinIO's bucket replication to sync data to/from CMC S3

### Pros
- Full STS + scoped temporary credentials
- No code changes to Spark connector (it just sees S3-compatible endpoint)
- MinIO is battle-tested

### Cons
- MinIO becomes another infra component to maintain
- Data flows through MinIO (extra hop)
- Replication lag between MinIO and CMC S3
- Data duplication (MinIO stores its own copy)

---

## Solution 2: Build a Lightweight STS Microservice for CMC S3 ⭐ Recommended

If CMC S3 has any admin API for creating users/access keys with policies (most S3-compatible stores support `CreateUser`, `PutUserPolicy`, `CreateAccessKey` admin APIs).

### Architecture

```
UC Server → Custom STS Service → CMC S3 Admin API
                                  ├── Create temp user
                                  ├── Attach scoped bucket policy (path + actions)
                                  └── Create access key
                                ← returns temp accessKey/secretKey

Spark → CMC S3 directly (using temp creds)

Background cleanup job → CMC S3 Admin API → delete expired temp users
```

### How It Works

1. Build a small service that implements an STS-like API
2. On each credential request:
   - Create a temporary CMC S3 user (e.g., `uc-temp-{uuid}`)
   - Attach a scoped bucket policy restricting to specific paths and actions
   - Create an access key for that user
   - Return the access key / secret key with a TTL
3. A background job periodically deletes expired temp users
4. Write a custom `AwsCredentialGenerator` that calls this STS service
5. Spark uses the temp creds **directly against CMC S3** — no proxy needed

### UC Configuration

```properties
# server.properties
s3.bucketPath.0=s3://your-bucket
s3.endpoint.0=https://cmc-s3.your-company.com
s3.pathStyleAccess.0=true
s3.credentialGenerator.0=io.unitycatalog.server.service.credential.aws.CmcStsCredentialGenerator
```

### Custom Generator Skeleton

```java
public class CmcStsCredentialGenerator implements AwsCredentialGenerator {
    private final String stsServiceUrl;

    public CmcStsCredentialGenerator(S3StorageConfig config) {
        // Read STS service URL from config or environment
        this.stsServiceUrl = System.getenv("CMC_STS_SERVICE_URL");
    }

    @Override
    public Credentials generate(CredentialContext ctx) {
        // 1. Build request with paths + privileges
        // 2. Call your STS microservice
        // 3. Return Credentials (accessKeyId, secretAccessKey, sessionToken)

        String policy = AwsPolicyGenerator.generatePolicy(
            ctx.getPrivileges(), ctx.getLocations());

        // Call STS service: POST /assume-role
        // Body: { "policy": policy, "duration": 3600 }
        // Response: { "accessKeyId": "...", "secretAccessKey": "...", "expiration": "..." }

        // Return as AWS SDK Credentials object
        return Credentials.builder()
            .accessKeyId(response.getAccessKeyId())
            .secretAccessKey(response.getSecretAccessKey())
            .sessionToken(response.getSessionToken()) // optional
            .expiration(response.getExpiration())
            .build();
    }
}
```

### Pros
- Spark talks to CMC S3 directly (no extra hop, no proxy)
- True scoped credentials per-user and per-path
- Minimal UC code changes (one new class + config line)
- Clean separation of concerns

### Cons
- Requires building + maintaining the STS microservice
- Depends on CMC S3's admin API capabilities
- Need a cleanup mechanism for expired temp users

---

## Solution 3: S3 Reverse Proxy with Token-Based Auth

Deploy a thin S3-compatible reverse proxy in front of CMC S3.

### Architecture

```
UC Server → signs a JWT with {user, paths, privileges, expiry}
           → returns accessKeyId=userId, secretAccessKey=signingKey, sessionToken=JWT

Spark → S3 Proxy
        ├── Validates JWT (sessionToken)
        ├── Checks path permissions encoded in JWT
        ├── Forwards allowed requests to CMC S3 (service account)
        └── Rejects unauthorized paths
CMC S3 ← proxy forwards with real service account creds
```

### How It Works

1. Write a custom `AwsCredentialGenerator` that mints a signed JWT containing:
   - Allowed S3 paths
   - Allowed actions (read/write)
   - User identity
   - Expiry time
2. Return `accessKeyId=userId`, `secretAccessKey=signingKey`, `sessionToken=JWT`
3. Deploy an S3-compatible proxy (e.g., [S3Proxy](https://github.com/gaul/s3proxy) or custom) that:
   - Intercepts all S3 API requests
   - Extracts and validates the JWT from the session token
   - Checks if the requested path is allowed by the JWT policy
   - Forwards allowed requests to CMC S3 using a service account
   - Rejects unauthorized requests with 403
4. Spark thinks it's talking to a normal S3 endpoint with temp creds

### Pros
- Full control over scoping logic
- No dependency on STS protocol
- Works with any S3-compatible backend

### Cons
- Extra network hop through the proxy
- Need to build/maintain the proxy with S3 API compatibility
- Proxy becomes a single point of failure (need HA)

---

## Solution 4: Check if CMC S3 Has Hidden STS Capabilities

Many private-cloud S3 implementations are built on Ceph RadosGW. **Ceph natively supports STS** including `AssumeRole` with scoped policies.

### Steps

1. Ask CMC team: "Does CMC S3 support `sts:AssumeRole`? Is it based on Ceph?"
2. Check if CMC S3 exposes an STS endpoint (e.g., `https://cmc-s3.company.com/?Action=AssumeRole`)
3. If it does, configure UC to point to it:

```properties
# If CMC S3 has STS, this might work out of the box
s3.bucketPath.0=s3://your-bucket
s3.endpoint.0=https://cmc-s3.your-company.com
s3.region.0=us-east-1
s3.awsRoleArn.0=arn:aws:iam::account:role/data-role
s3.accessKey.0=<CMC admin key>
s3.secretKey.0=<CMC admin secret>
s3.pathStyleAccess.0=true
```

The existing `StsAwsCredentialGenerator` already supports custom endpoints via the STS client builder.

### Pros
- Zero code changes if it works
- Native STS with full scoped policy support

### Cons
- Depends entirely on CMC S3's capabilities
- Most likely not available (otherwise this problem wouldn't exist)

---

## Recommendation

| Priority | Solution | When to Use |
|----------|----------|-------------|
| 1st | **Solution 4** — Check CMC S3 for native STS | Always check first. Zero effort if available. |
| 2nd | **Solution 2** — Custom STS microservice | If CMC S3 has admin APIs for user/policy management. Best balance of security + simplicity. |
| 3rd | **Solution 1** — MinIO as storage layer | If you want a proven STS implementation and can tolerate MinIO as an intermediary. |
| 4th | **Solution 3** — S3 reverse proxy | If CMC S3 has no admin APIs at all and you need maximum flexibility. |

## Next Steps

1. **Check CMC S3 capabilities:** Does it have STS? Admin APIs for creating users/policies?
2. **Choose a solution** based on available CMC S3 APIs
3. **Implement custom `AwsCredentialGenerator`** — the plugin hook already exists in UC
4. **Test with Spark** — the Spark connector doesn't need changes, it just uses the vended credentials
