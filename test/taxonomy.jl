# Taxonomy completion tests. BOLD is replaced by an in-memory fake: no network.
import JSON3

const BOMBUS = Dict("kingdom" => "Animalia", "phylum" => "Arthropoda", "class" => "Insecta",
                    "order" => "Hymenoptera", "family" => "Apidae", "subfamily" => "Apinae",
                    "tribe" => "Bombini", "genus" => "Bombus")
const PRUNELLA_PLANT = Dict("kingdom" => "Plantae", "phylum" => "Tracheophyta", "class" => "Magnoliopsida",
                            "order" => "Lamiales", "family" => "Lamiaceae", "genus" => "Prunella")
const PRUNELLA_BIRD = Dict("kingdom" => "Animalia", "phylum" => "Chordata", "class" => "Aves",
                           "order" => "Passeriformes", "family" => "Prunellidae", "genus" => "Prunella")

term(field, name, path; records=10) = Dict("field" => field, "term" => name, "original_term" => name,
                                          "standardized_term" => lowercase(replace(name, " " => "_")),
                                          "scope" => "tax", "records" => records, "tax_path" => path)
species_path(path, name) = merge(path, Dict("species" => name))

"""Fake BOLD: `routes` maps the `partial_term` value of a term search to its response."""
mutable struct FakeBold
    routes::Dict{String,Any}
    calls::Vector{String}
end
FakeBold(routes) = FakeBold(Dict{String,Any}(routes), String[])

function (f::FakeBold)(url)
    push!(f.calls, url)
    q = Dict(map(p -> Pair(split(p, '=')...), split(split(url, '?')[2], '&')))
    unescape(s) = replace(s, r"%([0-9A-F]{2})" => m -> string(Char(parse(UInt8, m[2:3]; base=16))))
    occursin("/terms?", url) || error("unexpected BOLD request: $url")
    key = unescape(q["partial_term"])
    r = get(f.routes, key, Any[])
    r isa Function && (r = r())
    r isa Tuple && return r
    return (200, Pair{String,String}[], Vector{UInt8}(codeunits(JSON3.write(r))))
end

client(fake; kw...) = BoldTaxonomyClient(; min_interval=0, fetch=fake, kw...)

const TERMS = Dict(
    "Bombus terrestris" => [term("species", "Bombus terrestris", species_path(BOMBUS, "Bombus terrestris"); records=1723),
                            term("subspecies", "Bombus terrestris audax",
                                 merge(species_path(BOMBUS, "Bombus terrestris"),
                                       Dict("subspecies" => "Bombus terrestris audax")))],
    "bombus" => [term("genus", "Bombus", BOMBUS; records=18628),
                 term("species", "Bombus terrestris", species_path(BOMBUS, "Bombus terrestris"))],
    "Apidae" => [term("family", "Apidae", Dict(k => BOMBUS[k] for k in ("kingdom", "phylum", "class", "order", "family")))],
    "Prunella" => [term("species", "Prunella vulgaris", species_path(PRUNELLA_PLANT, "Prunella vulgaris")),
                   term("genus", "Prunella", PRUNELLA_BIRD; records=102),
                   term("genus", "Prunella", PRUNELLA_PLANT; records=90)],
    "Bombux" => Any[])

@testset "Taxonomy: names that can be looked up" begin
    @test taxon_query("SPECIES", " Bombus   terrestris ") == "Bombus terrestris"
    @test taxon_query("SPECIES", "Bombus") === nothing
    @test taxon_query("SPECIES", "Bombus sp.") === nothing
    @test taxon_query("SPECIES", "Bombus cf. terrestris") === nothing
    @test taxon_query("SPECIES", "Bombus sp. 3") === nothing
    @test taxon_query("SPECIES", "Mentha x piperita") == "Mentha x piperita"
    @test taxon_query("SUBSPECIES", "Bombus terrestris audax") == "Bombus terrestris audax"
    @test taxon_query("SUBSPECIES", "Bombus terrestris") === nothing
    @test taxon_query("GENUS", "bombus") == "bombus"
    @test taxon_query("GENUS", "Bombus?") === nothing
    @test taxon_query("FAMILY", "Apidae Bombidae") === nothing
    @test taxon_query("GENUS", missing) === nothing && taxon_query("GENUS", "  ") === nothing
    @test taxon_query("GENUS", 12) === nothing
    @test taxon_case("GENUS", "baetis") == "Baetis" && taxon_case("FAMILY", "APIDAE") == "Apidae"
    @test taxon_case("SPECIES", " bombus   TERRESTRIS ") == "Bombus terrestris"
    @test taxon_case("SUBSPECIES", "Bombus terrestris Audax") == "Bombus terrestris audax"
    @test taxon_case("SPECIES", "Mentha X piperita") == "Mentha x piperita"
    @test taxon_case("SPECIES", "Bombus sp. A") === nothing             # open nomenclature untouched
end

@testset "Taxonomy: lookups" begin
    fake = FakeBold(TERMS)
    c = client(fake)
    r = lookup_taxon(c, "species", "Bombus terrestris")
    @test r.status === :found && r.lineage["tribe"] == "Bombini" && r.lineage["genus"] == "Bombus"
    @test !haskey(r.lineage, "subspecies")                     # descendants are ignored
    g = lookup_taxon(c, "genus", "bombus")                     # case-insensitive, BOLD spelling returned
    @test g.status === :found && g.lineage["genus"] == "Bombus" && g.lineage["family"] == "Apidae"
    @test occursin("partial_term=bombus&limit=100", fake.calls[end])
    a = lookup_taxon(c, "genus", "Prunella")                   # homonyms are never resolved
    @test a.status === :ambiguous && isempty(a.lineage)
    @test occursin("Plantae", a.detail) && occursin("Aves", a.detail)
    n = length(fake.calls)
    @test lookup_taxon(c, "genus", "Bombux").status === :not_found
    @test length(fake.calls) == n + 1                          # complete term list: no fallback request
    @test lookup_taxon(c, "family", "Apidae").lineage["order"] == "Hymenoptera"
    # Cached results send no request; matching ignores case and spacing.
    n = length(fake.calls)
    @test lookup_taxon(c, "species", "bombus  TERRESTRIS").status === :found
    @test lookup_taxon(c, "genus", "Prunella").status === :ambiguous
    @test lookup_taxon(c, "genus", "Bombux").status === :not_found
    @test length(fake.calls) == n
    @test_throws ArgumentError lookup_taxon(c, "kingdom", "Animalia")
end

@testset "Taxonomy: lineages from descendants" begin
    baetis = Dict("kingdom" => "Animalia", "phylum" => "Arthropoda", "class" => "Insecta",
                  "order" => "Ephemeroptera", "family" => "Baetidae", "subfamily" => "Baetinae", "genus" => "Baetis")
    morus_plant = Dict("kingdom" => "Plantae", "phylum" => "Tracheophyta", "class" => "Magnoliopsida",
                       "order" => "Rosales", "family" => "Moraceae", "genus" => "Morus")
    morus_bird = Dict("kingdom" => "Animalia", "phylum" => "Chordata", "class" => "Aves",
                      "order" => "Suliformes", "family" => "Sulidae", "genus" => "Morus")
    fake = FakeBold(Dict(
        # Only species are listed (as BOLD does for Baetis); one path lacks the subfamily.
        "baetis" => [term("species", "Baetis rhodani", species_path(baetis, "Baetis rhodani")),
                     term("species", "Baetis alpinus", delete!(species_path(baetis, "Baetis alpinus"), "subfamily")),
                     term("genus", "Baetisca", Dict("genus" => "Baetisca", "family" => "Baetiscidae"))],
        # The plant genus appears only through one of its species: still a homonym.
        "Morus" => [term("genus", "Morus", morus_bird; records=500),
                    term("species", "Morus alba", species_path(morus_plant, "Morus alba"))],
        # Paths that disagree below the family are merged without the disputed rank.
        "Bombus" => [term("species", "Bombus a", merge(species_path(BOMBUS, "Bombus a"), Dict("tribe" => "Bombini"))),
                     term("species", "Bombus b", merge(species_path(BOMBUS, "Bombus b"), Dict("tribe" => "Other")))]))
    c = client(fake)
    r = lookup_taxon(c, "genus", "baetis")
    @test r.status === :found
    @test r.lineage == baetis                                  # genus spelling and subfamily from the paths
    @test !haskey(r.lineage, "species")
    m = lookup_taxon(c, "genus", "Morus")
    @test m.status === :ambiguous && occursin("Plantae", m.detail) && occursin("Aves", m.detail)
    b = lookup_taxon(c, "genus", "Bombus")
    @test b.status === :found && !haskey(b.lineage, "tribe") && b.lineage["family"] == "Apidae"
end

@testset "Taxonomy: a full term page is never trusted (IBV10)" begin
    limit = ItaBOLValidator.TERMS_LIMIT
    carabus = Dict("kingdom" => "Animalia", "phylum" => "Arthropoda", "class" => "Insecta",
                   "order" => "Coleoptera", "family" => "Carabidae", "genus" => "Carabus")
    # One lineage on a full page: a homonym with fewer records may lie beyond it.
    one_group = [term("species", "Carabus x$(i)", species_path(carabus, "Carabus x$(i)")) for i in 1:limit]
    # The taxon itself beyond a full page of other names sharing the prefix.
    others = [term("species", "Carabusia x$(i)", Dict("genus" => "Carabusia", "species" => "Carabusia x$(i)"))
              for i in 1:limit]
    # Just below the limit: the list is complete and the lineage is trusted.
    complete = one_group[1:limit - 1]
    fake = FakeBold(Dict("Carabus" => one_group, "Carabusx" => others, "carabus" => complete))
    c = client(fake)
    r = lookup_taxon(c, "genus", "Carabus")
    @test r.status === :ambiguous && isempty(r.lineage) && occursin("cannot be verified", r.detail)
    @test occursin("limit=$limit", fake.calls[1]) && length(fake.calls) == 1      # no other endpoint
    @test lookup_taxon(c, "genus", "Carabusx").status === :ambiguous
    @test lookup_taxon(client(fake), "genus", "carabus").status === :found
end

@testset "Taxonomy: requests are spaced across clients" begin
    fake = FakeBold(TERMS)
    a = BoldTaxonomyClient(; min_interval=0.3, fetch=fake)
    b = BoldTaxonomyClient(; min_interval=0.3, fetch=fake)
    t = @elapsed begin
        x = Threads.@spawn lookup_taxon(a, "genus", "bombus")
        y = Threads.@spawn lookup_taxon(b, "family", "Apidae")
        fetch(x), fetch(y)
    end
    @test t >= 0.3 && length(fake.calls) == 2
end

@testset "Taxonomy: rate limits, retries and failures" begin
    # Requests are spaced by min_interval.
    fake = FakeBold(TERMS)
    c = BoldTaxonomyClient(; min_interval=0.2, fetch=fake)
    t = @elapsed for name in ("Bombus terrestris", "bombus", "Apidae")
        lookup_taxon(c, lowercase(name) == "apidae" ? "family" : occursin(' ', name) ? "species" : "genus", name)
    end
    @test t >= 0.4 && c.requests == 3

    # 429 with Retry-After is retried, then succeeds.
    answers = Any[(429, ["Retry-After" => "0"], UInt8[]), TERMS["bombus"]]
    fake = FakeBold(Dict("bombus" => () -> popfirst!(answers)))
    c = client(fake)
    @test lookup_taxon(c, "genus", "bombus").status === :found && c.requests == 2

    # Persistent 429: the lookup is skipped and no request is sent while blocked.
    fake = FakeBold(Dict("bombus" => () -> (429, ["Retry-After" => "0"], UInt8[]),
                         "Apidae" => TERMS["Apidae"]))
    c = client(fake; max_retries=1, block_seconds=60)
    r = lookup_taxon(c, "genus", "bombus")
    @test r.status === :skipped && length(fake.calls) == 2 && c.blocked_until > time()
    @test lookup_taxon(c, "family", "Apidae").status === :skipped && length(fake.calls) == 2
    @test isempty(c.cache)                                      # failures are not cached

    # Server errors and invalid responses are errors, retried then reported.
    fake = FakeBold(Dict("bombus" => () -> (503, Pair{String,String}[], UInt8[]),
                         "Apidae" => () -> (200, Pair{String,String}[], Vector{UInt8}(codeunits("<html>")))))
    c = client(fake; max_retries=1)
    r = lookup_taxon(c, "genus", "bombus")
    @test r.status === :error && occursin("HTTP 503", r.detail) && length(fake.calls) == 2
    @test lookup_taxon(c, "family", "Apidae").status === :error
    fake = FakeBold(Dict("bombus" => () -> error("connection refused")))
    r = lookup_taxon(client(fake; max_retries=0), "genus", "bombus")
    @test r.status === :error && occursin("network error", r.detail)
    @test_throws ArgumentError BoldTaxonomyClient(; base_url="http://example.org/api")
end

const TAXON_ROWS = [
    (2, Dict{String,Any}("SAMPLEID" => "T1", "SPECIES" => "Bombus terrestris")),
    (3, Dict{String,Any}("SAMPLEID" => "T2", "GENUS" => "bombus", "FAMILY" => "APIDAE")),
    (4, Dict{String,Any}("SAMPLEID" => "T3", "GENUS" => "Prunella")),
    (5, Dict{String,Any}("SAMPLEID" => "T4", "SPECIES" => "Bombus terrestris", "CLASS" => "Aves")),
    (6, Dict{String,Any}("SAMPLEID" => "T5", "SPECIES" => "Bombus sp.", "FAMILY" => "Apidae")),
    (7, Dict{String,Any}("SAMPLEID" => "T6", "NOTES" => "no taxonomy")),
    (8, Dict{String,Any}("SAMPLEID" => "T7", "PHYLUM" => "Arthropoda")),
    (9, Dict{String,Any}("SAMPLEID" => "T8", "GENUS" => "bombux")),
    (10, Dict{String,Any}("SAMPLEID" => "T9", "SPECIES" => "Bombus  terrestris", "PHYLUM" => "Arthropoda")),
]

@testset "Taxonomy: completion of a real BOLD5 workbook" begin
    template = joinpath(@__DIR__, "data", "BOLD5_BCDM_Specimen_Submission_SinglePage.xlsx")
    mktempdir() do dir
        root = geodata_root(dir)
        config = joinpath(dir, "layers.toml")
        write(config, LAYERS_TOML)
        path = populated_template_fixture(template, joinpath(dir, "taxa.xlsx"), TAXON_ROWS)
        before = read(path)
        submission = read_bold(path)
        registry = load_registry(config; geodata_root=root, log=false)
        try
            columns, names, unqueryable = taxonomy_queries(submission)
            @test columns == ["SPECIES", "GENUS", "GENUS", "SPECIES", "FAMILY", nothing, nothing, "GENUS", "SPECIES"]
            @test names[9] == "Bombus terrestris" && occursin("SPECIES 'Bombus sp.'", unqueryable[5])

            fake = FakeBold(TERMS)
            c = client(fake)
            completion = complete_taxonomy(submission, c)
            # Distinct (rank, name) pairs only; the two spellings of Bombus terrestris share one lookup.
            @test completion.distinct_names == 5 && completion.network_lookups == 5 && length(fake.calls) == 5
            @test [l === nothing ? nothing : l.status for l in completion.lookups] ==
                  [:found, :found, :ambiguous, :found, :found, nothing, nothing, :not_found, :found]

            @test_throws ArgumentError preview_enrichment(submission, registry; fields=String[])
            preview = preview_enrichment(submission, registry; fields=String[], taxonomy=completion,
                                         identifier_header="SAMPLEID")
            @test all(==(TAXONOMY_SOURCE), preview.source_layer)
            get_row(id, f) = only(eachrow(preview[(preview.specimen_id .== id) .& (preview.field .== f), :]))
            has_row(id, f) = any((preview.specimen_id .== id) .& (preview.field .== f))
            # T1: every rank above SPECIES filled; nothing below.
            @test [get_row("T1", f).proposed for f in TAXON_COLUMNS[1:7]] ==
                  ["Arthropoda", "Insecta", "Hymenoptera", "Apidae", "Apinae", "Bombini", "Bombus"]
            @test all(f -> get_row("T1", f).status == "fill", TAXON_COLUMNS[1:7]) && !has_row("T1", "SUBSPECIES")
            # T2: FAMILY "APIDAE" and the queried GENUS "bombus" match BOLD except for the capitals:
            # they take BOLD's spelling; lower ranks are untouched.
            @test get_row("T2", "FAMILY").status == "case_fixed" && get_row("T2", "FAMILY").proposed == "Apidae"
            @test get_row("T2", "GENUS").status == "case_fixed" && get_row("T2", "GENUS").proposed == "Bombus"
            @test get_row("T2", "SUBFAMILY").proposed == "Apinae" && !has_row("T2", "SPECIES")
            # T4 conflicts with BOLD: no capitalisation change either.
            @test !any(r -> r.status == "case_fixed", eachrow(preview[preview.specimen_id .== "T4", :]))
            # T3: homonyms, nothing proposed.
            @test all(f -> get_row("T3", f).status == "no_value" && occursin("ambiguous", get_row("T3", f).detail),
                      TAXON_COLUMNS[1:6])
            # T4: CLASS conflicts with BOLD: kept, and nothing filled for the record.
            @test get_row("T4", "CLASS").status == "conflict" && get_row("T4", "CLASS").proposed == "Insecta"
            @test get_row("T4", "PHYLUM").status == "no_value" && occursin("conflicts with CLASS 'Aves'",
                                                                           get_row("T4", "PHYLUM").detail)
            # T5: open nomenclature in SPECIES, so FAMILY is the query; GENUS stays empty.
            @test get_row("T5", "ORDER").status == "fill" && !has_row("T5", "SUBFAMILY") && !has_row("T5", "GENUS")
            @test !has_row("T6", "PHYLUM") && !has_row("T7", "PHYLUM")
            @test get_row("T8", "FAMILY").status == "no_value" && occursin("not found", get_row("T8", "FAMILY").detail)
            # Not in BOLD: the capitalisation rule alone applies.
            @test get_row("T8", "GENUS").status == "case_fixed" && get_row("T8", "GENUS").proposed == "Bombux"
            @test occursin("not confirmed by BOLD", get_row("T8", "GENUS").detail)
            @test get_row("T9", "PHYLUM").status == "unchanged" && get_row("T9", "TRIBE").status == "fill"

            # Combined with the geographic fields (no coordinates here) and written.
            result = enrich_workbook(submission, registry, joinpath(dir, "out"); taxonomy=completion,
                                     identifier_header="SAMPLEID")
            @test read(path) == before
            enriched = read_bold(result.workbook)
            @test enriched.excel_rows == submission.excel_rows && enriched.headers == submission.headers
            @test Vector(enriched.records[1, collect(TAXON_COLUMNS[1:8])]) ==
                  ["Arthropoda", "Insecta", "Hymenoptera", "Apidae", "Apinae", "Bombini", "Bombus", "Bombus terrestris"]
            @test enriched.records[2, "FAMILY"] == "Apidae" && enriched.records[2, "GENUS"] == "Bombus"
            @test enriched.records[8, "GENUS"] == "Bombux"
            @test result.report["taxon_names_recapitalised"] == 3
            @test result.report["taxonomy"]["per_rank"]["GENUS"]["case_fixed"] == 2
            @test ismissing(enriched.records[2, "SPECIES"])
            @test enriched.records[4, "CLASS"] == "Aves" && ismissing(enriched.records[4, "PHYLUM"])
            @test all(ismissing, enriched.records[3, collect(TAXON_COLUMNS[1:6])])
            @test enriched.records[5, "SPECIES"] == "Bombus sp." && ismissing(enriched.records[5, "GENUS"])
            @test enriched.records[6, "NOTES"] == "no taxonomy" && all(ismissing, enriched.records[6, collect(TAXON_COLUMNS)])
            tax = result.report["taxonomy"]
            @test tax["distinct_names"] == 5 && tax["conflict_excel_rows"] == [5]
            @test tax["per_rank"]["PHYLUM"]["filled"] == 3 && tax["per_rank"]["PHYLUM"]["already_matching"] == 1
            @test haskey(tax["names_not_resolved"], "ambiguous") && haskey(tax["names_not_resolved"], "not_found")
            @test result.report["options"]["taxonomy"] == true
            report = TOML.parsefile(joinpath(result.directory, "report.toml"))
            @test report["taxonomy"]["records_by_lookup_status"]["found"] == 5
            changes = CSV.read(joinpath(result.directory, "changes.csv"), DataFrame)
            @test count(==("fill"), changes.status) == count(==("fill"), result.preview.status)

            # A second run reuses the cache and the lookup limit stops new names only.
            fake2 = FakeBold(TERMS)
            c2 = client(fake2; max_lookups=2)
            limited = complete_taxonomy(submission, c2)
            @test limited.network_lookups == 2 && count(l -> l !== nothing && l.status === :skipped, limited.lookups) == 3
            again = complete_taxonomy(submission, c)
            @test again.network_lookups == 0 && length(fake.calls) == 5
        finally
            close(registry)
        end
    end
end

@testset "Taxonomy: hourly cap on BOLD requests (SEC1)" begin
    empty!(ItaBOLValidator.BOLD_RECENT_REQUESTS)
    fake = FakeBold(TERMS)
    c = BoldTaxonomyClient(; min_interval=0, max_per_hour=2, fetch=fake)
    @test lookup_taxon(c, "genus", "bombus").status === :found
    @test lookup_taxon(c, "family", "Apidae").status === :found
    r = lookup_taxon(c, "species", "Bombus terrestris")
    @test r.status === :skipped && occursin("hourly limit of 2", r.detail) && length(fake.calls) == 2
    @test length(ItaBOLValidator.BOLD_RECENT_REQUESTS) == 2
    # Clients without a cap record nothing, so the list stays bounded.
    lookup_taxon(client(FakeBold(TERMS)), "genus", "Prunella")
    @test length(ItaBOLValidator.BOLD_RECENT_REQUESTS) == 2
    empty!(ItaBOLValidator.BOLD_RECENT_REQUESTS)
    @test_throws ArgumentError BoldTaxonomyClient(; max_per_hour=-1)
end
