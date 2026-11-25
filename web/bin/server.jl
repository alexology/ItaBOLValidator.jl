# Start the ItaBOLValidator web application from ITABOL_* environment variables.
#
#   ITABOL_REGISTRY=/etc/itabol/layers.toml ITABOL_GEODATA_ROOT=/srv/itabol/geodata \
#   julia --project=web --threads=2 web/bin/server.jl
#
# See web/README.md for every variable and for production deployment.
using Logging
using ItaBOLWeb

level = lowercase(get(ENV, "ITABOL_LOG_LEVEL", "info"))
levels = Dict("debug" => Logging.Debug, "info" => Logging.Info, "warn" => Logging.Warn, "error" => Logging.Error)
haskey(levels, level) || error("ITABOL_LOG_LEVEL must be one of $(join(keys(levels), ", "))")
# Logs go to stderr; under systemd they are collected by the journal.
global_logger(ConsoleLogger(stderr, levels[level]))

Threads.nthreads() >= 2 || @warn "Start Julia with --threads=2 so that requests are served while a job runs"
serve(config_from_env())
