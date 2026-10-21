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

**Option A — own Spotify developer app (recommended; also needed for Phase 2)**
- [ ] developer.spotify.com/dashboard → Create app
  - Name `Homelab`, redirect URI `http://127.0.0.1:8888/callback`, tick **Web API**
- [ ] Send Claude the **Client ID** (not the secret)
- [ ] Put the **Client Secret** in a k8s Secret, never git/chat:
  `kubectl -n lidarr create secret generic spotify --from-literal=client-id=... --from-literal=client-secret=...`
- [ ] One-time Spotify sign-in (Claude provides the link) → refresh token stored in the same Secret
- [ ] Claude writes `manifests/spotify-lidarr-sync.yaml`: CronJob every few hours that reads followed artists + saved albums + playlist artists and adds them to Lidarr via its API (monitor: latest album, so back catalogs don't flood the drive)

**Option B — Last.fm (no developer app, but only learns from future plays)**
- [ ] Make a Last.fm account; connect it in Spotify → Settings → Apps → Last.fm
- [ ] Add a **Last.fm User** import list in Lidarr with the username (top artists)

### Phase 2 — playlists in Jellyfin (needs Option A's app)
- [ ] Install the Jellyfin **Spotify Import** plugin; give it the Client ID/secret
- [ ] Pick playlists to mirror; schedule re-sync
- [ ] Check matches in Finamp (playlists only fill in once Lidarr has downloaded those artists)

## Limits to remember
- Lidarr works by **artist/album**, not single songs — a playlist of one-off tracks pulls those artists' albums.
- Spotify's own recommendations (Discover Weekly, radio) don't come over — use Jellyfin's **Instant Mix** for radio.
- Only one music indexer in Prowlarr today (The Pirate Bay); add more if searches come up empty.
