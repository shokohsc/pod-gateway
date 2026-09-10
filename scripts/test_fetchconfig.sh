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

# --- Test 1: fetchconfig.sh downloads config via HTTP ---
echo "Test 1: fetchconfig.sh fetches config from URL"

# Start a temporary HTTP server to serve the dummy config
SERVE_DIR="$TMPDIR/serve"
mkdir -p "$SERVE_DIR"
cp "$DUMMY_CONFIG" "$SERVE_DIR/client.ovpn"
python3 -m http.server 18080 --directory "$SERVE_DIR" &>/dev/null &
HTTP_PID=$!
trap 'rm -rf "$TMPDIR"; kill "$HTTP_PID" 2>/dev/null || true' EXIT
sleep 0.5

OUT="$OUTPUT_FILE" CONFIG_URL="http://127.0.0.1:18080/client.ovpn" "$FETCHCONFIG" 2>&1

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
if OUT="$OUTPUT_FILE" "$FETCHCONFIG" 2>&1; then
    fail "expected failure with missing CONFIG_URL"
else
    pass "correctly fails without CONFIG_URL"
fi

# --- Test 3: Nonexistent config path causes failure ---
echo "Test 3: nonexistent config path causes failure"
rm -f "$OUTPUT_FILE"
if OUT="$OUTPUT_FILE" CONFIG_URL="http://127.0.0.1:18080/nonexistent.ovpn" "$FETCHCONFIG" 2>&1; then
    fail "expected failure with nonexistent config path"
else
    pass "correctly fails with nonexistent config path"
fi

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
