# LakeSail POC Setup

This project no longer keeps environment-specific values in source.
To run it successfully, you must provide your own bucket name and AWS
credentials path at runtime.

## What Is Required

The following values are required or expected:

- `S3_BUCKET` is required. Set it to an existing S3 bucket you control.
- `AWS_SHARED_CREDENTIALS_FILE` is optional if your credentials are stored at
  `${HOME}/lakesail-credentials`. Set it if your credentials file lives
  somewhere else.
- `AWS_PROFILE` defaults to `lakesail`.
- `AWS_REGION` defaults to `us-east-1`.

## Quick Setup

1. Create or export an AWS credentials file.

```bash
SOURCE_AWS_PROFILE="default"
CREDENTIALS_FILE="${HOME}/lakesail-credentials"
TEMP_CREDENTIALS="$(mktemp)"

aws configure export-credentials \
  --profile "$SOURCE_AWS_PROFILE" \
  --format process |
jq -r '
  "[lakesail]",
  "aws_access_key_id = \(.AccessKeyId)",
  "aws_secret_access_key = \(.SecretAccessKey)",
  "aws_session_token = \(.SessionToken)"
' > "$TEMP_CREDENTIALS"

install -m 600 "$TEMP_CREDENTIALS" "$CREDENTIALS_FILE"
rm -f "$TEMP_CREDENTIALS"
```

2. Export the runtime variables.

```bash
export S3_BUCKET="your-existing-bucket"
export AWS_SHARED_CREDENTIALS_FILE="${HOME}/lakesail-credentials"
export AWS_PROFILE="lakesail"
export AWS_REGION="us-east-1"
```

3. Optionally source the example env file and edit it first.

```bash
cp env.example.sh env.local.sh
# edit env.local.sh with your bucket and credentials path
source env.local.sh
```

## Local Script

`src/basic_test.py` expects `S3_BUCKET` to already be exported. It uses
`${HOME}/lakesail-credentials` by default unless you override
`AWS_SHARED_CREDENTIALS_FILE`.

Example:

```bash
export S3_BUCKET="your-existing-bucket"
python3 src/basic_test.py
```

## Distributed Script

`run_lakesail_distributed_poc.sh` now fails early if `S3_BUCKET` is missing.
That is intentional so the script does not silently run against a hardcoded
bucket.

Example:

```bash
export S3_BUCKET="your-existing-bucket"
./run_lakesail_distributed_poc.sh run
```

You can also pass values inline:

```bash
S3_BUCKET="your-existing-bucket" \
AWS_CREDENTIALS_FILE="${HOME}/lakesail-credentials" \
./run_lakesail_distributed_poc.sh run
```

## Glue Database Check

`setup.sh` also expects `S3_BUCKET` to be set before running:

```bash
export S3_BUCKET="your-existing-bucket"
./setup.sh
```

## Why This Changed

The bucket name and the old `/home/zeo/...` paths were machine-specific.
Keeping them out of source makes the repo portable and avoids accidentally
shipping personal or environment-bound values.
