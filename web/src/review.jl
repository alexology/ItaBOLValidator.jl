# Review page: the enriched (or uploaded) table, real-time compliance rules,
# the overview map and saving the user's edits as a new workbook.

const MAX_REVIEW_EDITS = 500_000
const Dates = ItaBOLValidator.Dates

"""The starting workbook of a review: the enriched one when it exists, else the upload."""
function _review_root(session)
    enriched = joinpath(session.dir, "result", "enriched.xlsx")
    return isfile(enriched) ? (enriched, "enriched") : (joinpath(session.dir, "upload.xlsx"), "original")
end

"""
The workbook the review page shows and edits: the last saved review when it was
made from the current root workbook, otherwise the root itself. A review made
from an earlier enrichment is stale and is deleted.
Returns `(path, kind, root_path, root_kind, root_sha256)`.
"""
function _review_base(session)
    root, kind = _review_root(session)
    root_sha = ItaBOLValidator._file_sha256(root)
    dir = joinpath(session.dir, "review")
    reviewed, report = joinpath(dir, "reviewed.xlsx"), joinpath(dir, "review.toml")
    if isfile(reviewed) && isfile(report)
        recorded = try
            get(TOML.parsefile(report), "root_sha256", "")
        catch
            ""
        end
        recorded == root_sha && return (reviewed, "reviewed", root, kind, root_sha)
    end
    isdir(dir) && rm(dir; recursive=true, force=true)
    return (root, kind, root, kind, root_sha)
end

_json_cell(v) = ismissing(v) || v === nothing ? nothing :
                v isa Bool ? string(v) :
                v isa Real ? (isfinite(v) ? v : string(v)) :
                v isa Dates.Date ? Dates.format(v, "yyyy-mm-dd") :
                v isa Dates.TimeType ? string(v) : string(v)

function _table(app::App)
    session = _session(app, get(_query(), "session", ""))
    lock(session.lock) do
        path, base, _, root_kind, _ = _review_base(session)
        submission, original, formulas = with_job(app.limiter) do
            s = read_bold(path)
            o = base == "original" ? nothing : read_bold(joinpath(session.dir, "upload.xlsx"))
            _, _, _, xml = ItaBOLValidator._sheet_xml(s)
            (s, o, ItaBOLValidator._formula_cells(xml, Set(s.excel_rows)))
        end
        n = length(submission.excel_rows)
        n <= app.config.review_max_records ||
            throw(RequestError(413, "Il file ha $n record: la revisione nel browser è limitata a $(app.config.review_max_records)."))
        headers = submission.headers
        rows = [Any[_json_cell(submission.records[i, h]) for h in headers] for i in 1:n]
        changed = Vector{Int}[]
        if original !== nothing
            for i in 1:n, (j, h) in enumerate(headers)
                isequal(submission.records[i, h], original.records[i, h]) || push!(changed, [i - 1, j - 1])
            end
        end
        column_index = Dict(c => j for (j, c) in enumerate(submission.column_numbers))
        row_index = Dict(r => i for (i, r) in enumerate(submission.excel_rows))
        formula_cells = [[row_index[r] - 1, column_index[c] - 1] for (r, c) in formulas
                         if haskey(row_index, r) && haskey(column_index, c)]
        checked = check_compliance(submission, app.compliance)
        return _json(200, Dict{String,Any}(
            "filename" => session.filename * ".xlsx", "base" => base, "root" => root_kind,
            "base_sha256" => submission.source_sha256,
            "headers" => headers, "excel_rows" => submission.excel_rows, "rows" => rows,
            "changed" => changed, "formulas" => formula_cells,
            "rules" => compliance_spec(app.compliance),
            "numeric_columns" => collect(ItaBOLValidator.REVIEW_NUMERIC_COLUMNS),
            "server_compliance" => compliance_summary(checked, app.compliance),
            "saved" => isfile(joinpath(session.dir, "review", "reviewed.xlsx"))))
    end
end

"""The basemap as serialized JSON, computed once and cached (a few hundred KiB)."""
function _basemap_value(app::App)
    cached = lock(() -> app.basemap[], app.basemap_lock)
    cached === nothing || return cached::String
    return lock(app.basemap_lock) do
        app.basemap[] === nothing || return app.basemap[]::String
        configured = isempty(app.config.basemap_layer) ? nothing : app.config.basemap_layer
        id = basemap_layer(app.registry; layer=configured)
        value = if id === nothing
            Dict{String,Any}("layer" => nothing, "rings" => Any[])
        else
            layer = only(l for l in app.registry.layers if l.id == id)
            outlines = with_job(() -> layer_outlines(app.registry.catalog, id), app.limiter)
            Dict{String,Any}("layer" => id, "name" => layer.name, "version" => layer.version,
                             "source" => layer.source, "rings" => outlines.rings)
        end
        app.basemap[] = JSON3.write(value)
    end
end

_basemap(app::App) = _response(200, _basemap_value(app), "application/json; charset=utf-8")

function _save_review(app::App)
    body = _payload()
    session = _session(app, get(body, :session, nothing))
    base_sha = get(body, :base_sha256, nothing)
    base_sha isa AbstractString || throw(RequestError(400, "base_sha256 mancante."))
    raw = get(body, :edits, nothing)
    raw isa AbstractVector || throw(RequestError(400, "edits deve essere un elenco di modifiche."))
    length(raw) <= MAX_REVIEW_EDITS || throw(RequestError(413, "Troppe modifiche in un solo salvataggio."))
    edits = map(raw) do e
        e isa JSON3.Object || throw(RequestError(400, "Ogni modifica deve essere un oggetto."))
        row, column, value = get(e, :row, nothing), get(e, :column, nothing), get(e, :value, nothing)
        row isa Integer && column isa AbstractString || throw(RequestError(400, "Ogni modifica richiede row e column."))
        try
            review_edit(row, column, value)
        catch err
            err isa ArgumentError || rethrow()
            throw(RequestError(400, "Modifica non valida ($column, riga $row): $(err.msg)"))
        end
    end
    lock(session.lock) do
        path, base, root, root_kind, root_sha = _review_base(session)
        dir = mkpath(joinpath(session.dir, "review"))
        result = try
            with_job(app.limiter) do
                submission = read_bold(path)
                submission.source_sha256 == base_sha ||
                    throw(RequestError(409, "Il file di partenza è cambiato (nuovo arricchimento?): ricarica la revisione."))
                staging = joinpath(dir, "reviewed-" * new_session_id() * ".xlsx")
                try
                    save_reviewed(submission, edits, staging)
                    reviewed = read_bold(staging)
                    checked = check_compliance(reviewed, app.compliance)
                    summary = compliance_summary(checked, app.compliance)
                    sha = ItaBOLValidator._file_sha256(staging)
                    report = Dict{String,Any}(
                        "schema_version" => 1, "application" => "ItaBOLValidator review",
                        "base" => base, "base_workbook" => basename(path), "base_sha256" => base_sha,
                        "root" => root_kind, "root_workbook" => basename(root), "root_sha256" => root_sha,
                        "reviewed_workbook" => "reviewed.xlsx", "reviewed_sha256" => sha,
                        "saved_at" => Dates.format(Dates.now(Dates.UTC), "yyyy-mm-ddTHH:MM:SSZ"),
                        "edits" => [Dict{String,Any}("excel_row" => e.row, "column" => e.column,
                                                     "value" => e.value === nothing ? "" : e.value) for e in edits],
                        "compliance" => summary,
                        "rules" => Dict("bold" => "$(app.compliance.bold.title) $(app.compliance.bold.version)",
                                        "itabol" => app.compliance.itabol.defined ?
                                                    "$(app.compliance.itabol.title) $(app.compliance.itabol.version)" :
                                                    "not defined"))
                    mv(staging, joinpath(dir, "reviewed.xlsx"); force=true)
                    open(io -> TOML.print(io, report; sorted=true), joinpath(dir, "review.toml"), "w")
                    (; summary, edits=length(edits), sha)
                finally
                    isfile(staging) && rm(staging)
                end
            end
        catch err
            err isa RequestError && rethrow()
            if err isa ArgumentError || err isa WorkbookStructureError || err isa TemplateError
                throw(RequestError(422, "Salvataggio non riuscito: " * _public(err, app, session.dir)))
            end
            rethrow()
        end
        return _json(200, Dict{String,Any}("edits" => result.edits, "compliance" => result.summary,
                                           "base_sha256" => result.sha))
    end
end
