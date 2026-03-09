import os
from pyspark.sql import SparkSession

CATALOG_NAME = "unity"
UC_ENDPOINT = "http://localhost:8080"
UC_TOKEN = ""

spark = (
    SparkSession.builder
    .appName("UC-CMC-S3-Test")
    .config(
        "spark.jars.packages",
        ",".join([
            "io.unitycatalog:unitycatalog-spark_2.13:0.4.0",
            "io.delta:delta-spark_2.13:4.0.1",
            "org.apache.hadoop:hadoop-aws:3.4.0",
        ])
    )
    .config("spark.sql.extensions", "io.delta.sql.DeltaSparkSessionExtension")
    .config("spark.sql.catalog.spark_catalog", "org.apache.spark.sql.delta.catalog.DeltaCatalog")
    .config(f"spark.sql.catalog.{CATALOG_NAME}", "io.unitycatalog.spark.UCSingleCatalog")
    .config(f"spark.sql.catalog.{CATALOG_NAME}.uri", UC_ENDPOINT)
    .config(f"spark.sql.catalog.{CATALOG_NAME}.token", UC_TOKEN)
    .config("spark.sql.defaultCatalog", CATALOG_NAME)
    .config("spark.hadoop.fs.s3.impl", "org.apache.hadoop.fs.s3a.S3AFileSystem")
    .config("spark.hadoop.fs.s3a.endpoint", "https://s3.hcm-3.cloud.cmctelecom.vn")
    .master("local[*]")
    .getOrCreate()
)

print("=== Spark session created ===")

# Write test data
print("=== Writing test data to CMC S3 ===")

print(f"=== UC_TOKEN starts with: {UC_TOKEN[:20]}..." if len(UC_TOKEN) > 20 else f"=== UC_TOKEN: {UC_TOKEN}")


spark.sql("""
    CREATE TABLE IF NOT EXISTS unity.default.orders_test1 (
        order_id INT,
        user_id INT,
        product STRING,
        amount DOUBLE
    )
    USING delta
    LOCATION 's3://dataplatform-dev-hn1/external/orders_test1'
""")

# data = [(1, 101, "test123", 333.33)]
# df = spark.createDataFrame(data, ["order_id", "user_id", "product", "amount"])
# df.write.format("delta").mode("overwrite").save("s3://dataplatform-dev-hn1/external/orders_test1")

spark.sql("INSERT INTO unity.default.orders_test1 VALUES (1, 101, 'laptop', 999.99), (2, 102, 'mouse', 29.99)")

print("=== Write complete. Reading back ===")

result = spark.sql("SELECT * FROM unity.default.orders_test1")
result.show()

print("=== Test passed! ===")
spark.stop()
