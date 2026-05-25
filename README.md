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

On the primary the zone then serves nothing; the secondaries keep answering
from their last good transfer and silently go stale — which is what looked like
"DDNS records don't propagate to ns2".

This testcase uses **only** a throwaway BIND9 container and the files in this
folder. It deliberately does **not** touch the project's `playbooks/` or
`inventory/`.

## Requirements

- `docker`, usable by the current user (the image is `internetsystemsconsortium/bind9:9.18`, matching production's BIND 9.18.x).

## Run it

```sh
./reproduce.sh
```

Exit status `0` means the failure was reproduced; the script asserts that the
"journal out of sync with zone" error appeared and that `rndc zonestatus`
reports the zone as not loaded. It cleans up its container on exit.

## Files

| File | Role |
|------|------|
| `reproduce.sh` | Driver: starts the container and walks through the 4 steps below. |
| `named.conf` | Minimal config: one dynamic primary zone (`repro.test`), logging to a readable file. |
| `repro.test.zone.initial` | Zone file as a **first** deploy templates it (serial `1`). |
| `repro.test.zone.redeployed` | Zone file as a **second** deploy re-templates it (fresh serial `2000000000`, dynamic record absent). |

## What the script does (the timeline it recreates)

1. **Deploy #1** — lay down `repro.test.zone` (serial `1`); named loads it.
2. **DDNS update** — an `nsupdate` adds `dynamic.repro.test`; named records the
   change in a journal (`repro.test.zone.jnl`, serial `1 → 2`).
3. **Deploy #2** — overwrite `repro.test.zone` with a fresh, higher serial
   (`2000000000`) and **leave the journal in place**.
4. **Restart named** — on start, BIND tries to roll the leftover journal forward
   onto the new file. The file's serial isn't in the journal's `1 → 2` range, so
   it gives up and refuses to load the zone.

## Why this is the real mechanism (not a contrived edit)

Two non-obvious facts make this happen on every real redeploy of a dynamic zone:

- **The role always mints a fresh serial for a once-updated dynamic zone.** The
  `bodsch.dns.bind` role's serial filter
  (`playbooks/collections/.../plugins/filter/bind.py`, `zone_serial`) reuses the
  previous serial only if it finds its own `; Hash: <sha> <serial>` marker in the
  existing zone file. But when named services a DDNS update it rewrites the
  master file **without** that marker, so the next run cannot match it and falls
  back to `int(time.time())` — a brand-new epoch serial, disjoint from the
  journal. Step 3 models that with a fixed high serial for determinism.
- **A plain `rndc reload` does not detonate it — a *restart* does.** A global
  `rndc reload` will not reload a still-dynamic zone from its master file, so
  right after the deploy the zone still serves the old serial and looks healthy.
  The failure only surfaces on the next `named` restart — a reboot, a package
  upgrade, or an explicit restart — which is exactly what happened in production.
  The script makes step 4 an explicit restart.

## The fix (for reference)

Before re-templating a dynamic zone, either `rndc freeze` it (flushing the
journal into the file) or delete the stale `*.jnl`, then `rndc thaw` / restart
afterwards. See the freeze/thaw + journal-cleanup change discussed in the
investigation; it is the durable prevention.
