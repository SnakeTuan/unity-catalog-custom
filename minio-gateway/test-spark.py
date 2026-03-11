"""
Test UC + MinIO Gateway: create external & managed tables, insert data.

Uses UC Spark catalog (SQL) — UC handles credential vending automatically.
Idempotent — safe to run multiple times.

Usage:
    python test-spark.py
"""

import requests
import sys

from pyspark.sql import SparkSession

UC_HOST = "http://localhost:8080"
UC_TOKEN = "eyJraWQiOiJjMTEzZDRkNzQ4Mjk4N2Y4NmNiZTc2ODEwZmNiZTE5OTcxOGRhY2VkYzYzODAxMWZhMjJiNWFmY2M1Y2U1M2U5IiwiYWxnIjoiUlM1MTIiLCJ0eXAiOiJKV1QifQ.eyJzdWIiOiJzbmFrZXR1YW5AZ21haWwuY29tIiwiaXNzIjoiaW50ZXJuYWwiLCJpYXQiOjE3NzMwNDM3MjQsImp0aSI6IjVhZTIxYjRhLTljYjMtNGU0MS05Y2VjLTI1MDgzNDBkNDkyYyIsInR5cGUiOiJBQ0NFU1MifQ.Fd3jLhgp9fQuunQ0Ao_Hqc1I49EnT8u7QiUV0eg_CXEKs4V2PMs-z0sqLJr_IrG5QWsaiBH6GtS5yz11HA1pR8PxGC4A0zPgGQBXNhNw8kB3_YCQIPcYMSt3wO0-Ld-CV7x7mVSlE1cjpml64i2rQg4oLaUq2OpOrJ97dX2YMHgYH-WrXp01v6NdmXsM_aWvhdiUuRDnhbfZZAVLhJQh-d-BQh-bACsMUbxjg1W1wEklPSiqcwy46fFWzQoxMBdlgayRfsul0N7W1g97VW0UT-BNZAW7mdR-qvYj-tyUE_RS5k7TZBRNcVHgrj6OeU40oiyQiM3YCmTWKxoCCLwTVA"
MINIO_ENDPOINT = "http://localhost:9000"
BUCKET = "dataplatform-dev-hn1"

CATALOG = "localtest_1"
SCHEMA = "default"

# CREDENTIAL_NAME = "minio-gateway-cred"
# EXTERNAL_LOCATION_NAME = "minio-gateway-location"
# CREDENTIAL_ROLE_ARN = "arn:aws:iam::minio:role/minio-gateway"
# EXTERNAL_LOCATION_URL = f"s3://{BUCKET}"

if __name__ == "__main__":
    if UC_TOKEN == "YOUR_UC_TOKEN_HERE":
        print("ERROR: Set UC_TOKEN in the script first!")
        sys.exit(1)

    # Step 2: Create Spark session with UC catalog
    print("  Starting Spark with UC catalog")

    spark = (
        SparkSession.builder
        .appName("UC-MinIO-Gateway-Test")
        .config(
            "spark.jars.packages",
            ",".join([
                "io.unitycatalog:unitycatalog-spark_2.13:0.4.0",
                "io.delta:delta-spark_2.13:4.0.1",
                "org.apache.hadoop:hadoop-aws:3.4.0",
            ])
        )
        .config("spark.sql.extensions",
                "io.delta.sql.DeltaSparkSessionExtension")
        .config("spark.sql.catalog.spark_catalog",
                "org.apache.spark.sql.delta.catalog.DeltaCatalog")
        .config(f"spark.sql.catalog.{CATALOG}",
                "io.unitycatalog.spark.UCSingleCatalog")
        .config(f"spark.sql.catalog.{CATALOG}.uri", UC_HOST)
        .config(f"spark.sql.catalog.{CATALOG}.token", UC_TOKEN)
        .config("spark.sql.defaultCatalog", CATALOG)
        .config("spark.hadoop.fs.s3.impl",
                "org.apache.hadoop.fs.s3a.S3AFileSystem")
        .config("spark.hadoop.fs.s3a.endpoint", MINIO_ENDPOINT)
        .config("spark.hadoop.fs.s3a.path.style.access", "true")
        .master("local[*]")
        .getOrCreate()
    )

    print("Spark session created")

    try:
        ext_location = (
            f"s3://{BUCKET}/tuantm/localtest_1/external/{CATALOG}/{SCHEMA}/orders"
        )

        spark.sql(f"""
            CREATE TABLE IF NOT EXISTS
                {CATALOG}.{SCHEMA}.orders (
                order_id INT,
                customer_id INT,
                product STRING,
                amount DOUBLE,
                quantity INT
            )
            USING delta
            LOCATION '{ext_location}'
        """)
        print("External table created")

        spark.sql(f"""
            INSERT INTO {CATALOG}.{SCHEMA}.orders VALUES
                (1, 101, 'Laptop', 1299.99, 1),
                (2, 102, 'Keyboard', 79.99, 2),
                (3, 103, 'Monitor', 449.99, 1),
                (4, 101, 'Mouse', 29.99, 3),
                (5, 104, 'Headphones', 199.99, 1),
                (6, 102, 'USB Cable', 12.99, 5),
                (7, 105, 'Webcam', 89.99, 1),
                (8, 103, 'Desk Lamp', 34.99, 2)
        """)
        print("Inserted order data")

        print("\nReading orders:")
        spark.sql(
            f"SELECT * FROM {CATALOG}.{SCHEMA}.orders"
        ).show()

        # -----------------------------------------------
        # Test 2: MANAGED table
        # -----------------------------------------------
        print("  Test 2: MANAGED table (customers)")

        spark.sql(f"""
            CREATE TABLE IF NOT EXISTS
                {CATALOG}.{SCHEMA}.customers (
                customer_id INT,
                name STRING,
                email STRING,
                city STRING
            )
            USING delta
            TBLPROPERTIES ('delta.feature.catalogManaged' = 'supported');
        """)
        print("Managed table created")

        spark.sql(f"""
            INSERT INTO {CATALOG}.{SCHEMA}.customers VALUES
                (101, 'Alice Nguyen', 'alice@example.com', 'Hanoi'),
                (102, 'Bob Tran', 'bob@example.com', 'HCMC'),
                (103, 'Charlie Le', 'charlie@example.com', 'Da Nang'),
                (104, 'Diana Pham', 'diana@example.com', 'Hanoi'),
                (105, 'Eve Vo', 'eve@example.com', 'Can Tho')
        """)
        print("Inserted customer data")

        print("\nReading customers:")
        spark.sql(
            f"SELECT * FROM {CATALOG}.{SCHEMA}.customers"
        ).show()

        # -----------------------------------------------
        # Test 3: Join across tables
        # -----------------------------------------------
        print("=" * 50)
        print("  Test 3: Join orders + customers")
        print("=" * 50)

        spark.sql(f"""
            SELECT o.order_id, c.name, o.product, o.amount
            FROM {CATALOG}.{SCHEMA}.orders o
            JOIN {CATALOG}.{SCHEMA}.customers c
                ON o.customer_id = c.customer_id
            ORDER BY o.order_id
        """).show()

        print("  ALL TESTS PASSED!")

    finally:
        spark.stop()
