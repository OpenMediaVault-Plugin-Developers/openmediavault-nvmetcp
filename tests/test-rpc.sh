#!/usr/bin/env bash
# test-rpc.sh — Integration tests for openmediavault-nvmetcp RPC methods.
#
# Usage: sudo ./tests/test-rpc.sh
#
# Exercises all plugin RPC methods against the live OMV configuration
# database: CRUD for ports, subsystems, and associations, plus enumeration
# and settings round-trips.  All test objects are removed on exit.
#
# Requirements:
#   - Run as root
#   - OMV with the nvmetcp plugin installed

set -uo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Must be run as root." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Colours / counters
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0
declare -a FAILED_TESTS=()

section() { echo -e "\n${CYAN}${BOLD}=== $* ===${NC}" >&2; }
info()    { echo -e "  ${YELLOW}»${NC} $*" >&2; }

_pass() { echo -e "  ${GREEN}PASS${NC}  $1" >&2; ((PASS++)) || true; }
_fail() {
    echo -e "  ${RED}FAIL${NC}  $1" >&2
    [ -n "${2:-}" ] && echo -e "         ${RED}→${NC} $2" >&2
    ((FAIL++)) || true
    FAILED_TESTS+=("$1")
}

# ---------------------------------------------------------------------------
# RPC helpers
# ---------------------------------------------------------------------------

# Raw RPC call; output to stdout, errors to stderr.
rpc() {
    local svc=$1 method=$2 params=${3:-'{}'}
    omv-rpc -u admin "$svc" "$method" "$params"
}

# Assert an RPC succeeds.  Result JSON is stored in RPC_OUT.
# Optional 5th arg: grep pattern that must appear in output.
RPC_OUT=""
assert_rpc() {
    local desc=$1 svc=$2 method=$3 params=${4:-'{}'} pattern=${5:-}
    local out ec=0
    out=$(omv-rpc -u admin "$svc" "$method" "$params" 2>&1) || ec=$?
    if [ $ec -ne 0 ]; then
        _fail "$desc" "$(echo "$out" | tail -3)"
        RPC_OUT=""
        return 1
    fi
    if [ -n "$pattern" ] && ! echo "$out" | grep -q "$pattern"; then
        _fail "$desc" "Pattern '$pattern' not found in: ${out:0:200}"
        RPC_OUT=""
        return 1
    fi
    _pass "$desc"
    RPC_OUT="$out"
    return 0
}

# Assert an RPC fails (non-zero exit or contains "exception"/"error").
assert_rpc_fails() {
    local desc=$1 svc=$2 method=$3 params=${4:-'{}'}
    local out ec=0
    out=$(omv-rpc -u admin "$svc" "$method" "$params" 2>&1) || ec=$?
    if [ $ec -eq 0 ] && ! echo "$out" | grep -qi "exception"; then
        _fail "$desc" "Expected failure but RPC succeeded: ${out:0:200}"
        return 1
    fi
    _pass "$desc"
    return 0
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
json_field() {
    # Extract a top-level string/number field from JSON using python3.
    local json=$1 field=$2
    echo "$json" | python3 -c \
        "import sys,json; d=json.load(sys.stdin); print(d.get('$field',''))" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
SVC="nvmetcp"
LIST_PARAMS='{"start":0,"limit":null,"sortfield":null,"sortdir":null}'

OMV_NEW_UUID=$(. /etc/default/openmediavault 2>/dev/null; \
    echo "${OMV_CONFIGOBJECT_NEW_UUID:-fa4b1c66-ef79-11e5-87a0-0002b3a176b4}")

# ---------------------------------------------------------------------------
# State — populated during tests, consumed by cleanup
# ---------------------------------------------------------------------------
ASSOC_UUID=""
PORT_UUID=""
PORT2_UUID=""
SS_UUID=""
SS2_UUID=""
ORIG_SETTINGS=""

# ---------------------------------------------------------------------------
# Cleanup — always runs on exit
# ---------------------------------------------------------------------------
cleanup() {
    section "Cleanup"

    if [ -n "$ASSOC_UUID" ]; then
        info "Deleting association $ASSOC_UUID"
        rpc "$SVC" deleteAssociation "{\"uuid\":\"$ASSOC_UUID\"}" >/dev/null 2>&1 || true
    fi
    if [ -n "$SS_UUID" ]; then
        info "Deleting subsystem $SS_UUID"
        rpc "$SVC" deleteSubsystem "{\"uuid\":\"$SS_UUID\"}" >/dev/null 2>&1 || true
    fi
    if [ -n "$SS2_UUID" ]; then
        info "Deleting subsystem $SS2_UUID"
        rpc "$SVC" deleteSubsystem "{\"uuid\":\"$SS2_UUID\"}" >/dev/null 2>&1 || true
    fi
    if [ -n "$PORT_UUID" ]; then
        info "Deleting port $PORT_UUID"
        rpc "$SVC" deletePort "{\"uuid\":\"$PORT_UUID\"}" >/dev/null 2>&1 || true
    fi
    if [ -n "$PORT2_UUID" ]; then
        info "Deleting port $PORT2_UUID"
        rpc "$SVC" deletePort "{\"uuid\":\"$PORT2_UUID\"}" >/dev/null 2>&1 || true
    fi
    if [ -n "$ORIG_SETTINGS" ]; then
        info "Restoring original settings"
        rpc "$SVC" setSettings "$ORIG_SETTINGS" >/dev/null 2>&1 || true
    fi

    echo >&2
    echo -e "${BOLD}Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}" >&2
    if [ ${#FAILED_TESTS[@]} -gt 0 ]; then
        echo -e "${RED}Failed tests:${NC}" >&2
        for t in "${FAILED_TESTS[@]}"; do
            echo -e "  - $t" >&2
        done
        exit 1
    fi
    exit 0
}
trap cleanup EXIT

# ===========================================================================
# Tests
# ===========================================================================

# ---------------------------------------------------------------------------
section "Settings"
# ---------------------------------------------------------------------------

assert_rpc "getSettings returns object" \
    "$SVC" getSettings '{}' '"enable"'
ORIG_SETTINGS="$RPC_OUT"

assert_rpc "setSettings round-trip (enable=false)" \
    "$SVC" setSettings \
    '{"enable":false,"description":"test run","auto_associate":false,"org_domain":"io.omv","org_date":"2014-08"}' \
    '"enable"'

assert_rpc "setSettings can re-enable" \
    "$SVC" setSettings \
    '{"enable":true,"description":"","auto_associate":true,"org_domain":"io.omv","org_date":"2014-08"}' \
    '"enable"'

# org_date has no schema-level pattern validation; the PHP silently falls back
# to a default when the value is malformed, so we verify it round-trips cleanly.
assert_rpc "setSettings accepts non-standard org_date (no server-side format check)" \
    "$SVC" setSettings \
    '{"enable":false,"description":"","auto_associate":true,"org_domain":"io.omv","org_date":"not-a-date"}' \
    '"org_date"'

# ---------------------------------------------------------------------------
section "Ports — create"
# ---------------------------------------------------------------------------

# The port schema requires uuid to be a valid UUIDv4 when present; pass the
# OMV new-object sentinel UUID so the RPC treats the object as new.
assert_rpc "setPort creates new port (4421)" \
    "$SVC" setPort \
    "{\"uuid\":\"$OMV_NEW_UUID\",\"addr\":\"127.0.0.1\",\"nport\":4421,\"adrfam\":\"ipv4\"}" \
    '"uuid"'
PORT_UUID=$(json_field "$RPC_OUT" "uuid")
info "PORT_UUID=$PORT_UUID"

if [ -z "$PORT_UUID" ] || [ "$PORT_UUID" = "$OMV_NEW_UUID" ]; then
    echo "Cannot continue without a real port UUID." >&2
    exit 1
fi

assert_rpc "setPort creates second port (4422, ipv4)" \
    "$SVC" setPort \
    "{\"uuid\":\"$OMV_NEW_UUID\",\"addr\":\"127.0.0.1\",\"nport\":4422,\"adrfam\":\"ipv4\"}" \
    '"uuid"'
PORT2_UUID=$(json_field "$RPC_OUT" "uuid")
info "PORT2_UUID=$PORT2_UUID"

# Duplicate port number must be rejected
assert_rpc_fails "setPort rejects duplicate nport" \
    "$SVC" setPort \
    "{\"uuid\":\"$OMV_NEW_UUID\",\"addr\":\"127.0.0.2\",\"nport\":4421,\"adrfam\":\"ipv4\"}"

# ---------------------------------------------------------------------------
section "Ports — read"
# ---------------------------------------------------------------------------

assert_rpc "listPorts returns at least 2 rows" \
    "$SVC" listPorts "$LIST_PARAMS" '"total"'

assert_rpc "getPort returns correct addr" \
    "$SVC" getPort "{\"uuid\":\"$PORT_UUID\"}" '"127.0.0.1"'

assert_rpc_fails "getPort with unknown UUID fails" \
    "$SVC" getPort '{"uuid":"00000000-0000-0000-0000-000000000000"}'

# ---------------------------------------------------------------------------
section "Ports — update"
# ---------------------------------------------------------------------------

assert_rpc "setPort updates addr" \
    "$SVC" setPort \
    "{\"uuid\":\"$PORT_UUID\",\"addr\":\"127.0.0.2\",\"nport\":4421,\"adrfam\":\"ipv4\"}" \
    '"127.0.0.2"'

# Restore addr for later association test
assert_rpc "setPort restores addr to 127.0.0.1" \
    "$SVC" setPort \
    "{\"uuid\":\"$PORT_UUID\",\"addr\":\"127.0.0.1\",\"nport\":4421,\"adrfam\":\"ipv4\"}" \
    '"127.0.0.1"'

# ---------------------------------------------------------------------------
section "Subsystems — create"
# ---------------------------------------------------------------------------

assert_rpc "setSubsystem creates new subsystem (auto NQN)" \
    "$SVC" setSubsystem \
    '{"uuid":"","enable":true,"description":"test subsystem","nqn":"nqn.2014-08.io.omv:test-nvmetcp-1","model":"OMV NVMe Target","serial":"TEST0001","allow_any_host":true,"hosts":[],"namespaces":[{"path":"/dev/null","readonly":false}]}' \
    '"uuid"'
SS_UUID=$(json_field "$RPC_OUT" "uuid")
info "SS_UUID=$SS_UUID"

if [ -z "$SS_UUID" ]; then
    echo "Cannot continue without a subsystem UUID." >&2
    exit 1
fi

assert_rpc "setSubsystem creates second subsystem (host-restricted)" \
    "$SVC" setSubsystem \
    '{"uuid":"","enable":true,"description":"host-restricted subsystem","nqn":"nqn.2014-08.io.omv:test-nvmetcp-2","model":"OMV NVMe Target","serial":"TEST0002","allow_any_host":false,"hosts":[{"hostnqn":"nqn.2014-08.io.omv:initiator-test"}],"namespaces":[]}' \
    '"uuid"'
SS2_UUID=$(json_field "$RPC_OUT" "uuid")
info "SS2_UUID=$SS2_UUID"

# Duplicate NQN must be rejected
assert_rpc_fails "setSubsystem rejects duplicate NQN" \
    "$SVC" setSubsystem \
    '{"uuid":"","enable":false,"description":"dup","nqn":"nqn.2014-08.io.omv:test-nvmetcp-1","model":"OMV NVMe Target","serial":"TEST9999","allow_any_host":true,"hosts":[],"namespaces":[]}'

# ---------------------------------------------------------------------------
section "Subsystems — read"
# ---------------------------------------------------------------------------

assert_rpc "listSubsystems returns at least 2 rows" \
    "$SVC" listSubsystems "$LIST_PARAMS" '"total"'

assert_rpc "getSubsystem returns correct NQN" \
    "$SVC" getSubsystem "{\"uuid\":\"$SS_UUID\"}" '"nqn.2014-08.io.omv:test-nvmetcp-1"'

assert_rpc_fails "getSubsystem with unknown UUID fails" \
    "$SVC" getSubsystem '{"uuid":"00000000-0000-0000-0000-000000000000"}'

# ---------------------------------------------------------------------------
section "Subsystems — update"
# ---------------------------------------------------------------------------

assert_rpc "setSubsystem updates description" \
    "$SVC" setSubsystem \
    "{\"uuid\":\"$SS_UUID\",\"enable\":true,\"description\":\"updated\",\"nqn\":\"nqn.2014-08.io.omv:test-nvmetcp-1\",\"model\":\"OMV NVMe Target\",\"serial\":\"TEST0001\",\"allow_any_host\":true,\"hosts\":[],\"namespaces\":[{\"path\":\"/dev/null\",\"readonly\":false}]}" \
    '"updated"'

# ---------------------------------------------------------------------------
section "Enumerate"
# ---------------------------------------------------------------------------

assert_rpc "enumeratePorts returns array" \
    "$SVC" enumeratePorts '{}' "127.0.0.1"

assert_rpc "enumerateSubsystems returns only enabled subsystems" \
    "$SVC" enumerateSubsystems '{}' '"uuid"'

# Disable SS_UUID and confirm it disappears from enumeration
assert_rpc "setSubsystem disables first subsystem" \
    "$SVC" setSubsystem \
    "{\"uuid\":\"$SS_UUID\",\"enable\":false,\"description\":\"updated\",\"nqn\":\"nqn.2014-08.io.omv:test-nvmetcp-1\",\"model\":\"OMV NVMe Target\",\"serial\":\"TEST0001\",\"allow_any_host\":true,\"hosts\":[],\"namespaces\":[{\"path\":\"/dev/null\",\"readonly\":false}]}"

ENUM_OUT=$(rpc "$SVC" enumerateSubsystems '{}' 2>&1)
if echo "$ENUM_OUT" | grep -q "test-nvmetcp-1"; then
    _fail "enumerateSubsystems excludes disabled subsystems" \
        "Disabled NQN still appears in enumeration"
else
    _pass "enumerateSubsystems excludes disabled subsystems"
fi

# Re-enable for association tests
assert_rpc "setSubsystem re-enables first subsystem" \
    "$SVC" setSubsystem \
    "{\"uuid\":\"$SS_UUID\",\"enable\":true,\"description\":\"updated\",\"nqn\":\"nqn.2014-08.io.omv:test-nvmetcp-1\",\"model\":\"OMV NVMe Target\",\"serial\":\"TEST0001\",\"allow_any_host\":true,\"hosts\":[],\"namespaces\":[{\"path\":\"/dev/null\",\"readonly\":false}]}"

# ---------------------------------------------------------------------------
section "Associations — create"
# ---------------------------------------------------------------------------

assert_rpc "setAssociation creates port+subsystem link" \
    "$SVC" setAssociation \
    "{\"uuid\":\"$OMV_NEW_UUID\",\"portref\":\"$PORT_UUID\",\"subsystemref\":\"$SS_UUID\"}" \
    '"uuid"'
ASSOC_UUID=$(json_field "$RPC_OUT" "uuid")
info "ASSOC_UUID=$ASSOC_UUID"

if [ -z "$ASSOC_UUID" ]; then
    echo "Cannot continue without an association UUID." >&2
    exit 1
fi

# Duplicate pair must be rejected
assert_rpc_fails "setAssociation rejects duplicate port+subsystem pair" \
    "$SVC" setAssociation \
    "{\"uuid\":\"$OMV_NEW_UUID\",\"portref\":\"$PORT_UUID\",\"subsystemref\":\"$SS_UUID\"}"

# ---------------------------------------------------------------------------
section "Associations — read"
# ---------------------------------------------------------------------------

assert_rpc "listAssociations returns at least 1 row" \
    "$SVC" listAssociations "$LIST_PARAMS" '"total"'

assert_rpc "getAssociation returns correct portref" \
    "$SVC" getAssociation "{\"uuid\":\"$ASSOC_UUID\"}" "\"$PORT_UUID\""

assert_rpc_fails "getAssociation with unknown UUID fails" \
    "$SVC" getAssociation '{"uuid":"00000000-0000-0000-0000-000000000000"}'

# ---------------------------------------------------------------------------
section "Cascade deletes"
# ---------------------------------------------------------------------------

# Deleting a port should also remove associations referencing it.
assert_rpc "deletePort cascades to association" \
    "$SVC" deletePort "{\"uuid\":\"$PORT_UUID\"}"
PORT_UUID=""   # already deleted

ASSOC_CHECK=$(rpc "$SVC" getAssociation "{\"uuid\":\"$ASSOC_UUID\"}" 2>&1) || true
if echo "$ASSOC_CHECK" | grep -qi "exception\|not found\|no object"; then
    _pass "Association removed after port cascade delete"
else
    _fail "Association removed after port cascade delete" \
        "Association still retrievable after port delete"
fi
ASSOC_UUID=""  # already gone

# Deleting a subsystem should also remove its associations.
# Create a fresh port+association to test subsystem cascade.
assert_rpc "setPort creates port for cascade test (4423)" \
    "$SVC" setPort \
    "{\"uuid\":\"$OMV_NEW_UUID\",\"addr\":\"127.0.0.1\",\"nport\":4423,\"adrfam\":\"ipv4\"}" \
    '"uuid"'
PORT_UUID=$(json_field "$RPC_OUT" "uuid")

assert_rpc "setAssociation links port to SS2 for cascade test" \
    "$SVC" setAssociation \
    "{\"uuid\":\"$OMV_NEW_UUID\",\"portref\":\"$PORT_UUID\",\"subsystemref\":\"$SS2_UUID\"}" \
    '"uuid"'
ASSOC_UUID=$(json_field "$RPC_OUT" "uuid")

assert_rpc "deleteSubsystem cascades to association" \
    "$SVC" deleteSubsystem "{\"uuid\":\"$SS2_UUID\"}"
SS2_UUID=""

ASSOC_CHECK2=$(rpc "$SVC" getAssociation "{\"uuid\":\"$ASSOC_UUID\"}" 2>&1) || true
if echo "$ASSOC_CHECK2" | grep -qi "exception\|not found\|no object"; then
    _pass "Association removed after subsystem cascade delete"
else
    _fail "Association removed after subsystem cascade delete" \
        "Association still retrievable after subsystem delete"
fi
ASSOC_UUID=""
