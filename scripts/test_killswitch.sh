#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OPEN_SRC="$REPO_ROOT/images/gateway/killswitch-open.sh"
CLOSE_SRC="$REPO_ROOT/images/gateway/killswitch-close.sh"

# --- Skip path: need root + nftables to exercise real nft rules ---
if [ "$(id -u)" -ne 0 ]; then
    echo "SKIP: must run as root (nftables requires root) - exit 77"
    exit 77
fi
for bin in nft ip; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo "SKIP: $bin binary not found - exit 77"
        exit 77
    fi
done

NS="killswitch-test"

# Guard: host netns may not be able to create a new network namespace
# (e.g. unprivileged container despite having root). Skip rather than fail.
if ! ip netns add "$NS" 2>/tmp/ns_err; then
    echo "SKIP: cannot create network namespace ($(cat /tmp/ns_err)) - exit 77"
    rm -f /tmp/ns_err
    exit 77
fi

# run inside the scratch netns
nsx() { ip netns exec "$NS" "$@"; }

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

TUN_IF="${TUN_IF:-tun0}"
CLUSTER_CIDR="${CLUSTER_CIDR:-10.0.0.0/8}"
GATEWAY_CIDR="${GATEWAY_CIDR:-192.168.1.0/24}"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"; ip netns del "$NS" >/dev/null 2>&1 || true' EXIT

# --- Pre-check: open/close scripts must exist and be syntactically valid ---
echo "Pre-check: open/close scripts exist"
for f in "$OPEN_SRC" "$CLOSE_SRC"; do
    if [ ! -f "$f" ]; then
        fail "missing script: $f"
        echo ""
        echo "Results: $PASS passed, $FAIL failed"
        exit 1
    fi
    pass "found $f"
done

echo "Pre-check: script syntax valid"
for f in "$OPEN_SRC" "$CLOSE_SRC"; do
    if bash -n "$f" 2>&1; then
        pass "syntax ok: $f"
    else
        fail "syntax error: $f"
        echo ""
        echo "Results: $PASS passed, $FAIL failed"
        exit 1
    fi
done

# --- Setup: scratch netns with table mirroring killswitch.sh + dummy tun0 ---
echo "Setup: create killswitch table and dummy $TUN_IF in scratch netns $NS"

cat > "$TMPDIR/killswitch.nft" <<EOF
table inet killswitch {
  chain gewall {
    type filter hook forward priority filter; policy drop;
    ct state established,related accept
    ip saddr { $CLUSTER_CIDR, $GATEWAY_CIDR } accept
    ip daddr { $CLUSTER_CIDR, $GATEWAY_CIDR } accept
  }
  chain outwall {
    type filter hook output priority filter; policy accept;
  }
}
EOF

nsx nft -f "$TMPDIR/killswitch.nft"
pass "killswitch table created in $NS with gewall chain (policy drop)"

# Bring up a dummy interface inside the netns to be the tunnel device
nsx ip link add "$TUN_IF" type dummy 2>&1 || { fail "cannot add dummy $TUN_IF in $NS"; exit 1; }
nsx ip link set "$TUN_IF" up
pass "dummy interface $TUN_IF up in $NS"

chain_has_rule() {
    nsx nft -a list chain inet killswitch gewall 2>/dev/null | grep -q "$1"
}
chain_policy_is_drop() {
    nsx nft list chain inet killswitch gewall 2>/dev/null | grep -q 'policy drop'
}
always_on_present() {
    chain_has_rule 'ct state established,related' \
        && chain_has_rule 'ip saddr' \
        && chain_has_rule 'ip daddr'
}

# --- Base state: always-on accepts present, policy drop, tun-egress absent ---
echo "Test: base state (tunnel down)"
if always_on_present; then
    pass "always-on accepts present in base state"
else
    fail "always-on accepts missing in base state"
fi
if chain_policy_is_drop; then
    pass "forward chain policy is drop in base state"
else
    fail "forward chain policy not drop in base state"
fi
if chain_has_rule 'oifname'; then
    fail "tun-egress rule should not exist before open"
else
    pass "no tun-egress rule in base state"
fi

# --- Close script should be idempotent-safe and keep base state ---
echo "Test: close applied (tunnel down)"
TUN_IF="$TUN_IF" nsx bash "$CLOSE_SRC" 2>&1
if chain_has_rule 'oifname'; then
    fail "close did not remove tun-egress rule"
else
    pass "close leaves no tun-egress rule"
fi
if always_on_present; then
    pass "always-on accepts survive close"
else
    fail "always-on accepts missing after close"
fi
if chain_policy_is_drop; then
    pass "forward chain policy drop after close (external egress blocked)"
else
    fail "forward chain policy not drop after close"
fi

# --- Open script adds tun-egress accept; policy stays drop ---
echo "Test: open applied (tunnel up)"
TUN_IF="$TUN_IF" nsx bash "$OPEN_SRC" 2>&1
if chain_has_rule "oifname \"$TUN_IF\""; then
    pass "open added tun-egress accept on $TUN_IF"
else
    fail "open did not add tun-egress accept"
fi
if always_on_present; then
    pass "always-on accepts survive open"
else
    fail "always-on accepts missing after open"
fi
if chain_policy_is_drop; then
    pass "forward chain policy remains drop after open (egress via explicit rule)"
else
    fail "forward chain policy not drop after open"
fi

# --- Close after open removes only the tun-egress rule ---
echo "Test: close after open (tunnel down)"
TUN_IF="$TUN_IF" nsx bash "$CLOSE_SRC" 2>&1
if chain_has_rule "oifname \"$TUN_IF\""; then
    fail "close did not remove tun-egress rule"
else
    pass "close removed tun-egress rule"
fi
if always_on_present; then
    pass "always-on accepts survive final close"
else
    fail "always-on accepts missing after final close"
fi
if chain_policy_is_drop; then
    pass "forward chain policy drop after final close"
else
    fail "forward chain policy not drop after final close"
fi

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
