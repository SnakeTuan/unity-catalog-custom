# Spark + Unity Catalog: Normal User Auth Flow

## Overview: Privileges Required per Operation

| Operation | Credential API | UC Privileges Required | S3 Actions Granted |
|-----------|---------------|----------------------|-------------------|
| **CREATE TABLE** | `temporary-path-credentials` (PATH_CREATE_TABLE) | External location: `OWNER` or `CREATE_EXTERNAL_TABLE` | `s3:GetO*`, `s3:PutO*`, `s3:DeleteO*`, `s3:*Multipart*` |
| **INSERT** | `temporary-table-credentials` (READ_WRITE) | `USE_CATALOG` + `USE_SCHEMA` + (`SELECT` + `MODIFY`) | `s3:GetO*`, `s3:PutO*`, `s3:DeleteO*`, `s3:*Multipart*` |
| **SELECT** | `temporary-table-credentials` (READ) | `USE_CATALOG` + `USE_SCHEMA` + `SELECT` | `s3:GetO*` |

---

## 1. CREATE TABLE flow (normal user)

```mermaid
sequenceDiagram
    participant Spark as Spark Driver
    participant Conn as UC Spark Connector
    participant UC as UC Server
    participant STS as AWS STS
    participant S3 as CMC S3

    Spark->>Conn: spark.sql("CREATE TABLE unity.default.new_table<br/>(id INT, name STRING) USING delta<br/>LOCATION 's3://bucket/new_path'")

    Note over Conn: UCSingleCatalog.createTable()<br/>→ has LOCATION → external table<br/>→ calls prepareExternalTableProperties()

    rect rgb(255, 243, 224)
        Note over Conn,UC: STEP 1: Get path credentials (before creating table)
        Conn->>UC: POST /temporary-path-credentials<br/>{url: "s3://bucket/new_path",<br/>operation: "PATH_CREATE_TABLE"}<br/>Authorization: Bearer UC_TOKEN

        Note over UC: AuthDecorator: validate JWT → extract user ID

        Note over UC: Authorization (PATH_CREATE_TABLE):<br/><br/>① #no_overlap_with_data_securable<br/>→ path must not overlap existing tables/volumes<br/><br/>② Is user metastore OWNER? → NO (normal user)<br/><br/>③ Does path match an external location?<br/>→ YES: user needs OWNER or CREATE_EXTERNAL_TABLE<br/>   on that external location<br/>→ NO: DENIED (no fallback for normal users)

        Note over UC: User has CREATE_EXTERNAL_TABLE<br/>on external location covering s3://bucket/
    end

    rect rgb(232, 245, 233)
        Note over UC: STEP 1b: Credential vending (inside UC Server)

        Note over UC: StorageCredentialVendor.vendCredential():<br/>① ExternalLocationUtils: find external location<br/>   that covers s3://bucket/new_path<br/>② Found → get its CredentialDAO<br/>   (contains role_arn, external_id)

        Note over UC: CredentialContext.create():<br/>→ storageScheme: S3<br/>→ privileges: {SELECT, UPDATE}<br/>→ locations: [s3://bucket/new_path]<br/>→ credentialDAO: present (from ext location)

        Note over UC: CloudCredentialVendor → S3 scheme<br/>→ AwsCredentialVendor.vendAwsCredentials()

        Note over UC: CredentialDAO present → use Master Role path:<br/>→ AwsCredentialGenerator.StsAwsCredentialGenerator

        Note over UC: AwsPolicyGenerator.generatePolicy():<br/>→ privileges has UPDATE → use UPDATE_ACTIONS<br/>→ Actions: s3:GetO*, s3:PutO*, s3:DeleteO*,<br/>  s3:*Multipart*<br/>→ Resource: arn:aws:s3:::bucket/new_path/*<br/>→ ListBucket on arn:aws:s3:::bucket<br/>  with prefix condition: new_path/*

        UC->>STS: AssumeRole {<br/>  roleArn: customer's data role (from CredentialDAO),<br/>  externalId: UUID (from CredentialDAO),<br/>  policy: scoped IAM policy (generated above),<br/>  roleSessionName: "uc-{uuid}",<br/>  durationSeconds: 3600<br/>}
        STS-->>UC: {accessKeyId, secretAccessKey,<br/>sessionToken, expiration}

        UC-->>Conn: 200 OK {aws_temp_credentials:<br/>{access_key_id, secret_access_key,<br/>session_token}, expiration_time}
    end

    rect rgb(227, 242, 253)
        Note over Conn: STEP 2: Inject credentials into table properties
        Note over Conn: CredPropsUtil.createPathCredProps():<br/>fs.s3a.access.key = ...<br/>fs.s3a.secret.key = ...<br/>fs.s3a.session.token = ...<br/>fs.s3a.path.style.access = true
    end

    rect rgb(243, 229, 245)
        Note over Conn,S3: STEP 3: Delta creates table + writes to S3
        Conn->>S3: PUT _delta_log/00000.json<br/>(initial Delta commit)<br/>using temp creds from STS
        S3-->>Conn: 200 OK
    end

    rect rgb(225, 245, 254)
        Note over Conn,UC: STEP 4: Register table in UC catalog
        Conn->>UC: POST /tables<br/>{name: "new_table", catalog: "unity",<br/>schema: "default", table_type: "EXTERNAL",<br/>storage_location: "s3://bucket/new_path",<br/>columns: [...]}

        Note over UC: Authorization (createTable):<br/>① USE_CATALOG on catalog<br/>② USE_SCHEMA + CREATE_TABLE on schema<br/>③ EXTERNAL table + external_location exists<br/>→ OWNER or CREATE_EXTERNAL_TABLE

        UC-->>Conn: 200 OK {table_id}
    end

    rect rgb(255, 249, 230)
        Note over Conn,UC: STEP 5: Load table back from UC
        Conn->>UC: GET /tables/unity.default.new_table
        Note over UC: Auth: USE_CATALOG + USE_SCHEMA<br/>+ (SELECT or MODIFY) on table
        UC-->>Conn: 200 OK {table metadata}
    end

    Conn-->>Spark: Table created successfully
```

## 2. INSERT flow (normal user)

```mermaid
sequenceDiagram
    participant Spark as Spark Driver
    participant Conn as UC Spark Connector
    participant UC as UC Server
    participant STS as AWS STS
    participant S3 as CMC S3

    Spark->>Conn: spark.sql("INSERT INTO unity.default.orders_test<br/>VALUES (1, 101, 'laptop', 999.99)")

    rect rgb(227, 242, 253)
        Note over Conn,UC: STEP 1: Load table metadata
        Conn->>UC: GET /tables/unity.default.orders_test<br/>Authorization: Bearer UC_TOKEN

        Note over UC: AuthDecorator: validate JWT → extract user ID

        Note over UC: Authorization (getTable):<br/>① USE_CATALOG on catalog<br/>② USE_SCHEMA on schema<br/>③ SELECT or MODIFY on table

        UC-->>Conn: 200 OK {table_id, storage_location: "s3://bucket/path"}
    end

    rect rgb(255, 243, 224)
        Note over Conn,UC: STEP 2: Request table credentials for WRITE
        Conn->>UC: POST /temporary-table-credentials<br/>{table_id: "xxx", operation: "READ_WRITE"}<br/>Authorization: Bearer UC_TOKEN

        Note over UC: AuthDecorator: validate JWT → extract user ID

        Note over UC: Authorization (READ_WRITE):<br/>① USE_CATALOG on catalog<br/>② USE_SCHEMA on schema<br/>③ operation=READ_WRITE requires:<br/>  OWNER on table<br/>  OR (SELECT + MODIFY) on table<br/>→ user has SELECT + MODIFY
    end

    rect rgb(232, 245, 233)
        Note over UC: STEP 2b: Credential vending (inside UC Server)

        Note over UC: StorageCredentialVendor.vendCredential():<br/>① tableRepository.getStorageLocationForTable()<br/>→ s3://bucket/path<br/>② ExternalLocationUtils: find external location<br/>   covering s3://bucket/path<br/>③ Found → get CredentialDAO (role_arn, external_id)

        Note over UC: CredentialContext.create():<br/>→ privileges: {SELECT, UPDATE}<br/>→ locations: [s3://bucket/path]<br/>→ credentialDAO: present

        Note over UC: AwsPolicyGenerator.generatePolicy():<br/>→ Actions: s3:GetO*, s3:PutO*, s3:DeleteO*,<br/>  s3:*Multipart*<br/>→ Resource: arn:aws:s3:::bucket/path/*

        UC->>STS: AssumeRole {<br/>  roleArn: customer's data role,<br/>  externalId: UUID,<br/>  policy: scoped IAM policy,<br/>  durationSeconds: 3600<br/>}
        STS-->>UC: {accessKeyId, secretAccessKey,<br/>sessionToken, expiration}

        UC-->>Conn: 200 OK {aws_temp_credentials:<br/>{access_key_id, secret_access_key,<br/>session_token}, expiration_time}
    end

    rect rgb(243, 229, 245)
        Note over Conn,S3: STEP 3: Write data to S3
        Note over Conn: Set Hadoop config with vended creds
        Conn->>S3: PUT parquet data files<br/>+ Delta log commit<br/>using temp creds from STS
        S3-->>Conn: 200 OK
    end

    Conn-->>Spark: Insert complete
```

## 3. SELECT flow (normal user)

```mermaid
sequenceDiagram
    participant Spark as Spark Driver
    participant Conn as UC Spark Connector
    participant UC as UC Server
    participant STS as AWS STS
    participant S3 as CMC S3

    Spark->>Conn: spark.sql("SELECT * FROM unity.default.orders_test")

    rect rgb(227, 242, 253)
        Note over Conn,UC: STEP 1: Load table metadata
        Conn->>UC: GET /tables/unity.default.orders_test<br/>Authorization: Bearer UC_TOKEN

        Note over UC: AuthDecorator: validate JWT → extract user ID

        Note over UC: Authorization (getTable):<br/>① USE_CATALOG on catalog<br/>② USE_SCHEMA on schema<br/>③ SELECT or MODIFY on table

        UC-->>Conn: 200 OK {table_id, storage_location: "s3://bucket/path"}
    end

    rect rgb(255, 243, 224)
        Note over Conn,UC: STEP 2: Request table credentials for READ
        Conn->>UC: POST /temporary-table-credentials<br/>{table_id: "xxx", operation: "READ"}<br/>Authorization: Bearer UC_TOKEN

        Note over UC: AuthDecorator: validate JWT → extract user ID

        Note over UC: Authorization (READ):<br/>① USE_CATALOG on catalog<br/>② USE_SCHEMA on schema<br/>③ operation=READ requires:<br/>  OWNER on table OR SELECT on table<br/>→ user has SELECT
    end

    rect rgb(232, 245, 233)
        Note over UC: STEP 2b: Credential vending (inside UC Server)

        Note over UC: StorageCredentialVendor.vendCredential():<br/>① tableRepository.getStorageLocationForTable()<br/>→ s3://bucket/path<br/>② ExternalLocationUtils: find external location<br/>   covering s3://bucket/path<br/>③ Found → get CredentialDAO (role_arn, external_id)

        Note over UC: CredentialContext.create():<br/>→ privileges: {SELECT}<br/>→ locations: [s3://bucket/path]<br/>→ credentialDAO: present

        Note over UC: AwsPolicyGenerator.generatePolicy():<br/>→ Actions: s3:GetO* (READ ONLY)<br/>→ Resource: arn:aws:s3:::bucket/path/*

        UC->>STS: AssumeRole {<br/>  roleArn: customer's data role,<br/>  externalId: UUID,<br/>  policy: scoped IAM policy (read-only),<br/>  durationSeconds: 3600<br/>}
        STS-->>UC: {accessKeyId, secretAccessKey,<br/>sessionToken, expiration}

        UC-->>Conn: 200 OK {aws_temp_credentials:<br/>{access_key_id, secret_access_key,<br/>session_token}, expiration_time}
    end

    rect rgb(243, 229, 245)
        Note over Conn,S3: STEP 3: Read data from S3
        Note over Conn: Set Hadoop config with vended creds
        Conn->>S3: GET Delta files + parquet data<br/>(read-only, temp creds from STS)
        S3-->>Conn: Return data
    end

    Conn-->>Spark: DataFrame results
```

## 4. Credential Vending: How UC gets temp S3 credentials

This is what happens inside `StorageCredentialVendor.vendCredential()` — the part that was missing from the flows above:

```mermaid
flowchart TD
    A["UC receives credential request<br/>(path or table_id + operation)"] --> B["StorageCredentialVendor.vendCredential(path, privileges)"]

    B --> C["ExternalLocationUtils:<br/>find external location covering this path"]

    C --> D{External location found?}

    D -->|YES| E["Get CredentialDAO from external location<br/>(contains role_arn, external_id)"]
    D -->|NO| F["Fallback: per-bucket config<br/>from server.properties<br/>(s3.bucketPath.*, s3.accessKey.*, etc.)"]

    E --> G["AwsCredentialVendor: use Master Role path<br/>→ StsAwsCredentialGenerator"]
    F --> H{sessionToken in config?}

    H -->|YES| I["StaticAwsCredentialGenerator<br/>→ return pre-configured keys directly<br/>(for testing only)"]
    H -->|NO| J["StsAwsCredentialGenerator<br/>→ use per-bucket role ARN"]

    G --> K["AwsPolicyGenerator.generatePolicy()"]
    J --> K

    K --> L{"Privileges?"}
    L -->|"{SELECT}"| M["Actions: s3:GetO*<br/>(read-only)"]
    L -->|"{SELECT, UPDATE}"| N["Actions: s3:GetO*, s3:PutO*,<br/>s3:DeleteO*, s3:*Multipart*<br/>(read+write)"]

    M --> O["Build IAM policy JSON:<br/>→ ListBucket on arn:aws:s3:::bucket<br/>  (with prefix condition)<br/>→ Actions on arn:aws:s3:::bucket/path/*"]
    N --> O

    O --> P["STS AssumeRole call"]
    P --> Q["UC Master Role assumes<br/>Customer's Data Role<br/>with scoped session policy"]
    Q --> R["AWS STS returns:<br/>accessKeyId + secretAccessKey<br/>+ sessionToken (expires in 1h)"]

    I --> S["Return TemporaryCredentials to Spark"]
    R --> S

    style I fill:#fff3e0,stroke:#e65100
    style R fill:#e8f5e9,stroke:#2e7d32
    style S fill:#e3f2fd,stroke:#1565c0
```

### The STS AssumeRole chain explained

```
UC Server has: Master IAM Role (configured in server.properties)
                    │
                    │  STS AssumeRole
                    │  + roleArn = customer's data role (from CredentialDAO)
                    │  + externalId = UUID (prevents confused deputy)
                    │  + policy = scoped session policy (generated above)
                    │  + duration = 1 hour
                    ▼
              AWS STS Service
                    │
                    │  Returns temporary credentials
                    │  (accessKeyId, secretAccessKey, sessionToken)
                    │  These creds can ONLY do what the scoped policy allows
                    │  on the specific bucket/path
                    ▼
              Spark uses these creds → S3 API calls
```

**Key point**: UC does NOT call S3 directly to get credentials. It calls **AWS STS** (Security Token Service) to assume a role. STS returns temporary credentials that are:
- Scoped to the specific S3 path (not the whole bucket)
- Scoped to specific actions (read-only for SELECT, read+write for INSERT/CREATE)
- Time-limited (1 hour)

## 5. Key Differences: CREATE vs INSERT vs SELECT

```mermaid
flowchart TB
    subgraph CREATE["CREATE TABLE"]
        direction TB
        C1["API: temporary-<b>path</b>-credentials<br/>Operation: PATH_CREATE_TABLE"]
        C2["Auth target: <b>external location</b><br/>(not the table — table doesn't exist yet)"]
        C3["Required: OWNER or<br/>CREATE_EXTERNAL_TABLE<br/>on external location"]
        C4["S3 creds: Read + Write<br/>s3:GetO*, s3:PutO*,<br/>s3:DeleteO*, s3:*Multipart*"]
        C5["Then: POST /tables to register<br/>needs USE_CATALOG + USE_SCHEMA<br/>+ CREATE_TABLE"]
        C1 --> C2 --> C3 --> C4 --> C5
    end

    subgraph INSERT["INSERT / UPDATE"]
        direction TB
        I1["API: temporary-<b>table</b>-credentials<br/>Operation: READ_WRITE"]
        I2["Auth target: <b>table</b><br/>(existing table)"]
        I3["Required: USE_CATALOG<br/>+ USE_SCHEMA<br/>+ SELECT + MODIFY on table"]
        I4["S3 creds: Read + Write<br/>s3:GetO*, s3:PutO*,<br/>s3:DeleteO*, s3:*Multipart*"]
        I1 --> I2 --> I3 --> I4
    end

    subgraph SELECT_OP["SELECT"]
        direction TB
        S1["API: temporary-<b>table</b>-credentials<br/>Operation: READ"]
        S2["Auth target: <b>table</b><br/>(existing table)"]
        S3["Required: USE_CATALOG<br/>+ USE_SCHEMA<br/>+ SELECT on table"]
        S4["S3 creds: Read only<br/>s3:GetO*"]
        S1 --> S2 --> S3 --> S4
    end

    style CREATE fill:#fff3e0,stroke:#e65100
    style INSERT fill:#e8f5e9,stroke:#2e7d32
    style SELECT_OP fill:#e3f2fd,stroke:#1565c0
```

### Summary

| | CREATE TABLE | INSERT | SELECT |
|---|---|---|---|
| **Credential API** | `temporary-path-credentials` | `temporary-table-credentials` | `temporary-table-credentials` |
| **Operation type** | `PATH_CREATE_TABLE` | `READ_WRITE` | `READ` |
| **Auth target** | External location (path-based) | Table (resource-based) | Table (resource-based) |
| **Catalog privilege** | `USE_CATALOG` | `USE_CATALOG` | `USE_CATALOG` |
| **Schema privilege** | `USE_SCHEMA` + `CREATE_TABLE` | `USE_SCHEMA` | `USE_SCHEMA` |
| **Resource privilege** | `CREATE_EXTERNAL_TABLE` on ext. loc. | `SELECT` + `MODIFY` on table | `SELECT` on table |
| **S3 read** | `s3:GetO*` | `s3:GetO*` | `s3:GetO*` |
| **S3 write** | `s3:PutO*`, `s3:DeleteO*`, `s3:*Multipart*` | `s3:PutO*`, `s3:DeleteO*`, `s3:*Multipart*` | -- |
| **External location required?** | **YES** (for normal users) | No | No |
| **STS role assumed** | Customer's data role (from ext. loc. CredentialDAO) | Customer's data role (from ext. loc. CredentialDAO) | Customer's data role (from ext. loc. CredentialDAO) |
