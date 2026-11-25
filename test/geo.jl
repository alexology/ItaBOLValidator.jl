using Random: MersenneTwister

include("geo_fixtures.jl")

const GEO_DIR = mktempdir()
const GEO, ROTATED_GT = geo_fixtures(GEO_DIR)

zones(path=GEO[:utm_gpkg]; kwargs...) =
    VectorLayer("zones", path; attributes=["name", "code"], overlap=:lowest_fid, kwargs...)
cells(; kwargs...) = VectorLayer("cells", GEO[:cells]; attributes=["code"], overlap=:lowest_fid, kwargs...)

@testset "Geo points" begin
    pts = GeoPoints([41.9, "42.1", 95, missing, "41,9", 41.0], [12.5, 13, 12, 12, 12, 181])
    @test pts.status == [:valid, :valid, :latitude_out_of_range, :latitude_missing,
                         :latitude_invalid_format, :longitude_out_of_range]
    @test pts.latitude[1:2] == [41.9, 42.1]
    @test all(isnan, pts.latitude[3:end])
    @test geopoints(pts) === pts
    @test geopoints(([41.0], [12.0])).status == [:valid]
    @test geopoints([validate_coordinates(41, 12)]).longitude == [12.0]
    @test_throws DimensionMismatch GeoPoints([41.0], [12.0, 13.0])
    @test_throws ArgumentError GeoPoints([95.0], [12.0], [:valid])
    @test_throws ArgumentError geopoints("41,12")
end

@testset "Vector extraction: CRS, attributes and formats" begin
    xs, ys = [320000, 380000, 450000, 650000, 610000, 900000], [4610000, 4670000, 4620000, 4650000, 4610000, 4610000]
    pts = points_from("EPSG:32633", xs, ys)
    gpkg = extract_vector(pts, zones())
    shp = extract_vector(pts, zones(GEO[:utm_shp]))
    @test gpkg.status == ["inside", "inside", "inside", "no_match", "inside", "outside_extent"]
    @test isequal(gpkg.name, ["A", "A", "B", missing, "D", missing])
    @test eltype(gpkg.code) == Union{Missing,Int32}
    # WGS84 input was transformed back to the layer CRS (sub-millimetre round trip).
    @test maximum(abs.(gpkg.x .- xs)) < 1e-6
    @test maximum(abs.(gpkg.y .- ys)) < 1e-6
    @test isequal(gpkg.fid, [1, 1, 2, missing, 4, missing])        # GeoPackage FIDs start at 1
    @test isequal(shp.fid, [0, 0, 1, missing, 3, missing])         # Shapefile FIDs start at 0
    @test isequal(shp.status, gpkg.status) && isequal(shp.name, gpkg.name)
    info = GeoCatalog([zones(GEO[:utm_shp])]) |> c -> (i = layer_info(c, "zones"); close(c); i)
    @test !info.spatial_index && info.envelope_index && info.features == 4   # no .qix: envelope index
    @test gpkg.match_fids[2] == [1, 3] && gpkg.n_matches == [1, 2, 1, 0, 1, 0]
    # Point 4 lies in the hole of polygon D.
    @test gpkg.status[4] == "no_match"
    renamed = extract_vector(pts, VectorLayer("z", GEO[:utm_gpkg]; attributes=["name" => "zone_name"],
                                              overlap=:lowest_fid))
    @test "zone_name" in names(renamed) && !("name" in names(renamed))
    nulls = extract_vector(points_from("EPSG:32633", [380000], [4670000]), zones(; overlap=:highest_fid))
    @test nulls.fid == [3] && ismissing(nulls.name[1])           # null attribute -> missing

    # Second projected CRS (LAEA Europe) and a closed-form check in Web Mercator.
    laea = extract_vector(points_from("EPSG:32633", [350000, 450000], [4650000, 4650000]),
                          VectorLayer("l", GEO[:laea]; attributes=["name"], overlap=:ambiguous))
    @test laea.name == ["A", "B"]
    lat, lon = [41.9, -33.5, 0.0], [12.5, 151.2, -179.9]
    merc = extract_vector(GeoPoints(lat, lon), VectorLayer("m", GEO[:mercator]; attributes=String[], overlap=:ambiguous))
    R = 6378137.0
    @test merc.x ≈ R .* deg2rad.(lon) atol = 1e-6
    @test merc.y ≈ R .* log.(tan.(π / 4 .+ deg2rad.(lat) ./ 2)) atol = 1e-6
    # Geographic layer: x is longitude and y is latitude (traditional GIS order).
    geo = extract_vector(GeoPoints([42.5], [11.5]), cells())
    @test geo.x == [11.5] && geo.y == [42.5] && geo.code == [4211]

    # Coordinate validation and transformation failure.
    bad = extract_vector(GeoPoints([95, "x", -52.0], [12, 12, -170.0]),
                         VectorLayer("l", GEO[:laea]; attributes=["name"], overlap=:ambiguous))
    @test bad.status == ["invalid_coordinate", "invalid_coordinate", "transform_failed"]
    @test all(ismissing, bad.x)
end

@testset "Vector overlap policies" begin
    pts = points_from("EPSG:32633", [380000], [4670000])     # inside A (fid 1) and C (fid 3)
    expected = Dict(:lowest_fid => 1, :highest_fid => 3, :smallest_area => 3, :largest_area => 1)
    for (policy, fid) in expected
        r = extract_vector(pts, zones(; overlap=policy))
        @test r.fid == [fid] && r.status == ["inside"] && r.match_fids == [[1, 3]]
    end
    @test extract_vector(pts, zones(; overlap=:min_attribute, overlap_attribute="rank")).fid == [1]
    @test extract_vector(pts, zones(; overlap=:max_attribute, overlap_attribute="rank")).fid == [3]
    amb = extract_vector(pts, zones(; overlap=:ambiguous))
    @test amb.status == ["ambiguous"] && ismissing(amb.fid[1]) && ismissing(amb.name[1])
    @test amb.match_fids == [[1, 3]]
    # Equal areas (A and B on their shared edge) fall back to the lowest FID.
    edge = points_from("EPSG:32633", [400000], [4610000])
    for policy in (:smallest_area, :largest_area)
        r = extract_vector(edge, zones(; overlap=policy, boundary=:include, boundary_tolerance=0.01))
        @test r.fid == [1] && r.match_fids == [[1, 2]] && r.status == ["boundary"]
    end
    # Missing priority values sort last; D has no rank.
    @test_throws ArgumentError zones(; overlap=:min_attribute)
    @test_throws ArgumentError zones(; overlap=:lowest_fid, overlap_attribute="rank")
    @test_throws ArgumentError zones(; overlap=:first)
end

@testset "Vector boundaries" begin
    # EPSG:4326 cells: WGS84 input reaches the layer unchanged, so edges are exact.
    pts = GeoPoints([42.5, 42.5, 42.0, 40.0, 39.0, 44.0], [11.5, 11.0, 11.0, 10.5, 10.5, 14.0])
    ex = extract_vector(pts, cells())
    @test ex.status == ["inside", "boundary", "boundary", "boundary", "outside_extent", "boundary"]
    @test isequal(ex.code, [4211, missing, missing, missing, missing, missing])
    @test ex.on_boundary == [false, true, true, true, false, true]
    @test ex.n_matches == [1, 0, 0, 0, 0, 0]
    inc = extract_vector(pts, cells(; boundary=:include))
    @test inc.status == ["inside", "boundary", "boundary", "boundary", "outside_extent", "boundary"]
    @test inc.match_fids[2] == [9, 10]                    # cells 42_10 and 42_11
    @test length(inc.match_fids[3]) == 4                 # a corner touches four cells
    @test isequal(inc.code, [4211, 4210, 4110, 4010, missing, 4313])
    amb = extract_vector(pts, cells(; boundary=:include, overlap=:ambiguous))
    @test amb.status[2] == "ambiguous" && amb.status[4] == "boundary"

    # Interior match wins over a boundary match with :prefer_inside.
    utm = points_from("EPSG:32633", [400000, 400000.5, 630000, 650000], [4670000, 4610000, 4650000, 4650000])
    pref = extract_vector(utm, zones(; boundary=:prefer_inside, boundary_tolerance=0.01))
    @test pref.status == ["inside", "inside", "boundary", "no_match"]
    @test pref.fid[1] == 3 && pref.on_boundary[1]        # in C, on the A/B edge
    @test pref.fid[2] == 2 && !pref.on_boundary[2]       # 0.5 m inside B
    @test pref.fid[3] == 4                               # on the hole ring of D
    wide = extract_vector(utm, zones(; boundary=:exclude, boundary_tolerance=1.0))
    @test wide.status[2] == "boundary" && wide.on_boundary[2]   # within 1 m of the edge
    @test_throws ArgumentError zones(; boundary=:touch)
    @test_throws ArgumentError zones(; boundary_tolerance=-1)
end

@testset "Vector batches match an analytic oracle" begin
    rng = MersenneTwister(20261123)
    n = 3000
    lat = 39.5 .+ 5 .* rand(rng, n)
    lon = 9.5 .+ 5 .* rand(rng, n)
    pts = GeoPoints(lat, lon)
    reference = extract_vector(pts, cells())
    for i in 1:n
        if 40 < lat[i] < 44 && 10 < lon[i] < 14
            @test reference.status[i] == "inside" && reference.code[i] == 100 * floor(Int, lat[i]) + floor(Int, lon[i])
        else
            @test reference.status[i] == "outside_extent"
        end
    end
    # Tiling and the candidate cache change performance only.
    for kwargs in ((tile_points=1,), (tile_points=7, tile_size=0.05), (tile_points=100_000, tile_size=100.0))
        r = extract_vector(pts, cells(; kwargs...))
        @test isequal(r, reference)
    end
    budget = ItaBOLValidator.GeoExtraction.CANDIDATE_CACHE_BYTES[]
    try
        ItaBOLValidator.GeoExtraction.CANDIDATE_CACHE_BYTES[] = 1      # evict after every tile
        @test isequal(extract_vector(pts, cells(; tile_points=7, tile_size=0.05)), reference)
        @test isequal(extract_vector(pts, cells(; tile_points=7, tile_size=0.05, overlap=:smallest_area)).code,
                      reference.code)
    finally
        ItaBOLValidator.GeoExtraction.CANDIDATE_CACHE_BYTES[] = budget
    end
end

@testset "Vector configuration errors" begin
    @test_throws GeoDatasetError extract_vector(GeoPoints([42], [12]), zones(joinpath(GEO_DIR, "absent.gpkg")))
    two = VectorLayer("t", GEO[:two_layers]; attributes=["name"], overlap=:lowest_fid)
    @test_throws GeoDatasetError extract_vector(GeoPoints([42], [12]), two)
    second = VectorLayer("t", GEO[:two_layers]; layer="second", attributes=["name"], overlap=:lowest_fid)
    @test extract_vector(points_from("EPSG:32633", [450000], [4650000]), second).name == ["second-B"]
    @test_throws GeoDatasetError extract_vector(GeoPoints([42], [12]),
        VectorLayer("t", GEO[:two_layers]; layer="third", attributes=["name"], overlap=:lowest_fid))
    err = try
        extract_vector(GeoPoints([42], [12]), VectorLayer("z", GEO[:utm_gpkg]; attributes=["Name"], overlap=:lowest_fid))
    catch e
        e
    end
    @test err isa GeoDatasetError && occursin("Name", err.message)   # field names are case-sensitive
    @test_throws GeoDatasetError extract_vector(GeoPoints([42], [12]),
        VectorLayer("l", GEO[:lines]; attributes=String[], overlap=:lowest_fid))
    # A Shapefile without .prj needs an explicit CRS; a declared CRS cannot be overridden.
    @test_throws GeoDatasetError extract_vector(GeoPoints([42], [12]), zones(GEO[:noprj_shp]))
    assumed = extract_vector(points_from("EPSG:32633", [320000], [4610000]),
                             zones(GEO[:noprj_shp]; assume_crs="EPSG:32633"))
    @test assumed.name == ["A"]
    @test_throws GeoDatasetError extract_vector(GeoPoints([42], [12]), zones(; assume_crs="EPSG:32633"))
    @test_throws GeoDatasetError extract_vector(GeoPoints([42], [12]), zones(GEO[:noprj_shp]; assume_crs="EPSG:nope"))
    @test_throws ArgumentError VectorLayer("z", "x.gpkg"; attributes=["status"], overlap=:lowest_fid)
    @test_throws ArgumentError VectorLayer("z", "x.gpkg"; attributes=["a", "a"], overlap=:lowest_fid)
    @test_throws ArgumentError VectorLayer("bad.name", "x.gpkg"; attributes=["a"], overlap=:lowest_fid)
    @test_throws UndefKeywordError VectorLayer("z", "x.gpkg"; attributes=["a"])
end

utm_centre(p, l) = (300000 + 100 * (p + 0.5), 4700000 - 100 * (l + 0.5))

@testset "Raster extraction: categorical" begin
    pl = [(0, 0), (150, 20), (599, 499), (15, 15), (130, 260), (250, 120)]
    cx = [utm_centre(p, l)[1] for (p, l) in pl]
    cy = [utm_centre(p, l)[2] for (p, l) in pl]
    pts = points_from("EPSG:32633", vcat(cx, 250000.0), vcat(cy, 4650000.0))
    layer = RasterLayer("classes", GEO[:classes]; kind=:categorical, categories=:dataset)
    r = extract_raster(pts, layer)
    @test r.status == ["ok", "ok", "ok", "nodata", "ok", "ok", "outside_coverage"]
    @test isequal(r.pixel, [0, 150, 599, 15, 130, 250, missing])
    @test isequal(r.line, [0, 20, 499, 15, 260, 120, missing])
    @test eltype(r.value) == Union{Missing,UInt8}
    @test isequal(r.value, [0x01, 0x02, 0x2e, missing, 0x16, 0x0d, missing])
    @test isequal(r.label, ["forest", "grassland", missing, missing, missing, missing, missing])
    mapped = extract_raster(pts, RasterLayer("c", GEO[:classes]; kind=:categorical,
                                             categories=Dict(1 => "woodland", 46 => "urban")))
    @test isequal(mapped.label[1:3], ["woodland", missing, "urban"])
    @test extract_raster(pts, RasterLayer("c", GEO[:classes]; kind=:categorical, nodata=:none)).value[4] == 0xff
    @test_throws GeoDatasetError extract_raster(pts, RasterLayer("c", GEO[:classes]; kind=:categorical, nodata=-1))
    @test_throws GeoDatasetError extract_raster(pts, RasterLayer("t", GEO[:temps]; kind=:categorical))
    @test_throws ArgumentError RasterLayer("t", GEO[:temps]; kind=:continuous, categories=:dataset)
    @test_throws GeoDatasetError extract_raster(pts, RasterLayer("c", GEO[:classes]; kind=:categorical, band=2))
end

@testset "Raster extraction: continuous, NoData and edges" begin
    layer = RasterLayer("temps", GEO[:temps]; kind=:continuous)
    lat = [41.5, 41.995, 41.995, 42.0, 41.5, 41.5, 40.0, 40.0 + 1e-6, 41.5, 30.0]
    lon = [10.555, 10.005, 10.055, 10.0, 10.5, 12.0, 11.0, 11.0, 12.0 - 1e-6, 10.0]
    r = extract_raster(GeoPoints(lat, lon), layer)
    @test r.status == ["ok", "nodata", "nodata", "nodata", "ok", "outside_coverage", "outside_coverage",
                       "ok", "ok", "outside_coverage"]
    expected(p, l) = Float64(Float32(10 + (p + 0.5) * 0.01 + (42 - (l + 0.5) * 0.01) / 100))
    @test r.value[1] == expected(55, 50)
    @test (r.pixel[4], r.line[4]) == (0, 0)              # top-left corner (NaN pixel)
    @test (r.pixel[5], r.line[5]) == (50, 50)            # on a pixel edge: right/lower pixel
    @test (r.pixel[8], r.line[8]) == (100, 199)          # just inside the bottom edge
    @test r.pixel[9] == 199
    @test eltype(r.value) == Union{Missing,Float64}
    raw = extract_raster(GeoPoints(lat[2:3], lon[2:3]), RasterLayer("t", GEO[:temps]; kind=:continuous, nodata=:none))
    @test raw.status == ["nodata", "ok"] && raw.value[2] == -9999     # NaN stays NoData

    scaled = GeoPoints([41.5, 41.5, 40.5, 40.5], [10.5, 11.5, 10.5, 11.5])
    s = extract_raster(scaled, RasterLayer("s", GEO[:scaled]; kind=:continuous))
    @test s.value == [105.0, 115.0, 110.0, 120.0]
    @test extract_raster(scaled, RasterLayer("s", GEO[:scaled]; kind=:continuous, apply_scale=false)).value ==
          [10.0, 30.0, 20.0, 40.0]
    over = extract_raster(scaled, RasterLayer("s", GEO[:scaled]; kind=:continuous, nodata=20))
    @test over.status == ["ok", "ok", "nodata", "ok"]
end

@testset "Raster extraction: rotated geotransform" begin
    gt = ROTATED_GT
    ps, ls, xs, ys = Int[], Int[], Float64[], Float64[]
    for p in 0:19, l in 0:29
        push!(ps, p); push!(ls, l)
        push!(xs, gt[1] + (p + 0.5) * gt[2] + (l + 0.5) * gt[3])
        push!(ys, gt[4] + (p + 0.5) * gt[5] + (l + 0.5) * gt[6])
    end
    r = extract_raster(GeoPoints(ys, xs), RasterLayer("rot", GEO[:rotated]; kind=:categorical))
    @test all(==("ok"), r.status)
    @test r.pixel == ps && r.line == ls
    @test r.value == Int32.(1000 .* ps .+ ls)
    # Ignoring the rotation terms would select different pixels.
    @test count(i -> floor(Int, (xs[i] - gt[1]) / gt[2]) != ps[i], eachindex(xs)) > 100
end

@testset "Raster extraction: data types" begin
    lat = [41.5, 40.5, 39.5, 41.5, 40.5, 39.5]
    lon = [10.5, 10.5, 10.5, 11.5, 11.5, 11.5]
    pts = GeoPoints(lat, lon)
    for T in (UInt8, Int8, UInt16, Int16, UInt32, Int32, Int64, UInt64, Float32, Float64)
        path = GEO[Symbol("type_", T)]
        extreme = T <: Integer ? typemax(T) : T(1.5e30)
        if T <: Integer
            r = extract_raster(pts, RasterLayer("t", path; kind=:categorical))
            @test eltype(r.value) == Union{Missing,T}
            @test r.value == T[1, 2, 3, 4, 5, extreme]          # exact, no Float64 round trip
        else
            r = extract_raster(pts, RasterLayer("t", path; kind=:continuous))
            @test r.value == Float64.(T[1, 2, 3, 4, 5, extreme])
        end
        @test all(==("ok"), r.status)
        @test extract_raster(pts, RasterLayer("t", path; kind=:continuous)).value == Float64.(r.value)
    end
end

@testset "Raster extraction: CRS handling" begin
    @test_throws GeoDatasetError extract_raster(GeoPoints([42], [12]), RasterLayer("n", GEO[:no_crs]; kind=:categorical))
    pts = points_from("EPSG:32633", [300050, 300150], [4699950, 4699850])
    r = extract_raster(pts, RasterLayer("n", GEO[:no_crs]; kind=:categorical, assume_crs="EPSG:32633"))
    @test r.value == UInt8[1, 4]
    @test_throws GeoDatasetError extract_raster(pts, RasterLayer("c", GEO[:classes]; kind=:categorical,
                                                                 assume_crs="EPSG:32633"))
    laea = extract_raster(GeoPoints([-52.0, 30.0], [-170.0, 10.0]), RasterLayer("l", GEO[:laea_raster]; kind=:categorical))
    @test laea.status[1] == "transform_failed"
    @test_throws GeoDatasetError extract_raster(pts, RasterLayer("x", joinpath(GEO_DIR, "absent.tif"); kind=:continuous))
end

@testset "Raster extraction: large tiled compressed file" begin
    path = write_large_raster(joinpath(GEO_DIR, "large.tif"))
    layer = RasterLayer("large", path; kind=:categorical)
    rng = MersenneTwister(7)
    n = 20_000
    p, l = rand(rng, 0:4095, n), rand(rng, 0:4095, n)
    pts = points_from("EPSG:32633", 500000 .+ 10 .* (p .+ 0.5), 4800000 .- 10 .* (l .+ 0.5))
    catalog = GeoCatalog([layer])
    try
        r = extract_raster(pts, catalog, "large")
        @test all(==("ok"), r.status)
        @test r.value == Int16.(p .÷ 256 .+ 100 .* (l .÷ 256))
        # A batch in one corner reads a few blocks, not the 32 MiB raster.
        corner = points_from("EPSG:32633", 500000 .+ 10 .* (rand(rng, 0:300, 1000) .+ 0.5),
                             4800000 .- 10 .* (rand(rng, 0:300, 1000) .+ 0.5))
        extract_raster(corner, catalog, "large")
        bytes = @allocated extract_raster(corner, catalog, "large")
        @test bytes < 4 * 2^20
        info = layer_info(catalog, "large")
        @test info.window == (256, 256) && info.width == 4096 && info.pixel_type == Int16
    finally
        close(catalog)
    end
end

@testset "Combined extraction and catalog" begin
    layers = [zones(), cells(; attributes=["code" => "cell"]),
              RasterLayer("classes", GEO[:classes]; kind=:categorical, categories=:dataset),
              RasterLayer("temps", GEO[:temps]; kind=:continuous)]
    pts = GeoPoints([41.5, "bad", 41.6214], [10.555, 12, 12.8394])
    combined = extract_geodata(pts, layers)
    @test names(combined) == ["point", "latitude", "longitude", "coordinate_status",
                              "zones.status", "zones.fid", "zones.name", "zones.code",
                              "cells.status", "cells.fid", "cells.cell",
                              "classes.status", "classes.value", "classes.label",
                              "temps.status", "temps.value"]
    @test combined.coordinate_status == ["valid", "latitude_invalid_format", "valid"]
    @test isequal(combined.latitude, [41.5, missing, 41.6214])
    @test combined[!, "temps.status"] == ["ok", "invalid_coordinate", "outside_coverage"]
    @test isequal(combined[!, "cells.cell"], [4110, missing, 4112])
    @test combined[3, "zones.name"] == "A"

    catalog = GeoCatalog(layers)
    @test layer_names(catalog) == ["zones", "cells", "classes", "temps"]
    subset = extract_geodata(pts, catalog, ["temps"])
    @test names(subset)[end] == "temps.value"
    handle = catalog.handles["temps"]
    extract_raster(pts, catalog, "temps")
    @test catalog.handles["temps"] === handle             # the dataset is opened once
    @test layer_info(catalog, "zones").spatial_index
    @test_throws ArgumentError extract_raster(pts, catalog, "zones")
    @test_throws ArgumentError extract_vector(pts, catalog, "temps")
    @test_throws ArgumentError extract_geodata(pts, catalog, ["nope"])
    @test_throws ArgumentError extract_geodata(pts, catalog, ["temps", "temps"])
    # Concurrent tasks share handles safely; each layer is used under its lock.
    rng = MersenneTwister(1)
    many = GeoPoints(40 .+ 4 .* rand(rng, 2000), 10 .+ 4 .* rand(rng, 2000))
    expected = extract_geodata(many, catalog)
    results = fetch.([Threads.@spawn extract_geodata(many, catalog) for _ in 1:6])
    @test all(r -> isequal(r, expected), results)
    close(catalog)
    @test !isopen(catalog)
    @test_throws ArgumentError extract_geodata(pts, catalog)
    @test_throws ArgumentError GeoCatalog([zones(), zones()])
end

@testset "Points from a BOLD submission" begin
    path = joinpath(GEO_DIR, "specimens.xlsx")
    write_fixture(path; records=[synthetic_record("1", "41.5", "11.5"), synthetic_record("2", "41,5", 11.5)])
    submission = read_bold(path)
    r = extract_vector(submission, cells())
    @test r.status == ["inside", "invalid_coordinate"] && r.code[1] == 4111
end
