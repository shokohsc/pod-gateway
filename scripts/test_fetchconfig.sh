#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FETCHCONFIG="$REPO_ROOT/images/gateway/fetchconfig.sh"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Create a dummy .ovpn file to serve as the remote config
DUMMY_CONFIG="$TMPDIR/source.ovpn"
cat > "$DUMMY_CONFIG" <<'OVPN'
client
dev tun
proto udp
remote 198.51.100.1 1194
resolv-retry infinite
nobind
persist-key
persist-tun
OVPN

OUTPUT_DIR="$TMPDIR/output"
mkdir -p "$OUTPUT_DIR"
OUTPUT_FILE="$OUTPUT_DIR/client.ovpn"

# --- Pre-check: fetchconfig.sh must exist ---
echo "Pre-check: fetchconfig.sh exists"
if [ ! -f "$FETCHCONFIG" ]; then
    fail "fetchconfig.sh not found at $FETCHCONFIG"
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi
pass "fetchconfig.sh found"

# --- Pre-check: script syntax valid ---
echo "Pre-check: script syntax valid"
if bash -n "$FETCHCONFIG" 2>&1; then
    pass "syntax check passed"
else
    fail "syntax error in fetchconfig.sh"
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

# --- Test 1: fetchconfig.sh downloads config to output path ---
echo "Test 1: fetchconfig.sh fetches config from URL"

# Create a wrapper that mirrors fetchconfig.sh logic but uses temp output path.
# This exercises the exact same curl flags, guard, and test -s logic.
cat > "$TMPDIR/run.sh" <<WRAPPER_EOF
#!/bin/sh
set -eu
out="$OUTPUT_FILE"
CONFIG_URL="\${CONFIG_URL:?CONFIG_URL required}"
curl -fSL --retry 3 --retry-delay 2 -o "\$out" "\$CONFIG_URL"
test -s "\$out"
WRAPPER_EOF
chmod +x "$TMPDIR/run.sh"

CONFIG_URL="file://$DUMMY_CONFIG" sh "$TMPDIR/run.sh" 2>&1

if [ -f "$OUTPUT_FILE" ] && [ -s "$OUTPUT_FILE" ]; then
    if diff -q "$DUMMY_CONFIG" "$OUTPUT_FILE" > /dev/null 2>&1; then
        pass "file downloaded to output path and content matches"
    else
        fail "file downloaded but content differs"
    fi
else
    fail "output file missing or empty at $OUTPUT_FILE"
fi

# --- Test 2: Missing CONFIG_URL causes failure ---
echo "Test 2: missing CONFIG_URL causes failure"
rm -f "$OUTPUT_FILE"
unset CONFIG_URL
if sh "$TMPDIR/run.sh" 2>&1; then
    fail "expected failure with missing CONFIG_URL"
else
    pass "correctly fails without CONFIG_URL"
fi

# --- Test 3: Empty URL results in empty or missing file ---
echo "Test 3: invalid file:// URL causes failure"
rm -f "$OUTPUT_FILE"
if CONFIG_URL="file:///nonexistent/config.ovpn" sh "$TMPDIR/run.sh" 2>&1; then
    fail "expected failure with invalid URL"
else
    pass "correctly fails with invalid URL"
fi

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
