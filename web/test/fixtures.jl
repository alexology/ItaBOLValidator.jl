# Shared fixtures for the web tests and the browser check (web/test/browser_check.py).
import JSON3
import ZipArchives
using ItaBOLValidator

const PKG_TEST = joinpath(@__DIR__, "..", "..", "test")
include(joinpath(PKG_TEST, "fixtures.jl"))
include(joinpath(PKG_TEST, "geo_fixtures.jl"))

const XLSX_TYPE = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

function web_fixture(dir)
    root = mkpath(joinpath(dir, "geodata"))
    write_polygons(joinpath(root, "cells.gpkg"), degree_cells(); crs="EPSG:4326", layer="cells")
    dem = Int16[100 * p + l for p in 0:3, l in 0:3]           # 1-degree pixels over 10-14 E, 40-44 N
    write_raster(joinpath(root, "dem.tif"), dem; gt=[10.0, 1.0, 0.0, 44.0, 0.0, -1.0], crs="EPSG:4326")
    registry = joinpath(dir, "layers.toml")
    write(registry, """
    schema_version = 1
    [[layers]]
    id = "country"
    name = "Synthetic country"
    type = "vector"
    path = "cells.gpkg"
    attribute = "name"
    output = "country"
    overlap = "ambiguous"
    version = "web-test-1"
    source = "synthetic"
    [layers.value_map]
    cell_41_11 = "Italy"
    cell_42_12 = "Italy"
    [[layers]]
    id = "dem"
    name = "Synthetic elevation"
    type = "raster"
    kind = "continuous"
    path = "dem.tif"
    unit = "m"
    measure = "elevation"
    output = "elevation"
    version = "web-test-1"
    source = "synthetic"
    [[layers]]
    id = "missing"
    name = "Not installed"
    type = "raster"
    kind = "continuous"
    path = "nothing.tif"
    output = "nothing"
    version = "0"
    source = "none"
    [[bold_fields]]
    column = "COUNTRY/OCEAN"
    layers = ["country"]
    [[bold_fields]]
    column = "ELEV"
    layers = ["dem"]
    """)
    records = [synthetic_record("S1", 41.5, 11.5), synthetic_record("S2", 42.5, 12.5),
               synthetic_record("S3", "bad", 12.0), synthetic_record("S4", 40.5, 10.5)]
    for r in records
        delete!(r, "COUNTRY/OCEAN")
        delete!(r, "ELEV")
    end
    records[2]["COUNTRY/OCEAN"] = "Italia"                     # existing value
    workbook = write_fixture(joinpath(dir, "Specimens 2026.xlsx"); records)
    return root, registry, workbook
end

"""A workbook with the BOLD taxonomic columns (synthetic otherwise)."""
function taxonomy_fixture(dir)
    headers = vcat(["SAMPLEID", "FIELD ID", "NOTES", "COLLECTION DATE"], collect(TAXON_COLUMNS),
                   ["SYNTHETIC METADATA $i" for i in 1:23], collect(GEOGRAPHIC_HEADERS))
    records = [Dict{String,Any}("SAMPLEID" => "T1", "SPECIES" => "Bombus terrestris", "COORD:LAT" => 41.5,
                                "COORD:LON" => 11.5),
               Dict{String,Any}("SAMPLEID" => "T2", "SPECIES" => "bombus terrestris", "CLASS" => "Aves"),
               Dict{String,Any}("SAMPLEID" => "T3", "GENUS" => "Nomennescio"),
               Dict{String,Any}("SAMPLEID" => "T4", "NOTES" => "no taxonomy")]
    return write_fixture(joinpath(dir, "Taxa.xlsx"); headers, records)
end

const BOLD5_TEMPLATE = joinpath(PKG_TEST, "data", "BOLD5_BCDM_Specimen_Submission_SinglePage.xlsx")

"""A workbook with the 50 BOLD5 headers: one BOLD-compliant record and two that are not."""
function review_fixture(dir)
    headers = read_bold(BOLD5_TEMPLATE).headers
    good = Dict{String,Any}("SAMPLEID" => "R1", "FIELDID" => "F1", "INST" => "Museo", "PHYLUM" => "Arthropoda",
                            "COUNTRY/OCEAN" => "Italy", "COORD:LAT" => 41.5, "COORD:LON" => 11.5)
    records = [good,
               merge(good, Dict{String,Any}("SAMPLEID" => "R2", "INST" => missing, "COORD:LAT" => 42.5,
                                            "COORD:LON" => 12.5)),
               merge(good, Dict{String,Any}("SAMPLEID" => "R3", "COORD:LAT" => "41,7"))]
    for r in records
        filter!(p -> !ismissing(p.second), r)
    end
    return write_fixture(joinpath(dir, "Review.xlsx"); headers, records, header_row=1)
end

"""Offline stand-in for the BOLD term search: knows only Bombus terrestris."""
function fake_bold(calls::Ref{Int})
    path = Dict("kingdom" => "Animalia", "phylum" => "Arthropoda", "class" => "Insecta", "order" => "Hymenoptera",
                "family" => "Apidae", "subfamily" => "Apinae", "tribe" => "Bombini", "genus" => "Bombus",
                "species" => "Bombus terrestris")
    return function (url)
        calls[] += 1
        body = occursin(r"partial_term=bombus%20terrestris&"i, url) ?
            [Dict("field" => "species", "term" => "Bombus terrestris", "standardized_term" => "bombus_terrestris",
                  "scope" => "tax", "records" => 1723, "tax_path" => path)] : Any[]
        return (200, Pair{String,String}[], Vector{UInt8}(codeunits(JSON3.write(body))))
    end
end

