# Spotify → Lidarr / Jellyfin music sync — TODO

Goal: what you follow / save / playlist on Spotify shows up automatically in Jellyfin Music (and the Finamp app), without searching for each song.

## Where things stand (2026-10-21)

- **Lidarr** (`manifests/lidarr.yaml`) → qBittorrent (VPN) → `/mnt/tank/media/music` → Jellyfin **Music** library. Working.
- **Ombi** (`manifests/ombi.yaml`) — family request music with their Jellyfin login, auto-approved into Lidarr. Working.
- **Lidarr's built-in Spotify import lists are broken**: sign-in goes through `spotify.lidarr.audio` (hosted by the Lidarr project), which returns "Internal server error". Not fixable on our side.

## TODO

### Phase 0 — housekeeping
- [ ] Create a login in Lidarr (Settings → General → Authentication) — it's open to the tailnet until then
- [ ] Delete the `auth.json` that the failed Spotify sign-in downloaded (may hold a token)

### Phase 1 — pick a route

> **2026-10-21:** the Spotify dashboard shows no "Create app" button. Since Feb 2026
> Spotify requires Premium for Development Mode apps (one app per developer,
> 5 users) and paused new apps for a while
> ([announcement](https://developer.spotify.com/blog/2026-02-06-update-on-developer-access-and-platform-security)).
> Option A is blocked unless that changes, so the plan is now **Option C + Option B**.

**Option C — Exportify one-time import (no developer app)**
- [ ] exportify.app → sign in with Spotify → export playlists + Liked Songs as CSV
- [ ] Put the CSVs on the pool (e.g. via Nextcloud) and tell Claude where
- [ ] Claude reads the artists from the CSVs and bulk-adds them to Lidarr (monitor: latest album)

**Option A — own Spotify developer app (blocked, see note above; also needed for Phase 2)**
- [ ] developer.spotify.com/dashboard → Create app
  - Name `Homelab`, redirect URI `http://127.0.0.1:8888/callback`, tick **Web API**
- [ ] Send Claude the **Client ID** (not the secret)
- [ ] Put the **Client Secret** in a k8s Secret, never git/chat:
  `kubectl -n lidarr create secret generic spotify --from-literal=client-id=... --from-literal=client-secret=...`
- [ ] One-time Spotify sign-in (Claude provides the link) → refresh token stored in the same Secret
- [ ] Claude writes `manifests/spotify-lidarr-sync.yaml`: CronJob every few hours that reads followed artists + saved albums + playlist artists and adds them to Lidarr via its API (monitor: latest album, so back catalogs don't flood the drive)

**Option B — Last.fm ongoing sync (no developer app; only learns from future plays)**
- [ ] Make a Last.fm account; connect it in Spotify → Settings → Apps → Last.fm
- [ ] Add a **Last.fm User** import list in Lidarr with the username (top artists)

### Phase 2 — playlists in Jellyfin (needs Option A's app; blocked for now)
- [ ] Install the Jellyfin **Spotify Import** plugin; give it the Client ID/secret
- [ ] Pick playlists to mirror; schedule re-sync
- [ ] Check matches in Finamp (playlists only fill in once Lidarr has downloaded those artists)

## Limits to remember
- Lidarr works by **artist/album**, not single songs — a playlist of one-off tracks pulls those artists' albums.
- Spotify's own recommendations (Discover Weekly, radio) don't come over — use Jellyfin's **Instant Mix** for radio.
- Only one music indexer in Prowlarr today (The Pirate Bay); add more if searches come up empty.
