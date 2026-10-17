#!/usr/bin/env bash
# run-all.sh — Run all openmediavault-nvmetcp test suites.
#
# Usage: ./tests/run-all.sh          # offline suites only (unless root)
#        sudo ./tests/run-all.sh     # offline suites + live RPC suite
#
# Suites:
#   test-salt-render.py  Offline Salt state rendering (no root)
#   test-migration.sh    confdb migrations on a temp config (no root)
#   test-rpc.sh          Live RPC integration tests (root, plugin installed)
#
# The RPC suite is skipped when not run as root.  Exit status is non-zero
# if any suite that ran failed.

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

TESTS_DIR=$(cd "$(dirname "$0")" && pwd)

declare -a PASSED=() FAILED=() SKIPPED=()

run_suite() {
    local name=$1; shift
    echo -e "\n${CYAN}${BOLD}##### ${name} #####${NC}" >&2
    if "$@"; then
        PASSED+=("$name")
    else
        FAILED+=("$name")
    fi
}

skip_suite() {
    echo -e "\n${YELLOW}${BOLD}##### $1 — skipped: $2 #####${NC}" >&2
    SKIPPED+=("$1 ($2)")
}

run_suite "test-salt-render.py" python3 -I "$TESTS_DIR/test-salt-render.py"
run_suite "test-migration.sh" bash "$TESTS_DIR/test-migration.sh"

if [ "$(id -u)" -ne 0 ]; then
    skip_suite "test-rpc.sh" "requires root"
elif ! command -v omv-rpc >/dev/null 2>&1; then
    skip_suite "test-rpc.sh" "omv-rpc not found"
else
    run_suite "test-rpc.sh" bash "$TESTS_DIR/test-rpc.sh"
fi

echo -e "\n${BOLD}Summary${NC}" >&2
for s in "${PASSED[@]}";  do echo -e "  ${GREEN}PASS${NC}  $s" >&2; done
for s in "${FAILED[@]}";  do echo -e "  ${RED}FAIL${NC}  $s" >&2; done
for s in "${SKIPPED[@]}"; do echo -e "  ${YELLOW}SKIP${NC}  $s" >&2; done

[ ${#FAILED[@]} -eq 0 ]
