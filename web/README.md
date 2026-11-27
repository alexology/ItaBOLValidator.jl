# ItaBOLWeb — web interface

Genie.jl application for the ItaBOLValidator workflow: upload a BOLD workbook,
validate it, choose the geographic fields, preserve or overwrite existing values,
run the enrichment, inspect the summary and preview, and download the enriched
workbook, the report and the full proposal table. Powered by
[dnambientale.it](https://dnambientale.it/en/index.html). The light theme follows
the [official ItaBOL palette](https://www.itabol.it/risorse/): white and pale-grey
surfaces, green actions and accents, and slate text. Darker green text and
status colours keep labels readable on the light surfaces.

All processing is done by ItaBOLValidator (`read_bold`, `load_registry`,
`enrich_workbook`); this project only adds HTTP handling, sessions, limits and
the page. The page is in Italian. A second page, **Revisione** (`/review`, opened from the
main page), shows the sites on an OpenStreetMap map (Leaflet 1.9.4, served by the
app; the browser loads the map tiles from tile.openstreetmap.org, which thus sees
the area being viewed, never the workbook or the coordinates themselves; tiles
send the page origin as referrer, as the OSM tile usage policy asks), the enriched table editable cell
by cell, and per-record BOLD / ItaBOL compliance recomputed in the browser as
the user types (rows white = not compliant, blue = BOLD, orange = ItaBOL;
Okabe–Ito colours plus a text badge). Saving writes `reviewed.xlsx` and
`review.toml` (edits, rule versions, server-side compliance counts); the saved
file is the starting point of later saves, and a new enrichment discards it. It can also complete empty
higher taxonomic ranks from the BOLD taxonomy API (`complete_taxonomy`; rules in
the package README): the option is on by default on the main page, and in the
review page a name written in a taxonomic column completes that record's empty
higher ranks when the cell is left (`POST /api/taxonomy`, `record_taxonomy`,
same rules; the values become unsaved edits and conflicts are reported). ItaBOL compliance (BOLD + coordinates + genus or species)
is shown in the review page; writing the criteria version into a workbook field
is not available yet, so that option of the main page stays disabled.

**Status.** Integration tests (185/185) and a headless-Chrome check (geographic, taxonomy and review runs) pass on Windows with
synthetic data. The application has not yet been deployed on Linux; follow the
staging checklist at the end before opening it to users.

## Development

```sh
cd ItaBOLValidator.jl
julia --project=web -e 'using Pkg; Pkg.instantiate()'
ITABOL_REGISTRY=config/layers.toml ITABOL_GEODATA_ROOT=data \
  julia --project=web --threads=2 web/bin/server.jl
```

Open <http://127.0.0.1:8000>. On Windows PowerShell set the variables with
`$env:ITABOL_REGISTRY = "config/layers.toml"` etc. The server binds to
127.0.0.1 by default. `web/Project.toml` uses `[sources]` (Julia ≥ 1.11) to find
the parent package.

## Configuration (environment variables)

| Variable | Default | Meaning |
| --- | --- | --- |
| `ITABOL_REGISTRY` | required | administrator's `layers.toml` |
| `ITABOL_GEODATA_ROOT` | required | approved geodata directory; registry paths cannot leave it |
| `ITABOL_HOST`, `ITABOL_PORT` | `127.0.0.1`, `8000` | listening address |
| `ITABOL_ALLOWED_HOSTS` | loopback names on a loopback address, otherwise any (with a warning) | comma-separated accepted `Host` headers (others get 421) |
| `ITABOL_TRUST_FORWARDED` | `false` | client address from the last `X-Forwarded-For` entry; enable only behind a proxy that is the sole way in |
| `ITABOL_RATE_WINDOW` | 600 | seconds of the per-client rate window |
| `ITABOL_RATE_UPLOADS`, `ITABOL_RATE_ENRICHMENTS`, `ITABOL_RATE_SAVES`, `ITABOL_RATE_READS` | 20, 20, 60, 300 | requests per client and window (0: no limit); beyond them HTTP 429 with `Retry-After` |
| `ITABOL_MAX_INFLIGHT_PER_CLIENT` | 2 | expensive requests of one client in progress at once |
| `ITABOL_MAX_SESSIONS_PER_CLIENT` | 5 | open uploads of one client |
| `ITABOL_BOLD_MAX_PER_HOUR` | 600 | requests to the BOLD API per hour for the whole server |
| `ITABOL_WORK_DIR` | `<tmp>/itabol-web` | parent of per-session directories (mode 0700) |
| `ITABOL_MAX_UPLOAD_MB` | 5 | upload limit, enforced while reading the body |
| `ITABOL_MAX_UNCOMPRESSED_MB` | 50 | limit on the workbook's uncompressed content (zip bombs) |
| `ITABOL_MAX_RECORDS` | 100 | specimens per workbook; sheets with more than max(1000, 10 × limit) rows are refused before parsing |
| `ITABOL_MAX_JOBS` | 1 | validations/enrichments running at once |
| `ITABOL_MAX_QUEUED` | 8 | requests waiting for a job slot; beyond it HTTP 503 |
| `ITABOL_MAX_SESSIONS` | 50 | uploads kept at once |
| `ITABOL_RETENTION_MINUTES` | 60 | idle time before a session's files are deleted |
| `ITABOL_CLEANUP_SECONDS` | 60 | sweep interval |
| `ITABOL_PREVIEW_ROWS` | 2000 | preview rows sent to the page (the CSV has all) |
| `ITABOL_LOG_LEVEL` | `info` | `debug`, `info`, `warn`, `error` |
| `ITABOL_BOLD_TAXONOMY` | `true` | offer taxonomy completion from the BOLD API (`false` hides it) |
| `ITABOL_BOLD_API_URL` | `https://portal.boldsystems.org/api` | BOLD API base URL |
| `ITABOL_BOLD_MIN_INTERVAL` | 1.0 | seconds between two requests to BOLD (whole process, all users) |
| `ITABOL_BOLD_TIMEOUT` | 20 | timeout of one BOLD request, seconds |
| `ITABOL_BOLD_MAX_LOOKUPS` | 100 | new distinct names looked up per enrichment (cached names excluded) |
| `ITABOL_COMPLIANCE` | package `config/compliance.toml` | BOLD/ItaBOL compliance rules |
| `ITABOL_REVIEW_MAX_RECORDS` | 100 | largest workbook opened in the review page |
| `ITABOL_BODY_TIMEOUT` | 60 | seconds a client may take to send a request body; slower uploads get 408 and the connection is closed |
| `ITABOL_IDLE_TIMEOUT` | 900 | seconds after which a connection without incoming data is closed (longer than any enrichment) |
| `ITABOL_WARMUP` | `true` | compile the processing path at start-up (see "Memory") |
| `ITABOL_RELEASE_MEMORY` | `true` | garbage collection and `malloc_trim` after the last running job |
| `GDAL_CACHEMAX` | GDAL default (5% RAM) | GDAL block cache in MB; 128 recommended on 4 GB |

## Security model

- Uploads: `Content-Type` and `.xlsx` name required; ZIP signature, part names,
  entry count, total uncompressed size, presence of the spreadsheet main part and
  absence of macros are checked before any spreadsheet parser runs; then the BOLD
  template contract is validated. The body limit is enforced before Genie reads it.
- Each upload gets a random 128-bit session id and its own directory; downloads
  serve only fixed file names from that directory, so no request can name a
  server path. Ids are validated as 32 hex characters. The id is a bearer token:
  it travels only in the JSON body of POST requests and in the `X-Session` header
  of GET requests, never in a URL, so it does not reach proxy access logs,
  browser history or `Referer` headers (the review page keeps it in the URL
  fragment, which browsers never send). Downloads are fetched with that header
  and saved by the page.
- Slow or stalled uploads cannot hold the server's 64 connections: the body
  must arrive within `ITABOL_BODY_TIMEOUT` seconds, and connections without
  incoming data are closed after `ITABOL_IDLE_TIMEOUT`; the Caddy configuration
  adds 10 s for headers and 60 s for bodies.
- CSV files (`changes.csv`, `coordinates.csv`) neutralise text that a
  spreadsheet would run as a formula (leading `=`, `+`, `-`, `@`, tab, CR get an
  apostrophe); the enriched workbook keeps the values unchanged.
- "Delete my files now" confirms the deletion only after the server answers;
  on failure the session is kept so that the user can retry. Files are deleted
  anyway after `ITABOL_RETENTION_MINUTES` of inactivity, a time the page states.
- A new enrichment discards the review saved from the previous result.
- The geodata directory is never served; `/api/fields` and reports omit dataset
  paths; error messages are stripped of server paths.
- Jobs are limited by `ITABOL_MAX_JOBS`/`ITABOL_MAX_QUEUED`; work runs off the
  HTTP tasks; each session and each dataset handle has its own lock.
- Responses carry a strict Content-Security-Policy (no inline script, no eval),
  `X-Frame-Options: DENY`, `nosniff`, `no-referrer`, `Cache-Control: no-store`.
- The service is **open, without accounts**. Abuse is bounded per client
  address: uploads, enrichments, saves and reads per 10-minute window, at most 2
  expensive requests in progress and 5 open uploads per client (HTTP 429 with
  `Retry-After`), one job at a time with a short queue for everybody, and at
  most 600 BOLD requests per hour for the whole server (beyond it the lookups are
  skipped, so that BOLD has no reason to block the server). Behind Caddy or
  nginx set `ITABOL_TRUST_FORWARDED=true` so that the client is the visitor,
  not the proxy.
- `OPTIONS` requests are answered by the server itself (204, no CORS
  permission): the application is same-origin only.
- Workbook XML nested deeper than 100 levels is refused before parsing (a
  recursive parser would exhaust its stack).
- `Permissions-Policy` disables device and browser features; Caddy adds HSTS.
- Without `ITABOL_ALLOWED_HOSTS`, a server on a loopback address answers only
  loopback host names (no DNS rebinding from a web page); on other addresses it
  logs a warning. The review page moves the session id from the URL fragment to
  the tab's storage, so it does not stay in the browser history.
- Taxonomy completion is the only outbound traffic: taxon names (never
  coordinates or other metadata) go to `portal.boldsystems.org` over HTTPS, one
  request per second for the whole server, cached for 7 days. The firewall must
  allow outbound 443. A run with many new names takes about one second per name;
  keep `ITABOL_BOLD_MAX_LOOKUPS × ITABOL_BOLD_MIN_INTERVAL` well below nginx's
  `proxy_read_timeout` (600 s for `/api/`).
- The access log records method, path, status and duration, never query strings
  (they contain session ids).

## Production on a Linux VPS (2 vCPU, 4 GB RAM, no Docker)

The recommended installation uses the container image published by GitHub, Docker Compose
and Caddy, as for ASVAtlas: see [`deploy/README.md`](../deploy/README.md). The steps below
install the same application without Docker.

1. **System user and directories**

   ```sh
   sudo useradd --system --home /opt/itabol --shell /usr/sbin/nologin itabol
   sudo mkdir -p /opt/itabol /srv/itabol/geodata /etc/itabol /var/lib/itabol/work
   sudo chown -R itabol:itabol /opt/itabol /var/lib/itabol
   sudo chmod 750 /var/lib/itabol
   ```

2. **Julia** (official binaries, no root runtime needed):

   ```sh
   cd /opt/itabol
   sudo -u itabol curl -fsSLO https://julialang-s3.julialang.org/bin/linux/x64/1.13/julia-1.13.4-linux-x86_64.tar.gz
   sudo -u itabol tar xzf julia-1.13.4-linux-x86_64.tar.gz && sudo -u itabol ln -s julia-1.13.4 julia
   ```

   Verify the checksum against julialang.org before extracting.

3. **Application** (copy the `ItaBOLValidator.jl` directory to `/opt/itabol/`), then
   instantiate and precompile as the service user:

   ```sh
   cd /opt/itabol/ItaBOLValidator.jl
   sudo -u itabol env JULIA_DEPOT_PATH=/opt/itabol/julia-depot /opt/itabol/julia/bin/julia \
       --project=web -e 'using Pkg; Pkg.instantiate(); Pkg.precompile(); using ItaBOLWeb'
   ```

4. **Datasets**: copy them under `/srv/itabol/geodata` (owner root, mode 0755 for
   directories, 0644 for files), write `/etc/itabol/layers.toml` from
   `config/layers.toml` with real paths, attributes, versions and sources, and check
   it before starting the service:

   ```sh
   sudo -u itabol env JULIA_DEPOT_PATH=/opt/itabol/julia-depot /opt/itabol/julia/bin/julia \
       --project=web -e 'using ItaBOLValidator; r = load_registry("/etc/itabol/layers.toml";
       geodata_root="/srv/itabol/geodata"); println(registry_report(r)); println(mapping_report(r))'
   ```

5. **Configuration and service**: copy `web/deploy/itabol.env.example` to
   `/etc/itabol/itabol.env` and `web/deploy/itabol.service` to
   `/etc/systemd/system/`, adjust host names, then

   ```sh
   sudo systemctl daemon-reload && sudo systemctl enable --now itabol
   journalctl -u itabol -f
   ```

   The unit runs as `itabol` with a read-only system, read-only geodata, a
   writable `/var/lib/itabol` only, `MemoryHigh=2000M`, `MemoryMax=2600M` and 2 threads (see "Memory").

6. **Reverse proxy**: install nginx and certbot, adapt
   `web/deploy/nginx-itabol.conf` (server name, certificate, `client_max_body_size`
   slightly above `ITABOL_MAX_UPLOAD_MB`, optional basic auth), then
   `sudo nginx -t && sudo systemctl reload nginx`. Open only ports 80/443 in the
   firewall; port 8000 stays on loopback.

## Memory on a 2 vCPU / 4 GB VPS

Measured on Windows 11 (Julia 1.13.4, 2 threads) with the real ISTAT 2026
boundaries (regions, provinces, 7,896 municipalities) and a TINITALY DEM extract,
20 consecutive sessions of 100 specimens each (upload, enrichment of five
fields, review table, map, saved review, discard):

| | Resident memory | First request after start | Later requests |
| --- | --- | --- | --- |
| Without warm-up | 717 MiB at start, 1,117 MiB peak | 29 s (compilation) | 0.9 s |
| With warm-up and memory release (default) | ~1,000 MiB at start, 1,102 MiB peak | 2.3 s | 1.4 s |

Memory did not grow over the 20 sessions. Linux figures have not been measured
yet: check `journalctl -u itabol` (the warm-up logs the resident memory) and
`systemctl status itabol` after deployment.

What keeps memory bounded:

- **100 specimens per workbook** (`ITABOL_MAX_RECORDS=100`); oversized sheets are
  refused by counting `<row>` elements before any parsing; uploads are limited to
  5 MB and 50 MB uncompressed.
- **One job at a time** (`ITABOL_MAX_JOBS=1`) with a short queue; BOLD lookups
  wait outside the job slot.
- **Rasters are read by blocks**, never whole: memory does not depend on the
  size of the DEM or bathymetry. Install them as tiled, compressed GeoTIFF
  (512 × 512 blocks, see `data/README.md`); `GDAL_CACHEMAX=128` caps GDAL's
  block cache. Polygon layers keep a 64 MB cache of prepared geometries.
- **Memory release**: after the last running job a full garbage collection
  runs and, on Linux/glibc, `malloc_trim` returns freed memory to the system
  (`ITABOL_RELEASE_MEMORY`). The unit sets `MALLOC_ARENA_MAX=2` and
  `--heap-size-hint=1200M`.
- **Warm-up** (`ITABOL_WARMUP`): before the port is announced, the server runs
  the processing path on a one-record workbook and then one complete HTTP
  session against itself (no BOLD request), so no user waits for compilation.
  Start-up takes 20-60 s longer; `TimeoutStartSec=300`.
- **systemd limits**: `MemoryHigh=2000M` (the kernel reclaims first) and
  `MemoryMax=2600M` (hard stop, then automatic restart), leaving room for the
  system, nginx and the page cache that speeds up raster reads.
- **Swap**: add a small swap file as a safety net (not for normal operation):
  `sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile`,
  add it to `/etc/fstab`, and set `vm.swappiness=10`.

## Logging and error reporting

Logs go to stderr and, under systemd, to the journal (`journalctl -u itabol`).
At startup the registry status and every unavailable or invalid layer or mapping
are logged as warnings. Each request logs one line; unexpected errors log a full
stack trace while the user sees a generic message. Restarts on failure are
handled by systemd (`Restart=on-failure`); consider forwarding the journal to your
monitoring and alerting on `Request failed` and on repeated restarts.

## Backup and updates

- Back up `/etc/itabol` (registry and environment) and the geodata directory, or the
  instructions to rebuild it, with each dataset's version and source. Session
  files in `/var/lib/itabol/work` are temporary and need no backup.
- Dataset update: install the new files under a new versioned name, update
  `path` and `version` in the registry, check it with the command above, then
  `systemctl restart itabol`. Keep the previous files until reports produced with
  them no longer need to be reproduced.
- Application update: stop the service, replace the code, run `Pkg.instantiate()`
  and `Pkg.precompile()` as in step 3, run the test suites on a staging copy, then
  start the service. Pin the Julia version; update it deliberately.
- Restarting deletes nothing permanent; open sessions are lost (users re-upload).

## Tests

```sh
julia --project=web --threads=2 -e 'using Pkg; Pkg.test()'
python web/test/browser_check.py OUTDIR      # Playwright + Chrome; screenshots in OUTDIR
```

The integration tests start a real server on an ephemeral loopback port and
cover pages and headers, upload validation (types, size, zip bomb, macros,
non-BOLD workbooks), enrichment, preview, downloads, path-traversal attempts,
overwrite, six concurrent sessions, discard, retention sweeps, the host
allow-list, the job limiter and environment configuration.

## Staging checklist

- [ ] Run both test suites on the VPS (Linux has not been tested yet).
- [ ] Load the real registry; every layer `available`, every mapping `active`.
- [ ] Enrich a known real submission and check values against an independent GIS.
- [ ] Measure time and memory with the real datasets for the largest expected
      submission; set `ITABOL_MAX_RECORDS` accordingly.
- [ ] Open an enriched workbook in Excel and upload it to BOLD's validator.
- [ ] Check the HTTPS configuration, access control and log forwarding.
