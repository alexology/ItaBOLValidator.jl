# Deployment with Docker (e.g. a netcup VPS, 2 vCPU / 4 GB)

The same scheme as ASVAtlas: GitHub builds a container image with the code only
and publishes it as `ghcr.io/alexology/itabolvalidator`; the server runs it
with Docker Compose behind Caddy (HTTPS), with the geographic data mounted
read-only. Nothing is built on the server and no data are in the repository or
in the image. (A systemd/nginx installation without Docker is described in
`web/README.md`.)

| File | Purpose |
| --- | --- |
| `Dockerfile` | image (Julia 1.13.4, code, `layers.toml`, compliance rules) |
| `layers.toml` | production registry: PROVINCE/STATE (ISTAT regions), REGION (ISTAT provinces), ELEV (TINITALY) |
| `docker-compose.yml` | the container alone on `127.0.0.1:8000` |
| `caddy/docker-compose.yml`, `caddy/Caddyfile` | container + Caddy on its own server |
| `caddy/docker-compose.asvatlas.yml` | container on a server that already runs ASVAtlas and its Caddy |
| `../.github/workflows/docker.yml` | builds and publishes the image on every push to `main` |
| `../.github/workflows/tests.yml` | runs the package and web tests on Linux |

## Geographic data (on the server only)

`/srv/itabol/geodata/`, readable by everybody, owned by root:

```text
istat/Reg01012026/Reg01012026_WGS84.shp .shx .dbf .prj      ISTAT regions, 1 Jan 2026
istat/ProvCM01012026/ProvCM01012026_WGS84.shp .shx .dbf .prj ISTAT provinces / metropolitan cities
dem/tinitaly_1_1.tif                                          TINITALY 1.1, whole country (13.3 GB)
```

- ISTAT: "Confini delle unità amministrative a fini statistici al 1° gennaio
  2026", full-detail version (`Limiti01012026.zip`, not the generalised `_g`
  one), the `Reg…` and `ProvCM…` folders only.
- TINITALY: the national Cloud-Optimised GeoTIFF (EPSG:32632, Float32, NoData
  -9999, 512 × 512 tiles, ZSTD, overviews). Checked on 2026-11-25: identical,
  cell by cell, to the INGV tile/WCS extract of the Pisa area; plausible values
  across Italy. It is read block by block: memory does not depend on its size.
  Copy it with `rsync -P` (resumable): `rsync -P tinitaly.tiff server:/srv/itabol/geodata/dem/tinitaly_1_1.tif`.
- Check the registry on the server before starting:
  `docker compose run --rm itabol julia --project=/opt/ItaBOLValidator.jl/web -e 'using ItaBOLValidator; r = load_registry(ENV["ITABOL_REGISTRY"]; geodata_root=ENV["ITABOL_GEODATA_ROOT"]); println(registry_report(r)); println(mapping_report(r))'`
  — three layers `available`, three mappings `active`.

## First installation

1. DNS `A` record of the domain to the server; Docker
   (`curl -fsSL https://get.docker.com | sh`); ports 22, 80, 443 open.
2. A swap file as a safety net: `sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile`,
   a line in `/etc/fstab`, `vm.swappiness=10`.
3. `/srv/itabol/geodata/` as above.
4. **Own server**: copy `caddy/docker-compose.yml` and `caddy/Caddyfile` to
   `/srv/itabol/`, write the domain instead of `itabol.example.org` in both,
   `docker compose up -d`.
   **Server with ASVAtlas** (Compose project in `/srv/asvatlas`): copy
   `caddy/docker-compose.asvatlas.yml` to `/srv/itabol/docker-compose.yml`, write
   the domain, `docker compose up -d`; add the global options block (time limits
   for slow clients; it applies to ASVAtlas too) and the `itabol.example.org { … }`
   block of `caddy/Caddyfile` (with the domain) to `/srv/asvatlas/Caddyfile`, check it with
   `docker compose -f /srv/asvatlas/docker-compose.yml exec caddy caddy validate --config /etc/caddy/Caddyfile`
   and reload with `… exec caddy caddy reload --config /etc/caddy/Caddyfile`.
   With both applications on 4 GB, lower ASVAtlas's `mem_limit` (3g) to about 2g.
5. `docker compose logs -f itabol` until `ItaBOLWeb listening` (the warm-up
   before it takes 20-60 s; the log reports the resident memory).
6. On first publication the image on GitHub is private: make the package
   public in its GitHub settings, or log the server in to `ghcr.io`.

Updates: `docker compose pull && docker compose up -d`. Data updates: replace
the files, change `version`/`path` in `layers.toml` (a new image) and restart.

## Memory

Measured on Windows with this registry and the national DEM, 20 sessions of
100 specimens (upload, enrichment of the three fields, review, map, save):
about 1.0 GB at start, 1.17 GB peak, no growth; first request 2.2 s after the
warm-up, then about 1.2 s. The container limit is 2.6 GB (`mem_limit`); the
image sets `MALLOC_ARENA_MAX=2`, `GDAL_CACHEMAX=128` and
`--heap-size-hint=1200M`. Linux values are not measured yet: check them with
`docker stats itabol` after installation.

## Security settings

- **Open service**: per-client limits (see `web/README.md`, "Security model");
  the Compose files set `ITABOL_TRUST_FORWARDED=true` because the container is
  reachable only through Caddy (or through the local proxy on 127.0.0.1).
- **Container**: read-only image, `/tmp` in memory (64 MB), `/work` on a
  volume, no Linux capabilities, `no-new-privileges`, at most 256 processes,
  2.6 GB of memory. The workflow starts the image with exactly these options
  before publishing it and checks uploads, the refusal of hostile files, the
  CORS preflight and the host allow-list.
- **Caddy**: HSTS (one year), time limits for slow clients, 6 MB request
  bodies, access log without identifiers.
- **Supply chain**: the dependency versions are fixed by the committed
  `Manifest.toml` files (the image installs exactly those, tested on Linux by
  `tests.yml`); GitHub Actions are pinned to commit SHAs and kept current by
  Dependabot; the image is rebuilt every Monday to pick up security updates of
  the Julia/Debian base image (`docker compose pull && docker compose up -d`
  on the server). Update the Julia packages deliberately: `Pkg.update()` in
  both projects, run the tests, commit the Manifests.
- **Server**: keep the VPS updated (`unattended-upgrades`), SSH with keys only,
  firewall open on 22, 80 and 443 only.

## Logs

The Caddy access log keeps masked IP addresses (/24, /48) and drops the
`X-Session`, `X-Filename`, `X-Forwarded-For`, `Cookie` and `Authorization`
headers and any `session` URL parameter; the application sends session ids only
in that header or in POST bodies. The application log records method, path,
status and time, never query strings or file names.

## What is published

The repository and the image contain code, tests with synthetic data, the
empty official BOLD5 template (used by the tests and the warm-up), the
compliance rules and `layers.toml`. They never contain geographic data,
uploaded workbooks, credentials or server addresses; uploads stay in the
container's `/work` and are deleted after 60 minutes of inactivity. Taxon
names (never coordinates) are sent to the public BOLD API when the user
enables the taxonomy completion.
