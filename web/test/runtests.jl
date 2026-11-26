# Integration tests: a real server on an ephemeral loopback port, real HTTP requests.
using Test
using ItaBOLWeb
using ItaBOLValidator
import HTTP
import JSON3
import Sockets
import TOML
import XLSX
import ZipArchives
using DataFrames: DataFrame, names, nrow

include(joinpath(@__DIR__, "fixtures.jl"))

function zip_bytes(entries)
    io = IOBuffer()
    ZipArchives.ZipWriter(io) do w
        for (name, data) in entries
            ZipArchives.zip_newfile(w, name; compress=true)
            write(w, Vector{UInt8}(data))
        end
    end
    return take!(io)
end

function call(method, url; body=UInt8[], headers=Pair{String,String}[])
    return HTTP.request(method, url, headers, body; status_exception=false, retry=false, readtimeout=120)
end
upload(base, bytes; name="Specimens 2026.xlsx", type=XLSX_TYPE) =
    call("POST", "$base/api/upload"; body=bytes, headers=["Content-Type" => type, "X-Filename" => HTTP.escapeuri(name)])
json(res) = JSON3.read(String(copy(res.body)))
post_json(base, path, x) = call("POST", "$base$path"; body=JSON3.write(x), headers=["Content-Type" => "application/json"])

@testset "ItaBOLWeb" begin
    mktempdir() do dir
        root, registry, workbook = web_fixture(dir)
        original = read(workbook)
        work = joinpath(dir, "work")
        bold_calls = Ref(0)
        config = WebConfig(; registry, geodata_root=root, port=0, work_dir=work, max_upload_mb=1,
                           max_uncompressed_mb=5, max_jobs=2, max_queued=16, retention_minutes=60,
                           bold_min_interval=0, taxonomy_fetch=fake_bold(bold_calls),
                           # The per-client limits are tested on their own server below.
                           rate_uploads=0, rate_enrichments=0, rate_saves=0, rate_reads=0,
                           max_inflight_per_client=0, max_sessions_per_client=0)
        server = serve(config; async=true)
        base = "http://127.0.0.1:$(server.port)"
        try
            @testset "Pages and headers" begin
                page = call("GET", "$base/")
                @test page.status == 200
                @test occursin("Caricamento e validazione", String(copy(page.body)))
                @test occursin("Opzioni dell'arricchimento", String(copy(page.body)))
                @test occursin("Risultati e download", String(copy(page.body))) && occursin("lang=\"it\"", String(copy(page.body)))
                @test startswith(HTTP.header(page, "Content-Security-Policy"), "default-src 'self'")
                @test HTTP.header(page, "X-Frame-Options") == "DENY"
                @test call("GET", "$base/assets/app.js").status == 200
                @test call("GET", "$base/assets/style.css").status == 200
                missing_page = call("GET", "$base/assets/../../layers.toml")
                @test missing_page.status == 404 && HTTP.header(missing_page, "Content-Type") == "application/json; charset=utf-8"
                @test call("GET", "$base/geodata/cells.gpkg").status == 404
                @test json(call("GET", "$base/health")).status == "ok"
                fields = call("GET", "$base/api/fields")
                text = String(copy(fields.body))
                info = JSON3.read(text)
                @test [f.column for f in info.fields] == ["COUNTRY/OCEAN", "ELEV"]
                @test info.fields[1].layers[1].version == "web-test-1"
                @test info.max_upload_mb == 1
                @test !occursin("gpkg", text) && !occursin("geodata", text) && !occursin(escape_string(root), text)
            end

            @testset "Upload validation" begin
                @test upload(base, original; type="text/plain").status == 415
                @test upload(base, original; name="specimens.xls").status == 415
                @test upload(base, UInt8[]).status == 400
                @test upload(base, Vector{UInt8}("not a workbook")).status == 422
                @test upload(base, zip_bytes(["readme.txt" => b"x"])).status == 422
                with_macro = zip_bytes(["[Content_Types].xml" => b"x", "xl/workbook.xml" => b"x", "xl/vbaProject.bin" => b"x"])
                @test upload(base, with_macro).status == 422
                bomb = zip_bytes(["[Content_Types].xml" => b"x", "xl/workbook.xml" => zeros(UInt8, 6 * 2^20)])
                @test length(bomb) < 2^20
                @test upload(base, bomb).status == 413
                big = upload(base, rand(UInt8, 2 * 2^20))
                @test big.status == 413 && occursin("limite di caricamento", json(big).error)
                other = joinpath(dir, "other.xlsx")
                XLSX.openxlsx(other; mode="w") do book
                    book[1]["A1"] = "not BOLD"
                end
                bad = upload(base, read(other))
                @test bad.status == 422 && occursin("non è una submission BOLD valida", json(bad).error)
                @test !occursin(work, json(bad).error)
                @test isempty(filter(n -> occursin(r"^[0-9a-f]{32}$", n), readdir(work)))   # rejected uploads removed
            end

            local session
            @testset "Upload, enrich, preview and download" begin
                res = upload(base, original)
                @test res.status == 200
                info = json(res)
                session = String(info.session)
                @test occursin(r"^[0-9a-f]{32}$", session)
                @test info.records == 4 && info.valid_coordinates == 3 && info.invalid_coordinates == 1
                @test info.filename == "Specimens_2026.xlsx"
                @test info.existing_values["COUNTRY/OCEAN"] == 1
                @test readdir(joinpath(work, session)) == ["upload.xlsx"]
                @test read(workbook) == original

                @test post_json(base, "/api/enrich", (session="0"^32, fields=["ELEV"])).status == 404
                @test post_json(base, "/api/enrich", (session="../../geodata", fields=["ELEV"])).status == 404
                @test post_json(base, "/api/enrich", (session=session, fields=String[])).status == 400
                @test post_json(base, "/api/enrich", (session=session, fields=["ELEV_ACCURACY"])).status == 400
                @test post_json(base, "/api/enrich", (session=session, fields=["ELEV"], overwrite="yes")).status == 400
                @test call("POST", "$base/api/enrich"; body="x", headers=["Content-Type" => "text/plain"]).status == 415
                @test call("POST", "$base/api/enrich"; body="[1]", headers=["Content-Type" => "application/json"]).status == 400
                @test call("POST", "$base/api/enrich"; body="{", headers=["Content-Type" => "application/json"]).status == 400
                @test call("GET", "$base/api/download?file=workbook"; headers=["X-Session" => session]).status == 404   # not run yet

                res = post_json(base, "/api/enrich", (session=session, fields=["COUNTRY/OCEAN", "ELEV"]))
                @test res.status == 200
                result = json(res)
                @test result.summary.input_specimens == 4
                @test result.summary.existing_values_preserved == 1
                @test result.summary.fields_populated == 4        # S1 country and ELEV, S2 and S4 ELEV
                @test result.preview_total == 8
                @test result.preview[1].status in ("fill", "overwrite")      # changes listed first
                s2 = only(r for r in result.preview if r.specimen_id == "S2" && r.field == "COUNTRY/OCEAN")
                @test s2.status == "preserved" && s2.original == "Italia" && s2.proposed == "Italy"
                @test [d.id for d in result.datasets] == ["country", "dem"]

                dl = call("GET", "$base/api/download?file=workbook"; headers=["X-Session" => session])
                @test dl.status == 200
                @test HTTP.header(dl, "Content-Disposition") == "attachment; filename=\"Specimens_2026_enriched.xlsx\""
                path = joinpath(dir, "downloaded.xlsx")
                write(path, dl.body)
                enriched = read_bold(path)
                @test enriched.excel_rows == read_bold(workbook).excel_rows
                @test enriched.records.SAMPLEID == ["S1", "S2", "S3", "S4"]
                @test isequal(enriched.records[!, "COUNTRY/OCEAN"], ["Italy", "Italia", missing, missing])
                @test isequal(enriched.records.ELEV, [102, 201, missing, 3])
                report = call("GET", "$base/api/download?file=report"; headers=["X-Session" => session])
                text = String(copy(report.body))
                parsed = TOML.parse(text)
                @test parsed["input_specimens"] == 4 && !haskey(parsed, "registry")
                @test all(d -> !haskey(d, "path"), parsed["datasets"])
                @test !occursin("gpkg", text) && !occursin("dem.tif", text)
                changes = call("GET", "$base/api/download?file=changes"; headers=["X-Session" => session])
                @test changes.status == 200 && startswith(String(copy(changes.body)), "excel_row,specimen_id")
                @test call("GET", "$base/api/download?file=../upload.xlsx"; headers=["X-Session" => session]).status == 404
                @test call("GET", "$base/api/download?file=upload"; headers=["X-Session" => session]).status == 404
                @test call("GET", "$base/api/download?file=workbook"; headers=["X-Session" => "..%2F.."]).status == 404

                over = json(post_json(base, "/api/enrich", (session=session, fields=["COUNTRY/OCEAN"], overwrite=true)))
                @test over.summary.values_overwritten == 1
                dl = call("GET", "$base/api/download?file=workbook"; headers=["X-Session" => session])
                write(path, dl.body)
                @test read_bold(path).records[2, "COUNTRY/OCEAN"] == "Italy"
                @test read(workbook) == original
            end

            @testset "Taxonomy completion" begin
                fields = json(call("GET", "$base/api/fields"))
                @test fields.taxonomy.available && fields.taxonomy.columns[1] == "PHYLUM"
                @test fields.retention_minutes == 60 && fields.max_records == 100
                taxa = taxonomy_fixture(dir)
                info = json(upload(base, read(taxa); name="Taxa.xlsx"))
                @test info.taxonomy.records_with_name == 3 && info.taxonomy.records_to_complete == 3
                @test info.taxonomy.distinct_names == 2 && info.taxonomy.columns_present
                tsession = String(info.session)
                @test post_json(base, "/api/enrich", (session=tsession, fields=String[], taxonomy="yes")).status == 400
                @test bold_calls[] == 0
                res = post_json(base, "/api/enrich", (session=tsession, fields=String[], taxonomy=true))
                @test res.status == 200
                r = json(res)
                @test bold_calls[] == 2 && r.taxonomy.network_lookups == 2 && r.taxonomy.distinct_names == 2
                @test r.taxonomy.per_rank.PHYLUM.filled == 1 && collect(r.taxonomy.conflict_excel_rows) == [5]
                @test r.taxonomy.records_by_lookup_status.not_found == 1
                @test isempty(r.per_field) && r.summary.values_filled == 7
                t1 = [x for x in r.preview if x.specimen_id == "T1"]
                @test all(x -> x.source_layer == "BOLD taxonomy" && x.status == "fill", t1) && length(t1) == 7
                path = joinpath(dir, "taxa_enriched.xlsx")
                write(path, call("GET", "$base/api/download?file=workbook"; headers=["X-Session" => tsession]).body)
                e = read_bold(path)
                @test e.records[1, "PHYLUM"] == "Arthropoda" && e.records[1, "TRIBE"] == "Bombini"
                @test e.records[2, "CLASS"] == "Aves" && ismissing(e.records[2, "PHYLUM"])
                @test ismissing(e.records[3, "FAMILY"]) && all(ismissing, e.records[4, collect(TAXON_COLUMNS)])
                report = TOML.parse(String(copy(call("GET", "$base/api/download?file=report"; headers=["X-Session" => tsession]).body)))
                @test report["taxonomy"]["source"] == "BOLD Systems taxonomy API" && report["options"]["taxonomy"]
                # Geographic fields and taxonomy together; the second run is served from the cache.
                both = json(post_json(base, "/api/enrich", (session=tsession, fields=["ELEV"], taxonomy=true)))
                @test bold_calls[] == 2 && both.taxonomy.network_lookups == 0 && haskey(both.per_field, :ELEV)
                # A workbook without the taxonomic columns cannot be completed.
                plain = json(upload(base, original))
                @test plain.taxonomy.columns_present == false
                @test post_json(base, "/api/enrich", (session=plain.session, fields=String[], taxonomy=true)).status == 422
            end

            @testset "Review page: table, map, compliance and saved edits" begin
                page = call("GET", "$base/review")
                @test page.status == 200 && occursin("Localizzazione dei siti", String(copy(page.body)))
                @test call("GET", "$base/assets/review.js").status == 200
                @test call("GET", "$base/api/table"; headers=["X-Session" => "0"^32]).status == 404
                info = json(upload(base, read(review_fixture(dir)); name="Review.xlsx"))
                rs = String(info.session)
                @test call("GET", "$base/api/table?session=$rs").status == 404
                @test call("GET", "$base/api/download?session=$rs&file=workbook").status == 404
                t = json(call("GET", "$base/api/table"; headers=["X-Session" => rs]))
                @test t.base == "original" && length(t.rows) == 3 && length(t.headers) == 50 && !t.saved
                @test t.rules.bold.defined && !t.rules.itabol.defined && "COORD:LAT" in t.numeric_columns
                @test t.server_compliance.bold_compliant == 1 && t.server_compliance.not_compliant == 2
                @test isempty(t.changed) && t.excel_rows == [2, 3, 4]
                lat = findfirst(==("COORD:LAT"), t.headers)
                @test t.rows[3][lat] == "41,7" && t.rows[1][lat] == 41.5

                # The review map: Leaflet served locally, OpenStreetMap tiles allowed by the CSP only.
                @test call("GET", "$base/api/basemap").status == 404
                leaflet = call("GET", "$base/assets/leaflet/leaflet.js")
                @test leaflet.status == 200 && occursin("Leaflet 1.9.4", String(leaflet.body))
                @test call("GET", "$base/assets/leaflet/leaflet.css").status == 200
                page = call("GET", "$base/review")
                @test occursin("img-src 'self' data: https://tile.openstreetmap.org;", HTTP.header(page, "Content-Security-Policy"))
                @test occursin("/assets/leaflet/leaflet.js", String(page.body))

                review(x) = post_json(base, "/api/review", x)
                sha = String(t.base_sha256)
                ok_edits = [(row=3, column="INST", value="Museo"), (row=4, column="COORD:LAT", value="41.7")]
                @test review((session=rs, edits=ok_edits)).status == 400                       # no base_sha256
                @test review((session=rs, base_sha256="x", edits=ok_edits)).status == 409
                @test review((session=rs, base_sha256=sha, edits=[(row=3, column="INST", value=true)])).status == 400
                @test review((session=rs, base_sha256=sha, edits=[(row=99, column="INST", value="x")])).status == 422
                @test review((session=rs, base_sha256=sha, edits="x")).status == 400
                @test call("GET", "$base/api/download?file=reviewed"; headers=["X-Session" => rs]).status == 404
                res = review((session=rs, base_sha256=sha, edits=ok_edits))
                @test res.status == 200
                saved = json(res)
                @test saved.edits == 2 && saved.compliance.bold_compliant == 3 && saved.base_sha256 != sha
                path = joinpath(dir, "reviewed.xlsx")
                write(path, call("GET", "$base/api/download?file=reviewed"; headers=["X-Session" => rs]).body)
                e = read_bold(path)
                @test e.records[2, "INST"] == "Museo" && e.records[3, "COORD:LAT"] == 41.7
                @test e.records[1, "SAMPLEID"] == "R1" && e.excel_rows == [2, 3, 4]
                rep = TOML.parse(String(copy(call("GET", "$base/api/download?file=review_report"; headers=["X-Session" => rs]).body)))
                @test rep["root"] == "original" && length(rep["edits"]) == 2 && rep["compliance"]["bold_compliant"] == 3
                @test rep["rules"]["itabol"] == "not defined"
                # Reopening shows the saved review; a further save builds on it.
                t2 = json(call("GET", "$base/api/table"; headers=["X-Session" => rs]))
                @test t2.base == "reviewed" && t2.saved && t2.rows[3][lat] == 41.7 && [2, lat - 1] in t2.changed
                more = review((session=rs, base_sha256=String(t2.base_sha256),
                               edits=[(row=2, column="NOTES", value="checked")]))
                @test more.status == 200
                write(path, call("GET", "$base/api/download?file=reviewed"; headers=["X-Session" => rs]).body)
                @test read_bold(path).records[1, "NOTES"] == "checked" && read_bold(path).records[2, "INST"] == "Museo"
                # A new enrichment makes the review stale: it is discarded.
                @test post_json(base, "/api/enrich", (session=rs, fields=["ELEV"])).status == 200
                @test call("GET", "$base/api/download?file=reviewed"; headers=["X-Session" => rs]).status == 404
                @test call("GET", "$base/api/download?file=review_report"; headers=["X-Session" => rs]).status == 404
                t3 = json(call("GET", "$base/api/table"; headers=["X-Session" => rs]))
                @test t3.base == "enriched" && !t3.saved && !isempty(t3.changed)
                @test call("GET", "$base/api/download?file=reviewed"; headers=["X-Session" => rs]).status == 404
            end

            @testset "Record limit, row precount and warm-up" begin
                @test server.app.config.max_records == 100
                many = write_fixture(joinpath(dir, "Many.xlsx");
                                     records=[synthetic_record("M$i", 41.5, 11.5) for i in 1:101])
                res = upload(base, read(many); name="Many.xlsx")
                @test res.status == 413 && occursin("101 campioni", json(res).error) &&
                      occursin("100 campioni", json(res).error)
                rows = join("<row r=\"$i\"><c r=\"A$i\" t=\"inlineStr\"><is><t>x</t></is></c></row>" for i in 1:1001)
                sheet = "<worksheet><sheetData>$rows</sheetData></worksheet>"
                big = zip_bytes(["[Content_Types].xml" => "<Types>$(ItaBOLWeb.XLSX_MAIN)</Types>",
                                 "xl/workbook.xml" => "<workbook/>", "xl/worksheets/sheet1.xml" => sheet])
                err = try
                    ItaBOLWeb.check_workbook_bytes(big, 10^8; max_rows=1000)
                catch e
                    e
                end
                @test err isa ItaBOLWeb.RequestError && err.status == 413 && occursin("troppe righe", err.message)
                @test ItaBOLWeb.check_workbook_bytes(big, 10^8; max_rows=1001) === nothing
                # The warm-up ran before listening: no leftovers.
                @test !any(startswith("warmup-"), readdir(work))
                @test server.app.limiter.release
                @test ItaBOLWeb.release_memory() === nothing
            end

            @testset "Hardening: preflight, host names, nesting, headers (SEC2-SEC4, SEC7)" begin
                # SEC2: preflights are answered without CORS permission and without a server error.
                pre = call("OPTIONS", "$base/api/upload"; headers=["Origin" => "https://evil.example",
                           "Access-Control-Request-Method" => "POST",
                           "Access-Control-Request-Headers" => "content-type,x-session"])
                @test pre.status == 204 && isempty(HTTP.header(pre, "Access-Control-Allow-Origin"))
                # SEC7: a loopback server without allow-list answers loopback names only.
                @test call("GET", "$base/health"; headers=["Host" => "evil.example"]).status == 421
                @test call("GET", "$base/health"; headers=["Host" => "localhost:1"]).status == 200
                # SEC4
                @test occursin("camera=()", HTTP.header(call("GET", "$base/"), "Permissions-Policy"))
                # SEC3: deeply nested XML is refused before parsing.
                names, entries = ItaBOLValidator._read_package(read(BOLD5_TEMPLATE))
                part = "xl/worksheets/sheet1.xml"
                xml = String(copy(entries[part]))
                deep = replace(xml, "</sheetData>" => "<row r=\"2\"><c r=\"A2\" t=\"inlineStr\"><is>" *
                                                     "<x>"^5000 * "</x>"^5000 * "</is></c></row></sheetData>")
                path = joinpath(dir, "deep.xlsx")
                ItaBOLValidator._write_package(path, names, entries, Dict(part => Vector{UInt8}(codeunits(deep))))
                res = upload(base, read(path); name="deep.xlsx")
                @test res.status == 422 && occursin("annidata", json(res).error)
                @test ItaBOLWeb.xml_depth("<a><b/><c><d>x</d></c><!-- <e><f> --><?pi <g>?></a>") == 3
                @test ItaBOLWeb.xml_depth("<a>" * "<b>"^200; limit=50) == 51
            end

            @testset "Concurrent sessions" begin
                tasks = [Threads.@spawn begin
                             r = json(upload(base, original))
                             e = json(post_json(base, "/api/enrich", (session=r.session, fields=["ELEV"])))
                             (String(r.session), e.summary.fields_populated)
                         end for _ in 1:6]
                results = fetch.(tasks)
                @test length(unique(first.(results))) == 6
                @test all(r -> r[2] == 3, results)
            end

            @testset "Discard and retention" begin
                @test json(post_json(base, "/api/discard", (session=session,))).discarded
                @test !isdir(joinpath(work, session))
                @test call("GET", "$base/api/download?file=workbook"; headers=["X-Session" => session]).status == 404
                app = server.app
                orphan = mkpath(joinpath(work, "f"^32))
                for s in values(app.sessions)
                    s.last_access = 0.0
                end
                ItaBOLWeb._sweep!(app)
                @test isempty(app.sessions)
                @test isdir(orphan)                                   # recent orphan kept
                ItaBOLWeb._sweep!(app; now=time() + 2 * 3600)      # two hours later
                @test !isdir(orphan)
            end
        finally
            shutdown(server)
        end
        @test isempty(filter(n -> occursin(r"^[0-9a-f]{32}$", n), readdir(work)))
        @test read(workbook) == original

        @testset "Allowed hosts and server busy" begin
            strict = serve(WebConfig(; registry, geodata_root=root, port=0, work_dir=work, allowed_hosts=["bold.example.org"],
                                     max_jobs=1, max_queued=0); async=true)
            try
                port = strict.port
                @test call("GET", "http://127.0.0.1:$port/health").status == 421
                @test call("GET", "http://127.0.0.1:$port/health"; headers=["Host" => "bold.example.org"]).status == 200
                @test_throws ArgumentError serve(WebConfig(; registry, geodata_root=root, port=0, work_dir=work); async=true)

                # IBV2: a refused (503) enrichment keeps the previous result downloadable.
                host = ["Host" => "bold.example.org"]
                sbase = "http://127.0.0.1:$port"
                up = call("POST", "$sbase/api/upload"; body=original,
                          headers=vcat(host, ["Content-Type" => XLSX_TYPE, "X-Filename" => "a.xlsx"]))
                sid = String(json(up).session)
                enrich(fields) = call("POST", "$sbase/api/enrich"; body=JSON3.write((session=sid, fields=fields)),
                                      headers=vcat(host, ["Content-Type" => "application/json"]))
                @test enrich(["ELEV"]).status == 200
                first_result = call("GET", "$sbase/api/download?file=workbook"; headers=vcat(host, ["X-Session" => sid]))
                @test first_result.status == 200
                gate = Channel{Nothing}(1)
                busy = Threads.@spawn ItaBOLWeb.with_job(() -> take!(gate), strict.app.limiter)
                timedwait(() -> strict.app.limiter.running == 1, 10.0)
                @test enrich(["COUNTRY/OCEAN"]).status == 503
                again = call("GET", "$sbase/api/download?file=workbook"; headers=vcat(host, ["X-Session" => sid]))
                @test again.status == 200 && again.body == first_result.body
                put!(gate, nothing)
                fetch(busy)
                @test isdir(joinpath(work, sid, "result")) && !any(startswith("result-"), readdir(joinpath(work, sid)))
                @test enrich(["COUNTRY/OCEAN"]).status == 200
                @test call("GET", "$sbase/api/download?file=workbook"; headers=vcat(host, ["X-Session" => sid])).body != first_result.body
            finally
                shutdown(strict)
            end
            # IBV6: 70 uploads that stop after one byte of a 100-byte body.
            slow = serve(WebConfig(; registry, geodata_root=root, port=0, work_dir=work, body_timeout=1,
                                   warmup=false); async=true)
            try
                socks = [Sockets.connect("127.0.0.1", slow.port) for _ in 1:70]
                for s in socks
                    write(s, "POST /api/discard HTTP/1.1\r\nHost: 127.0.0.1\r\n" *
                             "Content-Type: application/json\r\nContent-Length: 100\r\n\r\n{")
                end
                t = @elapsed health = call("GET", "http://127.0.0.1:$(slow.port)/health")
                @test health.status == 200 && t < 30
                closed = Threads.@spawn eof(socks[1])                 # true once the server closes it
                @test timedwait(() -> istaskdone(closed), 15.0) === :ok && fetch(closed)
                foreach(close, socks)
            finally
                shutdown(slow)
            end

            # SEC1: limits per client of the open service (client = last X-Forwarded-For entry).
            open_service = serve(WebConfig(; registry, geodata_root=root, port=0, work_dir=work, warmup=false,
                                           trust_forwarded=true, rate_uploads=3, rate_window=120,
                                           max_sessions_per_client=2); async=true)
            try
                obase = "http://127.0.0.1:$(open_service.port)"
                up(ip) = call("POST", "$obase/api/upload"; body=original,
                              headers=["Content-Type" => XLSX_TYPE, "X-Filename" => "a.xlsx",
                                       "X-Forwarded-For" => "198.51.100.7, $ip"])
                a1, a2 = up("203.0.113.1"), up("203.0.113.1")
                @test a1.status == 200 && a2.status == 200
                third = up("203.0.113.1")                   # two sessions already open
                @test third.status == 429 && occursin("file caricati aperti", json(third).error)
                @test up("203.0.113.2").status == 200       # another client is not affected
                @test json(post_json(obase, "/api/discard", (session=String(json(a1).session),))).discarded
                fourth = up("203.0.113.1")                  # fourth upload in the window: rate limit
                @test fourth.status == 429 && parse(Int, HTTP.header(fourth, "Retry-After")) > 0
                @test occursin("Troppe richieste", json(fourth).error)
            finally
                shutdown(open_service)
            end
            lim = ItaBOLWeb.ClientLimits()
            @test ItaBOLWeb.admit!(lim, "x", :upload, 2, 60; now=0.0) == 0
            @test ItaBOLWeb.admit!(lim, "x", :upload, 2, 60; now=1.0) == 0
            @test ItaBOLWeb.admit!(lim, "x", :upload, 2, 60; now=2.0) == 58
            @test ItaBOLWeb.admit!(lim, "x", :upload, 2, 60; now=61.0) == 0     # the first one expired
            @test ItaBOLWeb.admit!(lim, "x", :upload, 0, 60; now=61.0) == 0     # 0 = no limit
            @test ItaBOLWeb.enter!(lim, "x", 1) && !ItaBOLWeb.enter!(lim, "x", 1)
            ItaBOLWeb.leave!(lim, "x")
            @test ItaBOLWeb.enter!(lim, "x", 1)
            ItaBOLWeb.leave!(lim, "x")
            ItaBOLWeb.prune!(lim, 60; now=1000.0)
            @test isempty(lim.events) && isempty(lim.inflight)

            limiter = ItaBOLWeb.JobLimiter(1, 0)
            gate = Channel{Nothing}(1)
            busy = Threads.@spawn ItaBOLWeb.with_job(() -> take!(gate), limiter)
            timedwait(() -> limiter.running == 1, 10.0)
            err = try
                ItaBOLWeb.with_job(() -> 1, limiter)
            catch e
                e
            end
            @test err isa ItaBOLWeb.RequestError && err.status == 503
            put!(gate, nothing)
            fetch(busy)
            @test ItaBOLWeb.with_job(() -> 42, limiter) == 42
        end
    end
end

@testset "Configuration" begin
    mktempdir() do dir
        geodata = mkpath(joinpath(dir, "geo"))
        reg = touch(joinpath(dir, "layers.toml"))
        env = Dict("ITABOL_REGISTRY" => reg, "ITABOL_GEODATA_ROOT" => geodata, "ITABOL_PORT" => "9001",
                   "ITABOL_MAX_UPLOAD_MB" => "12.5", "ITABOL_ALLOWED_HOSTS" => "a.org, b.org",
                   "ITABOL_RETENTION_MINUTES" => "30")
        c = config_from_env(env)
        @test c.port == 9001 && c.max_upload_mb == 12.5 && c.allowed_hosts == ["a.org", "b.org"]
        @test c.retention_minutes == 30 && c.host == "127.0.0.1" && c.max_jobs == 1
        @test c.bold_taxonomy && c.bold_min_interval == 1.0 && c.bold_max_lookups == 100
        t = config_from_env(merge(env, Dict("ITABOL_BOLD_TAXONOMY" => "false", "ITABOL_BOLD_MIN_INTERVAL" => "2.5",
                                            "ITABOL_BOLD_MAX_LOOKUPS" => "40")))
        @test !t.bold_taxonomy && t.bold_min_interval == 2.5 && t.bold_max_lookups == 40
        @test_throws ArgumentError config_from_env(merge(env, Dict("ITABOL_BOLD_TAXONOMY" => "maybe")))
        r = config_from_env(merge(env, Dict("ITABOL_REVIEW_MAX_RECORDS" => "500")))
        @test r.review_max_records == 500 && isfile(r.compliance)
        @test_throws ArgumentError ItaBOLWeb._check(WebConfig(; registry=reg, geodata_root=geodata,
                                                             compliance=joinpath(dir, "none.toml"),
                                                             work_dir=joinpath(dir, "w")))
        @test config_from_env(merge(env, Dict("ITABOL_BODY_TIMEOUT" => "30"))).body_timeout == 30
        @test_throws ArgumentError ItaBOLWeb._check(WebConfig(; registry=reg, geodata_root=geodata, body_timeout=0,
                                                             work_dir=joinpath(dir, "w")))
        @test_throws ArgumentError ItaBOLWeb._check(WebConfig(; registry=reg, geodata_root=geodata, bold_timeout=0,
                                                             work_dir=joinpath(dir, "w")))
        @test_throws ArgumentError config_from_env(Dict("ITABOL_REGISTRY" => reg))
        @test_throws ArgumentError config_from_env(merge(env, Dict("ITABOL_PORT" => "eighty")))
        @test_throws ArgumentError ItaBOLWeb._check(WebConfig(; registry=reg, geodata_root=geodata,
                                                             work_dir=joinpath(geodata, "uploads")))
        @test_throws ArgumentError ItaBOLWeb._check(WebConfig(; registry=reg, geodata_root=geodata, max_jobs=0,
                                                             work_dir=joinpath(dir, "w")))
    end
end
