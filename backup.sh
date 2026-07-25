#!/bin/bash

set -o errexit -o nounset -o pipefail

export AWS_PAGER=""

# ── Sentry Cron Monitor check-ins (optional) ───────────────────────────────────────────────
# Set SENTRY_CRONS_URL to the monitor's check-in URL, e.g.
#   https://o<ORG_ID>.ingest.sentry.io/api/<PROJECT_ID>/cron/<MONITOR_SLUG>/<SENTRY_KEY>/
# Sentry then alerts on a FAILED run (status=error) AND on a MISSED run (no check-in within the
# monitor's schedule + margin) — the missed-run case is what catches a silently non-running
# backup, which a plain exit-code notification cannot see.
# Best-effort by design: a check-in never fails or delays the backup itself; an unset URL is a
# no-op, so the backup keeps working with or without alerting configured.
sentry_checkin() {
    local status="$1"
    local url="${SENTRY_CRONS_URL:-}"
    [ -n "$url" ] || return 0
    curl -sf -m 10 -o /dev/null "${url}?status=${status}" || true
}

# errexit fires on the first failed command, so any real failure exits non-zero. main() sends
# 'ok' on success and returns 0, so this EXIT trap only reports 'error' on an actual failure.
report_failure_on_error() {
    local rc=$?
    [ "$rc" -eq 0 ] || sentry_checkin error
}
trap report_failure_on_error EXIT

s3() {
    aws s3 --region "$AWS_REGION" "$@"
}

s3api() {
    aws s3api "$1" --region "$AWS_REGION" --bucket "$S3_BUCKET_NAME" "${@:2}"
}

bucket_exists() {
    s3 ls "$S3_BUCKET_NAME" &> /dev/null
}

create_bucket() {
    echo "Bucket $S3_BUCKET_NAME doesn't exist. Creating it now..."

    # create bucket
    # us-east-1 rejects a LocationConstraint; every other region requires it
    if [ "$AWS_REGION" = "us-east-1" ]; then
        s3api create-bucket \
            --object-ownership BucketOwnerEnforced
    else
        s3api create-bucket \
            --create-bucket-configuration LocationConstraint="$AWS_REGION" \
            --object-ownership BucketOwnerEnforced
    fi

    # block public access
    s3api put-public-access-block \
        --public-access-block-configuration \
        "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

    # enable versioning for objects in the bucket
    s3api put-bucket-versioning --versioning-configuration Status=Enabled

    # encrypt objects in the bucket
    s3api put-bucket-encryption \
      --server-side-encryption-configuration \
      '{"Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]}'
}

ensure_bucket_exists() {
    if bucket_exists; then
        return
    fi
    create_bucket
}

pg_dump_database() {
    pg_dump  --no-owner --no-privileges --clean --if-exists --quote-all-identifiers "$DATABASE_URL"
}

upload_to_bucket() {
    # if the zipped backup file is larger than 50 GB add the --expected-size option
    # see https://docs.aws.amazon.com/cli/latest/reference/s3/cp.html
    s3 cp - "s3://$S3_BUCKET_NAME/$(date +%Y/%m/%d/backup-%H-%M-%S.sql.gz)"
}

main() {
    sentry_checkin in_progress
    ensure_bucket_exists
    echo "Taking backup and uploading it to S3..."
    pg_dump_database | gzip | upload_to_bucket
    echo "Done."
    sentry_checkin ok
}

main
