# ntfy + Matrix on the Pi cluster — TODO

Goal: push notifications to phone (ntfy) + self-hosted chat (Matrix). Both free, both ARM-clean.

Email and carrier SMS deferred — Fastmail/Proton on a custom domain wins for personal use, and ntfy covers all "alert me" use cases.

## ntfy (phone push)

### What it gets you
- Frigate → "person at front door" push
- Home Assistant → any automation can push
- Immich / backup jobs → failure alerts
- claude-worker / trialday-builder → job status pings
- Free, no account, end-to-end optional, Android + iOS apps

### TODO
- [ ] Write `manifests/ntfy.yaml` (match existing manifest style — bjw-s pattern where applicable)
  - Stateless service, small PVC for message cache + ACL db
  - Expose via existing ingress (Authelia-protected? or public topic with hard-to-guess name?)
  - Optional: behind Tailscale only — simplest, no public exposure
- [ ] Decide auth model: public topics with obscure names vs. ntfy ACL with users
- [ ] Install ntfy app on phone, subscribe to topics
- [ ] Wire Home Assistant: REST notify platform → ntfy
- [ ] Wire Frigate: notification config → ntfy webhook
- [ ] Document topic naming in `docs/`

## Matrix (chat)

### What it gets you
- Family/personal chat that survives Meta/Discord enshittification
- Bridges to Signal / WhatsApp / iMessage / Discord if you want
- Bots can post to rooms (alternative pattern to ntfy for richer alerts)

### Server choice
- **Synapse** — reference impl, Python, heavy. Works on Pi but RAM-hungry.
- **Dendrite** — Go, lighter, ARM-friendly, federation still maturing.
- **Conduit/conduwuit** — Rust, lightest, single-binary. Best for a Pi cluster, federation works.

Recommend **Conduit/conduwuit** for resource cost on Pi hardware. Pick Synapse only if you specifically need a bridge that only ships for Synapse.

### TODO
- [ ] Pick server (recommend conduwuit)
- [ ] Domain decision — Matrix needs a server-name domain (e.g. `matrix.<yourdomain>`) for federation. Tailscale-only works if you don't care about federating with matrix.org users.
- [ ] Write `manifests/matrix.yaml`
  - PVC for media + state on tank tier
  - TLS / ingress
  - Well-known delegation file if federating
- [ ] Pick client: Element (Web/Android/iOS) is default
- [ ] Create admin account, invite family
- [ ] Optional bridges (mautrix-signal, mautrix-discord) — separate manifests later

## Open questions
- Public exposure or Tailscale-only for each?
- Existing ingress + cert-manager setup — what's the pattern in the repo?
- Storage tier for Matrix media (can grow fast with image/video sharing)

## Notes
- ntfy: https://ntfy.sh
- conduwuit: https://conduwuit.puppyirl.gay/
- Synapse: https://element-hq.github.io/synapse/
- Element client: https://element.io
