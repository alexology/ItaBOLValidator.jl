# Checks and timings with REAL ISTAT administrative boundaries (not distributed).
#
#   julia --project=. --threads=2 bench/real_boundaries.jl GEODATA_DIR [ORACLE_POINTS]
#
# GEODATA_DIR holds the unzipped ISTAT "Limiti" folders (Com, ProvCM, Reg,
# RipGeo *_WGS84 shapefiles, EPSG:32632 despite the name). The script
#  1. loads them through a registry (validation, metadata),
#  2. checks well-known places, enclaves and exclaves,
#  3. compares the engine with an independent even-odd ray-casting oracle on
#     random points generated in EPSG:32632 (municipalities),
#  4. times extraction and full workbook enrichment for 1,000-100,000 specimens.
using ItaBOLValidator
import ArchGDAL as AG
import GDAL
using Random: MersenneTwister

include(joinpath(@__DIR__, "enrichment_scaling.jl"))   # workbook generator, reprojection helpers

geodata = abspath(ARGS[1])
oracle_points = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 5000
shp(stem) = "$stem/$(stem)_WGS84.shp"

function registry_file(dir)
    path = joinpath(dir, "layers.toml")
    write(path, """
    schema_version = 1
    [[layers]]
    id = "country"
    name = "ISTAT geographic divisions (Italy)"
    type = "vector"
    path = "$(shp("RipGeo01012026"))"
    attribute = "DEN_RIP"
    output = "country"
    overlap = "ambiguous"
    version = "2026-01-01"
    source = "ISTAT, Confini delle unita amministrative a fini statistici"
    [layers.value_map]
    "Nord-ovest" = "Italy"
    "Nord-est" = "Italy"
    "Centro" = "Italy"
    "Sud" = "Italy"
    "Isole" = "Italy"
    [[layers]]
    id = "region"
    name = "ISTAT regions"
    type = "vector"
    path = "$(shp("Reg01012026"))"
    attribute = "DEN_REG"
    output = "region"
    overlap = "ambiguous"
    version = "2026-01-01"
    source = "ISTAT"
    [[layers]]
    id = "province"
    name = "ISTAT provinces and metropolitan cities"
    type = "vector"
    path = "$(shp("ProvCM01012026"))"
    attribute = "DEN_UTS"
    output = "province"
    overlap = "ambiguous"
    version = "2026-01-01"
    source = "ISTAT"
    [[layers]]
    id = "municipality"
    name = "ISTAT municipalities"
    type = "vector"
    path = "$(shp("Com01012026"))"
    attribute = "COMUNE"
    output = "municipality"
    overlap = "ambiguous"
    version = "2026-01-01"
    source = "ISTAT"
    [[bold_fields]]
    column = "COUNTRY/OCEAN"
    layers = ["country"]
    [[bold_fields]]
    column = "REGION"
    layers = ["province"]
    [[bold_fields]]
    column = "PROVINCE/STATE"
    layers = ["region"]
    """)
    return path
end

# --- Independent oracle: even-odd ray casting over every ring of every polygon.
struct OraclePolygon
    name::String
    bbox::NTuple{4,Float64}
    rings::Vector{Matrix{Float64}}
end

function _rings!(rings, g::Ptr{Cvoid})
    t = GDAL.ogr_gt_flatten(GDAL.ogr_g_getgeometrytype(g))
    if t == GDAL.wkbPolygon || t == GDAL.wkbMultiPolygon
        for k in 0:(GDAL.ogr_g_getgeometrycount(g) - 1)
            _rings!(rings, GDAL.ogr_g_getgeometryref(g, k))
        end
    else                                   # a linear ring
        n = GDAL.ogr_g_getpointcount(g)
        ring = Matrix{Float64}(undef, 2, n)
        for i in 1:n
            ring[1, i] = GDAL.ogr_g_getx(g, i - 1)
            ring[2, i] = GDAL.ogr_g_gety(g, i - 1)
        end
        push!(rings, ring)
    end
    return rings
end

function oracle_polygons(path)
    polys = OraclePolygon[]
    AG.read(path) do ds
        for f in AG.getlayer(ds, 0)
            g = GDAL.ogr_f_getgeometryref(f)
            rings = _rings!(Matrix{Float64}[], g)
            xs = reduce(vcat, [r[1, :] for r in rings]); ys = reduce(vcat, [r[2, :] for r in rings])
            push!(polys, OraclePolygon(AG.getfield(f, "COMUNE"), (minimum(xs), minimum(ys), maximum(xs), maximum(ys)), rings))
        end
    end
    return polys
end

function inside(p::OraclePolygon, x, y)
    c = false
    for r in p.rings
        n = size(r, 2)
        j = n
        for i in 1:n
            xi, yi, xj, yj = r[1, i], r[2, i], r[1, j], r[2, j]
            if (yi > y) != (yj > y) && x < (xj - xi) * (y - yi) / (yj - yi) + xi
                c = !c
            end
            j = i
        end
    end
    return c
end

function main()
    work = mktempdir()
    config = registry_file(work)
    t_load = @elapsed registry = load_registry(config; geodata_root=geodata)
    println("registry load + validation: $(round(t_load; digits=2)) s; $registry")
    show(stdout, MIME"text/plain"(), registry_report(registry)[:, [:id, :status, :driver, :crs, :features, :spatial_index]])
    println()

    # Expected values from general knowledge of Italian geography.
    places = [
        ("Colosseo, Roma", 41.8902, 12.4922, "Lazio", "Roma", "Roma"),
        ("Duomo, Milano", 45.4642, 9.1900, "Lombardia", "Milano", "Milano"),
        ("Napoli centro", 40.8518, 14.2681, "Campania", "Napoli", "Napoli"),
        ("Palermo centro", 38.1157, 13.3615, "Sicilia", "Palermo", "Palermo"),
        ("Cagliari centro", 39.2238, 9.1217, "Sardegna", "Cagliari", "Cagliari"),
        ("Trento centro", 46.0664, 11.1257, "Trentino-Alto Adige/Südtirol", "Trento", "Trento"),
        # ISTAT names the supra-municipal unit of Aosta Valley after the region.
        ("Aosta centro", 45.7372, 7.3201, "Valle d'Aosta/Vallée d'Aoste", "Valle d'Aosta/Vallée d'Aoste", "Aosta"),
        ("Lampedusa", 35.5097, 12.6050, "Sicilia", "Agrigento", "Lampedusa e Linosa"),
        ("Campione d'Italia (exclave)", 45.9686, 8.9706, "Lombardia", "Como", "Campione d'Italia"),
        ("San Marino (enclave)", 43.9356, 12.4473, missing, missing, missing),
        ("Basilica di San Pietro (Vatican)", 41.9022, 12.4539, missing, missing, missing),
        ("Lugano (Switzerland)", 46.0037, 8.9511, missing, missing, missing),
        ("Tyrrhenian Sea", 40.0, 12.0, missing, missing, missing),
    ]
    pts = GeoPoints([p[2] for p in places], [p[3] for p in places])
    got = extract_layers(pts, registry)
    println("\nKnown places (expected from general knowledge):")
    failures = 0
    for (i, p) in enumerate(places)
        ok = isequal(got.region[i], p[4]) && isequal(got.province[i], p[5]) && isequal(got.municipality[i], p[6])
        failures += !ok
        println(rpad(p[1], 34), ok ? "OK   " : "DIFF ", got[i, "region"], " / ", got[i, "province"], " / ",
                got[i, "municipality"], " [", got[i, "municipality.status"], "]", ok ? "" : "  expected $(p[4]) / $(p[5]) / $(p[6])")
    end
    println("known places: $(length(places) - failures)/$(length(places)) as expected")

    # Oracle comparison on municipalities.
    t_oracle = @elapsed polys = oracle_polygons(joinpath(geodata, shp("Com01012026")))
    rng = MersenneTwister(2026)
    xs = 320_000 .+ 1_000_000 .* rand(rng, oracle_points)
    ys = 4_000_000 .+ 1_250_000 .* rand(rng, oracle_points)
    lon, lat = reproject_points(xs, ys, "EPSG:32632", "EPSG:4326")
    engine = extract_layers(GeoPoints(lat, lon), registry; layers=["municipality"])
    agree = disagree = 0
    for i in 1:oracle_points
        hits = [p.name for p in polys if p.bbox[1] <= xs[i] <= p.bbox[3] && p.bbox[2] <= ys[i] <= p.bbox[4] && inside(p, xs[i], ys[i])]
        expected = length(hits) == 1 ? only(hits) : missing
        if isequal(expected, engine.municipality[i]) && (length(hits) <= 1)
            agree += 1
        else
            disagree += 1
            disagree <= 10 && println("  disagreement at ($(xs[i]), $(ys[i])): oracle $(hits), engine $(engine.municipality[i]) [$(engine[i, "municipality.status"])]")
        end
    end
    inside_count = count(!ismissing, engine.municipality)
    println("\noracle ($(round(t_oracle; digits=1)) s to load $(length(polys)) municipalities): $agree agree, $disagree disagree " *
            "over $oracle_points random points ($inside_count inside a municipality)")

    # Timings.
    for n in (1_000, 10_000, 100_000)
        r = MersenneTwister(n)
        lo, la = reproject_points(320_000 .+ 1_000_000 .* rand(r, n), 4_000_000 .+ 1_250_000 .* rand(r, n), "EPSG:32632", "EPSG:4326")
        p = GeoPoints(la, lo)
        GC.gc()
        t = @elapsed e = extract_layers(p, registry)
        println("extract 4 layers, $n points: $(round(t; digits=2)) s; inside municipality: $(count(!ismissing, e.municipality)); peak RSS $(round(Sys.maxrss() / 2^20)) MB")
    end
    for n in (1_000, 10_000, 100_000)
        path = workbook(joinpath(work, "n$n.xlsx"), n; seed=n)       # random points over Italy and seas
        GC.gc()
        t_read = @elapsed sub = read_bold(path)
        t = @elapsed res = enrich_workbook(sub, registry, joinpath(work, "out$n"); identifier_header="SAMPLEID")
        println("enrich workbook, $n specimens: read $(round(t_read; digits=2)) s, enrich $(round(t; digits=2)) s, populated $(res.report["fields_populated"]), peak RSS $(round(Sys.maxrss() / 2^20)) MB")
    end
    close(registry)
    rm(work; recursive=true, force=true)
end

main()
