import os
import uuid


def require_env(name: str) -> str:
    value = os.getenv(name)
    if not value:
        raise ValueError(f"Environment variable {name} must be set")
    return value


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
AWS_PROFILE = os.getenv("AWS_PROFILE", "lakesail")
AWS_REGION = os.getenv("AWS_REGION", "us-east-1")
AWS_CREDENTIALS_FILE = os.getenv(
    "AWS_SHARED_CREDENTIALS_FILE",
    os.path.join(os.path.expanduser("~"), "lakesail-credentials"),
)
S3_BUCKET = require_env("S3_BUCKET")

GLUE_CATALOG = "glue"
GLUE_DATABASE = "lakesail_poc"
GLUE_TABLE = "sales"

GLUE_DB="lakesail_poc"

DELTA_PATH = (
    f"s3://{S3_BUCKET}/lakesail-poc/tables/{GLUE_TABLE}"
)

QUALIFIED_TABLE = (
    f"{GLUE_CATALOG}.{GLUE_DATABASE}.{GLUE_TABLE}"
)


# ---------------------------------------------------------------------------
# Export environment variables before starting Sail
# ---------------------------------------------------------------------------
os.environ["AWS_SHARED_CREDENTIALS_FILE"] = AWS_CREDENTIALS_FILE
os.environ["AWS_PROFILE"] = AWS_PROFILE
os.environ["AWS_REGION"] = AWS_REGION
os.environ["AWS_SDK_LOAD_CONFIG"] = "true"

os.environ["SAIL_MODE"] = "local"
os.environ["RUST_LOG"] = "info"

os.environ["SAIL_CATALOG__LIST"] = (
    f'[{{type="glue",name="{GLUE_CATALOG}",region="{AWS_REGION}"}}]'
)

os.environ["SAIL_CATALOG__DEFAULT_CATALOG"] = GLUE_CATALOG
os.environ["SAIL_CATALOG__DEFAULT_DATABASE"] = (
    f'["{GLUE_DATABASE}"]'
)


# Import after setting Sail configuration.
from pysail.spark import SparkConnectServer
from pyspark.sql import SparkSession
from pyspark.sql import functions as F


# Keep the embedded server alive while the SparkSession is being used.
_sail_server = None


def get_spark_session() -> SparkSession:
    """Start an embedded local Sail server and return a SparkSession."""

    global _sail_server

    _sail_server = SparkConnectServer()

    # start() runs the embedded server in the background.
    _sail_server.start()

    host, port = _sail_server.listening_address

    print(f"Sail server listening on {host}:{port}")

    return (
        SparkSession.builder
        .appName("lakesail-glue-delta-local")
        .remote(f"sc://127.0.0.1:{port}")
        .getOrCreate()
    )


def create_table_if_missing(spark: SparkSession) -> None:
    spark.sql(
        f"""
        CREATE TABLE IF NOT EXISTS {QUALIFIED_TABLE} (
            batch_id   STRING,
            product_id BIGINT,
            category   STRING,
            quantity   INT,
            unit_price DOUBLE
        )
        USING DELTA
        LOCATION '{DELTA_PATH}'
        """
    )

    print(f"Table ready: {QUALIFIED_TABLE}")
    print(f"Delta path: {DELTA_PATH}")


def insert_sample_data(spark: SparkSession) -> str:
    # A unique batch ID makes repeated executions easy to identify.
    batch_id = str(uuid.uuid4())

    spark.sql(
        f"""
        INSERT INTO {QUALIFIED_TABLE}
        VALUES
            ('{batch_id}', 101, 'electronics', 2, 2499.00),
            ('{batch_id}', 102, 'electronics', 1, 4999.00),
            ('{batch_id}', 201, 'grocery',     5,  120.00),
            ('{batch_id}', 202, 'grocery',     3,  250.00),
            ('{batch_id}', 301, 'household',   4,  450.00)
        """
    )

    print(f"Inserted batch: {batch_id}")
    return batch_id


def run_dataframe_operations(
    spark: SparkSession,
    batch_id: str,
) -> None:
    # Reading through the Glue catalog name.
    df = spark.table(QUALIFIED_TABLE)

    print("\nAll rows:")
    df.orderBy("product_id").show(truncate=False)

    # Select only data inserted during this execution.
    current_batch = df.filter(F.col("batch_id") == batch_id)

    # Add a computed column.
    enriched = current_batch.withColumn(
        "line_total",
        F.col("quantity") * F.col("unit_price"),
    )

    print("\nCurrent batch with calculated line total:")
    (
        enriched
        .select(
            "product_id",
            "category",
            "quantity",
            "unit_price",
            "line_total",
        )
        .orderBy(F.desc("line_total"))
        .show(truncate=False)
    )

    # Filter operation.
    print("\nRows with line total >= 1000:")
    (
        enriched
        .filter(F.col("line_total") >= 1000)
        .orderBy(F.desc("line_total"))
        .show(truncate=False)
    )

    # Grouping, aggregation and sorting cause actual DataFrame processing.
    category_summary = (
        enriched
        .groupBy("category")
        .agg(
            F.count("*").alias("product_count"),
            F.sum("quantity").alias("total_quantity"),
            F.round(F.sum("line_total"), 2).alias("revenue"),
            F.round(F.avg("unit_price"), 2).alias("average_price"),
        )
        .orderBy(F.desc("revenue"))
    )

    print("\nCategory summary:")
    category_summary.show(truncate=False)

    row_count = current_batch.count()
    assert row_count == 5, f"Expected 5 rows, found {row_count}"

    print(f"\nVerification passed: {row_count} rows")


def main() -> None:
    spark = get_spark_session()

    try:
        spark.sql(
            """
            SELECT
                current_catalog() AS catalog,
                current_database() AS database
            """
        ).show(truncate=False)

        create_table_if_missing(spark)
        batch_id = insert_sample_data(spark)
        run_dataframe_operations(spark, batch_id)

    finally:
        spark.stop()
        # The embedded Sail server is process-owned and shuts down when
        # this Python process exits.


if __name__ == "__main__":
    main()
