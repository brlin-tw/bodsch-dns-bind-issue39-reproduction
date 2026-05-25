#!/usr/bin/env bash
# Reproduce the BIND dynamic-zone "journal out of sync with zone" load failure
# using the UPSTREAM bodsch.dns.bind role inside a single-VM Vagrant testing
# environment.
#
# Requires: vagrant + VirtualBox, ansible / ansible-galaxy, sshpass (for the
# vagrant password login).
#
# Timeline recreated (all against the role, none hand-edited):
#   #1 deploy  -> role templates the zone file (epoch serial); named loads it
#   ddns       -> nsupdate adds a record; named writes a journal (serial +1)
#   #2 deploy  -> role re-templates the zone file with a fresh, higher epoch
#                 serial but leaves the journal behind
#   restart    -> named tries to roll the stale journal forward and refuses to
#                 load the zone
#
# Exit status: 0 if the failure was reproduced, 1 otherwise.
#
# Copyright 2026 Buo-ren Lin (OSSII) <buoren.lin@ossii.com.tw>
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")"

ZONE='repro.test'
ZONEFILE="/var/cache/bind/${ZONE}"
JOURNAL="${ZONEFILE}.jnl"

step() { printf '\n========== %s ==========\n' "$1"; }
# Ansible ad-hoc against the single host (ansible.cfg supplies the inventory).
a() { ansible repro-primary "$@"; }

# `vagrant up` returns as soon as the box boots, but the host-only network
# interface (192.168.56.30) and sshd on it can take a few more seconds to come
# up.  Without this wait the first VM-bound task races the network and Ansible
# exits 4 (all hosts unreachable).
wait_for_vm() {
    i=1
    while [ "$i" -le 30 ]; do
        if a -m ansible.builtin.ping >/dev/null 2>&1; then
            echo "VM reachable via Ansible (attempt ${i})."
            return 0
        fi
        echo "  waiting for the VM to accept Ansible connections (attempt ${i}/30)..."
        sleep 5
        i=$((i + 1))
    done
    echo "ERROR: the VM never became reachable via Ansible (192.168.56.30)." >&2
    return 1
}

step "0. Bring up the Vagrant VM"
vagrant up

step "1. Wait for the VM to accept Ansible connections"
wait_for_vm

step "2. Install the UPSTREAM role from Ansible Galaxy into ./collections"
ansible-galaxy collection install -r requirements.yml -p collections --force | tail -3

step "3. Ensure BIND client tools on the VM (nsupdate, dig, named-journalprint)"
a -b -m ansible.builtin.apt \
    -a "name=bind9-dnsutils,bind9-utils state=present update_cache=true" >/dev/null
echo "tools present."

step "4. Reset any prior reproduction state for a clean run"
a -b -m ansible.builtin.shell \
    -a "systemctl stop named 2>/dev/null || true; rm -f /var/cache/bind/${ZONE}*; echo reset-done" \
    | grep -v '\(WARNING\|interpreter\)' | tail -2

step "5. DEPLOY #1 -- upstream role templates the dynamic zone; named loads it"
ansible-playbook deploy.yml >/dev/null
a -b -m ansible.builtin.command -a "rndc zonestatus ${ZONE}" \
    | grep -E 'serial|dynamic|files|nodes'

step "6. A DDNS client adds a record -> named writes a journal (serial bumps)"
a -b -m ansible.builtin.shell -a "nsupdate <<'EOF'
server 127.0.0.1 53
zone ${ZONE}
update add dynamic.${ZONE}. 600 A 192.0.2.99
send
EOF" >/dev/null
sleep 1
a -b -m ansible.builtin.shell \
    -a "printf 'dynamic.${ZONE} A = '; dig +short @127.0.0.1 dynamic.${ZONE} A; echo '--- journal ---'; named-journalprint ${JOURNAL}" \
    | grep -vE '(WARNING|interpreter)' | grep -E 'dynamic|del|add|SOA'

step "7. named flushes its journal into the zone file (its routine periodic sync)"
echo "This rewrites the master file in named's own format, dropping the role's"
echo "'; Hash:' serial marker. That is the precondition for the bug: with the"
echo "marker gone the role can no longer reuse the old serial and mints a fresh,"
echo "journal-incompatible one on the next deploy.  (In production this flush"
echo "happens on its own via the periodic dump / a restart / a reboot.)"
a -b -m ansible.builtin.command -a "rndc sync ${ZONE}" >/dev/null
a -b -m ansible.builtin.shell \
    -a "printf '; Hash: markers now left in the zone file: '; grep -c '; Hash:' ${ZONEFILE} || true; echo -n 'on-disk serial after sync: '; grep -E '^[[:space:]]*[0-9]+[[:space:]]*; serial' ${ZONEFILE}" \
    | grep -vE '(WARNING|interpreter)' | grep -iE 'Hash|serial'

step "8. DEPLOY #2 -- upstream role re-templates the zone file; journal left behind"
sleep 2   # ensure the fresh epoch serial is strictly greater than the journal's
ansible-playbook deploy.yml >/dev/null
a -b -m ansible.builtin.shell \
    -a "echo 'new on-disk serial:'; grep -E '^[[:space:]]*[0-9]+[[:space:]]*; serial' ${ZONEFILE}; echo 'journal still spans:'; named-journalprint ${JOURNAL} | grep SOA" \
    | grep -vE '(WARNING|interpreter)' | grep -E 'serial|SOA'

step "9. named RESTARTS (reboot / package upgrade) -> zone fails to load"
a -b -m ansible.builtin.systemd -a "name=named state=restarted" >/dev/null
sleep 2

step "RESULT"
set +e
ZS="$(a -b -m ansible.builtin.command -a "rndc zonestatus ${ZONE}" 2>&1 | grep -vE '(WARNING|interpreter)')"
echo "--- rndc zonestatus ${ZONE} ---"
echo "$ZS"
echo "--- named log (journal / load errors) ---"
LOG="$(a -b -m ansible.builtin.shell -a "{ journalctl -u named --no-pager --since '3 min ago' 2>/dev/null; cat /var/cache/bind/data/*.log /var/log/named/*.log 2>/dev/null; } | grep -iE 'journal|out of sync|not loaded' | tail -5" 2>&1 | grep -vE '(WARNING|interpreter|CHANGED|SUCCESS|rc=)')"
echo "$LOG"
echo "--- is ${ZONE} served on the primary now? (expect empty / SERVFAIL) ---"
a -b -m ansible.builtin.shell -a "dig +short @127.0.0.1 ${ZONE} SOA" | grep -vE '(WARNING|interpreter|CHANGED|SUCCESS)'
set -e

echo
if echo "$ZS" | grep -qi 'not loaded'; then
    if echo "$LOG" | grep -qi 'journal out of sync'; then
        echo "REPRODUCED: ${ZONE} failed to load (\"journal out of sync with zone\")."
    else
        echo "REPRODUCED: ${ZONE} is 'not loaded' after the redeploy + restart."
        echo "(Could not capture the exact log line; check 'journalctl -u named' on the VM.)"
    fi
    exit 0
else
    echo "NOT reproduced: the zone still loads. Inspect the output above."
    exit 1
fi
