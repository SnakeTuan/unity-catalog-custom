# `POST /auth/impersonate` — Admin User Impersonation

**Status: Implemented and tested**

## Problem

When `server.authorization=enable`, every API call requires a valid UC access token.
Getting a UC token currently requires either:

1. A Keycloak token exchange (needs user interaction or stored passwords)
2. The CLI `auth login` (needs a browser)
3. The service token from `etc/conf/token.txt` (admin-level, no per-user identity)

For automation scenarios like **Airflow cron jobs running Spark**, there is no way to
get a **user-specific** UC token without a password or browser flow.

## Solution

New endpoint that allows an **admin** (holder of a SERVICE token) to obtain a
UC ACCESS token for any existing, enabled user — by email only.

```
POST /api/1.0/unity-control/auth/impersonate
Authorization: Bearer <SERVICE-token>
Content-Type: application/x-www-form-urlencoded

user_email=etl-user@company.com
```

Response (same format as `/auth/tokens`):
```json
{
  "access_token": "<UC access token for etl-user>",
  "issued_token_type": "urn:ietf:params:oauth:token-type:access_token",
  "token_type": "Bearer"
}
```

## Usage Example (Airflow)

```bash
# Step 1: Read the admin service token (generated at server startup)
SERVICE_TOKEN=$(cat etc/conf/token.txt)

# Step 2: Impersonate a user
UC_TOKEN=$(curl -s -X POST http://localhost:8080/api/1.0/unity-control/auth/impersonate \
  -H "Authorization: Bearer $SERVICE_TOKEN" \
  -d "user_email=etl-user@company.com" | jq -r .access_token)

# Step 3: Pass to Spark
spark-submit ... --conf spark.sql.catalog.unity.token=$UC_TOKEN ...
```

## Security Flow

```
Caller sends: Authorization: Bearer <SERVICE-token>
        |
        v
  AuthDecorator (existing, unchanged)
    - Validates JWT signature, checks issuer="internal"
    - Looks up user ("admin") in DB
    - Stores DecodedJWT in request context
        |
        v
  impersonate() method
    1. Read caller's DecodedJWT from context
    2. Check claim "type" == "SERVICE"    <-- only admin can impersonate
    3. Validate user_email is non-empty
    4. Look up target user in DB, check state == ENABLED
    5. Mint ACCESS token with sub = target_email
    6. Return same response format as /tokens endpoint
```

## Verify Token Identity

Use the SCIM "Me" endpoint to confirm which user a token belongs to:

```bash
curl -s http://localhost:8080/api/1.0/unity-control/scim2/Me \
  -H "Authorization: Bearer $UC_TOKEN" | jq .
```

## Files Changed

### 1. `SecurityContext.java` (modified)

**Path:** `server/src/main/java/io/unitycatalog/server/security/SecurityContext.java`

Added `createAccessTokenForEmail(String email)` method. The existing
`createAccessToken(DecodedJWT)` is **unchanged**.

```java
// New method (added between existing createAccessToken and createServiceToken)
public String createAccessTokenForEmail(String email) {
    return JWT.create()
        .withSubject(serviceName)
        .withIssuer(localIssuer)
        .withIssuedAt(new Date())
        .withKeyId(keyId)
        .withJWTId(UUID.randomUUID().toString())
        .withClaim(JwtClaim.TOKEN_TYPE.key(), JwtTokenType.ACCESS.name())
        .withClaim(JwtClaim.SUBJECT.key(), email)
        .sign(algorithm);
}
```

### 2. `AuthService.java` (modified)

**Path:** `server/src/main/java/io/unitycatalog/server/service/AuthService.java`

Added `impersonate()` endpoint method using `@Param("user_email")` (form parameter,
no new model class needed). All existing methods are **unchanged**.

New imports added:
- `io.unitycatalog.server.exception.AuthorizationException`
- `io.unitycatalog.server.security.JwtTokenType`

### Files NOT changed

| File | Why no changes needed |
|---|---|
| `UnityCatalogServer.java` | `/auth/impersonate` is auto-protected by AuthDecorator (only `/auth/tokens` is excluded) |
| `AuthDecorator.java` | Already validates JWT and stores DecodedJWT in context |
| `JwtClaim.java` | Already defines TOKEN_TYPE and SUBJECT claims |
| `JwtTokenType.java` | Already defines SERVICE and ACCESS enum values |

## Test Results

All tests passed:

| Test | Command | Expected | Result |
|---|---|---|---|
| Impersonate valid user | `curl -X POST .../impersonate -H "Authorization: Bearer $SERVICE_TOKEN" -d "user_email=snaketuan@gmail.com"` | 200 + access_token | Pass |
| Reject ACCESS token | `curl -X POST .../impersonate -H "Authorization: Bearer $UC_TOKEN" -d "user_email=..."` | 403 "Only SERVICE token holders can impersonate users." | Pass |
| Reject non-existent user | `curl -X POST .../impersonate -H "Authorization: Bearer $SERVICE_TOKEN" -d "user_email=nobody@example.com"` | 404 "User not found" | Pass |
| Reject no auth header | `curl -X POST .../impersonate -d "user_email=..."` | 401 "No authorization found." | Pass |
| Reject missing email | `curl -X POST .../impersonate -H "Authorization: Bearer $SERVICE_TOKEN"` | 400 "user_email is required." | Pass |
| Verify identity via /scim2/Me | `curl .../scim2/Me -H "Authorization: Bearer $UC_TOKEN"` | Returns impersonated user's profile | Pass |
