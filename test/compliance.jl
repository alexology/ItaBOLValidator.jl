# Compliance rules, review edits and overview-map outlines.
using Dates: Date

const RULES_FILE = joinpath(@__DIR__, "..", "config", "compliance.toml")
const BOLD5_TEMPLATE = joinpath(@__DIR__, "data", "BOLD5_BCDM_Specimen_Submission_SinglePage.xlsx")

function record_frame(headers, rows)
    df = DataFrame([h => Any[get(r, h, missing) for r in rows] for h in headers])
    return df
end

const GOOD = Dict{String,Any}("SAMPLEID" => "S1", "FIELDID" => "F1", "INST" => "Museo", "PHYLUM" => "Arthropoda",
                              "COUNTRY/OCEAN" => "Italy", "COORD:LAT" => 43.723, "COORD:LON" => 10.3966,
                              "COLLECTION_DATE_START" => "2026-05-01", "ELEV" => 3.0)

function rules_file(dir, itabol)
    text = read(RULES_FILE, String)
    text = replace(text, r"^\[itabol\]$.*?(?=^\[lists\]$)"ms => itabol)
    occursin(itabol, text) || error("ItaBOL section not replaced")
    path = joinpath(dir, "rules.toml")
    write(path, text)
    return path
end

@testset "Compliance: rule file" begin
    rules = load_compliance(RULES_FILE)
    @test rules.bold.defined && rules.bold.version == "2026-11-27" && length(rules.bold.rules) == 10
    @test rules.itabol.defined && rules.itabol.version == "2026-11-27" && length(rules.itabol.rules) == 2
    @test "italy" in only(r for r in rules.bold.rules if r.kind == "vocabulary" && r.columns == ["COUNTRY/OCEAN"]).values
    spec = compliance_spec(rules)
    @test spec["bold"]["rules"][1]["kind"] == "required" && spec["itabol"]["defined"]
    @test length(only(r for r in spec["bold"]["rules"] if r["columns"] == ["COUNTRY/OCEAN"] && r["kind"] == "vocabulary")["values"]) == 268
    mktempdir() do dir
        bad(itabol) = load_compliance(rules_file(dir, itabol))
        @test_throws ArgumentError bad("[itabol]\ndefined = true\nversion = \"\"\n")
        @test_throws ArgumentError bad("[itabol]\ndefined = true\nversion = \"1\"\n")          # no rules
        @test_throws ArgumentError bad("[itabol]\ndefined = true\nversion = \"1\"\n[[itabol.rules]]\nkind = \"magic\"\ncolumns = [\"A\"]\n")
        @test_throws ArgumentError bad("[itabol]\ndefined = true\nversion = \"1\"\n[[itabol.rules]]\nkind = \"vocabulary\"\ncolumns = [\"A\"]\nlist = \"nope\"\n")
        @test_throws ArgumentError bad("[itabol]\ndefined = true\nversion = \"1\"\n[[itabol.rules]]\nkind = \"pattern\"\ncolumns = [\"A\"]\nregex = \"(\"\n")
        @test_throws ArgumentError bad("[itabol]\ndefined = true\nversion = \"1\"\n[[itabol.rules]]\nkind = \"unique\"\ncolumns = [\"A\", \"B\"]\n")
        @test_throws ArgumentError load_compliance(joinpath(dir, "missing.toml"))
        write(joinpath(dir, "broken.toml"), "schema_version = 1\n[bold\n")
        @test_throws ArgumentError load_compliance(joinpath(dir, "broken.toml"))
    end
end

@testset "Compliance: BOLD rules per record" begin
    rules = load_compliance(RULES_FILE)
    headers = read_bold(BOLD5_TEMPLATE).headers
    rows = [
        GOOD,                                                                         # 1 compliant
        merge(GOOD, Dict("SAMPLEID" => "S2", "INST" => "  ")),                        # 2 blank INST
        merge(GOOD, Dict("SAMPLEID" => "S3", "FIELDID" => missing, "MUSEUMID" => "M3")),  # 3 MUSEUMID suffices
        merge(GOOD, Dict("SAMPLEID" => "S4", "FIELDID" => missing)),                  # 4 neither id
        merge(GOOD, Dict("SAMPLEID" => "s1")),                                        # 5 duplicate of S1 (case)
        merge(GOOD, Dict("SAMPLEID" => "S6", "COUNTRY/OCEAN" => "italy")),            # 6 case ignored
        merge(GOOD, Dict("SAMPLEID" => "S7", "COUNTRY/OCEAN" => "Italia")),           # 7 not a BOLD name
        merge(GOOD, Dict("SAMPLEID" => "S8", "COLLECTION_DATE_START" => "2026-02-30")),
        merge(GOOD, Dict("SAMPLEID" => "S9", "COLLECTION_DATE_START" => Date(2026, 2, 1), "ELEV" => "12.5")),
        merge(GOOD, Dict("SAMPLEID" => "S10", "ELEV" => "12,5")),
        merge(GOOD, Dict("SAMPLEID" => "S11", "COORD:LAT" => "43,72")),
        merge(GOOD, Dict("SAMPLEID" => "S12", "COORD:LON" => missing)),
        merge(GOOD, Dict("SAMPLEID" => "S13", "COORD:LAT" => 4842060.0, "COORD:LON" => 612491.0)),  # UTM, not WGS84
        merge(GOOD, Dict("SAMPLEID" => "S14", "COORD:LAT" => missing, "COORD:LON" => missing)),     # optional
        merge(GOOD, Dict("SAMPLEID" => "S15", "IDENTIFICATION_METHOD" => "morphology")),
        merge(GOOD, Dict("SAMPLEID" => "S16", "IDENTIFICATION_METHOD" => "DNA")),
        merge(GOOD, Dict("SAMPLEID" => "S17", "COORD:LAT" => "43.72", "COORD:LON" => "10.39")),   # decimal text
    ]
    r = check_compliance(headers, record_frame(headers, rows), rules)
    codes(i) = Set((p.column, p.code) for p in r.problems[i] if p.profile == "bold")
    # Invalid coordinates (11-13) are warnings for BOLD: valid coordinates are an ItaBOL requirement.
    @test r.bold == [false, false, true, false, false, true, false, false, true, false, true, true, true, true,
                     true, false, true]
    @test all(p -> p.severity === :warning, (p for p in r.problems[13] if p.profile == "bold"))
    @test !any(r.itabol)                                       # no record is identified to genus
    @test codes(1) == Set([("SAMPLEID", "duplicate")])          # S1 and s1
    # Capitalisation is a warning only.
    caps = check_compliance(headers, record_frame(headers, [merge(GOOD, Dict("GENUS" => "baetis",
                                                                             "SPECIES" => "Baetis Rhodani"))]), rules)
    @test caps.bold == [true]
    @test Set((p.column, p.code, p.severity) for p in caps.problems[1]) ==
          Set([("GENUS", "pattern_mismatch", :warning), ("SPECIES", "pattern_mismatch", :warning)])
    @test ("INST", "missing") in codes(2)
    @test codes(4) == Set([("FIELDID|MUSEUMID", "missing_any")])
    @test codes(7) == Set([("COUNTRY/OCEAN", "not_in_vocabulary")])
    @test codes(8) == Set([("COLLECTION_DATE_START", "invalid_date")])
    @test codes(10) == Set([("ELEV", "not_a_number")])
    @test codes(11) == Set([("COORD:LAT", "latitude_invalid_format")])
    @test codes(12) == Set([("COORD:LON", "coordinates_incomplete")])
    @test codes(13) == Set([("COORD:LAT", "latitude_out_of_range"), ("COORD:LON", "longitude_out_of_range")])
    @test codes(16) == Set([("IDENTIFICATION_METHOD", "not_in_vocabulary")])
    s = compliance_summary(r, rules)
    @test s["records"] == 17 && s["bold_compliant"] == 9 && s["not_compliant"] == 8 && s["itabol_profile"] == "ItaBOL 2026-11-27"
    @test s["problems"]["bold:SAMPLEID:duplicate"] == 2
    # Missing columns count as empty for required rules and are ignored by format rules.
    few = ["SAMPLEID", "PHYLUM"]
    r2 = check_compliance(few, record_frame(few, [Dict{String,Any}("SAMPLEID" => "A", "PHYLUM" => "Chordata")]), rules)
    @test !r2.bold[1] && ("INST", "missing") in Set((p.column, p.code) for p in r2.problems[1])
end

@testset "Compliance: shipped ItaBOL criteria" begin
    # BOLD compliant + coordinates + identification to genus or species.
    rules = load_compliance(RULES_FILE)
    headers = read_bold(BOLD5_TEMPLATE).headers
    rows = [merge(GOOD, Dict("GENUS" => "Baetis")),                                        # 1 genus
            merge(GOOD, Dict("SAMPLEID" => "S2", "SPECIES" => "Baetis rhodani")),          # 2 species only
            merge(GOOD, Dict("SAMPLEID" => "S3", "SUBSPECIES" => "Salmo trutta fario")),   # 3 subspecies only
            merge(GOOD, Dict("SAMPLEID" => "S4", "FAMILY" => "Baetidae")),                 # 4 family only
            merge(GOOD, Dict("SAMPLEID" => "S5", "GENUS" => "Baetis",                      # 5 no coordinates
                             "COORD:LAT" => missing, "COORD:LON" => missing)),
            merge(GOOD, Dict("SAMPLEID" => "S6", "GENUS" => "Baetis", "INST" => missing)),  # 6 not BOLD
            merge(GOOD, Dict("SAMPLEID" => "S7", "GENUS" => "Baetis", "COORD:LAT" => "43,7"))]  # 7 invalid latitude
    r = check_compliance(headers, record_frame(headers, rows), rules)
    @test r.bold == [true, true, true, true, true, false, true]          # 7: coordinate warning for BOLD
    @test r.itabol == [true, true, true, false, false, false, false]
    itabol(i) = Set((p.column, p.code) for p in r.problems[i] if p.profile == "itabol")
    @test itabol(4) == Set([("GENUS|SPECIES|SUBSPECIES", "missing_any")])
    @test itabol(5) == Set([("COORD:LAT|COORD:LON", "coordinates_missing")])
    @test isempty(itabol(1)) && isempty(itabol(6))
    s = compliance_summary(r, rules)
    @test s["itabol_compliant"] == 3 && s["bold_compliant"] == 6 && s["itabol_profile"] == "ItaBOL 2026-11-27"
end

@testset "Compliance: ItaBOL profile" begin
    mktempdir() do dir
        itabol = """
        [itabol]
        title = "ItaBOL"
        version = "test-1"
        defined = true
        [[itabol.rules]]
        kind = "required"
        columns = ["COLLECTORS"]
        [[itabol.rules]]
        kind = "coordinates"
        latitude = "COORD:LAT"
        longitude = "COORD:LON"
        required = true
        [[itabol.rules]]
        kind = "pattern"
        columns = ["SAMPLEID"]
        regex = "^ITA"
        severity = "warning"

        """
        rules = load_compliance(rules_file(dir, itabol))
        headers = read_bold(BOLD5_TEMPLATE).headers
        rows = [merge(GOOD, Dict("SAMPLEID" => "ITA1", "COLLECTORS" => "A. Rossi")),
                merge(GOOD, Dict("SAMPLEID" => "X2", "COLLECTORS" => "A. Rossi")),               # warning only
                merge(GOOD, Dict("SAMPLEID" => "ITA3")),                                          # no collectors
                merge(GOOD, Dict("SAMPLEID" => "ITA4", "COLLECTORS" => "B", "INST" => missing)),  # not BOLD
                merge(GOOD, Dict("SAMPLEID" => "ITA5", "COLLECTORS" => "C", "COORD:LAT" => missing, "COORD:LON" => missing))]
        r = check_compliance(headers, record_frame(headers, rows), rules)
        @test r.bold == [true, true, true, false, true]
        @test r.itabol == [true, true, false, false, false]
        @test any(p -> p.code == "pattern_mismatch" && p.severity === :warning, r.problems[2])
        @test any(p -> p.code == "coordinates_missing" && p.profile == "itabol", r.problems[5])
        @test compliance_summary(r, rules)["itabol_profile"] == "ItaBOL test-1"
    end
end

@testset "Review: edits saved to a new workbook" begin
    @test review_edit(2, "COORD:LAT", "  ").value === nothing
    @test review_edit(2, "COORD:LAT", " 43.5 ").value === 43.5
    @test review_edit(2, "COORD:LAT", "43,5").value == "43,5"            # kept, so the check still flags it
    @test review_edit(2, "INST", "  Museo ").value == "  Museo "
    @test review_edit(2, "ELEV", 12).value === 12.0
    @test review_edit(2, "SAMPLEID", "007").value == "007"              # identifiers stay text
    @test_throws ArgumentError review_edit(2, "INST", true)
    @test_throws ArgumentError review_edit(2, "ELEV", Inf)
    mktempdir() do dir
        rows = [(2, Dict{String,Any}("SAMPLEID" => "A1", "INST" => "Old", "ELEV" => 5, "NOTES" => "keep")),
                (3, Dict{String,Any}("SAMPLEID" => "A2", "COORD:LAT" => "43,1"))]
        path = populated_template_fixture(BOLD5_TEMPLATE, joinpath(dir, "in.xlsx"), rows)
        before = read(path)
        s = read_bold(path)
        edits = [review_edit(2, "INST", "New"), review_edit(2, "ELEV", ""), review_edit(3, "COORD:LAT", "43.1"),
                 review_edit(3, "PHYLUM", "Arthropoda"), review_edit(2, "SAMPLEID", "007")]
        out = save_reviewed(s, edits, joinpath(dir, "reviewed.xlsx"))
        @test read(path) == before
        e = read_bold(out)
        @test e.records[1, "INST"] == "New" && ismissing(e.records[1, "ELEV"]) && e.records[1, "NOTES"] == "keep"
        @test e.records[1, "SAMPLEID"] == "007"
        @test e.records[2, "COORD:LAT"] == 43.1 && e.records[2, "PHYLUM"] == "Arthropoda"
        @test e.excel_rows == s.excel_rows && e.headers == s.headers
        names0, entries0 = ItaBOLValidator._read_package(before)
        names1, entries1 = ItaBOLValidator._read_package(read(out))
        @test names1 == names0 && [n for n in names0 if entries1[n] != entries0[n]] == ["xl/worksheets/sheet1.xml"]
        @test_throws ArgumentError save_reviewed(s, edits, out)                                   # exists
        @test_throws ArgumentError save_reviewed(s, [review_edit(9, "INST", "x")], joinpath(dir, "a.xlsx"))
        @test_throws ArgumentError save_reviewed(s, [review_edit(2, "NOPE", "x")], joinpath(dir, "b.xlsx"))
        @test_throws ArgumentError save_reviewed(s, [review_edit(2, "INST", "x"), review_edit(2, "INST", "y")],
                                                 joinpath(dir, "c.xlsx"))
        @test !isfile(joinpath(dir, "a.xlsx")) && !isfile(joinpath(dir, "c.xlsx"))
        # Formula cells are refused.
        XLSX.openxlsx(path; mode="rw") do book
            XLSX.setFormula(book["Submissions"], XLSX.CellRef(2, findfirst(==("ELEV"), s.headers)), "1+1"; value=2)
        end
        s2 = read_bold(path)
        @test_throws ArgumentError save_reviewed(s2, [review_edit(2, "ELEV", "3")], joinpath(dir, "d.xlsx"))
    end
end

@testset "Overview map outlines" begin
    mktempdir() do dir
        root = geodata_root(dir)
        config = joinpath(dir, "layers.toml")
        write(config, LAYERS_TOML)
        registry = load_registry(config; geodata_root=root, log=false)
        try
            id = basemap_layer(registry)
            @test id !== nothing && only(l for l in registry.layers if l.id == id).type === :vector
            @test basemap_layer(registry; layer=id) == id
            @test_throws ArgumentError basemap_layer(registry; layer="nope")
            o = layer_outlines(registry.catalog, id)
            @test !isempty(o.rings) && all(r -> iseven(length(r)) && length(r) >= 8, o.rings)
            lons = [r[k] for r in o.rings for k in 1:2:length(r)]
            lats = [r[k] for r in o.rings for k in 2:2:length(r)]
            @test all(x -> 0 < x < 30, lons) && all(y -> 30 < y < 50, lats)      # WGS84 degrees, not metres
            coarse = layer_outlines(registry.catalog, id; max_vertices=20)
            @test coarse.tolerance > o.tolerance || sum(length, coarse.rings) <= 40
            # Extraction still works after the outline scan (spatial filter reset).
            frame = extract_layers(GeoPoints([41.5], [11.5]), registry)
            @test nrow(frame) == 1
        finally
            close(registry)
        end
    end
end
