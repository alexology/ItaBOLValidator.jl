"""
    WebConfig(; registry, geodata_root, kwargs...)

Server settings. `registry` is the administrator's `layers.toml`; `geodata_root`
is the approved geodata directory (see `ItaBOLValidator.load_registry`).

| Field | Default | Meaning |
|---|---|---|
| `host`, `port` | `127.0.0.1`, `8000` | listening address |
| `work_dir` | `<tempdir>/itabol-web` | parent of per-session directories |
| `max_upload_mb` | 5 | largest accepted workbook |
| `max_uncompressed_mb` | 50 | largest total uncompressed workbook content |
| `max_records` | 100 | largest accepted number of specimen records per workbook |
| `max_jobs` | 1 | validations/enrichments running at the same time |
| `max_queued` | 8 | requests waiting for a job slot (more get HTTP 503) |
| `max_sessions` | 50 | uploads kept at the same time |
| `retention_minutes` | 60 | idle time after which a session and its files are deleted |
| `cleanup_seconds` | 60 | interval of the retention sweep |
| `preview_rows` | 2000 | preview rows returned to the page (the CSV has all) |
| `allowed_hosts` | none | accepted `Host` headers (empty: any) |
| `bold_taxonomy` | `true` | offer completion of higher ranks from the BOLD taxonomy API |
| `bold_api_url` | `https://portal.boldsystems.org/api` | BOLD API base URL |
| `bold_min_interval` | 1.0 | seconds between two requests to BOLD (whole process) |
| `bold_timeout` | 20 | timeout of one BOLD request, in seconds |
| `bold_max_lookups` | 100 | distinct names looked up per enrichment (cached names excluded) |
| `taxonomy_fetch` | `nothing` | replacement HTTP transport (tests only; see `BoldTaxonomyClient`) |
| `compliance` | package `config/compliance.toml` | BOLD/ItaBOL compliance rules (see `load_compliance`) |
| `basemap_layer` | automatic | registry vector layer drawn under the review map |
| `review_max_records` | 100 | largest workbook shown in the review page |
| `warmup` | `true` | run the processing path once at start-up so the first user does not wait for compilation |
| `release_memory` | `true` | after the last running job, collect garbage and return freed memory to the system |
"""
Base.@kwdef struct WebConfig
    registry::String
    geodata_root::String
    host::String = "127.0.0.1"
    port::Int = 8000
    work_dir::String = joinpath(tempdir(), "itabol-web")
    max_upload_mb::Float64 = 5
    max_uncompressed_mb::Float64 = 50
    max_records::Int = 100
    max_jobs::Int = 1
    max_queued::Int = 8
    max_sessions::Int = 50
    retention_minutes::Float64 = 60
    cleanup_seconds::Float64 = 60
    preview_rows::Int = 2000
    allowed_hosts::Vector{String} = String[]
    bold_taxonomy::Bool = true
    bold_api_url::String = "https://portal.boldsystems.org/api"
    bold_min_interval::Float64 = 1.0
    bold_timeout::Float64 = 20
    bold_max_lookups::Int = 100
    taxonomy_fetch::Any = nothing
    compliance::String = joinpath(pkgdir(ItaBOLValidator), "config", "compliance.toml")
    basemap_layer::String = ""
    review_max_records::Int = 100
    warmup::Bool = true
    release_memory::Bool = true
end

const ENV_KEYS = Dict(
    "ITABOL_REGISTRY" => :registry, "ITABOL_GEODATA_ROOT" => :geodata_root, "ITABOL_HOST" => :host,
    "ITABOL_PORT" => :port, "ITABOL_WORK_DIR" => :work_dir, "ITABOL_MAX_UPLOAD_MB" => :max_upload_mb,
    "ITABOL_MAX_UNCOMPRESSED_MB" => :max_uncompressed_mb, "ITABOL_MAX_RECORDS" => :max_records,
    "ITABOL_MAX_JOBS" => :max_jobs, "ITABOL_MAX_QUEUED" => :max_queued, "ITABOL_MAX_SESSIONS" => :max_sessions,
    "ITABOL_RETENTION_MINUTES" => :retention_minutes, "ITABOL_CLEANUP_SECONDS" => :cleanup_seconds,
    "ITABOL_PREVIEW_ROWS" => :preview_rows, "ITABOL_ALLOWED_HOSTS" => :allowed_hosts,
    "ITABOL_BOLD_TAXONOMY" => :bold_taxonomy, "ITABOL_BOLD_API_URL" => :bold_api_url,
    "ITABOL_BOLD_MIN_INTERVAL" => :bold_min_interval, "ITABOL_BOLD_TIMEOUT" => :bold_timeout,
    "ITABOL_BOLD_MAX_LOOKUPS" => :bold_max_lookups, "ITABOL_COMPLIANCE" => :compliance,
    "ITABOL_BASEMAP_LAYER" => :basemap_layer, "ITABOL_REVIEW_MAX_RECORDS" => :review_max_records,
    "ITABOL_WARMUP" => :warmup, "ITABOL_RELEASE_MEMORY" => :release_memory)

"""
    config_from_env(env=ENV) -> WebConfig

Build the configuration from `ITABOL_*` environment variables (see `WebConfig`
and `web/README.md`). `ITABOL_REGISTRY` and `ITABOL_GEODATA_ROOT` are required;
`ITABOL_ALLOWED_HOSTS` is a comma-separated list.
"""
function config_from_env(env=ENV)
    kwargs = Dict{Symbol,Any}()
    for (key, field) in ENV_KEYS
        haskey(env, key) || continue
        raw = strip(env[key])
        T = fieldtype(WebConfig, field)
        kwargs[field] = if T === String
            String(raw)
        elseif T === Vector{String}
            String[strip(h) for h in split(raw, ',') if !isempty(strip(h))]
        else
            value = tryparse(T, raw)
            value === nothing && throw(ArgumentError("$key must be $(T === Bool ? "true or false" : "a number"), got $(repr(raw))"))
            value
        end
    end
    for key in ("ITABOL_REGISTRY", "ITABOL_GEODATA_ROOT")
        haskey(kwargs, ENV_KEYS[key]) || throw(ArgumentError("$key is required"))
    end
    return WebConfig(; kwargs...)
end

function _check(config::WebConfig)
    isfile(config.registry) || throw(ArgumentError("Registry file not found: $(config.registry)"))
    isdir(config.geodata_root) || throw(ArgumentError("Geodata directory not found: $(config.geodata_root)"))
    0 <= config.port <= 65535 || throw(ArgumentError("port must be within [0, 65535]"))
    for f in (:max_upload_mb, :max_uncompressed_mb, :max_records, :max_jobs, :max_sessions, :preview_rows)
        getfield(config, f) > 0 || throw(ArgumentError("$f must be positive"))
    end
    config.max_queued >= 0 || throw(ArgumentError("max_queued must not be negative"))
    config.retention_minutes >= 0 || throw(ArgumentError("retention_minutes must not be negative"))
    config.cleanup_seconds > 0 || throw(ArgumentError("cleanup_seconds must be positive"))
    config.bold_min_interval >= 0 || throw(ArgumentError("bold_min_interval must not be negative"))
    config.bold_timeout > 0 || throw(ArgumentError("bold_timeout must be positive"))
    config.bold_max_lookups >= 0 || throw(ArgumentError("bold_max_lookups must not be negative"))
    config.review_max_records > 0 || throw(ArgumentError("review_max_records must be positive"))
    isfile(config.compliance) || throw(ArgumentError("Compliance rule file not found: $(config.compliance)"))
    # Uploads must never be stored where the geodata are.
    work = abspath(config.work_dir)
    root = realpath(config.geodata_root)
    (_within(work, root) || _within(root, work)) &&
        throw(ArgumentError("work_dir and geodata_root must not contain each other"))
    return config
end

function _within(path, root)
    p, r = splitpath(normpath(path)), splitpath(normpath(root))
    if Sys.iswindows()
        p, r = lowercase.(p), lowercase.(r)
    end
    return length(p) >= length(r) && p[1:length(r)] == r
end

_max_upload_bytes(c::WebConfig) = round(Int, c.max_upload_mb * 2^20)
