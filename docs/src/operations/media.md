# Media

The media stack runs in one namespace, `media`, from `kubernetes/apps/media/` under its own
Flux Kustomization (`clusters/main/media.yaml`). Everything is pinned to rem-4, because
everything mounts the one ZFS dataset that holds the library. Why the node and the pool look
the way they do is in [Decisions → Media Node](../decisions/media-node.md); running the pool
is [Storage (ZFS)](./zfs.md). Versions of the pieces Renovate tracks through a chart are in
[Reference → Versions](../reference/versions.md); app images are tracked in their manifests.

## What runs

| App | Hostname | Does |
| --- | --- | --- |
| Jellyfin | `jellyfin.lilstrudel.io` | Plays movies, TV and anime; QSV transcoding on the Arc A40 |
| Seerr | `seerr.lilstrudel.io` | Requests, approved into Sonarr and Radarr |
| Shoko | `shoko.lilstrudel.io` | AniDB metadata for the anime folders, served to Jellyfin by Shokofin |
| Sonarr | `sonarr.lilstrudel.io` | TV and anime series |
| Radarr | `radarr.lilstrudel.io` | Movies and anime movies |
| Prowlarr | `prowlarr.lilstrudel.io` | Indexers, synced into Sonarr and Radarr |
| Bazarr | `bazarr.lilstrudel.io` | Subtitles, written next to the media |
| Recyclarr | — (CronJob) | Syncs TRaSH quality profiles, custom formats and naming daily |
| qBittorrent | `qbittorrent.lilstrudel.io` | Torrents, only through Mullvad |
| SABnzbd | `sabnzbd.lilstrudel.io` | Usenet, off the VPN |
| Byparr | — (in-cluster) | Cloudflare solver for Prowlarr, Shelfmark and Suwayomi (FlareSolverr API) |
| qbit_manage | `qbit-manage.lilstrudel.io` | Torrent tagging, share limits, orphan cleanup |
| Cleanuparr | `cleanuparr.lilstrudel.io` | Removes stalled, fake and malicious downloads from the arr queues |
| Kavita | `kavita.lilstrudel.io` | Manga, webtoons and ebooks |
| Komf | — (in-cluster) | Kavita metadata from MangaUpdates, AniList, MangaDex and Webtoons |
| Audiobookshelf | `audiobookshelf.lilstrudel.io` | Audiobooks and podcasts |
| Shelfmark | `shelfmark.lilstrudel.io` | Ebook and audiobook search and downloads |
| Suwayomi | `suwayomi.lilstrudel.io` | Manga and webtoon sources; downloads CBZs for Kavita |
| Jellystat | `jellystat.lilstrudel.io` | Jellyfin watch history and stats, on its own CNPG cluster |

Every hostname is internal: a pinned IP in the `10.69.65.50`–`.65` media band in
`local.services`, reachable from the Home VLAN and WireGuard.

## The library: one dataset

All media and all downloads live on one PVC, `media-data`, on the `zfs-shared` class. It has
to be one dataset, because hardlinks and atomic moves do not cross filesystems, and a ZFS
dataset is a filesystem. Do not split it into child datasets.

```
/data
├── torrents/{movies,tv,anime,anime-movies,books,audiobooks}
├── usenet/{incomplete,complete/{movies,tv,anime,anime-movies,books,audiobooks}}
└── media/{movies,tv,anime,anime-movies,audiobooks,podcasts,books,manga,comics}
```

The tree is created by `layout-configmap.yaml`, which a `layout` init container runs in every
pod that mounts a subdirectory. Without it the kubelet creates a missing `subPath` as root,
and the non-root app cannot write into it. To add a category, add it there.

Every pod sees the library at the **same path**, `/data/...`. Hardlinks need the source and
the destination visible in one mount inside one container, and Shokofin's symlinks point at
paths Jellyfin must resolve.

| Pod | Sees | Mode |
| --- | --- | --- |
| sonarr, radarr, bazarr, shelfmark | `/data` | read-write |
| qbittorrent, qbit-manage | `/data/torrents` | read-write |
| sabnzbd | `/data/usenet` | read-write |
| jellyfin, shoko | `/data` | read-only |
| kavita | `/data/media` | read-only |
| audiobookshelf | `/data/media` | read-write (podcast downloads) |
| suwayomi | `/data/media/manga` (as its downloads folder) | read-write |

App configuration lives on per-app PVCs on the `zfs` class, opted into Velero. `/data` is
deliberately not backed up; see [Decisions → Media Node](../decisions/media-node.md).

## Secrets

| Secret | Holds | Source |
| --- | --- | --- |
| `media-api-keys` (`api-keys.sops.yaml`) | Sonarr, Radarr, Prowlarr and SABnzbd API keys | Generated; the apps read them from env at start, so the keys are known before first run |
| `gluetun` (`qbittorrent/gluetun.sops.yaml`) | Mullvad WireGuard private key and tunnel address, not the account number | mullvad.net → Downloads → WireGuard configuration → Generate key; take `PrivateKey` and the IPv4 half of `Address` from the downloaded `.conf`, then delete it |
| `suwayomi` | Login for the Suwayomi UI | Generated; read it with `sops -d` |
| `komf` | Kavita API key | Kavita → User settings → API key, after Kavita's first start |
| `jellystat` | `JWT_SECRET` | Generated |
| `jellystat-pg-backup` | S3 credentials for barman | `terraform output -json cnpg_access_key_ids` / `cnpg_secret_access_keys`, key `jellystat` |

Fill a placeholder without writing plaintext to disk:

```bash
sops set kubernetes/apps/media/qbittorrent/gluetun.sops.yaml '["stringData"]["WIREGUARD_PRIVATE_KEY"]' '"<KEY>"'
sops set kubernetes/apps/media/qbittorrent/gluetun.sops.yaml '["stringData"]["WIREGUARD_ADDRESSES"]' '"<ADDRESS>/32"'
sops set kubernetes/apps/media/jellystat/postgres-backup-secret.sops.yaml '["stringData"]["ACCESS_KEY_ID"]' \
  "\"$(terraform -chdir=terraform output -json cnpg_access_key_ids | jq -r .jellystat)\""
sops set kubernetes/apps/media/jellystat/postgres-backup-secret.sops.yaml '["stringData"]["ACCESS_SECRET_KEY"]' \
  "\"$(terraform -chdir=terraform output -json cnpg_secret_access_keys | jq -r .jellystat)\""
```

## The VPN

qBittorrent's pod carries gluetun as a native sidecar (an init container with
`restartPolicy: Always`), so the tunnel is up before qBittorrent starts and stays up for the
pod's life. Four layers keep torrent traffic in the tunnel:

1. gluetun's firewall drops anything on `eth0` that is not the WireGuard handshake, apart
   from replies to the web UI port.
2. The pod's `CiliumNetworkPolicy` allows **only UDP 51820** out to public addresses. There
   is no rule for kube-dns.
3. The pod's DNS is `127.0.0.1`, which is gluetun's resolver, so no lookup leaves outside the
   tunnel.
4. qBittorrent is bound to `wg0`, the name gluetun is told to give its interface with
   `VPN_INTERFACE` (its own default is `tun0`). The `configure` init container sets the
   binding on every start,
   along with the default save path. It also turns off the image's default auth bypass for
   10.0.0.0/8: every request through the Ingress arrives from the pod CIDR, so the bypass
   would mean no login at all.

SABnzbd and Prowlarr stay off the VPN. Usenet runs over TLS to the provider, and indexers
are better reached from the home address than from a shared VPN exit.

**Mullvad has no port forwarding**, so qBittorrent cannot accept incoming peers. That is
fine for public trackers. On private trackers, where ratio depends on being connectable,
switch providers: in the gluetun container set `VPN_SERVICE_PROVIDER=protonvpn`,
`VPN_PORT_FORWARDING=on`, `PORT_FORWARD_ONLY=on`, and
`VPN_PORT_FORWARDING_UP_COMMAND` to a `wget` that posts `{"listen_port":{{PORT}}}` to
`http://127.0.0.1:8080/api/v2/app/setPreferences`. Proton's credentials replace the
Mullvad key in `gluetun.sops.yaml`. Nothing else changes.

Check it after any change:

```bash
kubectl -n media logs deploy/qbittorrent -c gluetun | grep -i "public ip"
kubectl -n media exec deploy/qbittorrent -c gluetun -- wget -qO- https://am.i.mullvad.net/json
```

Load a torrent-IP check (for example ipleak.net's magnet) in qBittorrent and confirm only
the Mullvad address appears.

## Quality profiles

Recyclarr (`recyclarr/configmap.yaml`) syncs TRaSH profiles every night at 04:00, plus
TRaSH naming for Jellyfin. The profile is chosen per title, so "default" and "max" sit side
by side:

| Instance | Profile | Use for |
| --- | --- | --- |
| Sonarr | WEB-1080p | Default for TV |
| Sonarr | WEB-2160p | TV worth 4K |
| Sonarr | Anime 1080p | Default for anime: TRaSH's anime scoring, without remuxes |
| Sonarr | [Anime] Remux-1080p | Anime worth full quality (Demon Slayer, and so on) |
| Radarr | HD Bluray + WEB | Default for movies |
| Radarr | UHD Bluray + WEB | Movies worth 4K |
| Radarr | Remux + WEB 2160p | Full quality (Spider-Verse, Ghibli, and so on) |
| Radarr | [Anime] Remux-1080p | Anime movies |

Pick the profile in Seerr's request approval (the admin can override profile and root
folder), or change it on the series or movie in Sonarr or Radarr. Do not add the same Sonarr
or Radarr to Seerr a second time as a "4K server". Seerr then tracks availability twice and
gets it wrong.

Sonarr uses TRaSH's **anime** quality definition, not the series one. Quality definitions
are per instance, and the series floor for Bluray-1080p (50 MB per minute) rejects the
small encodes that "Anime 1080p" exists for.

Sonarr is held below v5 in `renovate.json` because Recyclarr cannot sync v5's quality
definitions yet (recyclarr#988). Lift the bound when that is fixed.

## First-run wiring

Do this once, in order, after the first reconcile.

1. **qBittorrent.** The first start prints a temporary admin password in the log
   (`kubectl -n media logs deploy/qbittorrent -c qbittorrent`). Set a real one. Then
   Options → Downloads: keep *Default Torrent Management Mode* on Automatic and turn on
   *Append .!qB extension to incomplete files*. Under BitTorrent, remove seeding limits:
   qbit_manage owns them. The categories (`tv`, `anime`, `movies`, `anime-movies`, `books`,
   `audiobooks`) save into `/data/torrents/<category>`.
2. **SABnzbd.** Add the Usenet provider (SSL, port 563). Folders: temporary
   `/data/usenet/incomplete`, completed `/data/usenet/complete`. Categories as above. Turn
   off all Sorting. Set a username and password: SABnzbd treats the pod CIDR as local, so
   without one the UI is open.
3. **Prowlarr.** Add indexers. Settings → Indexers → add a FlareSolverr proxy at
   `http://byparr:8191`, tagged, and tag only the indexers that need it. Apps → add Sonarr
   (`http://sonarr:8989`) and Radarr (`http://radarr:7878`) with the keys from
   `media-api-keys`, and set Prowlarr's own server as `http://prowlarr:9696`. Add
   qBittorrent and SABnzbd as download clients if you search from Prowlarr.
4. **Sonarr.** Root folders `/data/media/tv` and `/data/media/anime`. Download clients:
   qBittorrent at `qbittorrent:8080` with category `tv`, and a second one with category
   `anime` restricted to the `anime` tag; SABnzbd at `sabnzbd:8080` likewise. Media
   Management: *Use Hardlinks instead of Copy* on. Anime series are added with Series Type
   **Anime**. Connect → Jellyfin at `http://jellyfin:8096`.
5. **Radarr.** The same, with `/data/media/movies` and `/data/media/anime-movies` and
   categories `movies` / `anime-movies`.
6. **Recyclarr.** Run it once now instead of waiting for the night:
   `kubectl -n media create job --from=cronjob/recyclarr recyclarr-manual`.
7. **Bazarr.** Connect Sonarr and Radarr by service name. Add providers. For anime, prefer
   the release's own subtitles; Bazarr is mostly for movies and TV.
8. **Shoko.** Run the first-start wizard and log in to AniDB. Add import folders
   `/data/media/anime` and `/data/media/anime-movies` as **Watch** folders, never drop
   source or destination. Shoko must not move files: Sonarr owns the layout, and a move
   would break its tracking and the torrent hardlinks. Create an API user for Jellyfin.
9. **Jellyfin.** Run the wizard, then add the plugin repositories below and install the
   plugins. Libraries:
   - *Movies* on `/data/media/movies` and *Shows* on `/data/media/tv`.
   - Anime on `/data/media/anime` and `/data/media/anime-movies`, as *Shows* and *Movies*
     libraries with **Shokofin** as the metadata provider and its virtual file system on.
     Turn NFO savers off.
   - Dashboard → Networking → *Known proxies* `10.244.0.0/16`, *LAN networks* `10.69.0.0/16`.
   - Playback → Transcoding: see [Transcoding](#transcoding).
10. **Seerr.** Sign in with Jellyfin at `http://jellyfin:8096`. Add Sonarr with the anime
    root folder and the Anime 1080p profile set as its anime defaults, and Radarr.
11. **Kavita.** Create libraries: *Manga* on `/data/media/manga/mangas` (Suwayomi's tree,
    one folder per source) and *Book* on `/data/media/books`. Webtoons go in the Manga
    library and use the Webtoon reading mode. Create an API key and put it in the `komf`
    secret (see [Secrets](#secrets)).
12. **Audiobookshelf.** Libraries on `/data/media/audiobooks` and a Podcast library on
    `/data/media/podcasts`.
13. **Suwayomi.** Log in with the `suwayomi` secret. The Keiyoushi extension store is
    preconfigured. Add sources, and add series to the library to have them downloaded.
14. **Shelfmark.** Settings → add Prowlarr, qBittorrent (category `books` or `audiobooks`)
    and SABnzbd. Books land in `/data/media/books`, audiobooks in `/data/media/audiobooks`.
15. **qbit_manage.** In its web UI, write `config.yml`: qBittorrent at `qbittorrent:8080`
    with its login, `root_dir: /data/torrents`, the share limits, and the recycle bin.
    It starts with `QBT_DRY_RUN=true`. Read a few runs' logs, then set it to `false` in
    `qbit-manage/deployment.yaml`.
16. **Cleanuparr.** Connect qBittorrent, Sonarr and Radarr. Turn on the queue cleaner and
    the malware blocker. Leave its **download cleaner off**: qbit_manage owns seeding
    limits and cleanup, and two tools deleting torrents disagree.
17. **Jellystat.** Create the admin account, then connect Jellyfin at
    `http://jellyfin:8096` with an API key from Jellyfin.

## Jellyfin plugins

Plugins install from the UI (Dashboard → Plugins → Repositories) and live in the config
PVC.

| Plugin | Repository | Why |
| --- | --- | --- |
| Shokofin | `https://raw.githubusercontent.com/ShokoAnime/Shokofin/metadata/dev/manifest.json` | AniDB metadata from Shoko. The **dev** channel, because only dev builds support current Jellyfin |
| Intro Skipper | `https://intro-skipper.org/manifest.json` | Detects intros and credits into Jellyfin's Media Segments, which clients show as skip buttons |
| Jellyfin Enhanced | `https://raw.githubusercontent.com/n00bcodr/jellyfin-plugins/main/manifest.json` | UI additions, including Seerr search inside Jellyfin |
| Playback Reporting | official | Per-user playback history |
| OpenSubtitles | official | Subtitle search for non-anime |
| AniList | official | Fallback anime metadata for anything Shoko does not match |
| Webhook | official | Notifications |

Two plugins to leave out:

- **AniDB.** Shoko already talks to AniDB from this WAN address. AniDB rate-limits and
  bans by IP, and a second client makes bans far more likely.
- **Jellyscrub.** Trickplay is built in.

Shokofin and Shoko are coupled. Shokofin dev builds support stable Shoko Server until
Shoko's next major. A major of Jellyfin breaks plugin ABIs. Both images need dashboard
approval for majors in `renovate.json`; upgrade them together.

## Transcoding

Settings (Dashboard → Playback → Transcoding):

- Hardware acceleration **Intel QuickSync (QSV)**, device `/dev/dri/renderD128`.
- Hardware decoding for H.264, HEVC, HEVC 10-bit, HEVC RExt, VP9 and AV1.
- **Low-power H.264 and HEVC encoders on.** DG2 only encodes in low-power mode.
- HEVC encoding allowed; AV1 encoding off. The Shield and older Android devices cannot
  decode AV1, so an AV1 transcode would itself need transcoding.
- Tone mapping on. Compare VPP and OpenCL in the benchmark below.
- Throttle transcodes and delete segments on. Segments live in `/cache/transcodes`, a
  size-limited `emptyDir`.

Most transcodes of anime are caused by subtitles, not codecs. Clients that render ASS
themselves direct-play: Jellyfin Media Player, the web client, Kodi with JellyCon, and mpv
or Findroid on Android. The official Android TV app burns ASS in, which forces a transcode.
libass renders on the CPU even when the overlay and encode run on the GPU.

### Benchmark

This is how the transcoding decision in
[Decisions → Media Node](../decisions/media-node.md#transcoding) is measured. Re-run it after
a Jellyfin major, a driver change, or a change in clients.

1. **Driver chain.** In the Jellyfin pod:
   ```bash
   kubectl -n media exec deploy/jellyfin -- /usr/lib/jellyfin-ffmpeg/vainfo --display drm --device /dev/dri/renderD128
   ```
   Expect the iHD driver and `VAEntrypointEncSliceLP` for H.264, HEVC and AV1.
2. **Test files**, from the real library:
   - A: 1080p HEVC 10-bit anime with heavy ASS typesetting, to 1080p H.264 with burn-in.
   - B: 4K HDR10 HEVC, to 1080p SDR (tone-mapped).
   - C: 1080p H.264, to 720p at 4 Mbps (a phone on a weak link).
   - D: Dolby Vision profile 5 or 8, if the library has any.
3. **Capture real commands.** Start each case once from a client forced to transcode.
   Copy its command line from `/config/log/FFmpeg.Transcode-*.log`, which carries
   Jellyfin's real filter graph.
4. **Find the ceiling.** Change each command's output to `-t 120 -f null -` and add
   `-benchmark`. Run N copies in parallel inside the pod for N = 1, 2, 3, 4, 6, 8. For each,
   record every process's `speed=`, its CPU from `top`, and the GPU engines from
   `intel_gpu_top` (in a debug pod:
   `kubectl debug node/rem-4 -it --profile sysadmin --image=alpine`, then
   `apk add igt-gpu-tools`). The ceiling is the N where the slowest copy drops below
   1.0×; 1.2× is the sustainable level, which leaves room for seeking. Also run a mix of
   two A plus one B.
5. **Live check.** Three real sessions at once: Android TV playing ASS anime, a phone at a
   forced low bitrate, and a 4K HDR title in a browser. Watch Dashboard → Active Devices
   for the transcode reasons and the client's playback info for the transcode rate. Seek a
   few times. Play for more than 15 minutes through the Ingress to rule out a proxy
   timeout.
6. **Record** the numbers in [Decisions → Media Node](../decisions/media-node.md#transcoding).

## Troubleshooting

Policy drops are the most likely reason something cannot reach something else. Each Cilium
agent only sees its own node's flows, so watch them from the agent on rem-4:

```bash
AGENT=$(kubectl -n kube-system get pod -l k8s-app=cilium --field-selector spec.nodeName=rem-4 -o name)
kubectl -n kube-system exec "$AGENT" -- hubble observe --namespace media --verdict DROPPED -f
```

A drop to a public FQDN means the app's `toFQDNs` list is missing a name. A drop between
two media apps means the edge is missing from both sides' policies; each policy lists who
may call it and whom it may call.

A pod stuck in `ContainerCreating` with `device already mounted` is a volume from the `zfs`
class mounted twice; only `zfs-shared` volumes can be shared. See
[Storage (ZFS)](./zfs.md#what-you-can-claim).

Recyclarr skips an instance whose config fails validation and says why only at debug
level, so a run that logs nothing for Sonarr or Radarr is a config error. Rerun it with
debug output and look for `Invalid instances`:

```bash
kubectl -n media get cronjob recyclarr -o json \
  | jq '{apiVersion:"batch/v1",kind:"Job",metadata:{name:"recyclarr-debug",namespace:"media"},spec:(.spec.jobTemplate.spec | .template.spec.containers[0].args=["sync","--log","debug"])}' \
  | kubectl apply -f -
kubectl -n media logs -f job/recyclarr-debug | grep -A1 'Invalid instances'
kubectl -n media delete job recyclarr-debug
```

gluetun refuses to start on a server filter it does not recognise, and logs the valid
choices. Mullvad's US cities carry their state (`Denver CO`).

Shoko checks four internet endpoints (1.1.1.1, msftconnecttest.com, detectportal.firefox.com
and wechat.com) before it will contact AniDB, and with none reachable it logs "No internet,
so not sending AniDB request". All four are in its network policy for that reason; drop one
and Shoko reports only partial internet.

qbit_manage refuses to run against a qBittorrent newer than its release was tested with,
and logs "qbit_manage is only compatible with v… or lower". `QBT_SKIP_QB_VERSION_CHECK` in
`qbit-manage/deployment.yaml` bypasses that while qBittorrent is one patch release ahead
(5.2.4 against qbit_manage 4.13.0, whose develop branch already supports it). Remove it
once a qbit_manage release lists the running qBittorrent version.

If gluetun's container restarts on its own (an OOM kill, say), it cannot bring the tunnel
back: the pod's network namespace outlives the container, and gluetun logs `adding ip rule
101 … file exists` and retries forever while qBittorrent shows as disconnected. Delete the
pod to get a fresh namespace: `kubectl -n media delete pod -l app=qbittorrent`. The DNS
block lists are off (`BLOCK_MALICIOUS=off`, `DNS_UPDATE_PERIOD=0`) because their daily
refresh is what pushed gluetun over its memory limit.
