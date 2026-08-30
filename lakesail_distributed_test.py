"""Argo-launched LakeSail distributed-mode POC using Glue + Delta on S3.

The Argo workflow pod is both the thin PySpark client and the LakeSail driver.
LakeSail creates separate worker pods on demand in the same Kubernetes namespace.
All catalog references intentionally use the ``database.table`` convention.
"""

import json
import os
import uuid
from datetime import datetime, timezone


def require_env(name: str) -> str:
    value = os.getenv(name)
    if not value:
        raise ValueError(f"Environment variable {name} must be set")
    return value


# ---------------------------------------------------------------------------
# POC settings (each value can be overridden by an Argo environment variable)
# ---------------------------------------------------------------------------
AWS_PROFILE = os.getenv("AWS_PROFILE", "lakesail")
AWS_REGION = os.getenv("AWS_REGION", "us-east-1")
AWS_CREDENTIALS_FILE = os.getenv(
    "AWS_SHARED_CREDENTIALS_FILE",
    "/var/run/lakesail/aws/credentials",
)
S3_BUCKET = require_env("S3_BUCKET")

GLUE_CATALOG = os.getenv("GLUE_CATALOG", "glue")
GLUE_DATABASE = os.getenv("GLUE_DATABASE", "lakesail_poc")

# These are new tables and paths, separate from basic_test.py's sales table.
EVENTS_TABLE = f"{GLUE_DATABASE}.distributed_sales_eventsv2"
SUMMARY_TABLE = f"{GLUE_DATABASE}.distributed_category_summaryv2"
EVENTS_PATH = f"s3://{S3_BUCKET}/lakesail-poc/tables/distributed_sales_eventsv2"
SUMMARY_PATH = (
    f"s3://{S3_BUCKET}/lakesail-poc/tables/distributed_category_summaryv2"
)

ROW_COUNT = int(os.getenv("POC_ROW_COUNT", "100000"))
PARTITION_COUNT = int(os.getenv("POC_PARTITIONS", "4"))
WORKER_INITIAL_COUNT = int(os.getenv("SAIL_WORKER_INITIAL_COUNT", "4"))
WORKER_MAX_COUNT = int(os.getenv("SAIL_WORKER_MAX_COUNT", "4"))
WORKER_TASK_SLOTS = int(os.getenv("SAIL_WORKER_TASK_SLOTS", "1"))

KUBERNETES_NAMESPACE = os.getenv("POD_NAMESPACE", "argo")
DRIVER_POD_NAME = os.getenv("POD_NAME", "")
DRIVER_POD_IP = os.getenv("POD_IP", "")
SAIL_IMAGE = os.getenv(
    "SAIL_IMAGE",
    "lakesail-poc:pysail-0.6.6-rustls-aws-lc-v4",
)
SAIL_SERVICE_ACCOUNT = os.getenv(
    "SAIL_SERVICE_ACCOUNT",
    "lakesail-runner",
)
AWS_SECRET_NAME = os.getenv(
    "AWS_CREDENTIALS_SECRET",
    "lakesail-aws-credentials",
)


def require_argo_environment() -> None:
    """Fail early if this file was not launched as a Kubernetes/Argo pod."""

    missing = [
        name
        for name, value in {
            "POD_NAME": DRIVER_POD_NAME,
            "POD_IP": DRIVER_POD_IP,
            "POD_NAMESPACE": KUBERNETES_NAMESPACE,
        }.items()
        if not value
    ]
    if missing:
        raise RuntimeError(
            "Missing Argo downward-API environment variable(s): "
            + ", ".join(missing)
        )

    if ROW_COUNT <= 0 or PARTITION_COUNT <= 0:
        raise ValueError("POC_ROW_COUNT and POC_PARTITIONS must be positive")


def configure_lakesail() -> None:
    """Export LakeSail, Glue, S3 and worker-pod settings before imports."""

    worker_pod_template = {
        "metadata": {
            "labels": {
                "app.kubernetes.io/name": "lakesail",
                "app.kubernetes.io/component": "worker",
                "lakesail-poc/driver": DRIVER_POD_NAME,
            }
        },
        "spec": {
            "containers": [
                {
                    "name": "worker",
                    "env": [
                        {"name": "AWS_PROFILE", "value": AWS_PROFILE},
                        {"name": "AWS_REGION", "value": AWS_REGION},
                        {"name": "AWS_DEFAULT_REGION", "value": AWS_REGION},
                        {"name": "AWS_SDK_LOAD_CONFIG", "value": "true"},
                        {
                            "name": "AWS_SHARED_CREDENTIALS_FILE",
                            "value": AWS_CREDENTIALS_FILE,
                        },
                    ],
                    "volumeMounts": [
                        {
                            "name": "aws-credentials",
                            "mountPath": "/var/run/lakesail/aws",
                            "readOnly": True,
                        }
                    ],
                    "resources": {
                        "requests": {"cpu": "500m", "memory": "768Mi"},
                        "limits": {"cpu": "2", "memory": "2Gi"},
                    },
                }
            ],
            "volumes": [
                {
                    "name": "aws-credentials",
                    "secret": {"secretName": AWS_SECRET_NAME},
                }
            ],
        },
    }

    settings = {
        "AWS_PROFILE": AWS_PROFILE,
        "AWS_REGION": AWS_REGION,
        "AWS_DEFAULT_REGION": AWS_REGION,
        "AWS_SDK_LOAD_CONFIG": "true",
        "AWS_SHARED_CREDENTIALS_FILE": AWS_CREDENTIALS_FILE,
        # AWS SDK INFO logs can include the access-key identifier. Keep the
        # LakeSail runtime informative while suppressing credential details.
        "RUST_LOG": os.getenv(
            "RUST_LOG",
            "info,aws_config::profile::credentials=warn",
        ),
        "SAIL_MODE": "kubernetes-cluster",
        "SAIL_CLUSTER__DRIVER_LISTEN_HOST": "0.0.0.0",
        "SAIL_CLUSTER__DRIVER_EXTERNAL_HOST": DRIVER_POD_IP,
        "SAIL_CLUSTER__WORKER_INITIAL_COUNT": str(WORKER_INITIAL_COUNT),
        "SAIL_CLUSTER__WORKER_MAX_COUNT": str(WORKER_MAX_COUNT),
        "SAIL_CLUSTER__WORKER_TASK_SLOTS": str(WORKER_TASK_SLOTS),
        "SAIL_EXECUTION__DEFAULT_PARALLELISM": str(PARTITION_COUNT),
        "SAIL_KUBERNETES__NAMESPACE": KUBERNETES_NAMESPACE,
        "SAIL_KUBERNETES__DRIVER_POD_NAME": DRIVER_POD_NAME,
        "SAIL_KUBERNETES__IMAGE": SAIL_IMAGE,
        "SAIL_KUBERNETES__IMAGE_PULL_POLICY": "IfNotPresent",
        "SAIL_KUBERNETES__WORKER_SERVICE_ACCOUNT_NAME": (
            SAIL_SERVICE_ACCOUNT
        ),
        "SAIL_KUBERNETES__WORKER_POD_TEMPLATE": json.dumps(
            worker_pod_template,
            separators=(",", ":"),
        ),
        "SAIL_CATALOG__LIST": (
            f'['
            f'{{type="glue",name="{GLUE_CATALOG}",region="{AWS_REGION}"}}'
            f']'
        ),
        "SAIL_CATALOG__DEFAULT_CATALOG": GLUE_CATALOG,
        "SAIL_CATALOG__DEFAULT_DATABASE": f'["{GLUE_DATABASE}"]',
    }
    os.environ.update(settings)


require_argo_environment()
configure_lakesail()

# LakeSail reads its environment during import/server initialization.
from pysail.spark import SparkConnectServer  # noqa: E402
from pyspark.sql import SparkSession  # noqa: E402
from pyspark.sql import functions as F  # noqa: E402


_sail_server = None


def log(message: str) -> None:
    timestamp = datetime.now(timezone.utc).isoformat(timespec="seconds")
    print(f"[{timestamp}] {message}", flush=True)


def get_spark_session() -> SparkSession:
    """Start the LakeSail driver in this Argo pod and connect locally."""

    global _sail_server

    _sail_server = SparkConnectServer(ip="0.0.0.0", port=50051)
    _sail_server.start()
    host, port = _sail_server.listening_address

    log(
        f"LakeSail driver listening on {host}:{port}; "
        f"mode={os.environ['SAIL_MODE']}; pod={DRIVER_POD_NAME}"
    )

    return (
        SparkSession.builder.appName("lakesail-argo-distributed-poc")
        .remote(f"sc://127.0.0.1:{port}")
        .getOrCreate()
    )


def create_tables_if_missing(spark: SparkSession) -> None:
    log(f"Creating/checking input table {EVENTS_TABLE}")
    spark.sql(
        f"""
        CREATE TABLE IF NOT EXISTS {EVENTS_TABLE} (
            batch_id   STRING,
            event_id   BIGINT,
            category   STRING,
            quantity   INT,
            unit_price DOUBLE
        )
        USING DELTA
        LOCATION '{EVENTS_PATH}'
        """
    )

    log(f"Creating/checking summary table {SUMMARY_TABLE}")
    spark.sql(
        f"""
        CREATE TABLE IF NOT EXISTS {SUMMARY_TABLE} (
            batch_id       STRING,
            category       STRING,
            event_count    BIGINT,
            total_quantity BIGINT,
            revenue        DOUBLE
        )
        USING DELTA
        LOCATION '{SUMMARY_PATH}'
        """
    )

    log(f"Input table registered in Glue: {EVENTS_TABLE}")
    log(f"Summary table registered in Glue: {SUMMARY_TABLE}")


def get_catalog_resolved_location(
    spark: SparkSession,
    table_name: str,
) -> str:
    """Fetch a table location from Spark/LakeSail catalog metadata."""

    metadata_rows = spark.sql(
        f"DESCRIBE TABLE EXTENDED {table_name}"
    ).collect()
    for row in metadata_rows:
        values = ["" if value is None else str(value).strip() for value in row]
        if len(values) >= 2 and values[0].lower() == "location":
            location = values[1]
            if location:
                return location

    raise RuntimeError(
        f"LakeSail did not return a Location for catalog table {table_name}"
    )


def log_catalog_io_location(
    spark: SparkSession,
    operation: str,
    table_name: str,
) -> None:
    """Print the S3 location LakeSail resolved from a db.table identifier."""

    resolved_location = get_catalog_resolved_location(spark, table_name)
    log(
        f"LakeSail catalog-resolved {operation} location: "
        f"table={table_name}, location={resolved_location}"
    )


def verify_catalog_resolution(spark: SparkSession) -> None:
    """Use db.table only to resolve each storage location from Glue."""

    for table_name in (EVENTS_TABLE, SUMMARY_TABLE):
        resolved_location = get_catalog_resolved_location(spark, table_name)
        log(
            f"Glue metadata resolution succeeded: table={table_name}, "
            f"location={resolved_location}"
        )

    log(
        "The transformation source read will use the resolved S3 location "
        "directly; its db.table identifier will not be passed to "
        "DataFrameReader or transformation SQL"
    )


def generate_distributed_batch(spark: SparkSession) -> str:
    """Generate partitioned data and append it to the Delta input table."""

    batch_id = str(uuid.uuid4())
    rows_per_partition = (ROW_COUNT + PARTITION_COUNT - 1) // PARTITION_COUNT
    log(
        f"Starting distributed INSERT for batch {batch_id}: "
        f"rows={ROW_COUNT:,}, source_partitions={PARTITION_COUNT}, "
        f"approximately_rows_per_partition={rows_per_partition:,}"
    )
    log_catalog_io_location(spark, "WRITE", EVENTS_TABLE)
    spark.sql(
        f"""
        INSERT INTO {EVENTS_TABLE}
        SELECT
            '{batch_id}' AS batch_id,
            id AS event_id,
            CASE pmod(id, 4)
                WHEN 0 THEN 'electronics'
                WHEN 1 THEN 'grocery'
                WHEN 2 THEN 'household'
                ELSE 'farm'
            END AS category,
            CAST(1 + pmod(id, 10) AS INT) AS quantity,
            CAST(50 + pmod(id * 37, 10000) / 10.0 AS DOUBLE) AS unit_price
        FROM range(0, {ROW_COUNT}, 1, {PARTITION_COUNT})
        """
    )
    log(
        f"Inserted batch {batch_id}: {ROW_COUNT:,} rows across "
        f"{PARTITION_COUNT} source partitions"
    )
    return batch_id


def transform_batch_with_sql(
    spark: SparkSession,
    batch_id: str,
):
    """Read Delta by resolved path, transform with SQL, and inspect schemas."""

    resolved_location = get_catalog_resolved_location(spark, EVENTS_TABLE)
    log(
        f"Reading Delta source directly from Glue-resolved S3 location: "
        f"{resolved_location}"
    )
    source = spark.read.format("delta").load(resolved_location)

    source_schema_fields = source.schema.fields
    log(
        "Python reached direct-path source.schema.fields: "
        + ", ".join(
            f"{field.name}:{field.dataType.simpleString()}"
            for field in source_schema_fields
        )
    )
    required_source_fields = {
        "batch_id",
        "event_id",
        "category",
        "quantity",
        "unit_price",
    }
    source_field_names = {field.name for field in source_schema_fields}
    missing_source_fields = required_source_fields - source_field_names
    if missing_source_fields:
        raise AssertionError(
            "Direct Delta source schema is missing fields: "
            + ", ".join(sorted(missing_source_fields))
        )

    source_view = "resolved_delta_events_source"
    source.createOrReplaceTempView(source_view)
    log(
        f"Registered direct-path Delta DataFrame as temporary view "
        f"{source_view}; running spark.sql transformation"
    )
    transformed = spark.sql(
        f"""
        SELECT
            batch_id,
            event_id,
            category,
            quantity,
            unit_price,
            CAST(CAST(quantity AS DOUBLE) * unit_price AS DOUBLE)
                AS line_total,
            CASE
                WHEN quantity >= 6 THEN 'bulk'
                ELSE 'standard'
            END AS quantity_band
        FROM {source_view}
        WHERE batch_id = '{batch_id}'
        """
    )

    # Spark Connect sends the analyzed StructType back to this Python client.
    # Accessing .fields proves the schema is available as native Python objects.
    schema_fields = transformed.schema.fields
    field_types = {
        field.name: field.dataType.simpleString() for field in schema_fields
    }
    log(
        "Python reached transformed.schema.fields: "
        + ", ".join(
            f"{field.name}:{field.dataType.simpleString()}"
            for field in schema_fields
        )
    )

    expected_fields = {
        "line_total": "double",
        "quantity_band": "string",
    }
    for field_name, expected_type in expected_fields.items():
        actual_type = field_types.get(field_name)
        if actual_type != expected_type:
            raise AssertionError(
                f"Expected SQL-derived field {field_name}:{expected_type}, "
                f"found {actual_type!r}"
            )

    log(
        "SQL transformation schema verification passed: "
        "line_total:double, quantity_band:string"
    )
    return transformed


def aggregate_and_write_summary(
    spark: SparkSession,
    batch_id: str,
) -> None:
    """Run distributed filtering, projection, shuffle aggregation and write."""

    transformed = transform_batch_with_sql(spark, batch_id)

    summary = (
        transformed.repartition(PARTITION_COUNT, "category")
        .groupBy("batch_id", "category")
        .agg(
            F.count("*").alias("event_count"),
            F.sum("quantity").cast("long").alias("total_quantity"),
            F.round(F.sum("line_total"), 2).alias("revenue"),
        )
        .orderBy(F.desc("revenue"))
    )

    log(
        f"Starting repartition + groupBy shuffle using "
        f"{PARTITION_COUNT} partitions"
    )
    log("Materializing distributed aggregation result")
    summary.show(truncate=False)

    log_catalog_io_location(spark, "WRITE", SUMMARY_TABLE)
    log(f"Appending aggregation result to {SUMMARY_TABLE}")
    summary.write.mode("append").saveAsTable(SUMMARY_TABLE)

    log("Counting the generated input batch for verification")
    actual_count = transformed.count()
    if actual_count != ROW_COUNT:
        raise AssertionError(
            f"Expected {ROW_COUNT} rows for {batch_id}, found {actual_count}"
        )

    summary_location = get_catalog_resolved_location(spark, SUMMARY_TABLE)
    log(
        f"Reading saved summary directly from Glue-resolved S3 location: "
        f"{summary_location}"
    )
    saved_summary = (
        spark.read.format("delta").load(summary_location)
        .filter(F.col("batch_id") == batch_id)
        .orderBy(F.desc("revenue"))
    )
    saved_categories = saved_summary.count()
    if saved_categories != 4:
        raise AssertionError(
            f"Expected 4 summary rows, found {saved_categories}"
        )

    log("Summary read back from Glue + Delta")
    saved_summary.show(truncate=False)
    log(
        f"Verification passed: {actual_count:,} input rows and "
        f"{saved_categories} summary rows"
    )


def main() -> None:
    log(
        f"POC configuration: rows={ROW_COUNT:,}, partitions={PARTITION_COUNT}, "
        f"workers={WORKER_INITIAL_COUNT}..{WORKER_MAX_COUNT}, "
        f"task_slots_per_worker={WORKER_TASK_SLOTS}"
    )
    spark = get_spark_session()
    try:
        log("Checking the active Glue catalog and database")
        spark.sql(
            """
            SELECT
                current_catalog() AS catalog,
                current_database() AS database
            """
        ).show(truncate=False)

        create_tables_if_missing(spark)
        verify_catalog_resolution(spark)
        batch_id = generate_distributed_batch(spark)
        aggregate_and_write_summary(spark, batch_id)
    finally:
        log("Stopping Spark session and LakeSail driver")
        spark.stop()


if __name__ == "__main__":
    main()
