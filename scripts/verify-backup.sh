#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <official-export-directory>"
    exit 1
fi

EXPORT_DIR="$(realpath "$1")"
INFO_FILE="${EXPORT_DIR}/backup-info.txt"
TEST_ROOT=$(mktemp -d /opt/paperless-restore-test.XXXXXX)
TEST_DB="paperless_restore_test_$$"
REDIS_DB=15
UV=/usr/local/bin/uv

if [[ ! -s "${EXPORT_DIR}/manifest.json" || ! -s "$INFO_FILE" ]]; then
    echo "Error: export is missing manifest.json or backup-info.txt"
    exit 1
fi

cleanup() {
    redis-cli -n "$REDIS_DB" FLUSHDB >/dev/null 2>&1 || true
    sudo -u postgres dropdb --if-exists --force "$TEST_DB" >/dev/null 2>&1 || true
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

mkdir -p \
    "$TEST_ROOT/consume" \
    "$TEST_ROOT/data/index" \
    "$TEST_ROOT/media" \
    "$TEST_ROOT/trash"

sudo -u postgres createdb --owner=paperless "$TEST_DB"
redis-cli -n "$REDIS_DB" FLUSHDB >/dev/null

export PAPERLESS_CONFIGURATION_PATH=/opt/paperless/paperless.conf
export DJANGO_SETTINGS_MODULE=paperless.settings
export PAPERLESS_DBNAME="$TEST_DB"
export PAPERLESS_REDIS="redis://localhost:6379/${REDIS_DB}"
export PAPERLESS_REDIS_PREFIX="restore-test-${TEST_DB}:"
export PAPERLESS_CONSUMPTION_DIR="$TEST_ROOT/consume"
export PAPERLESS_DATA_DIR="$TEST_ROOT/data"
export PAPERLESS_MEDIA_ROOT="$TEST_ROOT/media"
export PAPERLESS_EMPTY_TRASH_DIR="$TEST_ROOT/trash"

cd /opt/paperless/src
"$UV" run manage.py migrate --noinput --verbosity 0
"$UV" run manage.py document_importer "$EXPORT_DIR" --no-progress-bar
"$UV" run manage.py document_index reindex --if-needed
"$UV" run manage.py document_create_classifier
"$UV" run manage.py check

read -r restored_active restored_total restored_tags restored_types < <(
    "$UV" run python - <<'PY'
import django

django.setup()

from documents.models import Document, DocumentType, Tag

print(
    Document.objects.count(),
    Document.global_objects.count(),
    Tag.objects.count(),
    DocumentType.objects.count(),
)
PY
)

expected_active=$(sed -n 's/^active_documents=//p' "$INFO_FILE")
expected_total=$(sed -n 's/^total_documents=//p' "$INFO_FILE")
expected_tags=$(sed -n 's/^tags=//p' "$INFO_FILE")
expected_types=$(sed -n 's/^document_types=//p' "$INFO_FILE")

[[ "$restored_active" == "$expected_active" ]]
[[ "$restored_total" == "$expected_total" ]]
[[ "$restored_tags" == "$expected_tags" ]]
[[ "$restored_types" == "$expected_types" ]]
test -s "$TEST_ROOT/data/classification_model.pickle"

"$UV" run manage.py document_sanity_checker

printf 'Restore verification passed: %s active, %s total, %s tags, %s document types.\n' \
    "$restored_active" "$restored_total" "$restored_tags" "$restored_types"
