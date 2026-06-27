# UPS + Graceful Shutdown — TODO

Goal: keep the cluster + storage enclosure up through brownouts, and shut down cleanly on extended outages so SnapRAID parity and longhorn volumes stay consistent.

## Power audit

| Device | Typical W | Peak W |
|---|---|---|
| 5× Raspberry Pi 5 | 25–50 | 75 |
| TerraMaster D4-320U + 2× 26 TB CMR | 20 | 40 (spin-up) |
| Same w/ 4 drives (future) | 35 | 65 |
| Managed gigabit switch | 10–20 | — |
| Router / modem (if on UPS) | 10–20 | — |
| **Total now** | ~80–110 | ~180 |
| **Total at 4 drives** | ~100–140 | ~220 |

## Hardware

**Buy: CyberPower CP1500PFCLCD** — 1500 VA / 1000 W, pure sine wave, 10 outlets, USB. ~$200.
- Pure sine wave is required for the DAS — simulated sine wave shortens HDD PSU life.
- Expected runtime at ~120 W: 60–80 min.

Outlet plan (4 of 5 battery outlets):
1. Router/modem
2. Managed switch
3. rpi-node4 (storage node) + DAS (via short power strip from one outlet)
4. Power strip → other 4 Pis (their draw is tiny)

Upgrade later (optional): APC Smart-UPS SMT1500 — swappable battery, 10+ year service life, ~$550.

## NUT (Network UPS Tools) integration

- **USB → rpi-node4** (storage node — wants the longest runway).
- rpi-node4: `nut-server` + `upsmon` primary.
- rpi-control, rpi-node1/2/3: `upsmon` secondary, pointing at rpi-node4.
- LOWBATT event → workers shut down first, storage node last.
- Optional pre-shutdown hook: `kubectl cordon + drain` for graceful pod eviction. Not required (k3s recovers fine), but cleaner.

## TODO

### Phase 0 — buy + place
- [ ] Order CP1500PFCLCD
- [ ] Confirm there's a USB-A to USB-B cable in the box (some Cyberpowers ship one, some don't)
- [ ] Physically place: near the storage rack, USB run to rpi-node4
- [ ] Wire outlets per plan above
- [ ] Note serial number and purchase date for warranty + battery replacement reminder (~3 yr)

### Phase 1 — software (NUT)
- [ ] Write `ansible/playbooks/ups-nut.yml`
  - Install `nut-server nut-client` on rpi-node4, `nut-client` on rest
  - Configure `/etc/nut/ups.conf`, `upsd.conf`, `upsmon.conf` per role
  - Set polling driver (likely `usbhid-ups`) and shutdown thresholds
  - Open UDP 3493 on rpi-node4 for secondaries (firewall rule if any)
- [ ] Test: `upsc cyberpower@rpi-node4` from each node — should return battery status
- [ ] Test: pull the UPS plug, watch a node log into `LOWBATT`, confirm chain of shutdowns
- [ ] Optional: add k8s drain hook to upsmon NOTIFYCMD

### Phase 2 — observability
- [ ] Add UPS metrics scraper (nut_exporter for prometheus) — fits the existing grafana-dashboard-rpi-power pattern
- [ ] Dashboard panel: battery %, load W, runtime estimate
- [ ] Alert to ntfy when on battery > 1 min (see [[ntfy-and-matrix]])

## Open questions
- Move modem/router onto UPS? They use ~15 W combined, costs ~10 min runtime. Worth it for the Tailscale-keeps-working benefit during a blip.
- Worth adding a small UPS for the workbench / lab desktop too? Or is that out of scope?

## Notes
- NUT docs: https://networkupstools.org/
- CyberPower NUT driver: `usbhid-ups` works out of the box for CP1500PFCLCD
- Existing power monitoring: `manifests/grafana-dashboard-rpi-power.yaml` — extend rather than duplicate
- SnapRAID parity calc runs nightly on rpi-node4 (per `manifests/tank-storage.yaml` header) — make sure shutdown doesn't kill it mid-run; either schedule parity earlier or have upsmon abort it cleanly
