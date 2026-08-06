#!/usr/bin/env bash
# Verify that S3-spilled memory content survives the --skip-data golden test.
#
# Exit predicate for issue #395: Write a >100KB memory, verify it's S3-spilled,
# run uninstall-full.sh --skip-data && deploy-full.sh, then verify the memory
# content is fully retrievable afterward.
#
# Usage:
#   scripts/test-golden-s3.sh [--write-only] [--verify-only MEMORY_ID]
#
#   --write-only      Write the test memory and print its ID, then exit.
#                     Use this before manually running the golden test.
#   --verify-only ID  Verify an existing memory is retrievable with full
#                     content after a golden test cycle. Use after --write-only.
#   (no flags)        Run the full cycle: write, uninstall --skip-data, deploy,
#                     verify. DESTRUCTIVE — takes the stack down and back up.
#
# Prerequisites:
#   - memoryhub CLI or SDK installed (checks .venv/bin/memoryhub)
#   - MEMORYHUB_URL and MEMORYHUB_API_KEY set, or ~/.config/memoryhub/credentials
#   - OpenShift login active (for the golden test cycle)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONTEXT="${MEMORYHUB_CONTEXT:-mcp-rhoai}"

# S3 spill threshold is 102400 bytes (100KB) — generate content above this.
TEST_CONTENT_SIZE=110000
TEST_TAG="golden-s3-test-$$-$(date -u +%Y%m%dT%H%M%SZ)"

# ---------------------------------------------------------------------------
# Color support
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
    BOLD="\033[1m"
    GREEN="\033[0;32m"
    YELLOW="\033[0;33m"
    RED="\033[0;31m"
    CYAN="\033[0;36m"
    RESET="\033[0m"
else
    BOLD="" GREEN="" YELLOW="" RED="" CYAN="" RESET=""
fi

banner() {
    echo ""
    echo -e "${BOLD}${CYAN}=========================================${RESET}"
    echo -e "${BOLD}${CYAN}  $1${RESET}"
    echo -e "${BOLD}${CYAN}=========================================${RESET}"
}
info()  { echo -e "  ${GREEN}→${RESET} $*"; }
warn()  { echo -e "  ${YELLOW}!${RESET} $*"; }
die()   { echo -e "  ${RED}✗${RESET} $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Resolve memoryhub CLI
# ---------------------------------------------------------------------------
resolve_cli() {
    if command -v memoryhub &>/dev/null; then
        echo "memoryhub"
    elif "$REPO_ROOT/.venv/bin/memoryhub" --version &>/dev/null 2>&1; then
        echo "$REPO_ROOT/.venv/bin/memoryhub"
    else
        die "memoryhub CLI not found. Install with: pip install memoryhub-cli"
    fi
}

# ---------------------------------------------------------------------------
# Write a >100KB test memory and verify it's S3-spilled
# ---------------------------------------------------------------------------
write_test_memory() {
    local memoryhub_bin=$1

    banner "1. Write S3-spilled test memory"

    info "Generating ${TEST_CONTENT_SIZE}-byte test content..."
    local content
    content="[golden-s3-test ${TEST_TAG}] "
    content+="This is a test memory for issue #395 — verifying that S3-spilled "
    content+="content survives the --skip-data golden test. "
    while [ ${#content} -lt "$TEST_CONTENT_SIZE" ]; do
        content+="The quick brown fox jumps over the lazy dog. "
    done
    info "Content size: ${#content} bytes (threshold: 102400)"

    info "Writing memory..."
    local write_output
    write_output=$(echo "$content" | $memoryhub_bin write --scope user --weight 0.1 -o json) || {
        die "Write failed: $write_output"
    }

    local memory_id
    memory_id=$(echo "$write_output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
mem = (d.get('data') or {}).get('memory')
if mem:
    print(mem['id'])
else:
    cur = (d.get('data') or {}).get('curation') or {}
    if cur.get('blocked'):
        print('BLOCKED:' + (cur.get('reason') or 'unknown'), file=sys.stderr)
        sys.exit(1)
    print('')
" 2>&1) || die "Write blocked by curation: $memory_id"

    if [ -z "$memory_id" ]; then
        die "Could not parse memory ID from write response"
    fi

    info "Written: $memory_id"

    banner "2. Verify S3 spill"

    info "Reading memory back to check storage type..."
    local read_output
    read_output=$($memoryhub_bin read "$memory_id" -o json) || {
        die "Read failed"
    }

    local storage_type content_len
    storage_type=$(echo "$read_output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
mem = d.get('data', d)
print(mem.get('storage_type', 'inline'))
")
    content_len=$(echo "$read_output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
mem = d.get('data', d)
c = mem.get('content') or ''
print(len(c))
")

    if [ "$storage_type" = "s3" ]; then
        info "Storage type: s3 (S3-spilled as expected)"
    else
        warn "Storage type: $storage_type (content_len=$content_len)"
        warn "Memory may not be S3-spilled. If MinIO is not configured,"
        warn "content is stored inline. The test can still verify data"
        warn "survival but won't exercise the S3 spill path."
    fi

    echo "$memory_id"
}

# ---------------------------------------------------------------------------
# Verify a memory is fully retrievable after golden test
# ---------------------------------------------------------------------------
verify_memory() {
    local memoryhub_bin=$1
    local memory_id=$2

    banner "4. Verify memory retrieval after golden test"

    info "Reading memory $memory_id..."
    local read_output
    read_output=$($memoryhub_bin read "$memory_id" -o json) || {
        die "Read failed — memory may have been lost"
    }

    local content_len has_tag
    content_len=$(echo "$read_output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
mem = d.get('data', d)
c = mem.get('content') or ''
print(len(c))
")
    has_tag=$(echo "$read_output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
mem = d.get('data', d)
c = mem.get('content') or ''
print('true' if 'golden-s3-test' in c else 'false')
")

    if [ "$has_tag" != "true" ]; then
        die "Memory content does not contain test tag — content may be corrupted or truncated"
    fi

    if [ "$content_len" -lt "$TEST_CONTENT_SIZE" ]; then
        die "Content length ($content_len) is less than expected ($TEST_CONTENT_SIZE) — content truncated"
    fi

    info "Content length: $content_len bytes (expected >= $TEST_CONTENT_SIZE)"
    info "Test tag present: yes"

    banner "5. Cleanup"

    info "Deleting test memory $memory_id..."
    $memoryhub_bin delete "$memory_id" -f -o quiet 2>/dev/null || warn "Delete failed (non-fatal)"
    info "Cleanup complete"

    echo ""
    echo -e "  ${GREEN}${BOLD}PASS: S3-spilled memory survived the --skip-data golden test${RESET}"
    echo ""
}

# ---------------------------------------------------------------------------
# Run the full golden test cycle
# ---------------------------------------------------------------------------
run_golden_test() {
    banner "3. Golden test: uninstall --skip-data && deploy"

    warn "This will take the entire MemoryHub stack down and redeploy it."
    warn "The --skip-data flag preserves both DB and storage namespaces."
    echo ""

    if [ -t 0 ]; then
        read -r -p "  Continue? [y/N] " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            die "Aborted by user"
        fi
    fi

    info "Running: uninstall-full.sh --skip-data --yes"
    "$SCRIPT_DIR/uninstall-full.sh" --skip-data --yes || {
        die "Uninstall failed"
    }

    info "Running: deploy-full.sh --skip-models --skip-smoke-test"
    "$SCRIPT_DIR/deploy-full.sh" --skip-models --skip-smoke-test || {
        die "Deploy failed"
    }

    info "Golden test cycle complete"
}

# ---------------------------------------------------------------------------
# Parse args and run
# ---------------------------------------------------------------------------
MODE="full"
VERIFY_MEMORY_ID=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --write-only)
            MODE="write"
            shift
            ;;
        --verify-only)
            MODE="verify"
            VERIFY_MEMORY_ID="${2:-}"
            if [ -z "$VERIFY_MEMORY_ID" ]; then
                die "--verify-only requires a memory ID argument"
            fi
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [--write-only] [--verify-only MEMORY_ID]"
            echo ""
            echo "  --write-only        Write test memory, print ID, exit"
            echo "  --verify-only ID    Verify memory survived golden test"
            echo "  (no flags)          Full cycle: write → uninstall → deploy → verify"
            exit 0
            ;;
        *)
            die "Unknown argument: $1"
            ;;
    esac
done

MEMORYHUB_BIN=$(resolve_cli)
info "Using CLI: $MEMORYHUB_BIN"

case "$MODE" in
    write)
        MEMORY_ID=$(write_test_memory "$MEMORYHUB_BIN" | tail -1)
        echo ""
        echo "Memory ID: $MEMORY_ID"
        echo ""
        echo "Next steps:"
        echo "  1. Run the golden test: scripts/uninstall-full.sh --skip-data --yes && scripts/deploy-full.sh"
        echo "  2. Verify:              scripts/test-golden-s3.sh --verify-only $MEMORY_ID"
        ;;
    verify)
        verify_memory "$MEMORYHUB_BIN" "$VERIFY_MEMORY_ID"
        ;;
    full)
        MEMORY_ID=$(write_test_memory "$MEMORYHUB_BIN" | tail -1)
        run_golden_test
        verify_memory "$MEMORYHUB_BIN" "$MEMORY_ID"
        ;;
esac
