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
if ! command -v nft >/dev/null 2>&1; then
    echo "SKIP: nft binary not found - exit 77"
    exit 77
fi

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

TUN_IF="${TUN_IF:-tun0}"
VPN_SERVER_IP="${VPN_SERVER_IP:-198.51.100.1}"
CLUSTER_CIDR="${CLUSTER_CIDR:-10.0.0.0/8}"
GATEWAY_CIDR="${GATEWAY_CIDR:-192.168.1.0/24}"

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

# --- Setup: create table mirroring images/gateway/killswitch.sh + dummy tun0 ---
echo "Setup: create killswitch table and dummy $TUN_IF"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"; ip link del "$TUN_IF" >/dev/null 2>&1 || true; nft delete table inet killswitch >/dev/null 2>&1 || true' EXIT

# iproute2 required for the dummy interface
if ! command -v ip >/dev/null 2>&1; then
    fail "ip (iproute2) not available"
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

cat > "$TMPDIR/killswitch.nft" <<EOF
table inet killswitch {
  chain gewall {
    type filter hook forward priority filter; policy drop;
    ct state established,related accept
    ip saddr { $CLUSTER_CIDR, $GATEWAY_CIDR } accept
    ip daddr { $CLUSTER_CIDR, $GATEWAY_CIDR } accept
    ip daddr $VPN_SERVER_IP accept
  }
  chain outwall {
    type filter hook output priority filter; policy accept;
  }
}
EOF

nft -f "$TMPDIR/killswitch.nft"
pass "killswitch table created with gewall chain (policy drop)"

# Bring up a dummy interface to be the tunnel device
ip link add "$TUN_IF" type dummy 2>&1 || { fail "cannot add dummy $TUN_IF"; exit 1; }
ip link set "$TUN_IF" up
pass "dummy interface $TUN_IF up"

chain_has_rule() {
    nft -a list chain inet killswitch gewall 2>/dev/null | grep -q "$1"
}

# --- Base state: always-on accepts present, tun-egress absent ---
echo "Test: base state (tunnel down)"
if chain_has_rule 'ip daddr' && chain_has_rule 'ip saddr' && chain_has_rule 'ct state established,related'; then
    pass "always-on accepts present in base state"
else
    fail "always-on accepts missing in base state"
fi
if nft -a list chain inet killswitch gewall 2>/dev/null | grep -q 'oifname'; then
    fail "tun-egress rule should not exist before open"
else
    pass "no tun-egress rule in base state"
fi

# --- Close script should be idempotent-safe and keep base state ---
echo "Test: close applied (tunnel down)"
TUN_IF="$TUN_IF" bash "$CLOSE_SRC" 2>&1
if nft -a list chain inet killswitch gewall 2>/dev/null | grep -q 'oifname'; then
    fail "close did not remove tun-egress rule"
else
    pass "close leaves no tun-egress rule"
fi
if chain_has_rule 'ct state established,related' && chain_has_rule 'ip saddr' && chain_has_rule 'ip daddr' && chain_has_rule 'ip daddr'; then
    pass "always-on accepts survive close (forward still drop for external)"
else
    fail "always-on accepts missing after close"
fi

# --- Open script adds tun-egress accept ---
echo "Test: open applied (tunnel up)"
TUN_IF="$TUN_IF" bash "$OPEN_SRC" 2>&1
if chain_has_rule "oifname \"$TUN_IF\""; then
    pass "open added tun-egress accept on $TUN_IF"
else
    fail "open did not add tun-egress accept"
fi
if chain_has_rule 'ct state established,related' && chain_has_rule 'ip saddr' && chain_has_rule 'ip daddr' && chain_has_rule 'ip daddr'; then
    pass "always-on accepts survive open"
else
    fail "always-on accepts missing after open"
fi

# --- Close after open removes only the tun-egress rule ---
echo "Test: close after open (tunnel down)"
TUN_IF="$TUN_IF" bash "$CLOSE_SRC" 2>&1
if chain_has_rule "oifname \"$TUN_IF\""; then
    fail "close did not remove tun-egress rule"
else
    pass "close removed tun-egress rule"
fi
if chain_has_rule 'ct state established,related' && chain_has_rule 'ip saddr' && chain_has_rule 'ip daddr' && chain_has_rule 'ip daddr'; then
    pass "always-on accepts survive final close"
else
    fail "always-on accepts missing after final close"
fi

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
