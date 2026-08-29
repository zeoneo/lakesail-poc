export AWS_REGION=us-east-1
export S3_BUCKET="${S3_BUCKET:?Set S3_BUCKET before running setup.sh}"
export GLUE_DB=lakesail_poc
export SAIL_VERSION=0.7.1

# aws glue create-database \
#   --region "$AWS_REGION" \
#   --database-input "{
#     \"Name\": \"$GLUE_DB\",
#     \"LocationUri\": \"s3://$S3_BUCKET/lakesail-poc/warehouse/$GLUE_DB.db/\"
#   }"

aws glue get-database \
  --region "$AWS_REGION" \
  --name "$GLUE_DB"
