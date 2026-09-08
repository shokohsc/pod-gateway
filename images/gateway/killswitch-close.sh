#!/bin/sh
set -e

TUN_IF="${TUN_IF:-tun0}"

# ponytail: delete only the tunnel-egress accept (not a full chain flush) so the
# always-on accepts (established/related, cluster ranges, VPN server IP) survive
# every tunnel state. If the rule is already absent (idempotent re-close), do
# nothing rather than error out.
nft delete rule inet killswitch gewall oifname "$TUN_IF" accept 2>/dev/null || true
