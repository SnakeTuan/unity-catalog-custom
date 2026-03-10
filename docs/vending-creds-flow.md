# Vending Credentials Flow for Spark Job

## High-Level Overview

```mermaid
sequenceDiagram
    participant Spark as Spark Job
    participant UC as Unity Catalog Server
    participant STS as AWS STS
    participant S3 as S3 Storage

    Spark->>UC: 1. Resolve table metadata (catalog.schema.table)
    UC-->>Spark: Table info + storage location (s3://bucket/path)

    Spark->>UC: 2. Request temporary credentials (tableId, READ or READ_WRITE)
    UC->>UC: 3. Authorize (USE_CATALOG, USE_SCHEMA, SELECT/MODIFY)
    UC->>UC: 4. Lookup storage credential (ExternalLocation or per-bucket config)
    UC->>UC: 5. Generate scoped IAM policy (restrict to S3 paths + operations)
    UC->>STS: 6. AssumeRole (roleArn, externalId, scoped policy, TTL=1h)
    STS-->>UC: 7. Temporary credentials (accessKeyId, secretAccessKey, sessionToken)
    UC-->>Spark: 8. Return temporary credentials + expiration

    Spark->>S3: 9. Read/write data files using temp credentials
    S3-->>Spark: Data

    Note over Spark: Credentials are cached. Auto-renewed before expiry.
```

## Detailed Architecture

```mermaid
sequenceDiagram
    participant Spark as Spark Job
    participant Catalog as UCSingleCatalog
    participant S3A as Hadoop S3A
    participant Cred as AwsVendedTokenProvider
    participant Cache as Credential Cache
    participant API as UC REST API
    participant Auth as Authorization Layer
    participant SCV as StorageCredentialVendor
    participant CCV as CloudCredentialVendor
    participant ACV as AwsCredentialVendor
    participant Policy as AwsPolicyGenerator
    participant Gen as AwsCredentialGenerator
    participant STS as AWS STS
    participant S3 as S3 Storage

    Note over Spark,S3: Spark Connector Side

    Spark->>Catalog: Step 1. SELECT * FROM catalog.schema.table
    Catalog-->>Spark: Step 2. Table metadata + storage location s3://bucket/path

    Spark->>S3A: Step 3. Read/write data files
    S3A->>Cred: Step 4. Need AWS credentials
    Cred->>Cache: Step 5. Check cache for valid credentials

    alt Cache hit and not expired
        Cache-->>Cred: Return cached credentials
    else Cache miss or expired
        Note over API,Gen: Unity Catalog Server Side

        Cache->>API: Step 6. POST /temporary-table-credentials with tableId + READ/READ_WRITE
        API->>Auth: Step 7. Check USE_CATALOG, USE_SCHEMA, SELECT/MODIFY on TABLE
        Auth-->>API: Authorized
        API->>SCV: Step 8. Lookup ExternalLocation or per-bucket config for path
        SCV-->>API: CredentialDAO or per-bucket S3StorageConfig
        API->>CCV: Step 9. Route by storage scheme s3:// to AWS vendor
        CCV->>ACV: Step 10. Select credential generator mode
        ACV->>Policy: Step 11. Generate scoped IAM policy for S3 paths + actions
        Policy-->>ACV: IAM policy: s3:GetO*, s3:PutO*, s3:DeleteO*

        Note over STS: AWS Side

        ACV->>Gen: Step 12. Build AssumeRole request
        Gen->>STS: Step 13. AssumeRole with roleArn + externalId + policy + TTL=1h
        STS-->>Gen: Step 14. accessKeyId + secretAccessKey + sessionToken + expiration

        Gen-->>CCV: Credentials
        CCV-->>API: TemporaryCredentials JSON
        API-->>Cache: Step 15. HTTP 200 with AwsCredentials + expirationTime
        Cache->>Cache: Step 16. Cache credentials, set expiration timer
    end

    Cache-->>Cred: AwsSessionCredentials
    Cred-->>S3A: accessKeyId + secretAccessKey + sessionToken
    S3A->>S3: Step 17. Read/write data files using temp credentials
    S3-->>S3A: Data
    S3A-->>Spark: Query results

    Note over Spark: Credentials auto-renewed before expiry
```

## Overview

When a Spark job accesses a Unity Catalog table, it needs temporary cloud storage credentials to read/write the underlying data files. Unity Catalog vends these credentials through a multi-step flow involving the Spark connector and the UC server.

## Sequence Diagram

```mermaid
sequenceDiagram
    participant Spark as Spark Connector
    participant VTP as AwsVendedTokenProvider
    participant GCP as GenericCredentialProvider
    participant API as TemporaryCredentialsApi (HTTP)
    participant TCS as TemporaryTableCredentialsService
    participant SCV as StorageCredentialVendor
    participant CCV as CloudCredentialVendor
    participant ACV as AwsCredentialVendor
    participant ACG as AwsCredentialGenerator
    participant STS as AWS STS AssumeRole

    Spark->>VTP: resolveCredentials()
    VTP->>GCP: accessCredentials()
    GCP->>GCP: Check if credential is null or expired
    alt Credential needs renewal
        GCP->>API: generateTemporaryTableCredentials(tableId, operation)
        API->>TCS: POST /temporary-table-credentials
        TCS->>TCS: Resolve table storage location
        TCS->>SCV: vendCredential(path, privileges)
        SCV->>SCV: Lookup ExternalLocation CredentialDAO
        SCV->>CCV: vendCredential(context)
        CCV->>CCV: Detect storage scheme (S3)
        CCV->>ACV: vendAwsCredentials(context)
        alt CredentialDAO present (External Location)
            ACV->>ACG: MasterRole StsGenerator.generate(context)
        else Per-Bucket Config
            alt Static session token
                ACV->>ACG: StaticGenerator.generate(context)
                ACG-->>ACV: Fixed Credentials (no STS call)
            else STS mode
                ACV->>ACG: StsGenerator.generate(context)
            end
        end
        ACG->>ACG: Generate scoped IAM policy (AwsPolicyGenerator)
        ACG->>STS: assumeRole(roleArn, policy, externalId, 1h)
        STS-->>ACG: Credentials (accessKeyId, secretAccessKey, sessionToken, expiration)
        ACG-->>ACV: Credentials
        ACV-->>CCV: Credentials
        CCV-->>TCS: TemporaryCredentials (AwsCredentials)
        TCS-->>API: HTTP 200 JSON
        API-->>GCP: TemporaryCredentials
        GCP->>GCP: Cache credential
    end
    GCP-->>VTP: GenericCredential
    VTP->>VTP: Extract AwsCredentials
    VTP-->>Spark: AwsSessionCredentials
```

## Key Components

### Spark Connector Side

| Component | File | Role |
|---|---|---|
| `AwsVendedTokenProvider` | `connectors/spark/.../storage/AwsVendedTokenProvider.java` | Implements `AwsCredentialsProvider` for Hadoop S3A. Wraps vended credentials as `AwsSessionCredentials`. |
| `GenericCredentialProvider` | `connectors/spark/.../storage/GenericCredentialProvider.java` | Manages credential lifecycle (caching, renewal). Calls UC server API when credentials expire. |
| `TemporaryCredentialsApi` | Generated client | HTTP client that calls `POST /api/2.1/unity-catalog/temporary-table-credentials` on the UC server. |

### UC Server Side

| Component | File | Role |
|---|---|---|
| `TemporaryTableCredentialsService` | `server/.../service/TemporaryTableCredentialsService.java` | REST endpoint. Resolves table → storage location, enforces authorization, delegates to credential vendor. |
| `StorageCredentialVendor` | `server/.../service/credential/StorageCredentialVendor.java` | Looks up `CredentialDAO` from external locations, builds `CredentialContext`, delegates to cloud vendor. |
| `CloudCredentialVendor` | `server/.../service/credential/CloudCredentialVendor.java` | Routes to AWS/Azure/GCP vendor based on storage scheme (`s3://`, `abfss://`, `gs://`). |
| `AwsCredentialVendor` | `server/.../service/credential/aws/AwsCredentialVendor.java` | Selects credential generator based on config mode (external location vs per-bucket). |
| `AwsCredentialGenerator` | `server/.../service/credential/aws/AwsCredentialGenerator.java` | Calls AWS STS `AssumeRole` with a scoped-down IAM policy. Returns temporary `accessKeyId`, `secretAccessKey`, `sessionToken`. |
| `AwsPolicyGenerator` | `server/.../service/credential/aws/AwsPolicyGenerator.java` | Generates a scoped IAM policy restricting access to specific S3 paths and operations (SELECT → `s3:GetO*`, UPDATE → `s3:PutO*`, `s3:DeleteO*`). |

## Credential Generation Modes

```mermaid
flowchart TD
    A[AwsCredentialVendor.vendAwsCredentials] --> B{CredentialDAO present?}
    B -->|Yes - External Location| C[Master Role STS Generator]
    B -->|No - Per-Bucket Config| D{Config type?}
    D -->|credentialGenerator class set| E[Custom Generator - dynamically loaded]
    D -->|sessionToken set| F[StaticAwsCredentialGenerator - returns fixed creds]
    D -->|otherwise| G[StsAwsCredentialGenerator]
    C --> H[STS AssumeRole with externalId]
    G --> I[STS AssumeRole without externalId]
    H --> J[Scoped temporary credentials]
    I --> J
    F --> J
    E --> J
```

### Mode 1: External Location Credentials (CredentialDAO)

The UC master IAM role assumes the customer's storage IAM role via STS:

- **roleArn**: from `CredentialDAO` → `AwsIamRoleResponse.roleArn`
- **externalId**: from `CredentialDAO` → `AwsIamRoleResponse.externalId` (prevents confused deputy)
- **policy**: scoped-down to specific S3 paths and operations
- **duration**: 1 hour

### Mode 2: Per-Bucket Config (`server.properties`)

Uses `s3.bucketPath.*`, `s3.accessKey.*`, `s3.secretKey.*` etc.:

- **Static**: If `sessionToken` is set, returns it directly (no STS call). For testing only.
- **Custom**: If `credentialGenerator` is set, loads the class dynamically.
- **STS**: Otherwise, uses the configured access/secret key (or default credentials) to call STS AssumeRole.

## Credential Caching & Renewal

The Spark connector caches credentials to avoid excessive API calls:

1. `GenericCredentialProvider` holds a `volatile GenericCredential`
2. On each `accessCredentials()` call, checks if credential is null or near expiry
3. Renewal lead time is configurable via `fs.unitycatalog.credential.renewalLeadTime` (default: pre-expiry buffer)
4. A global `Cache<String, GenericCredential>` is shared across providers (max 1024 entries)

## Non-AWS S3 (e.g., CMC S3) Considerations

The default STS flow assumes AWS infrastructure (`sts.amazonaws.com`, `arn:aws:s3:::` ARNs). For S3-compatible storage:

- **Option 1**: Use `StaticAwsCredentialGenerator` with a pre-set session token (bypasses STS)
- **Option 2**: Implement a custom `AwsCredentialGenerator` and set it via `s3.credentialGenerator.<bucket>` in `server.properties`
- **Option 3**: Skip credential vending entirely and configure static S3 keys directly in Spark/Hadoop config
