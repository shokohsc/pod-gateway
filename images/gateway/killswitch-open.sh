#!/bin/sh
set -e

TUN_IF="${TUN_IF:-tun0}"

# Route-up may re-fire on a tun restart in the same netns, where the rule from
# the previous add already exists: tolerate it.
nft add rule inet killswitch gewall oifname "$TUN_IF" accept 2>/dev/null || true