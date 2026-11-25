# Enrichment workflow tests; reuse GEO, geodata_root and LAYERS_TOML from geo.jl/registry.jl.

utm_to_wgs(x, y) = reproject_points([x], [y], "EPSG:32633", "EPSG:4326")

function enrichment_fixture(dir)
    root = geodata_root(dir)
    config = joinpath(dir, "layers.toml")
    write(config, LAYERS_TOML)
    lon3, lat3 = utm_to_wgs(300050.0, 4699950.0)          # habitat code 1, zone A
    lon5, lat5 = utm_to_wgs(310050.0, 4699950.0)          # habitat code 2, zone A
    lon6, lat6 = utm_to_wgs(350050.0, 4699950.0)          # habitat code 6 (unmapped)
    rec(id, lat, lon; kw...) = begin
        r = synthetic_record(id, lat, lon)
        for k in ("COUNTRY/OCEAN", "ELEV", "HABITAT")
            delete!(r, k)
        end
        for (k, v) in kw
            r[String(k)] = v
        end
        r
    end
    records = [rec("0001", 41.5, 11.5),                                   # all geographic cells empty
               rec("0002", "40.5", 10.5; var"COUNTRY/OCEAN"="Italia"),    # existing country
               rec("0003", lat3[1], lon3[1]; var"COUNTRY/OCEAN"="Francia", HABITAT="forest"),
               rec("0004", "bad", 11.5),                                  # invalid coordinates
               rec("0005", lat5[1], lon5[1]; HABITAT="  "),               # blank text is empty
               rec("0006", lat6[1], lon6[1]),
               rec("0007", 41.5, 11.5; ELEV=0)]                          # equal to the proposal
    path = joinpath(dir, "specimens.xlsx")
    headers = synthetic_headers()
    headers = vcat(headers[45:end], headers[1:44])   # geographic columns not in their usual place
    write_fixture(path; headers, records, blank_after=3)
    # A formula in a target cell and a styled empty target cell.
    XLSX.openxlsx(path; mode="rw") do book
        sheet = book["Submissions"]
        elev = findfirst(==("ELEV"), headers)
        XLSX.setFormula(sheet, XLSX.CellRef(10, elev), "100+23"; value=123)     # record 0006
        sheet[4, elev] = ""                                                    # record 0001: empty text
        XLSX.setFill(sheet, XLSX.CellRef(4, elev); pattern="solid", fgColor="FF00FF00")
    end
    return root, config, path, headers
end

function sheet_xml(path)
    names, entries = ItaBOLValidator._read_package(read(path))
    part = ItaBOLValidator._worksheet_part(entries, "Submissions")
    return String(copy(entries[part])), names, entries, part
end

function cell_tag(xml, ref)
    m = match(Regex("<c r=\"$ref\"[^>]*>"), xml)
    return m === nothing ? nothing : m.match
end

@testset "Enrichment: preview" begin
    mktempdir() do dir
        root, config, path, headers = enrichment_fixture(dir)
        before = read(path)
        submission = read_bold(path)
        registry = load_registry(config; geodata_root=root, log=false)
        try
            preview = preview_enrichment(submission, registry; identifier_header="SAMPLEID")
            @test read(path) == before
            fields = ["COUNTRY/OCEAN", "ELEV", "DEPTH", "HABITAT"]
            @test names(preview) == ["excel_row", "specimen_id", "field", "original", "proposed",
                                     "source_layer", "status", "detail"]
            @test nrow(preview) == 7 * 4
            @test preview.field == repeat(fields, 7)
            @test preview.excel_row == repeat(submission.excel_rows, inner=4)
            @test preview.specimen_id == repeat(["0001", "0002", "0003", "0004", "0005", "0006", "0007"], inner=4)
            get_row(id, f) = preview[findfirst(i -> preview.specimen_id[i] == id && preview.field[i] == f, 1:nrow(preview)), :]
            r = get_row("0001", "COUNTRY/OCEAN")
            @test r.status == "fill" && r.proposed == "Italy" && r.source_layer == "cells"
            @test get_row("0001", "ELEV").status == "fill" && get_row("0001", "ELEV").proposed == 0.0
            @test get_row("0001", "DEPTH").proposed == 2000.0
            hab = get_row("0001", "HABITAT")
            @test hab.status == "no_value" && occursin("habitat: outside_coverage", hab.detail)
            c2 = get_row("0002", "COUNTRY/OCEAN")
            @test c2.status == "no_value" && occursin("cells: unmapped", c2.detail)   # never invented
            @test get_row("0002", "DEPTH").status == "no_value"                     # bathymetry > 0 on land
            c3 = get_row("0003", "COUNTRY/OCEAN")
            @test c3.status == "preserved" && c3.original == "Francia" && c3.proposed == "A"
            @test get_row("0003", "HABITAT").status == "preserved"
            @test all(==("invalid_coordinates"), preview.status[preview.specimen_id .== "0004"])
            @test get_row("0005", "HABITAT").status == "fill" && get_row("0005", "HABITAT").proposed == "grassland"
            h6 = get_row("0006", "HABITAT")
            @test h6.status == "no_value" && occursin("habitat: unmapped", h6.detail)
            @test get_row("0006", "ELEV").status == "formula_preserved"
            @test get_row("0007", "ELEV").status == "unchanged"
            @test all(in(ItaBOLValidator.PREVIEW_STATUSES), preview.status)

            over = preview_enrichment(submission, registry; overwrite=["COUNTRY/OCEAN"])
            @test over.status[findfirst(i -> over.excel_row[i] == 6 && over.field[i] == "COUNTRY/OCEAN", 1:nrow(over))] == "overwrite"
            @test all(ismissing, over.specimen_id)
            only_elev = preview_enrichment(submission, registry; fields=["ELEV"])
            @test unique(only_elev.field) == ["ELEV"]
            @test_throws ArgumentError preview_enrichment(submission, registry; fields=["ELEV_ACCURACY"])
            @test_throws ArgumentError preview_enrichment(submission, registry; fields=["REGION"])   # no mapping
            @test_throws ArgumentError preview_enrichment(submission, registry; fields=["ELEV"], overwrite=["HABITAT"])
            @test_throws ArgumentError preview_enrichment(submission, registry; identifier_header="sampleid")
            # Without the land check, DEPTH could be proposed where elevation is above sea level.
            @test count(==("fill"), preview_enrichment(submission, registry; fields=["DEPTH"], depth_land_check=false).status) >=
                  count(==("fill"), preview_enrichment(submission, registry; fields=["DEPTH"]).status)
        finally
            close(registry)
        end
    end
end

@testset "Enrichment: enriched workbook and report" begin
    mktempdir() do dir
        root, config, path, headers = enrichment_fixture(dir)
        before = read(path)
        submission = read_bold(path)
        registry = load_registry(config; geodata_root=root, log=false)
        try
            out = joinpath(dir, "out")
            result = enrich_workbook(submission, registry, out; identifier_header="SAMPLEID")
            @test read(path) == before                                      # original unchanged
            @test sort(readdir(out)) == ["changes.csv", "enriched.xlsx", "report.toml"]
            @test_throws ArgumentError enrich_workbook(submission, registry, out)   # never overwrites

            enriched = read_bold(result.workbook)
            @test enriched.headers == submission.headers                      # BOLD structure kept
            @test enriched.column_numbers == submission.column_numbers
            @test enriched.sheet_names == ["Submissions", "Instructions"]
            @test enriched.excel_rows == submission.excel_rows                # no record lost or moved
            @test enriched.records.SAMPLEID == submission.records.SAMPLEID
            edits = Set((r.excel_row, r.field) for r in eachrow(result.preview) if r.status in ("fill", "overwrite"))
            for (i, row) in enumerate(submission.excel_rows), h in submission.headers
                if (row, h) in edits
                    p = result.preview[findfirst(k -> result.preview.excel_row[k] == row && result.preview.field[k] == h,
                                                 1:nrow(result.preview)), :proposed]
                    @test enriched.records[i, h] == p
                else
                    @test isequal(enriched.records[i, h], submission.records[i, h])
                end
            end
            col(h) = findfirst(==(h), headers)
            @test enriched.records[1, "COUNTRY/OCEAN"] == "Italy"
            @test enriched.records[3, "COUNTRY/OCEAN"] == "Francia"           # existing value preserved
            @test enriched.records[3, "HABITAT"] == "forest"
            @test enriched.records[5, "HABITAT"] == "grassland"
            @test ismissing(enriched.records[6, "HABITAT"])                   # unmapped stays missing
            @test ismissing(enriched.records[4, "ELEV"])                      # invalid coordinates
            @test enriched.records[1, "NOTES"] == "existing metadata; àèìòù"
            @test all(ismissing, enriched.records[!, "ELEV_ACCURACY"])
            @test all(ismissing, enriched.records[!, "DEPTH_ACCURACY"])

            # Package: only the Submissions worksheet part differs; the formula survives.
            xml0, names0, entries0, part = sheet_xml(path)
            xml1, names1, entries1, _ = sheet_xml(result.workbook)
            @test names1 == names0
            @test all(n -> n == part || entries1[n] == entries0[n], names0)
            @test xml1 != xml0
            elev = ItaBOLValidator._column_letters(col("ELEV"))
            @test occursin("<f>100+23</f>", xml1)
            style(tag) = match(r" s=\"(\d+)\"", tag).captures[1]
            @test style(cell_tag(xml1, "$(elev)4")) == style(cell_tag(xml0, "$(elev)4"))   # style kept
            @test XLSX.readxlsx(result.workbook)["Instructions"]["B3"] == "Reference information"
            @test XLSX.readxlsx(result.workbook)["Submissions"]["A1"] == "Synthetic workbook: no real specimen data"

            report = TOML.parsefile(joinpath(out, "report.toml"))
            @test report["input_specimens"] == 7
            @test report["valid_coordinates"] == 6 && report["invalid_coordinates"] == 1
            @test report["fields_populated"] == count(in(("fill", "overwrite")), result.preview.status)
            @test report["existing_values_preserved"] == 2
            @test report["existing_values_matching"] == 1
            @test report["formula_cells_preserved"] == 1 && report["worksheet_formulas"] == 1
            @test report["source_sha256"] == submission.source_sha256
            @test report["enriched_sha256"] == bytes2hex(open(sha256, result.workbook))
            @test report["per_field"]["HABITAT"]["unmapped_categories"] == Dict("habitat:6" => 1)
            @test report["per_field"]["HABITAT"]["no_value_reasons"]["outside_coverage"] >= 1
            @test report["per_field"]["COUNTRY/OCEAN"]["no_value_reasons"]["unmapped"] == 1
            ids = Set(d["id"] for d in report["datasets"])
            @test ids == Set(["cells", "zones", "elevation", "bathymetry", "habitat"])
            @test all(d -> d["version"] == "test-1" && d["source"] == "synthetic", report["datasets"])
            changes = CSV.read(joinpath(out, "changes.csv"), DataFrame; types=String)
            @test nrow(changes) == nrow(result.preview)

            # Explicit overwrite of one field only.
            over = enrich_workbook(submission, registry, joinpath(dir, "over"); overwrite=["COUNTRY/OCEAN"])
            again = read_bold(over.workbook)
            @test again.records[3, "COUNTRY/OCEAN"] == "A"
            @test again.records[2, "COUNTRY/OCEAN"] == "Italia"            # no proposal: kept
            @test again.records[3, "HABITAT"] == "forest"                   # not selected for overwrite
            @test over.report["values_overwritten"] == 1
            @test read(path) == before
            # Field selection.
            sel = enrich_workbook(submission, registry, joinpath(dir, "sel"); fields=["HABITAT"])
            @test all(==("HABITAT"), sel.preview.field)
            @test ismissing(read_bold(sel.workbook).records[1, "COUNTRY/OCEAN"])
            # A workbook changed after parsing is refused and nothing is published.
            write(path, before[1:(end - 1)])
            @test_throws ArgumentError enrich_workbook(submission, registry, joinpath(dir, "late"))
            @test !ispath(joinpath(dir, "late"))
        finally
            close(registry)
        end
    end
end

@testset "Enrichment: OOXML cell editing" begin
    xml = """<?xml version="1.0"?><worksheet xmlns="x"><dimension ref="A1:D3"/><sheetData>""" *
          """<row r="1" spans="1:2"><c r="A1" t="s"><v>0</v></c><c r="B1" s="2"/></row>""" *
          """<row r="2"/>""" *
          """<row r="3"><c r="D3"><f>1+1</f><v>2</v></c></row></sheetData></worksheet>"""
    E = ItaBOLValidator.CellEdit
    out = ItaBOLValidator._edit_sheet(xml, [E(1, 2, "a & <b>"), E(1, 4, 5.0), E(2, 1, " x"), E(1, 3, 2.5)])
    @test occursin("""<c r="B1" s="2" t="inlineStr"><is><t>a &amp; &lt;b&gt;</t></is></c><c r="C1"><v>2.5</v></c><c r="D1"><v>5</v></c></row>""", out)
    @test occursin("""<row r="1">""", out)                                # spans dropped after insertion
    @test occursin("""<row r="2"><c r="A2" t="inlineStr"><is><t xml:space="preserve"> x</t></is></c></row>""", out)
    @test occursin("""<c r="A1" t="s"><v>0</v></c>""", out)
    @test_throws ItaBOLValidator.WorkbookStructureError ItaBOLValidator._edit_sheet(xml, [E(3, 4, "x")])
    @test_throws ItaBOLValidator.WorkbookStructureError ItaBOLValidator._edit_sheet(xml, [E(9, 1, "x")])
    @test_throws ArgumentError ItaBOLValidator._edit_sheet(xml, [E(1, 2, "bad\x01")])
    prefixed = replace(xml, r"<(/?)(\w)" => s"<\1x:\2")
    pout = ItaBOLValidator._edit_sheet(prefixed, [E(2, 1, "y")])
    @test occursin("<x:row r=\"2\"><x:c r=\"A2\" t=\"inlineStr\"><x:is><x:t>y</x:t></x:is></x:c></x:row>", pout)
    @test ItaBOLValidator._column_letters.([1, 26, 27, 52, 703]) == ["A", "Z", "AA", "AZ", "AAA"]
    @test ItaBOLValidator._formula_cells(xml, Set([1, 2, 3])) == Set([(3, 4)])
end

@testset "Enrichment: real BOLD5 template" begin
    template = joinpath(@__DIR__, "data", "BOLD5_BCDM_Specimen_Submission_SinglePage.xlsx")
    template_bytes = read(template)
    mktempdir() do dir
        root = geodata_root(dir)
        config = joinpath(dir, "layers.toml")
        write(config, LAYERS_TOML)
        rows = [(2, Dict{String,Any}("SAMPLEID" => "000001", "COORD:LAT" => 41.5, "COORD:LON" => 11.5,
                                     "NOTES" => "kept & <unchanged>")),
                (3, Dict{String,Any}("SAMPLEID" => "000002", "COORD:LAT" => 41.5, "COORD:LON" => 11.5,
                                     "COUNTRY/OCEAN" => "Italia", "ELEV" => 7)),
                (5, Dict{String,Any}("SAMPLEID" => "000003", "COORD:LAT" => "x", "COORD:LON" => 11.5))]
        populated = populated_template_fixture(template, joinpath(dir, "bold5.xlsx"), rows)
        before = read(populated)
        submission = read_bold(populated)
        registry = load_registry(config; geodata_root=root, log=false)
        try
            result = enrich_workbook(submission, registry, joinpath(dir, "out"); identifier_header="SAMPLEID")
            @test read(populated) == before
            enriched = read_bold(result.workbook)
            @test enriched.headers == PROVIDED_BOLD5_HEADERS && enriched.header_row == 1
            @test enriched.excel_rows == [2, 3, 5]
            @test enriched.records[1, "COUNTRY/OCEAN"] == "Italy"
            @test enriched.records[1, "ELEV"] == 0 && enriched.records[1, "DEPTH"] == 2000
            @test enriched.records[2, "COUNTRY/OCEAN"] == "Italia" && enriched.records[2, "ELEV"] == 7
            @test enriched.records[1, "NOTES"] == "kept & <unchanged>"
            @test all(ismissing, enriched.records[3, ["COUNTRY/OCEAN", "ELEV", "DEPTH", "HABITAT"]])
            @test all(ismissing, enriched.records[!, "ELEV_ACCURACY"]) && all(ismissing, enriched.records[!, "COORD_ACCURACY"])
            names0, entries0 = ItaBOLValidator._read_package(before)
            names1, entries1 = ItaBOLValidator._read_package(read(result.workbook))
            @test names1 == names0
            changed = [n for n in names0 if entries1[n] != entries0[n]]
            @test changed == ["xl/worksheets/sheet1.xml"]
            @test any(startswith("xl/media/"), names1) && any(startswith("xl/drawings/"), names1)
            @test result.report["fields_populated"] == 4 && result.report["existing_values_preserved"] == 2
        finally
            close(registry)
        end
    end
    @test read(template) == template_bytes
end
