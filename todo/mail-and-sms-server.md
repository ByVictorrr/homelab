# Mail + SMS Server — TODO

Goal: self-host email and SMS-style messaging on the Pi cluster using the **cheapest viable services**.

## Cheapest stack

### Email
| Piece | Pick | Cost |
|---|---|---|
| Domain | Cloudflare-registered `.com` (at-cost) | ~$10/yr |
| Mail server (on cluster) | **Stalwart** (single Go-ish binary, ARM-friendly, IMAP+SMTP+JMAP+webmail in one) | $0 |
| Outbound relay | **SMTP2GO free tier** — 1,000 emails/mo, no card required | $0 |
| Fallback relay (if you outgrow free) | **AWS SES** — $0.10 per 1,000 emails | ~pennies/mo |
| Inbound | Direct MX → Pi over Tailscale Funnel **or** port-forward 25/465/993 | $0 |

Skip Mailcow (heavier, less ARM-clean) and Mail-in-a-Box (Ubuntu-specific).

### SMS / push-to-phone
| Piece | Pick | Cost |
|---|---|---|
| Real SMS | **Telnyx** — $1/mo number + ~$0.004/SMS (cheaper than Twilio's $0.0079) | ~$1/mo |
| Free alternative if "text me" really means "ping my phone" | **ntfy.sh self-hosted** on the cluster + phone app | $0 |
| Group/family chat | **Matrix (Synapse)** on cluster | $0 |

Recommendation: start with **self-hosted ntfy** ($0). Only add Telnyx if you actually need carrier SMS (e.g. 2FA codes out, alerts to non-app users).

## TODO

### Phase 0 — decide
- [ ] Pick a domain (or reuse `bluebuck-micro.ts.net` style — but Tailscale domains can't receive public mail; need a real domain for email)
- [ ] Confirm: do you need real SMS, or is ntfy/Matrix enough?

### Phase 1 — email receive + send via relay
- [ ] Register domain at Cloudflare (~$10/yr)
- [ ] Add DNS: MX → mail.<domain>, A/AAAA → Pi public IP or Tailscale
- [ ] Create SMTP2GO account, verify domain, grab SPF/DKIM records
- [ ] Add SPF, DKIM, DMARC records in Cloudflare
- [ ] Write `manifests/stalwart.yaml` (style-match existing manifests in repo)
  - PVC for mail store on tank/bulk tier
  - Configure outbound to relay via SMTP2GO
  - TLS via cert-manager / existing ingress pattern
- [ ] Test: send to gmail, check it lands in inbox (not spam)
- [ ] Test: receive from gmail

### Phase 2 — phone notifications (free path)
- [ ] Write `manifests/ntfy.yaml`
- [ ] Install ntfy Android/iOS app, subscribe to topic
- [ ] Wire Home Assistant alerts to ntfy

### Phase 3 — real SMS (only if Phase 2 isn't enough)
- [ ] Telnyx account, buy number (~$1)
- [ ] Add Telnyx webhook → small service on cluster
- [ ] Optional: bridge SMS into Matrix (mautrix-gmessages / mautrix-twilio-style)

## Open questions
- Public IP available on the cluster, or everything goes through Tailscale Funnel?
- Existing ingress/TLS setup — what cert issuer is already wired up?
- Mail storage tier — tank (cold), or the SSD tier?

## Notes
- Residential ISPs almost universally block port 25 outbound → the relay is non-negotiable for sending.
- DKIM/SPF/DMARC must be set BEFORE sending the first mail or your domain reputation starts in the hole.
- Stalwart docs: https://stalw.art
- SMTP2GO free tier: https://www.smtp2go.com/pricing/
- ntfy: https://ntfy.sh
