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
 * <p>Calls MinIO's STS AssumeRole endpoint with a scoped session policy. MinIO's STS is
 * AWS-compatible, so we reuse the AWS SDK StsClient with an endpoint override pointing to the MinIO
 * gateway.
 *
 * <p>Key differences from {@link AwsCredentialGenerator.StsAwsCredentialGenerator}:
 *
 * <ul>
 *   <li>STS endpoint = MinIO gateway endpoint (not AWS STS)
 *   <li>roleArn is a dummy value (MinIO ignores it, identifies user from Signature V4)
 *   <li>No externalId (not applicable for MinIO)
 *   <li>Credentials are the S3 root credentials configured for the bucket
 * </ul>
 */
public class MinioStsCredentialGenerator implements AwsCredentialGenerator {

  private final StsClient stsClient;

  public MinioStsCredentialGenerator(S3StorageConfig config) {
    Region region =
        (config.getRegion() != null && !config.getRegion().isEmpty())
            ? Region.of(config.getRegion())
            : Region.US_EAST_1;

    this.stsClient =
        StsClient.builder()
            .region(region)
            .credentialsProvider(
                StaticCredentialsProvider.create(
                    AwsBasicCredentials.create(config.getAccessKey(), config.getSecretKey())))
            .endpointOverride(URI.create(config.getEndpoint()))
            .build();
  }

  @Override
  public Credentials generate(CredentialContext ctx) {
    String policy = AwsPolicyGenerator.generatePolicy(ctx.getPrivileges(), ctx.getLocations());

    AssumeRoleRequest request =
        AssumeRoleRequest.builder()
            .roleArn("arn:aws:iam::minio:role/minio-gateway")
            .policy(policy)
            .roleSessionName("uc-" + UUID.randomUUID())
            .durationSeconds(3600)
            .build();

    return stsClient.assumeRole(request).credentials();
  }
}
