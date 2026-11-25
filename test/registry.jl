# Layer registry tests; reuses the synthetic datasets built in geo.jl (GEO).

function geodata_root(dir)
    root = mkpath(joinpath(dir, "geodata"))
    mkpath(joinpath(root, "admin"))
    mkpath(joinpath(root, "raster"))
    cp(GEO[:cells], joinpath(root, "admin", "cells.gpkg"))
    for ext in ("shp", "shx", "dbf", "prj")
        cp(replace(GEO[:utm_shp], r"shp$" => ext), joinpath(root, "admin", "zones.$ext"))
    end
    for ext in ("shp", "shx", "dbf")
        cp(replace(GEO[:noprj_shp], r"shp$" => ext), joinpath(root, "admin", "noprj.$ext"))
    end
    cp(GEO[:classes], joinpath(root, "raster", "classes.tif"))
    cp(GEO[:temps], joinpath(root, "raster", "temps.tif"))
    # Elevation in centimetres and bathymetry as negative elevation, EPSG:4326, 1-degree pixels.
    write_raster(joinpath(root, "raster", "dem_cm.tif"), Int32[12345 -500; 0 99999];
                 gt=[10.0, 1.0, 0.0, 42.0, 0.0, -1.0], crs="EPSG:4326", nodata=-32768)
    write_raster(joinpath(root, "raster", "bathy.tif"), Float32[-10.5 5.0; -2000.0 NaN];
                 gt=[10.0, 1.0, 0.0, 42.0, 0.0, -1.0], crs="EPSG:4326", nodata=NaN)
    return root
end

const LAYERS_TOML = """
schema_version = 1

[[layers]]
id = "cells"
name = "Synthetic cells"
type = "vector"
path = "admin/cells.gpkg"
attribute = "name"
output = "cell_name"
overlap = "ambiguous"
version = "test-1"
source = "synthetic"
[layers.value_map]
cell_41_11 = "Italy"

[[layers]]
id = "zones"
name = "Synthetic UTM zones"
type = "vector"
path = "admin/zones.shp"
attribute = "name"
output = "zone"
overlap = "lowest_fid"
version = "test-1"
source = "synthetic"

[[layers]]
id = "elevation"
name = "Elevation"
type = "raster"
kind = "continuous"
path = "raster/dem_cm.tif"
unit = "m"
measure = "elevation"
conversion = { from = "cm" }
output = "elevation_m"
version = "test-1"
source = "synthetic"

[[layers]]
id = "bathymetry"
name = "Bathymetry"
type = "raster"
kind = "continuous"
path = "raster/bathy.tif"
unit = "m"
conversion = { factor = -1.0 }
valid_min = 0.0
measure = "depth"
output = "depth_m"
version = "test-1"
source = "synthetic"

[[layers]]
id = "land_cover"
name = "Land cover"
type = "raster"
kind = "categorical"
path = "raster/classes.tif"
categories = "dataset"
output = "land_cover"
version = "test-1"
source = "synthetic"

[[layers]]
id = "habitat"
name = "Habitat"
type = "raster"
kind = "categorical"
path = "raster/classes.tif"
output = "habitat"
version = "test-1"
source = "synthetic"
[layers.value_map]
1 = "woodland"
2 = "grassland"

[[layers]]
id = "temperature"
name = "Temperature"
type = "raster"
kind = "continuous"
path = "raster/temps.tif"
output = "temperature"
version = "test-1"
source = "synthetic"
enabled = false

[[bold_fields]]
column = "COUNTRY/OCEAN"
layers = ["cells", "zones"]

[[bold_fields]]
column = "ELEV"
layers = ["elevation"]

[[bold_fields]]
column = "DEPTH"
layers = ["bathymetry"]

[[bold_fields]]
column = "HABITAT"
layers = ["habitat"]
"""

load_quiet(path; kwargs...) = load_registry(path; log=false, kwargs...)

@testset "Registry: BOLD column sets" begin
    @test Set(BOLD_TARGET_COLUMNS) ∪ Set(keys(BOLD_PROTECTED_COLUMNS)) == Set(GEOGRAPHIC_HEADERS)
    @test isempty(intersect(Set(BOLD_TARGET_COLUMNS), Set(keys(BOLD_PROTECTED_COLUMNS))))
end

@testset "Registry: valid configuration, metadata and extraction" begin
    mktempdir() do dir
        root = geodata_root(dir)
        config = joinpath(dir, "layers.toml")
        write(config, LAYERS_TOML)
        registry = load_quiet(config; geodata_root=root)
        try
            @test isempty(registry.problems)
            @test available_layers(registry) == ["cells", "zones", "elevation", "bathymetry", "land_cover", "habitat"]
            @test only(l for l in registry.layers if l.id == "temperature").status === :disabled
            @test all(m -> m.status === :active, registry.mappings)

            report = registry_report(registry)
            @test report.status == ["available", "available", "available", "available", "available", "available", "disabled"]
            @test report.driver[1:3] == ["GPKG", "ESRI Shapefile", "GTiff"]
            @test startswith(report.crs[2], "EPSG:32633")
            @test report.features[1:2] == [16, 4]
            @test report.spatial_index[1:2] == [true, false]
            @test report.pixel_type[5] == "UInt8" && report.nodata[5] == "255" && ismissing(report.nodata[1])
            @test report.bold_columns[1:4] == ["COUNTRY/OCEAN", "COUNTRY/OCEAN", "ELEV", "DEPTH"]
            @test report.bold_columns[5] == ""                      # land cover feeds no BOLD column
            meta = layer_metadata(registry, "elevation")
            @test meta.version == "test-1" && meta.source == "synthetic" && meta.unit == "m"
            @test meta.factor == 0.01 && meta.dataset.width == 2
            @test_throws ArgumentError layer_metadata(registry, "nope")

            # (41.5, 11.5): cell_41_11, elevation pixel (1, 0); (40.5, 10.5): pixel (0, 1);
            # (41.6214, 12.8394): zone A only; (45, 30): nothing; then an invalid point.
            pts = GeoPoints([41.5, 40.5, 41.6214, 45.0, "x"], [11.5, 10.5, 12.8394, 30.0, 12.0])
            values = extract_layers(pts, registry)
            @test isequal(values.cell_name, ["Italy", missing, missing, missing, missing])
            @test values[!, "cell_name.status"] == ["inside", "unmapped", "unmapped", "outside_extent", "invalid_coordinate"]
            @test isequal(values[!, "cell_name.raw"], ["cell_41_11", "cell_40_10", "cell_41_12", missing, missing])
            @test isequal(values.elevation_m, [0.0, -5.0, missing, missing, missing])
            @test isequal(values[!, "elevation_m.raw"], [0.0, -500.0, missing, missing, missing])
            @test isequal(values.depth_m, [2000.0, missing, missing, missing, missing])
            @test values[!, "depth_m.status"][1:2] == ["ok", "out_of_range"]   # land: negative depth
            @test !("land_cover.raw" in names(values))
            sub = extract_layers(pts, registry; layers=["elevation"])
            @test names(sub) == ["point", "coordinate_status", "elevation_m", "elevation_m.status", "elevation_m.raw"]
            @test_throws ArgumentError extract_layers(pts, registry; layers=["temperature"])

            proposals = propose_bold_fields(pts, registry)
            @test names(proposals) == ["point", "coordinate_status",
                                       "COUNTRY/OCEAN", "COUNTRY/OCEAN.source", "COUNTRY/OCEAN.status",
                                       "ELEV", "ELEV.source", "ELEV.status", "DEPTH", "DEPTH.source", "DEPTH.status",
                                       "HABITAT", "HABITAT.source", "HABITAT.status"]
            # Ordered fallback: cells first, then zones.
            @test isequal(proposals[!, "COUNTRY/OCEAN"], ["Italy", missing, "A", missing, missing])
            @test isequal(proposals[!, "COUNTRY/OCEAN.source"], ["cells", missing, "zones", missing, missing])
            @test proposals[!, "ELEV.status"] == ["proposed", "proposed", "no_value", "no_value", "no_value"]
            @test !any(c -> occursin("ACCURACY", c) || occursin("COORD", c), names(proposals))

            # Habitat comes only from the explicit table; land-cover labels are not used.
            utm = points_from("EPSG:32633", [300050, 310050, 350050], [4699950, 4699950, 4699950])
            habitat = propose_bold_fields(utm, registry)
            @test isequal(habitat.HABITAT, ["woodland", "grassland", missing])
            lc = extract_layers(utm, registry; layers=["land_cover", "habitat"])
            @test lc.land_cover == UInt8[1, 2, 6]
            @test lc[!, "habitat.status"] == ["ok", "ok", "unmapped"]
            @test isequal(lc[!, "habitat.raw"], UInt8[1, 2, 6])
        finally
            close(registry)
        end
    end
end

function layer_block(; id="bad", type="vector", path="admin/cells.gpkg", output=id, extra="")
    return """
    [[layers]]
    id = "$id"
    name = "Layer $id"
    type = "$type"
    path = '$path'
    output = "$output"
    version = "1"
    source = "synthetic"
    $extra
    """
end

const GOOD_VECTOR = layer_block(id="good", extra="attribute = \"code\"\noverlap = \"ambiguous\"")

@testset "Registry: invalid layers are reported without failing" begin
    mktempdir() do dir
        root = geodata_root(dir)
        config = joinpath(dir, "layers.toml")
        vector(id, extra; kw...) = layer_block(; id, extra, kw...)
        blocks = [
            GOOD_VECTOR,
            vector("missing_attr", "attribute = \"nope\"\noverlap = \"ambiguous\""),
            vector("case_attr", "attribute = \"CODE\"\noverlap = \"ambiguous\""),
            vector("no_overlap", "attribute = \"code\""),
            vector("bad_policy", "attribute = \"code\"\noverlap = \"first\""),
            vector("unknown_key", "attribute = \"code\"\noverlap = \"ambiguous\"\ncolour = \"red\""),
            vector("absent", "attribute = \"code\"\noverlap = \"ambiguous\""; path="admin/absent.gpkg"),
            vector("no_crs", "attribute = \"name\"\noverlap = \"ambiguous\""; path="admin/noprj.shp"),
            vector("assumed", "attribute = \"name\"\noverlap = \"ambiguous\"\nassume_crs = \"EPSG:32633\""; path="admin/noprj.shp"),
            vector("bad_crs", "attribute = \"name\"\noverlap = \"ambiguous\"\nassume_crs = \"EPSG:0\""; path="admin/noprj.shp"),
            layer_block(id="band9", type="raster", path="raster/classes.tif", extra="kind = \"categorical\"\nband = 9"),
            layer_block(id="float_cat", type="raster", path="raster/temps.tif", extra="kind = \"categorical\""),
            layer_block(id="raster_as_vector", path="raster/classes.tif", extra="attribute = \"x\"\noverlap = \"ambiguous\""),
            layer_block(id="bad_type", type="mesh"),
            layer_block(id="bad_unit", type="raster", path="raster/temps.tif",
                        extra="kind = \"continuous\"\nunit = \"m\"\nconversion = { from = \"furlong\" }"),
            layer_block(id="good", output="other", extra="attribute = \"code\"\noverlap = \"ambiguous\""),
            layer_block(id="dup_output", output="good", extra="attribute = \"code\"\noverlap = \"ambiguous\""),
            layer_block(id="Bad-Id"),
            "[[layers]]\nid = \"incomplete\"\ntype = \"vector\"\n",
        ]
        write(config, "schema_version = 1\n" * join(blocks, "\n"))
        registry = load_quiet(config; geodata_root=root)
        try
            status = Dict{String,Symbol}()
            for l in registry.layers
                haskey(status, l.id) || (status[l.id] = l.status)
            end
            @test status["good"] === :available
            @test status["assumed"] === :available
            @test status["absent"] === :unavailable
            for id in ("missing_attr", "case_attr", "no_overlap", "bad_policy", "unknown_key", "no_crs", "bad_crs",
                       "band9", "float_cat", "raster_as_vector", "bad_type", "bad_unit", "dup_output", "Bad-Id",
                       "incomplete")
                @test status[id] === :invalid
            end
            @test count(l -> l.id == "good" && l.status === :invalid, registry.layers) == 1   # duplicate id
            problems(id) = join(only(l for l in registry.layers if l.id == id).problems, " ")
            @test occursin("unknown vector layer keys: colour", problems("unknown_key"))
            @test occursin("declares no CRS", problems("no_crs"))
            @test occursin("missing required key 'overlap'", problems("no_overlap"))
            @test occursin("band 9", problems("band9"))
            @test occursin("missing required key 'name'", problems("incomplete"))
            # The application keeps working with the valid layers.
            @test available_layers(registry) == ["good", "assumed"]
            r = extract_layers(GeoPoints([41.5], [11.5]), registry; layers=["good"])
            @test r.good == [4111]
            @test nrow(registry_report(registry)) == length(blocks)
        finally
            close(registry)
        end

        write(config, "schema_version = 1\n[[layers]\nid = ")
        broken = load_quiet(config; geodata_root=root)
        @test isempty(broken.layers) && occursin("cannot read", only(broken.problems))
        write(config, "schema_version = 2\nextra = 1\n" * GOOD_VECTOR)
        versioned = load_quiet(config; geodata_root=root)
        @test any(occursin("schema_version", p) for p in versioned.problems)
        @test any(occursin("unknown top-level keys: extra", p) for p in versioned.problems)
        close(versioned)
        missing_file = load_quiet(joinpath(dir, "absent.toml"); geodata_root=root)
        @test occursin("cannot read", only(missing_file.problems))
        # Warnings are logged, not thrown.
        write(config, "schema_version = 1\n" * blocks[7])
        logged = @test_logs (:warn, r"absent.*unavailable") match_mode=:any load_registry(config; geodata_root=root)
        close(logged)
    end
end

@testset "Registry: geodata directory confinement" begin
    mktempdir() do dir
        root = geodata_root(dir)
        outside = mkpath(joinpath(dir, "outside"))
        cp(GEO[:cells], joinpath(outside, "cells.gpkg"))
        config = joinpath(dir, "layers.toml")
        attr = "attribute = \"code\"\noverlap = \"ambiguous\""
        paths = ["../outside/cells.gpkg", "admin/../../outside/cells.gpkg", joinpath(outside, "cells.gpkg"),
                 "/vsicurl/https://example.org/cells.gpkg", "C:cells.gpkg", "\\\\server\\share\\cells.gpkg", ""]
        blocks = [layer_block(id="p$i", path=p, extra=attr) for (i, p) in enumerate(paths)]
        write(config, "schema_version = 1\n" * join(blocks, "\n"))
        registry = load_quiet(config; geodata_root=root)
        @test all(l -> l.status === :invalid, registry.layers)
        @test all(l -> l.resolved === nothing || l.engine === nothing, registry.layers)
        @test any(occursin("relative", p) for p in registry.layers[3].problems)
        close(registry)

        # Symbolic links (or junctions) leading outside the root are refused.
        link = joinpath(root, "admin", "linked.gpkg")
        linked = try
            symlink(joinpath(outside, "cells.gpkg"), link)
            true
        catch
            false
        end
        if linked
            write(config, "schema_version = 1\n" * layer_block(id="linked", path="admin/linked.gpkg", extra=attr))
            r = load_quiet(config; geodata_root=root)
            @test only(r.layers).status === :invalid
            @test occursin("outside the geodata root", only(only(r.layers).problems))
            close(r)
        else
            @info "Symbolic links are not permitted here; link-escape test skipped"
        end

        # A configured root must lie inside the approved root.
        write(config, "schema_version = 1\ngeodata_root = \"outside\"\n" * GOOD_VECTOR)
        r = load_quiet(config; geodata_root=root)
        @test any(occursin("outside the approved directory", p) for p in r.problems)
        @test only(r.layers).status === :invalid
        close(r)
        write(config, "schema_version = 1\ngeodata_root = \"geodata\"\n" * GOOD_VECTOR)
        r = load_quiet(config; geodata_root=dir)
        @test isempty(r.problems) && available_layers(r) == ["good"]
        close(r)
        write(config, "schema_version = 1\n" * GOOD_VECTOR)
        r = load_quiet(config)
        @test any(occursin("no geodata root", p) for p in r.problems)
        close(r)
    end
end

@testset "Registry: BOLD mapping rules" begin
    mktempdir() do dir
        root = geodata_root(dir)
        config = joinpath(dir, "layers.toml")
        base = split(LAYERS_TOML, "[[bold_fields]]")[1]
        mapping(column, layers) = "[[bold_fields]]\ncolumn = \"$column\"\nlayers = [$(join(repr.(layers), ", "))]\n"
        feet = layer_block(id="elev_ft", type="raster", path="raster/dem_cm.tif",
                           extra="kind = \"continuous\"\nunit = \"ft\"\nmeasure = \"depth\"\nconversion = { from = \"cm\" }")
        dem_m = layer_block(id="dem_m", type="raster", path="raster/dem_cm.tif",
                            extra="kind = \"continuous\"\nunit = \"m\"\nmeasure = \"elevation\"\ndigits = 1")
        mappings = [mapping("HABITAT", ["land_cover"]),          # categorical without value_map
                    mapping("ELEV_ACCURACY", ["elevation"]),      # protected
                    mapping("COORD_ACCURACY", ["elevation"]),
                    mapping("COORD:LAT", ["elevation"]),
                    mapping("ELEV", ["land_cover"]),              # numeric from categorical
                    mapping("DEPTH", ["elev_ft"]),                # wrong unit
                    mapping("REGION", ["elevation"]),             # text from continuous
                    mapping("SITE", ["nope"]),                    # unknown layer
                    mapping("COLOUR", ["cells"]),                 # unknown column
                    mapping("COUNTRY/OCEAN", ["cells"]),
                    mapping("COUNTRY/OCEAN", ["zones"]),          # duplicate column
                    mapping("SECTOR", ["temperature"]),           # text from continuous (disabled)
                    mapping("PROVINCE/STATE", ["zones"]),
                    mapping("DEPTH", ["dem_m"]),                  # elevation is not a depth
                    mapping("REGION", ["habitat"]),               # raster for an administrative column
                    mapping("HABITAT", ["zones"])]                # vector habitat without value_map
        write(config, base * feet * dem_m * join(mappings, "\n"))
        registry = load_quiet(config; geodata_root=root)
        try
            report = mapping_report(registry)
            @test report.status == ["invalid", "invalid", "invalid", "invalid", "invalid", "invalid", "invalid",
                                    "invalid", "invalid", "active", "invalid", "invalid", "active", "invalid", "invalid",
                                    "invalid"]
            @test occursin("explicit value_map", report.problems[1])
            @test occursin("raster resolution", report.problems[2])
            @test occursin("never rewritten", report.problems[4])
            @test occursin("unit = \"m\"", report.problems[6])
            @test occursin("duplicate mapping", report.problems[11])
            @test occursin("measure = \"depth\"", report.problems[14])
            @test occursin("only from polygon layers", report.problems[15])
            @test occursin("explicit value_map", report.problems[16])
            @test layer_metadata(registry, "dem_m").digits == 1
            dem = extract_layers(GeoPoints([40.5], [11.5]), registry; layers=["dem_m"])
            @test dem.dem_m == [99999.0]
            proposals = propose_bold_fields(GeoPoints([41.5], [11.5]), registry)
            @test names(proposals)[3:end] == ["COUNTRY/OCEAN", "COUNTRY/OCEAN.source", "COUNTRY/OCEAN.status",
                                              "PROVINCE/STATE", "PROVINCE/STATE.source", "PROVINCE/STATE.status"]
        finally
            close(registry)
        end
    end
end

@testset "Registry: example configuration" begin
    example = joinpath(@__DIR__, "..", "config", "layers.toml")
    registry = load_quiet(example)
    try
        @test isempty(registry.problems)
        @test length(registry.layers) == 7
        @test all(l -> l.status in (:unavailable, :disabled), registry.layers)   # datasets are not shipped
        @test Set(m.column for m in registry.mappings) ==
              Set(["COUNTRY/OCEAN", "PROVINCE/STATE", "REGION", "ELEV", "DEPTH", "HABITAT"])
        @test all(m -> m.status === :inactive, registry.mappings)
        @test only(l for l in registry.layers if l.id == "land_cover").value_map === nothing
    finally
        close(registry)
    end
end

@testset "Registry: blank attributes are not values" begin
    mktempdir() do dir
        root = mkpath(joinpath(dir, "geodata"))
        write_polygons(joinpath(root, "blank.gpkg"),
                       [(wkt=box(10, 40, 11, 41), name="  ", code=Int32(1), rank=1.0),
                        (wkt=box(11, 40, 12, 41), name="Named", code=Int32(2), rank=1.0)];
                       crs="EPSG:4326", layer="blank")
        config = joinpath(dir, "layers.toml")
        write(config, "schema_version = 1\n" * layer_block(id="blank", path="blank.gpkg",
                                                           extra="attribute = \"name\"\noverlap = \"ambiguous\""))
        registry = load_quiet(config; geodata_root=root)
        try
            r = extract_layers(GeoPoints([40.5, 40.5], [10.5, 11.5]), registry)
            @test isequal(r.blank, [missing, "Named"])
            @test r[!, "blank.status"] == ["inside", "inside"]
        finally
            close(registry)
        end
    end
end
