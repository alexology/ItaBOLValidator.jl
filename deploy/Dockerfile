# Container image of ItaBOLWeb (the web application of ItaBOLValidator).
# Build from the repository root:
#   docker build -f deploy/Dockerfile -t itabol .
# Run with the geographic data in /path/to/geodata (layout in deploy/layers.toml):
#   docker run -d --name itabol -p 127.0.0.1:8000:8000 -v /path/to/geodata:/geodata:ro itabol
# The GitHub workflow .github/workflows/docker.yml builds this image and
# publishes it as ghcr.io/alexology/itabolvalidator. The image holds the code,
# the production registry (deploy/layers.toml) and the compliance rules, but no
# geographic data: they are mounted at run time.

FROM julia:1.13.4

LABEL org.opencontainers.image.source="https://github.com/alexology/ItaBOLValidator.jl" \
      org.opencontainers.image.description="ItaBOLWeb: geographic and taxonomic enrichment of BOLD specimen submissions" \
      org.opencontainers.image.licenses="MIT"

RUN useradd --system --create-home itabol && mkdir /opt/depot /work && chown itabol /opt/depot /work

# Code compiled for generic x86-64 CPUs (as in the official Julia images), so
# that an image built on GitHub does not recompile on the server.
# Memory settings for a 2 vCPU / 4 GB server (see deploy/README.md).
ENV JULIA_CPU_TARGET="generic;sandybridge,-xsaveopt,clone_all;haswell,-rdrnd,base(1)" \
    JULIA_DEPOT_PATH=/opt/depot \
    JULIA_NUM_THREADS=2 \
    MALLOC_ARENA_MAX=2 \
    GDAL_CACHEMAX=128 \
    ITABOL_HOST=0.0.0.0 \
    ITABOL_PORT=8000 \
    ITABOL_REGISTRY=/opt/ItaBOLValidator.jl/deploy/layers.toml \
    ITABOL_GEODATA_ROOT=/geodata \
    ITABOL_WORK_DIR=/work

COPY --chown=itabol . /opt/ItaBOLValidator.jl
USER itabol
# Exactly the dependency versions of the committed web/Manifest.toml (tested in CI).
RUN julia --project=/opt/ItaBOLValidator.jl/web -e 'using Pkg; Pkg.instantiate(); Pkg.precompile()'

# Read-only container: a writable depot in /tmp comes first, for what Julia and
# Pkg write at run time (Genie's start-up asks Pkg for the dependencies, which
# logs the environment use); the installed and compiled packages are read from
# /opt/depot.
ENV JULIA_DEPOT_PATH=/tmp/julia-depot:/opt/depot

EXPOSE 8000
# The server warms up (about 20-60 s) before it logs "ItaBOLWeb listening".
CMD ["julia", "--project=/opt/ItaBOLValidator.jl/web", "--threads=2", "--heap-size-hint=1200M", \
     "/opt/ItaBOLValidator.jl/web/bin/server.jl"]
