# End-to-end enrichment benchmark on SYNTHETIC geodata and workbooks.
#
#   julia --project=. bench/enrichment_scaling.jl setup DIR          # build geodata once
#   julia --project=. --threads=2 bench/enrichment_scaling.jl run DIR N
#
# Each `run` is a fresh process: a 20-record warm-up excludes compilation, then
# read_bold and enrich_workbook are timed for N specimens; peak RSS is reported.
# Results describe these synthetic layers only; real national datasets (far
# more vertices, larger rasters) will be slower.
using ItaBOLValidator
using Random: MersenneTwister
import ArchGDAL as AG
import GDAL

include(joinpath(@__DIR__, "..", "test", "geo_fixtures.jl"))

const TEMPLATE = joinpath(@__DIR__, "..", "test", "data", "BOLD5_BCDM_Specimen_Submission_SinglePage.xlsx")
const X0, Y0, X1, Y1 = 300_000.0, 4_000_000.0, 1_100_000.0, 5_200_000.0   # EPSG:32632 extent

function grid_polygons(path, nx, ny, max_segment; layer)
    w, h = (X1 - X0) / nx, (Y1 - Y0) / ny
    AG.create(path; driver=AG.getdriver("GPKG")) do ds
        lyr = AG.createlayer(name=layer, dataset=ds, geom=AG.wkbPolygon, spatialref=AG.importUserInput("EPSG:32632"))
        AG.addfielddefn!(lyr, "name", AG.OFTString)
        for i in 0:(nx - 1), j in 0:(ny - 1)
            g = AG.fromWKT(box(X0 + i * w, Y0 + j * h, X0 + (i + 1) * w, Y0 + (j + 1) * h))
            AG.segmentize!(g, max_segment)
            AG.addfeature(lyr) do f
                AG.setgeom!(f, g)
                AG.setfield!(f, 0, "$(layer)_$(i)_$(j)")
            end
        end
    end
end

function big_raster(path, ::Type{T}, value) where {T}
    width, height, block = 8000, 12000, 256
    AG.create(path; driver=AG.getdriver("GTiff"), width=width, height=height, nbands=1, dtype=T,
              options=["TILED=YES", "COMPRESS=DEFLATE", "BLOCKXSIZE=$block", "BLOCKYSIZE=$block", "BIGTIFF=YES"]) do ds
        set_geotransform!(ds, [X0, 100.0, 0.0, Y1, 0.0, -100.0])
        AG.setproj!(ds, AG.toWKT(AG.importUserInput("EPSG:32632")))
        band = AG.getband(ds, 1)
        T <: Integer && T !== UInt8 && AG.setnodatavalue!(band, -32768)
        buffer = Matrix{T}(undef, width, block)
        for y0 in 0:block:(height - 1)
            rows = min(block, height - y0)
            for l in 1:rows, p in 1:width
                buffer[p, l] = value(p - 1, y0 + l - 1)
            end
            AG.write!(band, rows == block ? buffer : buffer[:, 1:rows], 0, y0, width, rows)
        end
    end
end

function setup(dir)
    root = mkpath(joinpath(dir, "geodata"))
    grid_polygons(joinpath(root, "country.gpkg"), 1, 1, 200.0; layer="country")        # ~20,000 vertices
    grid_polygons(joinpath(root, "regions.gpkg"), 5, 4, 300.0; layer="regions")        # 20 polygons
    grid_polygons(joinpath(root, "provinces.gpkg"), 11, 10, 300.0; layer="provinces")  # 110 polygons
    big_raster(joinpath(root, "dem.tif"), Int16, (p, l) -> Int16((p + l) % 3000))
    big_raster(joinpath(root, "habitat.tif"), UInt8, (p, l) -> UInt8(1 + (p ÷ 500 + l ÷ 500) % 12))
    vector(id, path) = """
    [[layers]]
    id = "$id"
    name = "Synthetic $id"
    type = "vector"
    path = "$path"
    attribute = "name"
    output = "$id"
    overlap = "ambiguous"
    version = "synthetic"
    source = "bench/enrichment_scaling.jl"
    """
    habitat_map = join(["$c = \"habitat term $c\"" for c in 1:10], "\n")
    write(joinpath(dir, "layers.toml"), """
    schema_version = 1
    $(vector("country", "country.gpkg"))
    $(vector("regions", "regions.gpkg"))
    $(vector("provinces", "provinces.gpkg"))
    [[layers]]
    id = "dem"
    name = "Synthetic DEM"
    type = "raster"
    kind = "continuous"
    path = "dem.tif"
    unit = "m"
    measure = "elevation"
    output = "elevation"
    version = "synthetic"
    source = "bench/enrichment_scaling.jl"
    [[layers]]
    id = "habitat"
    name = "Synthetic habitat"
    type = "raster"
    kind = "categorical"
    path = "habitat.tif"
    output = "habitat"
    version = "synthetic"
    source = "bench/enrichment_scaling.jl"
    [layers.value_map]
    $habitat_map
    [[bold_fields]]
    column = "COUNTRY/OCEAN"
    layers = ["country"]
    [[bold_fields]]
    column = "REGION"
    layers = ["regions"]
    [[bold_fields]]
    column = "PROVINCE/STATE"
    layers = ["provinces"]
    [[bold_fields]]
    column = "ELEV"
    layers = ["dem"]
    [[bold_fields]]
    column = "HABITAT"
    layers = ["habitat"]
    """)
    println("geodata ready in $root")
end

const HEADERS = [
    "SAMPLEID", "FIELDID", "MUSEUMID", "COLLECTION_CODE", "INST", "FUNDING_SRC",
    "PHYLUM", "CLASS", "ORDER", "FAMILY", "SUBFAMILY", "TRIBE", "GENUS",
    "SPECIES", "SUBSPECIES", "IDENTIFIED_BY", "IDENTIFICATION_METHOD", "TAXONOMY_NOTES",
    "SEX", "REPRODUCTION", "LIFE_STAGE", "SHORT_NOTE", "NOTES", "VOUCHER_TYPE",
    "TISSUE_TYPE", "SPECIMEN_LINKOUT", "ASSOCIATED_TAXA", "ASSOCIATED_SPECIMENS",
    "COLLECTORS", "COLLECTION_DATE_START", "COLLECTION_DATE_END", "COUNTRY/OCEAN",
    "PROVINCE/STATE", "REGION", "SECTOR", "SITE", "COORD:LAT", "COORD:LON",
    "ELEV", "DEPTH", "ELEV_ACCURACY", "DEPTH_ACCURACY", "COORD_SOURCE",
    "COORD_ACCURACY", "COLLECTION_TIME", "HABITAT", "SAMPLING_PROTOCOL",
    "COLLECTION_NOTES", "SITE_CODE", "COLLECTION_EVENT_ID",
]
const FILLED = ["SAMPLEID", "FIELDID", "INST", "PHYLUM", "CLASS", "ORDER", "FAMILY", "GENUS", "SPECIES",
                "IDENTIFIED_BY", "LIFE_STAGE", "NOTES", "VOUCHER_TYPE", "TISSUE_TYPE", "COLLECTORS",
                "COLLECTION_DATE_START", "SITE", "COORD:LAT", "COORD:LON", "SAMPLING_PROTOCOL"]

"""Append N synthetic records (20 filled columns) to the real BOLD5 template."""
function workbook(path, n; seed=1)
    rng = MersenneTwister(seed)
    names, entries = ItaBOLValidator._read_package(read(TEMPLATE))
    part = "xl/worksheets/sheet1.xml"
    xml = String(copy(entries[part]))
    lon, lat = reproject_points(X0 .+ (X1 - X0 - 1) .* rand(rng, n), Y0 .+ (Y1 - Y0 - 1) .* rand(rng, n),
                                "EPSG:32632", "EPSG:4326")
    io = IOBuffer()
    for i in 1:n
        r = i + 1
        print(io, "<row r=\"", r, "\">")
        for (c, h) in enumerate(HEADERS)
            h in FILLED || (h == "COUNTRY/OCEAN" && i % 10 == 0) || continue
            ref = ItaBOLValidator._column_letters(c) * string(r)
            if h == "COORD:LAT" || h == "COORD:LON"
                v = h == "COORD:LAT" ? lat[i] : lon[i]
                i % 100 == 0 && h == "COORD:LAT" ? print(io, "<c r=\"$ref\" t=\"inlineStr\"><is><t>41,9</t></is></c>") :
                    print(io, "<c r=\"$ref\"><v>", round(v; digits=6), "</v></c>")
            else
                text = h == "SAMPLEID" ? "SYN$(lpad(i, 7, '0'))" : h == "COUNTRY/OCEAN" ? "Italy" : "synthetic $(h) $(i % 97)"
                print(io, "<c r=\"$ref\" t=\"inlineStr\"><is><t>", text, "</t></is></c>")
            end
        end
        print(io, "</row>")
    end
    rows = String(take!(io))
    edited = occursin("<sheetData/>", xml) ? replace(xml, "<sheetData/>" => "<sheetData>" * rows * "</sheetData>") :
             replace(xml, "</sheetData>" => rows * "</sheetData>"; count=1)
    ItaBOLValidator._write_package(path, names, entries, Dict(part => Vector{UInt8}(codeunits(edited))))
    return path
end

function run(dir, n)
    registry = load_registry(joinpath(dir, "layers.toml"); geodata_root=joinpath(dir, "geodata"), log=false)
    work = mktempdir(dir)
    try
        warm = workbook(joinpath(work, "warm.xlsx"), 20)
        enrich_workbook(read_bold(warm), registry, joinpath(work, "warm"); identifier_header="SAMPLEID")
        rss_ready = Sys.maxrss()
        path = workbook(joinpath(work, "n$n.xlsx"), n; seed=n)
        GC.gc()
        t_read = @elapsed submission = read_bold(path)
        t_enrich = @elapsed result = enrich_workbook(submission, registry, joinpath(work, "out");
                                                     identifier_header="SAMPLEID")
        r = result.report
        println(join(["specimens=$n", "workbook_mb=$(round(filesize(path) / 2^20; digits=2))",
                      "read_s=$(round(t_read; digits=2))", "enrich_s=$(round(t_enrich; digits=2))",
                      "populated=$(r["fields_populated"])", "preserved=$(r["existing_values_preserved"])",
                      "invalid=$(r["invalid_coordinates"])",
                      "rss_after_warmup_mb=$(round(rss_ready / 2^20; digits=0))",
                      "peak_rss_mb=$(round(Sys.maxrss() / 2^20; digits=0))", "threads=$(Threads.nthreads())"], " "))
    finally
        close(registry)
        rm(work; recursive=true, force=true)
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    if ARGS[1] == "setup"
        setup(ARGS[2])
    else
        run(ARGS[2], parse(Int, ARGS[3]))
    end
end
