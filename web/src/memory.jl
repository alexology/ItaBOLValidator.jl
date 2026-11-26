# Memory housekeeping and start-up warm-up for small servers (2 vCPU, 4 GB).

"""
Return freed memory after a job: a full garbage collection and, on Linux with
glibc, `malloc_trim` so that memory released by GDAL and Julia goes back to the
system instead of staying in the allocator's free lists.
"""
function release_memory()
    GC.gc(true)
    if Sys.islinux()
        try
            ccall(:malloc_trim, Cint, (Csize_t,), 0)
        catch
            # Not glibc (e.g. musl): nothing to trim.
        end
    end
    return nothing
end

"""Resident memory of this process in MiB (Linux `/proc`), or `nothing` elsewhere."""
function resident_mib()
    Sys.islinux() || return nothing
    for line in eachline("/proc/self/status")
        startswith(line, "VmRSS:") && return parse(Int, split(line)[2]) ÷ 1024
    end
    return nothing
end

"""A one-record copy of the BOLD5 template, for the warm-up run."""
function _warmup_workbook(path, latitude, longitude)
    template = joinpath(pkgdir(ItaBOLValidator), "test", "data", "BOLD5_BCDM_Specimen_Submission_SinglePage.xlsx")
    isfile(template) || return nothing
    names, entries = ItaBOLValidator._read_package(read(template))
    part = ItaBOLValidator._worksheet_part(entries, "Submissions")
    xml = String(copy(entries[part]))
    headers = read_bold(template).headers
    cells = Dict("SAMPLEID" => "WARMUP1", "PHYLUM" => "Arthropoda", "SPECIES" => "Bombus terrestris",
                 "COORD:LAT" => latitude, "COORD:LON" => longitude)
    io = IOBuffer()
    print(io, "<row r=\"2\">")
    for (j, h) in enumerate(headers)
        haskey(cells, h) || continue
        ref = ItaBOLValidator._column_letters(j) * "2"
        v = cells[h]
        v isa Real ? print(io, "<c r=\"$ref\"><v>$v</v></c>") :
                     print(io, "<c r=\"$ref\" t=\"inlineStr\"><is><t>$v</t></is></c>")
    end
    print(io, "</row>")
    row = String(take!(io))
    edited = occursin("<sheetData/>", xml) ? replace(xml, "<sheetData/>" => "<sheetData>$row</sheetData>") :
             replace(xml, "</sheetData>" => row * "</sheetData>"; count=1)
    ItaBOLValidator._write_package(path, names, entries, Dict(part => Vector{UInt8}(codeunits(edited))))
    return path
end

"""
Run the whole processing path once on a one-record workbook before serving, so
that the first user does not wait for Julia's compilation (about 25 s
otherwise). No network request is made (the taxonomy uses an offline lookup
table); failures are logged and never prevent the start.
"""
function warmup(app)
    started = time()
    dir = mktempdir(app.work_dir; prefix="warmup-")
    try
        path = _warmup_workbook(joinpath(dir, "warmup.xlsx"), 41.9, 12.5)
        path === nothing && return @warn "Warm-up skipped: BOLD5 template not found in the package"
        submission = read_bold(path)
        fields = [m.column for m in app.registry.mappings if m.status === :active]
        offline = BoldTaxonomyClient(; min_interval=0, fetch=_ -> (200, Pair{String,String}[], Vector{UInt8}(codeunits("[]"))))
        completion = complete_taxonomy(submission, offline)
        result = enrich_workbook(submission, app.registry, joinpath(dir, "result"); fields, taxonomy=completion,
                                 identifier_header="SAMPLEID")
        enriched = read_bold(result.workbook)
        compliance_summary(check_compliance(enriched, app.compliance), app.compliance)
        save_reviewed(enriched, [review_edit(2, "INST", "warm-up")], joinpath(dir, "reviewed.xlsx"))
        JSON3.write(compliance_spec(app.compliance))
        @info "Warm-up done in $(round(time() - started; digits=1)) s" * something(_rss_text(), "")
    catch err
        @warn "Warm-up failed; the first request will be slower" exception = (err, catch_backtrace())
    finally
        rm(dir; recursive=true, force=true)
        release_memory()
    end
    return nothing
end

_rss_text() = (m = resident_mib(); m === nothing ? nothing : "; resident memory $m MiB")

"""
After the port is open: one complete user session through HTTP (pages, upload,
enrichment without taxonomy, table, review page, saved review, download, discard), so
that the web layer is compiled too. Requests are local; errors are logged only.
"""
function http_warmup(app, port)
    started = time()
    dir = mktempdir(app.work_dir; prefix="warmup-")
    try
        path = _warmup_workbook(joinpath(dir, "warmup.xlsx"), 41.9, 12.5)
        path === nothing && return nothing
        host = app.config.host in ("0.0.0.0", "::") ? "127.0.0.1" : app.config.host
        base = occursin(':', host) ? "http://[$host]:$port" : "http://$host:$port"
        headers = isempty(app.config.allowed_hosts) ? Pair{String,String}[] : ["Host" => first(app.config.allowed_hosts)]
        call(method, target; body=UInt8[], extra=Pair{String,String}[]) =
            HTTP.request(method, base * target, vcat(headers, extra), body; status_exception=false, retry=false,
                         readtimeout=300)
        json_call(target, x) = call("POST", target; body=JSON3.write(x), extra=["Content-Type" => "application/json"])
        call("GET", "/")
        call("GET", "/api/fields")
        up = call("POST", "/api/upload"; body=read(path),
                  extra=["Content-Type" => XLSX_MIME, "X-Filename" => "warmup.xlsx"])
        up.status == 200 || return @warn "HTTP warm-up: upload answered $(up.status)"
        session = String(JSON3.read(up.body).session)
        fields = [f.column for f in _fields(app).fields]
        isempty(fields) || json_call("/api/enrich", (session=session, fields=fields, taxonomy=false))
        table = call("GET", "/api/table"; extra=["X-Session" => session])
        call("GET", "/review")
        if table.status == 200
            t = JSON3.read(table.body)
            json_call("/api/review", (session=session, base_sha256=String(t.base_sha256),
                                      edits=[(row=2, column="INST", value="warm-up")]))
        end
        call("GET", "/api/download?file=workbook"; extra=["X-Session" => session])
        json_call("/api/discard", (session=session,))
        @info "HTTP warm-up done in $(round(time() - started; digits=1)) s" * something(_rss_text(), "")
    catch err
        @warn "HTTP warm-up failed; the first request will be slower" exception = (err, catch_backtrace())
    finally
        rm(dir; recursive=true, force=true)
        release_memory()
    end
    return nothing
end
