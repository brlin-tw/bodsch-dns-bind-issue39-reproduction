#!/usr/bin/env sh
# Minimal, self-contained reproduction of the BIND dynamic-zone
# "journal out of sync with zone" load failure that breaks DDNS propagation
# after a service re-deployment.
#
# It uses ONLY a throwaway BIND9 container plus the three sibling files in this
# folder -- none of the project's playbooks or inventory.
#
# Requires: docker (usable by the current user).
#
# The timeline it recreates:
#   1. Deploy #1 templates the zone file (serial 1); named loads it.
#   2. A DDNS client nsupdates a record -> named writes a journal (serial 1->2).
#   3. Deploy #2 re-templates the zone file with a fresh, higher serial but
#      leaves the journal behind (the bug).
#   4. named restarts (reboot / package upgrade) -> zone fails to load.
#
# Exit status: 0 if the failure was reproduced, 1 otherwise.
#
# Copyright 2026 Buo-ren Lin (OSSII) <buoren.lin@ossii.com.tw>
# SPDX-License-Identifier: AGPL-3.0-or-later
set -eu

IMAGE='internetsystemsconsortium/bind9:9.18'
CONTAINER='bind-stale-journal-repro'
HERE="$(cd "$(dirname "$0")" && pwd)"

step() { printf '\n=== %s ===\n' "$1"; }
dexec() { docker exec "$CONTAINER" /bin/sh -c "$1"; }

cleanup() { docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

step "0. Start a throwaway BIND container (idle; we drive named via docker exec)"
docker run -d --name "$CONTAINER" \
    -v "$HERE:/repro-src:ro" \
    --entrypoint /bin/sh \
    "$IMAGE" -c 'sleep infinity' >/dev/null
docker exec "$CONTAINER" named -v

step "1. Lay down the minimal config + the initial (deploy #1) zone file"
dexec '
    set -e
    mkdir -p /work
    cp /repro-src/named.conf            /work/named.conf
    cp /repro-src/repro.test.zone.initial /work/repro.test.zone
    tsig-keygen -a hmac-sha256 rndc-key > /etc/bind/rndc.key
    named -c /work/named.conf
'
sleep 1
dexec 'rndc zonestatus repro.test | grep -E "serial|files|dynamic"'
printf 'initial query: dynamic.repro.test A = '
dexec 'dig +short @127.0.0.1 dynamic.repro.test A' || true
echo '(empty = record not present yet, as expected)'

step "2. A DDNS client adds a record -> named writes a journal (serial 1 -> 2)"
dexec 'nsupdate <<EOF
server 127.0.0.1 53
zone repro.test
update add dynamic.repro.test. 600 A 192.0.2.99
send
EOF'
sleep 1
printf 'after update: dynamic.repro.test A = '
dexec 'dig +short @127.0.0.1 dynamic.repro.test A'
echo '--- journal now on disk ---'
dexec 'ls -l /work/repro.test.zone.jnl; echo "journal transactions:"; named-journalprint /work/repro.test.zone.jnl'

step "3. Deploy #2: re-template the zone file (fresh serial), leave the journal"
echo '(named is stopped first so the on-disk end-state is deterministic;'
echo ' in production Ansible rewrites the file while named runs and the'
echo ' restart in step 4 comes later -- the resulting on-disk state is identical.)'
dexec 'rndc stop'
sleep 1
dexec 'cp /repro-src/repro.test.zone.redeployed /work/repro.test.zone'
echo '--- new on-disk serial vs leftover journal range ---'
dexec 'grep -E "^[[:space:]]*[0-9]+[[:space:]]*; serial" /work/repro.test.zone; echo "journal still:"; named-journalprint /work/repro.test.zone.jnl | head -2'

step "4. named restarts -> attempts journal rollforward -> FAILS to load"
dexec 'named -c /work/named.conf'
sleep 2

step "RESULT"
echo '--- rndc zonestatus repro.test ---'
ZONESTATUS="$(dexec 'rndc zonestatus repro.test 2>&1' || true)"
echo "$ZONESTATUS"
echo '--- named.log (zone-load lines) ---'
LOG="$(dexec 'cat /work/named.log' 2>/dev/null || true)"
echo "$LOG" | grep -iE 'journal|out of sync|not loaded' || echo '(no matching log lines)'
echo '--- is the zone being served? (expect SERVFAIL/empty on the primary) ---'
dexec 'dig +short @127.0.0.1 repro.test SOA' || true

echo
if printf '%s' "$LOG" | grep -qi 'journal out of sync with zone' \
   && printf '%s' "$ZONESTATUS" | grep -qi 'not loaded'; then
    echo 'REPRODUCED: zone failed to load ("journal out of sync with zone").'
    exit 0
else
    echo 'NOT reproduced: the zone loaded unexpectedly. Inspect the output above.'
    exit 1
fi
