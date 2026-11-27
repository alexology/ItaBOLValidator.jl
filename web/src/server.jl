# HTTP layer. Genie routes the requests; a stream handler in front of it
# enforces the body limit before anything is read into memory and adds
# security headers to every response.

const ASSETS = joinpath(@__DIR__, "assets")
const STATIC = Dict(
    "/" => ("index.html", "text/html; charset=utf-8"),
    "/review" => ("review.html", "text/html; charset=utf-8"),
    "/assets/app.js" => ("app.js", "text/javascript; charset=utf-8"),
    "/assets/review.js" => ("review.js", "text/javascript; charset=utf-8"),
    "/assets/style.css" => ("style.css", "text/css; charset=utf-8"),
    "/assets/dnambientale.png" => ("dnambientale.png", "image/png"),
    # Leaflet 1.9.4 (BSD-2-Clause, leaflet/LICENSE), served locally: the review map.
    "/assets/leaflet/leaflet.js" => ("leaflet/leaflet.js", "text/javascript; charset=utf-8"),
    "/assets/leaflet/leaflet.css" => ("leaflet/leaflet.css", "text/css; charset=utf-8"),
)
for (_, (file, _)) in STATIC
    include_dependency(joinpath(ASSETS, file))
end
const STATIC_BODY = Dict(path => read(joinpath(ASSETS, file)) for (path, (file, _)) in STATIC)

const SECURITY_HEADERS = [
    "Content-Security-Policy" => "default-src 'self'; style-src 'self'; script-src 'self'; " *
                                 "connect-src 'self'; img-src 'self' data: https://tile.openstreetmap.org; " *
                                 "base-uri 'none'; form-action 'none'; " *
                                 "frame-ancestors 'none'",
    "X-Content-Type-Options" => "nosniff",
    "X-Frame-Options" => "DENY",
    # The OSM tiles of the review map send the origin only (their usage policy
    # asks for a referrer); they set it themselves (referrerpolicy attribute).
    "Referrer-Policy" => "no-referrer",
    "Cross-Origin-Opener-Policy" => "same-origin",
    "Cross-Origin-Resource-Policy" => "same-origin",
    # SEC4: the page needs no device or browser feature.
    "Permissions-Policy" => "camera=(), microphone=(), geolocation=(), payment=(), usb=(), serial=(), " *
                            "bluetooth=(), fullscreen=(self)",
]

const XLSX_MIME = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
# file key => (session subdirectory, fixed file name, download suffix, type)
const DOWNLOADS = Dict(
    "workbook" => ("result", "enriched.xlsx", "_enriched.xlsx", XLSX_MIME),
    "report" => ("result", "report.toml", "_report.toml", "application/toml; charset=utf-8"),
    "changes" => ("result", "changes.csv", "_changes.csv", "text/csv; charset=utf-8"),
    "reviewed" => ("review", "reviewed.xlsx", "_reviewed.xlsx", XLSX_MIME),
    "review_report" => ("review", "review.toml", "_review.toml", "application/toml; charset=utf-8"),
)

const UPLOAD_TYPES = ("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                      "application/octet-stream")

mutable struct App
    config::WebConfig
    registry::GeoRegistry
    work_dir::String
    sessions::Dict{String,Session}
    lock::ReentrantLock
    limiter::JobLimiter
    taxonomy::Union{Nothing,BoldTaxonomyClient}
    limits::ClientLimits
    compliance::ComplianceRules
    stopping::Threads.Atomic{Bool}
    cleaner::Union{Nothing,Task}
end

const APP = Ref{Union{Nothing,App}}(nothing)
const START_LOCK = ReentrantLock()

_response(status, body, type; extra=Pair{String,String}[]) =
    HTTP.Response(status, vcat(["Content-Type" => type, "Cache-Control" => "no-store"], extra), body)
_json(status, x) = _response(status, JSON3.write(x), "application/json; charset=utf-8")
_error(status, message) = _json(status, (error=message,))

function _harden!(res::HTTP.Response)
    if res.status >= 400 && !startswith(HTTP.header(res, "Content-Type"), "application/json")
        res.body = Vector{UInt8}(JSON3.write((error=res.status == 404 ? "Risorsa non trovata." : "Richiesta non riuscita.",)))
        HTTP.setheader(res, "Content-Type" => "application/json; charset=utf-8")
    end
    for h in SECURITY_HEADERS
        HTTP.setheader(res, h)
    end
    HTTP.setheader(res, "Content-Length" => string(length(res.body)))
    return res
end

_request() = Genie.Requests.request()::HTTP.Request
_query() = HTTP.queryparams(HTTP.URI(_request().target))
# GET requests carry the session id in a header: never in a URL, so it does not
# reach proxy access logs, browser history or Referer headers.
_session_header() = HTTP.header(_request(), "X-Session")

function _payload()
    startswith(lowercase(HTTP.header(_request(), "Content-Type")), "application/json") ||
        throw(RequestError(415, "Invia i dati come application/json."))
    body = try
        JSON3.read(String(copy(_request().body)))
    catch
        throw(RequestError(400, "JSON non valido."))
    end
    body isa JSON3.Object || throw(RequestError(400, "Invia un oggetto JSON."))
    return body
end

function _session(app::App, id)
    (id isa AbstractString && occursin(SESSION_ID, id)) || throw(RequestError(404, "Sessione sconosciuta o scaduta."))
    session = lock(() -> get(app.sessions, id, nothing), app.lock)
    session === nothing && throw(RequestError(404, "Sessione sconosciuta o scaduta."))
    session.last_access = time()
    return session
end

# Messages shown to users never contain server paths.
function _public(err, app::App, session_dir="")
    message = sprint(showerror, err)
    isempty(session_dir) || (message = replace(message, session_dir => "upload"))
    for path in (app.config.geodata_root, realpath(app.config.geodata_root), app.work_dir)
        message = replace(message, path => "<server>")
    end
    return first(message, 500)
end

# ---------------------------------------------------------------------------
# Handlers

function _fields(app::App)
    reg = app.registry
    layer(id) = only(l for l in reg.layers if l.id == id)
    fields = [(; column=m.column,
               layers=[(; id, name=layer(id).name, version=layer(id).version, source=layer(id).source)
                       for id in m.layers if layer(id).status === :available],
               parameters=m.parameters)
              for m in reg.mappings if m.status === :active]
    unavailable = count(m -> m.status !== :active, reg.mappings)
    taxonomy = (; available=app.taxonomy !== nothing, columns=collect(TAXON_COLUMNS),
                max_lookups=app.config.bold_max_lookups, source="BOLD Systems taxonomy API")
    return (; fields, unavailable_mappings=unavailable, max_upload_mb=app.config.max_upload_mb, taxonomy,
            max_records=app.config.max_records, retention_minutes=app.config.retention_minutes)
end

function _upload(app::App)
    req = _request()
    type = lowercase(strip(first(split(HTTP.header(req, "Content-Type"), ';'))))
    type in UPLOAD_TYPES || throw(RequestError(415, "Carica il file in formato .xlsx."))
    filename = HTTP.unescapeuri(HTTP.header(req, "X-Filename"))
    endswith(lowercase(filename), ".xlsx") || throw(RequestError(415, "Sono accettati solo file .xlsx."))
    bytes = req.body
    isempty(bytes) && throw(RequestError(400, "Il file caricato è vuoto."))
    # Up to 10 empty formatted rows per record are tolerated before parsing; the
    # record limit itself is exact and checked after parsing.
    check_workbook_bytes(bytes, round(Int, app.config.max_uncompressed_mb * 2^20);
                         max_rows=max(1000, 10 * app.config.max_records))
    _sweep!(app)
    id = new_session_id()
    dir = joinpath(app.work_dir, id)
    client = HTTP.header(req, "X-Itabol-Client")
    lock(app.lock) do
        length(app.sessions) >= app.config.max_sessions &&
            throw(RequestError(503, "Troppe sessioni aperte; riprova più tardi."))
        cap = app.config.max_sessions_per_client
        cap > 0 && count(s -> s.client == client, values(app.sessions)) >= cap &&
            throw(RequestError(429, "Hai già $cap file caricati aperti: eliminane uno con il pulsante in fondo ai " *
                                    "risultati o attendi che scadano."))
        mkdir(dir; mode=0o700)
        app.sessions[id] = Session(id, dir, _safe_filename(filename), "", time(), Dict{String,Any}(), nothing,
                                   ReentrantLock(), client)
    end
    try
        path = joinpath(dir, "upload.xlsx")
        write(path, bytes)
        submission = with_job(() -> read_bold(path), app.limiter)
        n = length(submission.excel_rows)
        n <= app.config.max_records ||
            throw(RequestError(413, "Il file contiene $n campioni: il limite è di $(app.config.max_records) campioni per file."))
        statuses = Dict{String,Int}()
        for pair in submission.coordinates
            isvalid(pair) && continue
            key = pair.latitude.status === :valid ? "longitude_$(pair.longitude.status)" :
                  "latitude_$(pair.latitude.status)"
            statuses[key] = get(statuses, key, 0) + 1
        end
        existing = Dict(c => count(v -> !(ismissing(v) || v === nothing || (v isa AbstractString && isempty(strip(v)))),
                                   submission.records[!, c]) for c in BOLD_TARGET_COLUMNS)
        session = app.sessions[id]
        session.sha256 = submission.source_sha256
        taxonomy = _taxonomy_summary(submission)
        session.summary = Dict{String,Any}(
            "session" => id, "filename" => session.filename * ".xlsx", "records" => n,
            "valid_coordinates" => count(isvalid, submission.coordinates),
            "invalid_coordinates" => n - count(isvalid, submission.coordinates),
            "invalid_by_status" => statuses, "header_row" => submission.header_row,
            "existing_values" => existing, "has_sampleid" => "SAMPLEID" in submission.headers,
            "taxonomy" => taxonomy)
        return _json(200, merge(session.summary, Dict("fields" => _fields(app).fields)))
    catch err
        _discard!(app, id)
        err isa RequestError && rethrow()
        if err isa TemplateError || err isa ArgumentError
            throw(RequestError(422, "Il file non è una submission BOLD valida: " * _public(err, app, dir)))
        end
        # A parser exhausting its stack on hostile structure is a refusal, not a server error.
        err isa StackOverflowError && throw(RequestError(422, "Il file non è leggibile: struttura non valida."))
        rethrow()
    end
end

blank(v) = ismissing(v) || v === nothing || (v isa AbstractString && isempty(strip(v)))

"""Records with a name to look up, those with empty higher ranks, and distinct names."""
function _taxonomy_summary(submission)
    columns, names, _ = taxonomy_queries(submission)
    present = [c for c in TAXON_COLUMNS if c in submission.headers]
    to_complete = count(eachindex(columns)) do i
        c = columns[i]
        c === nothing && return false
        any(h -> blank(submission.records[i, h]), present[1:findfirst(==(c), present) - 1])
    end
    distinct = length(unique((c, lowercase(n)) for (c, n) in zip(columns, names) if c !== nothing))
    return Dict{String,Any}("records_with_name" => count(!isnothing, columns), "records_to_complete" => to_complete,
                            "distinct_names" => distinct, "columns_present" => length(present) == length(TAXON_COLUMNS))
end

function _preview_rows(preview, limit)
    rows = [(; excel_row=r.excel_row, specimen_id=ismissing(r.specimen_id) ? nothing : string(r.specimen_id),
             field=r.field, original=_cell(r.original), proposed=_cell(r.proposed),
             source_layer=ismissing(r.source_layer) ? nothing : r.source_layer, status=r.status, detail=r.detail)
            for r in eachrow(preview)]
    changes = [r for r in rows if r.status in CHANGE_STATUSES]
    others = [r for r in rows if !(r.status in CHANGE_STATUSES)]
    # Changes first, so the page always shows them within the limit.
    return first(vcat(changes, others), limit), length(rows), length(changes)
end
_cell(x) = ismissing(x) || x === nothing ? nothing : x isa Real ? x : string(x)

const CHANGE_STATUSES = ("fill", "overwrite", "case_fixed")     # statuses that write a cell
const REPORT_SUMMARY = ("input_specimens", "valid_coordinates", "invalid_coordinates", "fields_populated",
                        "values_filled", "values_overwritten", "taxon_names_recapitalised", "existing_values_preserved",
                        "existing_values_matching", "formula_cells_preserved", "no_value",
                        "specimens_outside_coverage")

function _enrich(app::App)
    body = _payload()
    session = _session(app, get(body, :session, nothing))
    fields = get(body, :fields, String[])
    (fields isa AbstractVector && all(f -> f isa AbstractString, fields)) ||
        throw(RequestError(400, "fields deve essere un elenco di nomi di campo."))
    fields = String.(fields)
    taxonomy = get(body, :taxonomy, false)
    taxonomy isa Bool || throw(RequestError(400, "taxonomy deve essere true o false."))
    taxonomy && app.taxonomy === nothing &&
        throw(RequestError(400, "Il completamento della tassonomia non è attivo su questo server."))
    isempty(fields) && !taxonomy &&
        throw(RequestError(400, "Seleziona almeno un campo o il completamento della tassonomia."))
    available = Set(f.column for f in _fields(app).fields)
    unknown = setdiff(fields, available)
    isempty(unknown) || throw(RequestError(400, "Campi non disponibili: $(join(unknown, ", "))."))
    overwrite = get(body, :overwrite, false)
    overwrite isa Bool || throw(RequestError(400, "overwrite deve essere true o false."))
    lock(session.lock) do
        result_dir = joinpath(session.dir, "result")
        # The new result is built aside; the previous one is replaced only on success,
        # so a refused (503) or failed run keeps the last downloadable result.
        staging = joinpath(session.dir, "result-" * new_session_id())
        upload = joinpath(session.dir, "upload.xlsx")
        result = try
            submission = with_job(() -> read_bold(upload), app.limiter)
            submission.source_sha256 == session.sha256 || throw(RequestError(409, "Il file caricato è cambiato."))
            # BOLD lookups wait on the network and on the rate limit, not on a job slot.
            completion = taxonomy ? complete_taxonomy(submission, app.taxonomy) : nothing
            with_job(app.limiter) do
                enrich_workbook(submission, app.registry, staging; fields,
                                overwrite=overwrite ? fields : String[],
                                identifier_header="SAMPLEID" in submission.headers ? "SAMPLEID" : nothing,
                                taxonomy=completion)
            end
        catch err
            rm(staging; recursive=true, force=true)
            err isa RequestError && rethrow()
            if err isa ArgumentError || err isa WorkbookStructureError || err isa TemplateError
                throw(RequestError(422, _public(err, app, session.dir)))
            end
            rethrow()
        end
        report = result.report
        try
            # The downloadable report must not reveal server paths.
            delete!(report, "registry")
            foreach(d -> delete!(d, "path"), report["datasets"])
            open(io -> TOML.print(io, report; sorted=true), joinpath(staging, "report.toml"), "w")
            rm(result_dir; recursive=true, force=true)
            mv(staging, result_dir)
            # A review saved from the previous result no longer applies.
            rm(joinpath(session.dir, "review"); recursive=true, force=true)
        catch
            rm(staging; recursive=true, force=true)
            rethrow()
        end
        rows, total, changes = _preview_rows(result.preview, app.config.preview_rows)
        session.enriched = Dict{String,Any}(
            "summary" => Dict(k => report[k] for k in REPORT_SUMMARY),
            "per_field" => report["per_field"], "datasets" => report["datasets"],
            "fields" => fields, "overwrite" => overwrite, "taxonomy" => get(report, "taxonomy", nothing),
            "preview" => rows, "preview_total" => total, "preview_changes" => changes)
        return _json(200, session.enriched)
    end
end

function _download(app::App)
    q = _query()
    session = _session(app, _session_header())
    spec = get(DOWNLOADS, get(q, "file", ""), nothing)
    spec === nothing && throw(RequestError(404, "File sconosciuto."))
    sub, file, suffix, type = spec
    path = joinpath(session.dir, sub, file)    # fixed names only; no user path component
    # Under the session lock: never read a result while a run replaces it.
    body = lock(session.lock) do
        # A review made from an earlier result is stale: _review_base discards it.
        sub == "review" && _review_base(session)
        isfile(path) || throw(RequestError(404, sub == "review" ? "Salva prima le modifiche della revisione." :
                                                "Esegui prima l'arricchimento."))
        read(path)
    end
    return _response(200, body, type;
                     extra=["Content-Disposition" => "attachment; filename=\"$(session.filename)$suffix\""])
end

function _discard!(app::App, id)
    session = lock(() -> pop!(app.sessions, id, nothing), app.lock)
    session === nothing && return false
    lock(session.lock) do
        rm(session.dir; recursive=true, force=true)
    end
    return true
end

"""Delete idle sessions and orphaned session directories older than the retention time."""
function _sweep!(app::App; now::Float64=time())
    limit = app.config.retention_minutes * 60
    expired = lock(app.lock) do
        [id for (id, s) in app.sessions if now - s.last_access > limit]
    end
    foreach(id -> _discard!(app, id), expired)
    prune!(app.limits, app.config.rate_window; now)
    for name in readdir(app.work_dir)
        occursin(SESSION_ID, name) || continue
        lock(() -> haskey(app.sessions, name), app.lock) && continue
        path = joinpath(app.work_dir, name)
        now - mtime(path) > limit && rm(path; recursive=true, force=true)
    end
    return length(expired)
end

function _register_routes(app::App)
    R = Genie.Router
    # Genie routes are global; named routes replace those of an earlier instance.
    for (path, (_, type)) in STATIC
        body = STATIC_BODY[path]
        R.route(() -> _response(200, body, type), path; named=Symbol(:itabol_static, path))
    end
    wrap(f) = () -> try
        f()
    catch err
        err isa RequestError && return _error(err.status, err.message)
        @error "Request failed" exception = (err, catch_backtrace())
        _error(500, "Errore interno; i dettagli sono nel log del server.")
    end
    R.route(wrap(() -> _json(200, (status="ok",))), "/health"; named=:itabol_health)
    R.route(wrap(() -> _json(200, _fields(app))), "/api/fields"; named=:itabol_fields)
    R.route(wrap(() -> _upload(app)), "/api/upload"; method=R.POST, named=:itabol_upload)
    R.route(wrap(() -> _enrich(app)), "/api/enrich"; method=R.POST, named=:itabol_enrich)
    R.route(wrap(() -> _download(app)), "/api/download"; named=:itabol_download)
    R.route(wrap(() -> _table(app)), "/api/table"; named=:itabol_table)
    R.route(wrap(() -> _save_review(app)), "/api/review"; method=R.POST, named=:itabol_review)
    R.route(wrap(() -> _review_taxonomy(app)), "/api/taxonomy"; method=R.POST, named=:itabol_taxonomy)
    R.route(wrap(() -> begin
                body = _payload()
                id = get(body, :session, "")
                (id isa AbstractString && occursin(SESSION_ID, id)) || throw(RequestError(404, "Sessione sconosciuta."))
                _json(200, (discarded=_discard!(app, id),))
            end), "/api/discard"; method=R.POST, named=:itabol_discard)
    return nothing
end

# ---------------------------------------------------------------------------
# Stream handler and server lifecycle

"""
Run `f()`, which reads from `stream`; after `seconds` the connection is closed,
which ends any pending read, and HTTP 408 is reported. Bounds the time a client
may take to send a body, so that slow or stalled uploads cannot hold the
server's connections (the work after reading has no such limit).
"""
function _with_deadline(f, stream::HTTP.Stream, seconds::Real)
    expired = Threads.Atomic{Bool}(false)
    timer = Timer(seconds) do _
        expired[] = true
        try
            close(stream.stream)
        catch
        end
    end
    try
        return f()
    catch err
        expired[] && throw(RequestError(408, "Il caricamento ha superato il tempo massimo; riprova."))
        rethrow()
    finally
        close(timer)
    end
end

function _read_body(stream::HTTP.Stream, max_body::Int)
    buffer = IOBuffer()
    while !eof(stream)
        write(buffer, readavailable(stream))
        position(buffer) > max_body && throw(RequestError(413, "Il file supera il limite di caricamento."))
    end
    return take!(buffer)
end

function _drain!(stream::HTTP.Stream, limit::Int)
    n = 0
    try
        while !eof(stream)
            n += length(readavailable(stream))
            n > limit && return
        end
    catch err
        err isa Union{EOFError,Base.IOError,HTTP.Exceptions.HTTPError} || rethrow()
    end
    return
end

function _stream_handler(app::App)
    max_body = _max_upload_bytes(app.config)
    hosts = accepted_hosts(app.config)
    return function (stream::HTTP.Stream)
        req = stream.message
        started = time()
        close_after = false
        inflight = nothing
        res = try
            app.stopping[] && throw(RequestError(503, "Il server si sta arrestando."))
            if !isempty(hosts)
                host = lowercase(strip(HTTP.header(req, "Host")))
                name = startswith(host, '[') ? first(split(host[2:end], ']')) : first(split(host, ':'))
                (host in hosts || name in hosts) || throw(RequestError(421, "Host sconosciuto."))
            end
            # SEC2: same-origin application, no CORS: answer preflights here, before Genie.
            req.method == "OPTIONS" && throw(RequestError(204, ""))
            # The client address replaces anything the request says about itself.
            client = client_address(app.config, stream)
            HTTP.setheader(req, "X-Itabol-Client" => client)
            kind = get(LIMITED_ENDPOINTS, (req.method, first(split(req.target, '?'))), nothing)
            if kind !== nothing
                wait = admit!(app.limits, client, kind, _rate(app.config, kind), app.config.rate_window)
                wait > 0 && throw(RequestError(429, "Troppe richieste da questo indirizzo; riprova tra " *
                                                    "$(cld(wait, 60)) minuti.", wait))
                enter!(app.limits, client, app.config.max_inflight_per_client) ||
                    throw(RequestError(429, "Ci sono già richieste in corso da questo indirizzo; attendi che finiscano.", 5))
                inflight = client
            end
            length_header = HTTP.header(req, "Content-Length")
            if !isempty(length_header)
                n = tryparse(Int, strip(length_header))
                (n === nothing || n < 0) && throw(RequestError(400, "Content-Length non valido."))
                n > max_body && throw(RequestError(413, "Il file supera il limite di caricamento di $(app.config.max_upload_mb) MB."))
            end
            req.body = _with_deadline(() -> _read_body(stream, max_body), stream, app.config.body_timeout)
            HTTP.closeread(stream)
            # Genie parses JSON bodies itself and logs malformed ones as errors;
            # refuse anything but a JSON object before it gets there.
            if startswith(lowercase(HTTP.header(req, "Content-Type")), "application/json")
                is_object = try
                    JSON3.read(String(copy(req.body))) isa JSON3.Object
                catch
                    false
                end
                is_object || throw(RequestError(400, "Invia un oggetto JSON."))
            end
            Genie.Server.setup_http_listener(req, HTTP.Response(); stream)
        catch err
            if err isa RequestError && err.status == 204
                HTTP.Response(204, ["Allow" => "GET, HEAD, POST", "Cache-Control" => "no-store"])
            elseif err isa RequestError
                close_after = err.status in (400, 413)
                if err.status == 413
                    try
                        _with_deadline(() -> _drain!(stream, 4 * max_body), stream, 5)
                    catch
                    end
                end
                r = _error(err.status, err.message)
                err.retry_after > 0 && HTTP.setheader(r, "Retry-After" => string(err.retry_after))
                r
            else
                @error "Request failed" exception = (err, catch_backtrace())
                _error(500, "Errore interno; i dettagli sono nel log del server.")
            end
        finally
            inflight === nothing || leave!(app.limits, inflight)
        end
        _harden!(res)
        # Access log without query strings: they carry session identifiers.
        @info "$(req.method) $(first(split(req.target, '?'))) $(res.status) $(round(Int, 1000 * (time() - started))) ms"
        close_after && HTTP.setheader(res, "Connection" => "close")
        req.response = res
        res.request = req
        # The connection may already be closed (expired upload or client gone).
        isopen(stream.stream) || return
        try
            HTTP.startwrite(stream)
            write(stream, res.body)
        catch err
            err isa Union{Base.IOError,EOFError,HTTP.Exceptions.HTTPError} || rethrow()
            return
        end
        if close_after
            close(stream.stream)
            stream.ntoread = 0
        end
        return
    end
end

function _cleaner(app::App)
    while !app.stopping[]
        try
            _sweep!(app)
        catch err
            @error "Session cleanup failed" exception = (err, catch_backtrace())
        end
        slept = 0.0
        while slept < app.config.cleanup_seconds && !app.stopping[]
            sleep(0.25)
            slept += 0.25
        end
    end
end

"""
    serve(config::WebConfig=config_from_env(); async=false)

Validate the layer registry (unavailable layers are logged, not fatal) and start
the web application on `http://host:port` (`port = 0` picks a free port,
reported as `server.port`). Each upload gets an isolated
directory under `work_dir`, removed after `retention_minutes` of inactivity or
when the user discards it. With `async=true` the server is returned; stop it
with [`shutdown`](@ref). There is no authentication: in production put it
behind a reverse proxy with HTTPS (see `web/README.md`).
"""
function serve(config::WebConfig=config_from_env(); async::Bool=false)
    _check(config)
    app, listener = lock(START_LOCK) do
        APP[] === nothing || throw(ArgumentError("An ItaBOLWeb server is already running in this process"))
        work = mkpath(abspath(config.work_dir))
        Sys.isunix() && chmod(work, 0o700)
        registry = load_registry(config.registry; geodata_root=config.geodata_root)
        @info "Geospatial registry: $registry"
        taxonomy = config.bold_taxonomy ?
            BoldTaxonomyClient(; base_url=config.bold_api_url, min_interval=config.bold_min_interval,
                               timeout=config.bold_timeout, max_lookups=config.bold_max_lookups,
                               max_per_hour=config.bold_max_per_hour, fetch=config.taxonomy_fetch) : nothing
        @info "BOLD taxonomy completion: $(taxonomy === nothing ? "disabled" : taxonomy)"
        compliance = try
            load_compliance(config.compliance)
        catch
            close(registry)
            rethrow()
        end
        @info "Compliance rules: $(compliance.bold.title) $(compliance.bold.version); ItaBOL " *
              (compliance.itabol.defined ? compliance.itabol.version : "not defined")
        local app = App(config, registry, realpath(work), Dict{String,Session}(), ReentrantLock(),
                        JobLimiter(config.max_jobs, config.max_queued; release=config.release_memory), taxonomy,
                        ClientLimits(), compliance, Threads.Atomic{Bool}(false), nothing)
        # Before listening: the first request must not pay for compilation.
        config.warmup && warmup(app)
        local listener = try
            Genie.config.app_env = "prod"
            Genie.config.server_document_root = mktempdir()
            Genie.config.server_handle_static_files = false
            Genie.config.server_signature = ""
            Genie.config.log_requests = false
            Genie.config.websockets_server = false
            _register_routes(app)
            ip = Sockets.getaddrinfo(config.host)
            socket = Sockets.listen(ip, config.port)    # port 0 picks a free port
            HTTP.listen!(_stream_handler(app), ip, Int(Sockets.getsockname(socket)[2]);
                         server=socket, max_connections=64, readtimeout=config.idle_timeout)
        catch
            close(registry)
            rethrow()
        end
        app.cleaner = errormonitor(Threads.@spawn _cleaner(app))
        APP[] = app
        (app, listener)
    end
    port = Int(Sockets.getsockname(listener.listener.server)[2])
    server = (; app, listener, port)
    config.warmup && http_warmup(app, port)
    @info "ItaBOLWeb listening on http://$(config.host):$port"
    async && return server
    try
        Base.exit_on_sigint(false)
        while isopen(listener)
            sleep(0.5)
        end
    catch err
        err isa InterruptException || rethrow()
    finally
        shutdown(server)
    end
    return server
end

"""
    shutdown(server)

Stop accepting requests, wait for running jobs, close the datasets and delete
every session directory of this server.
"""
function shutdown(server)
    app = server.app
    app.stopping[] = true
    close(server.listener)
    lock(app.limiter.condition) do
        while app.limiter.running > 0
            wait(app.limiter.condition)
        end
    end
    cleaner = app.cleaner
    cleaner === nothing || wait(cleaner)
    for id in collect(keys(app.sessions))
        _discard!(app, id)
    end
    close(app.registry)
    lock(() -> APP[] === app && (APP[] = nothing), START_LOCK)
    return nothing
end
