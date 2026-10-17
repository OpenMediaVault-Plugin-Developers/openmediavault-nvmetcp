#!/usr/bin/env bash
# test-migration.sh — Tests for the openmediavault-nvmetcp confdb migrations.
#
# Usage: ./tests/test-migration.sh
#
# Runs each migration script against a temporary copy of a sample
# config.xml (via OMV_DEFAULT_FILE / OMV_CONFIG_FILE overrides) and checks
# the result.  The live OMV configuration is never touched.
#
# Requirements:
#   - xmlstarlet
#   - /usr/share/openmediavault/scripts/helper-functions (OMV installed)

set -uo pipefail

# ---------------------------------------------------------------------------
# Colours / counters
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0
declare -a FAILED_TESTS=()

section() { echo -e "\n${CYAN}${BOLD}=== $* ===${NC}" >&2; }

_pass() { echo -e "  ${GREEN}PASS${NC}  $1" >&2; ((PASS++)) || true; }
_fail() {
    echo -e "  ${RED}FAIL${NC}  $1" >&2
    [ -n "${2:-}" ] && echo -e "         ${RED}→${NC} $2" >&2
    ((FAIL++)) || true
    FAILED_TESTS+=("$1")
}

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
MIGRATIONS_DIR="$REPO_DIR/usr/share/openmediavault/confdb/migrations.d"

if ! command -v xmlstarlet >/dev/null 2>&1; then
    echo "Missing required command: xmlstarlet" >&2
    exit 1
fi
if [ ! -f /usr/share/openmediavault/scripts/helper-functions ]; then
    echo "OMV helper-functions not found." >&2
    exit 1
fi

WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

export OMV_DEFAULT_FILE="$WORK_DIR/default"
export OMV_CONFIG_FILE="$WORK_DIR/config.xml"
echo "OMV_CONFIG_FILE=\"$OMV_CONFIG_FILE\"" > "$OMV_DEFAULT_FILE"

# Count nodes matching an XPath in the temporary config.
xcount() { xmlstarlet sel -t -v "count($1)" "$OMV_CONFIG_FILE"; }
xvalue() { xmlstarlet sel -t -v "$1" "$OMV_CONFIG_FILE"; }

assert_count() {
    local desc=$1 xpath=$2 expected=$3 actual
    actual=$(xcount "$xpath")
    if [ "$actual" = "$expected" ]; then
        _pass "$desc"
    else
        _fail "$desc" "count($xpath) = $actual, expected $expected"
    fi
}

assert_value() {
    local desc=$1 xpath=$2 expected=$3 actual
    actual=$(xvalue "$xpath")
    if [ "$actual" = "$expected" ]; then
        _pass "$desc"
    else
        _fail "$desc" "$xpath = '$actual', expected '$expected'"
    fi
}

run_migration() {
    local script=$1 out ec=0
    out=$(sh "$script" 2>&1) || ec=$?
    if [ $ec -ne 0 ]; then
        _fail "$(basename "$script") exits 0" "exit $ec: $out"
        return 1
    fi
    _pass "$(basename "$script") exits 0"
}

write_sample_config() {
    cat > "$OMV_CONFIG_FILE" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<config>
  <system/>
  <services>
    <nvmetcp>
      <enable>1</enable>
      <description/>
      <auto_associate>1</auto_associate>
      <org_domain>io.omv</org_domain>
      <org_date>2014-08</org_date>
      <ports>
        <port>
          <uuid>11111111-1111-4111-8111-111111111111</uuid>
          <addr>0.0.0.0</addr>
          <nport>4420</nport>
          <adrfam>ipv4</adrfam>
        </port>
      </ports>
      <subsystems>
        <subsystem>
          <uuid>22222222-2222-4222-8222-222222222222</uuid>
          <enable>1</enable>
          <description/>
          <nqn>nqn.2014-08.io.omv:one</nqn>
          <model>OMV NVMe Target</model>
          <serial>OMV00000001</serial>
          <allow_any_host>1</allow_any_host>
          <namespaces>
            <nsid>1</nsid>
            <path>/dev/a</path>
            <uuid/>
            <nguid/>
            <eui64/>
            <readonly>1</readonly>
          </namespaces>
          <namespaces>
            <nsid>2</nsid>
            <path>/dev/b</path>
            <uuid/>
            <nguid/>
            <eui64/>
            <readonly>0</readonly>
          </namespaces>
        </subsystem>
        <subsystem>
          <uuid>33333333-3333-4333-8333-333333333333</uuid>
          <enable>0</enable>
          <description/>
          <nqn>nqn.2014-08.io.omv:two</nqn>
          <model>OMV NVMe Target</model>
          <serial>OMV00000002</serial>
          <allow_any_host>0</allow_any_host>
          <hosts>
            <hostnqn>nqn.2014-08.io.omv:host</hostnqn>
          </hosts>
          <namespaces>
            <nsid>1</nsid>
            <path>/dev/c</path>
            <uuid/>
            <nguid/>
            <eui64/>
            <readonly>0</readonly>
          </namespaces>
        </subsystem>
      </subsystems>
      <associations/>
    </nvmetcp>
    <other>
      <readonly>1</readonly>
    </other>
  </services>
</config>
EOF
}

NS="/config/services/nvmetcp/subsystems/subsystem/namespaces"

# ===========================================================================
# Tests
# ===========================================================================

# ---------------------------------------------------------------------------
section "Migration scripts"
# ---------------------------------------------------------------------------

for script in "$MIGRATIONS_DIR"/conf.service.nvmetcp_*.sh; do
    [ -e "$script" ] || continue
    if [ -x "$script" ]; then
        _pass "$(basename "$script") is executable"
    else
        _fail "$(basename "$script") is executable"
    fi
    if sh -n "$script"; then
        _pass "$(basename "$script") has valid syntax"
    else
        _fail "$(basename "$script") has valid syntax"
    fi
done

# ---------------------------------------------------------------------------
section "8.0.1 — remove namespace readonly"
# ---------------------------------------------------------------------------

M801="$MIGRATIONS_DIR/conf.service.nvmetcp_8.0.1.sh"
if [ ! -f "$M801" ]; then
    _fail "8.0.1 migration exists" "$M801 not found"
else
    write_sample_config
    assert_count "sample has readonly nodes before migration" "$NS/readonly" 3

    run_migration "$M801"

    assert_count "all namespace readonly nodes removed" "$NS/readonly" 0
    assert_count "namespaces preserved" "$NS" 3
    assert_count "namespace paths preserved" "$NS/path" 3
    assert_value "first namespace nsid preserved" \
        "/config/services/nvmetcp/subsystems/subsystem[1]/namespaces[1]/nsid" 1
    assert_value "second namespace path preserved" \
        "/config/services/nvmetcp/subsystems/subsystem[1]/namespaces[2]/path" /dev/b
    assert_count "other namespace fields preserved" "$NS/eui64" 3
    assert_value "hosts preserved" \
        "/config/services/nvmetcp/subsystems/subsystem[2]/hosts/hostnqn" \
        nqn.2014-08.io.omv:host
    assert_count "ports preserved" "/config/services/nvmetcp/ports/port" 1
    assert_value "settings preserved" "/config/services/nvmetcp/org_domain" io.omv
    assert_count "readonly outside nvmetcp untouched" \
        "/config/services/other/readonly" 1
    if xmlstarlet val -q "$OMV_CONFIG_FILE"; then
        _pass "config is well-formed XML after migration"
    else
        _fail "config is well-formed XML after migration"
    fi

    # Running the migration again must be a no-op.
    cp "$OMV_CONFIG_FILE" "$WORK_DIR/after-first.xml"
    run_migration "$M801"
    if cmp -s "$OMV_CONFIG_FILE" "$WORK_DIR/after-first.xml"; then
        _pass "migration is idempotent"
    else
        _fail "migration is idempotent" "config changed on second run"
    fi

    # A fresh install has no subsystems at all.
    cat > "$OMV_CONFIG_FILE" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<config><services><nvmetcp><enable>0</enable><ports/><subsystems/><associations/></nvmetcp></services></config>
EOF
    run_migration "$M801"
    assert_count "empty config keeps nvmetcp node" "/config/services/nvmetcp" 1
fi

# ---------------------------------------------------------------------------
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
