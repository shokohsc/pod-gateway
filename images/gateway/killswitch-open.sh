#!/bin/sh
set -e

TUN_IF="${TUN_IF:-tun0}"

nft add rule inet killswitch gewall oifname "$TUN_IF" accept
