<!--
Copyright 2026 Buo-ren Lin (OSSII) <buoren.lin@ossii.com.tw>
SPDX-License-Identifier: AGPL-3.0-or-later
-->
# Minimal reproduction: dynamic zone fails to reload after re-deployment

A self-contained reproduction of the bug investigated in
[`../name-resolution-failure-investigation.md`](../name-resolution-failure-investigation.md):
a BIND **dynamic** zone stops loading after a service re-deployment, with

```
zoneload: error: zone <zone>/IN: journal rollforward failed: journal out of sync with zone
zoneload: error: zone <zone>/IN: not loaded due to errors.
```

On the primary the zone then serves nothing; secondaries keep answering from
their last good transfer and silently go stale — which is what looked like
"DDNS records don't propagate to ns2".

This testcase reproduces the failure with the **unmodified upstream
`bodsch.dns.bind` role** (installed from Ansible Galaxy) inside its own
single-VM **Vagrant** environment. It does not use the parent project's
`playbooks/` or `inventory/`.

## Requirements

- VirtualBox + Vagrant (the box is `bento/debian-12`, matching the parent project).
- `ansible` / `ansible-galaxy`.
- `sshpass` (for the Vagrant `vagrant`/`vagrant` password login).

## Run it

```sh
./reproduce.sh
```

Exit status `0` means the failure was reproduced: the script asserts that
`rndc zonestatus` reports the zone as *not loaded* and (best-effort) shows the
`journal out of sync with zone` log line. It is re-runnable — step 3 resets the
zone state on the VM each time. Tear the VM down with `vagrant destroy -f` when
finished.

## Files

| File | Role |
|------|------|
| `Vagrantfile` | One Debian 12 VM (`192.168.56.30`), the authoritative primary. |
| `requirements.yml` | The upstream role under test: `bodsch.dns` `1.4.1` (same as the parent project). |
| `inventory.yml` | One host + a single **dynamic** primary zone `repro.test` (the role's variable interface, this testcase's own values). |
| `deploy.yml` | A minimal "deployment" that just imports `bodsch.dns.bind` and `rndc reload`s — the shape of the real deploy, with no freeze/thaw or journal cleanup. |
| `reproduce.sh` | Driver: brings up the VM and walks the steps below, asserting the failure. |
| `ansible.cfg` | Points Ansible at `inventory.yml` and the Galaxy-installed role in `./collections`. |

## What the script does (the timeline it recreates)

1. **Deploy #1** — the role templates `repro.test` (epoch serial, e.g. `…308`);
   named loads it.
2. **DDNS update** — an `nsupdate` adds `dynamic.repro.test`; named records it in
   a journal (`repro.test.jnl`, serial `…308 → …309`). The master *file* on disk
   is untouched for now (named keeps the change only in the journal).
3. **named flushes the journal to the file** (`rndc sync`) — this is the crux.
   named rewrites the master file in its own format, which **drops the role's
   `; Hash:` serial marker**. In production this flush happens on its own (the
   periodic zone dump, a restart, or a reboot).
4. **Deploy #2** — the role no longer finds its `; Hash:` marker, so it cannot
   reuse the old serial and mints a fresh `int(time.time())` serial (e.g.
   `…32x`). The leftover journal still only spans `…308 → …309`.
5. **Restart named** — on start it tries to roll the journal forward onto the
   new file; the file's serial isn't in the journal's range, so it gives up and
   refuses to load the zone.

## Why this is the real mechanism

Two non-obvious facts, both demonstrated by the script:

- **A once-synced dynamic zone gets a fresh, journal-incompatible serial on
  every redeploy.** The role's serial filter
  (`bodsch.dns/.../plugins/filter/bind.py`, `zone_serial`) reuses the previous
  serial only if it finds its own `; Hash: <sha> <serial>` marker in the existing
  file. Once named has rewritten that file (step 3), the marker is gone, so the
  role falls back to `int(time.time())` — a serial that does not line up with the
  journal. **Step 3 is required**: redeploying *before* any sync simply reuses
  the old serial and the zone keeps loading (this was the first thing that
  tripped up the reproduction).
- **A plain `rndc reload` does not detonate it — a *restart* does.** A global
  `rndc reload` won't reload a still-dynamic zone from its master file, so right
  after deploy #2 the zone still serves the old serial and looks healthy. The
  failure only surfaces on the next `named` restart — a reboot, a package
  upgrade, or an explicit restart. Step 5 makes that restart explicit.

## The fix (for reference)

Before re-templating a dynamic zone, either `rndc freeze` it (which flushes the
journal into the file and suspends updates) or delete the stale `*.jnl`, then
`rndc thaw` / reload afterwards — wrapped so a mid-deploy failure never leaves a
zone frozen. That freeze/thaw + journal-cleanup change is the durable
prevention discussed in the investigation.
