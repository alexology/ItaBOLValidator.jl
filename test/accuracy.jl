# ELEV_ACCURACY: local relief on a DEM within the coordinate uncertainty, combined
# with the DEM's vertical RMSE. Reuses write_raster, reproject_points, synthetic_record
# and write_fixture from the earlier suites.

# A 15 x 15 DEM with 10 m pixels in EPSG:32632, all at 100 m except: a cell at
# 160 m whose centre is 20 m east of the centre cell, and a NoData cell 20 m west.
function accuracy_geodata(dir)
    root = mkpath(joinpath(dir, "geodata", "dem"))
    x0, y0 = 600000.0, 4800150.0
    z = fill(100.0f0, 15, 15)              # z[column + 1, row + 1]
    z[7 + 2 + 1, 7 + 1] = 160.0f0           # centre cell is (column 7, row 7)
    z[7 - 2 + 1, 7 + 1] = -9999.0f0
    write_raster(joinpath(root, "dem.tif"), z; gt=[x0, 10.0, 0.0, y0, 0.0, -10.0], crs="EPSG:32632",
                 nodata=-9999.0)
    # The centre of cell (7, 7) in WGS84.
    lon, lat = reproject_points([x0 + 75.0], [y0 - 75.0], "EPSG:32632", "EPSG:4326")
    return joinpath(dir, "geodata"), lat[1], lon[1]
end

function accuracy_registry(dir; mapping_extra="", layer_extra="vertical_accuracy = 3.5")
    config = joinpath(dir, "layers.toml")
    write(config, """
schema_version = 1

[[layers]]
id = "dem"
name = "Synthetic DEM"
type = "raster"
kind = "continuous"
path = "dem/dem.tif"
unit = "m"
measure = "elevation"
digits = 0
$layer_extra
output = "elevation_m"
version = "test-1"
source = "synthetic"

[[bold_fields]]
column = "ELEV"
layers = ["dem"]

[[bold_fields]]
column = "ELEV_ACCURACY"
layers = ["dem"]
$mapping_extra
""")
    return config
end

@testset "ELEV_ACCURACY: local relief" begin
    mktempdir() do dir
        root, lat, lon = accuracy_geodata(dir)
        registry = load_registry(accuracy_registry(dir); geodata_root=root, log=false)
        try
            @test all(m -> m.status === :active, registry.mappings)
            m = only(m for m in registry.mappings if m.column == "ELEV_ACCURACY")
            @test m.parameters == Dict("default_coord_accuracy" => 30.0, "max_coord_accuracy" => 5000.0)
            @test layer_metadata(registry, "dem").vertical_accuracy == 3.5
            pts = GeoPoints(fill(lat, 4), fill(lon, 4))
            r = layer_relief(pts, registry, "dem"; radius=[0.0, 15.0, 25.0, 6000.0])
            @test r.status == ["ok", "ok", "ok", "radius_too_large"]
            @test r.value[1:3] == [100.0, 100.0, 100.0]
            # The 160 m cell is 20 m away; the NoData cell, also 20 m away, is ignored.
            @test r.relief[1:3] == [0.0, 0.0, 60.0]
            # A geographic raster cannot measure metres.
            geo = mkpath(joinpath(dir, "geo4326", "dem"))
            write_raster(joinpath(geo, "dem.tif"), fill(1.0f0, 3, 3); gt=[11.0, 0.001, 0.0, 46.0, 0.0, -0.001],
                         crs="EPSG:4326")
            g = load_registry(accuracy_registry(mkpath(joinpath(dir, "g"))); geodata_root=joinpath(dir, "geo4326"),
                              log=false)
            try
                @test layer_relief(GeoPoints([45.9995], [11.0005]), g, "dem"; radius=[10.0]).status == ["unsupported_crs"]
            finally
                close(g)
            end
        finally
            close(registry)
        end
    end
end

@testset "ELEV_ACCURACY: registry rules" begin
    mktempdir() do dir
        root, _, _ = accuracy_geodata(dir)
        report(; kw...) = (r = load_registry(accuracy_registry(dir; kw...); geodata_root=root, log=false);
                           try (mapping_report(r), registry_report(r)) finally close(r) end)
        m, _ = report(layer_extra="")
        @test m.status[2] == "invalid" && occursin("vertical_accuracy", m.problems[2])
        _, l = report(layer_extra="vertical_accuracy = -1")
        @test l.status[1] == "invalid" && occursin("positive", l.problems[1])
        m, _ = report(mapping_extra="default_coord_accuracy = 100\nmax_coord_accuracy = 50")
        @test m.status[2] == "invalid" && occursin("must not exceed", m.problems[2])
        m, _ = report(mapping_extra="radius = 5")
        @test m.status[2] == "invalid" && occursin("unknown bold_fields keys: radius", m.problems[2])
        m, _ = report(mapping_extra="default_coord_accuracy = 50")
        @test m.status == ["active", "active"]
    end
end

@testset "ELEV_ACCURACY: enrichment" begin
    mktempdir() do dir
        root, lat, lon = accuracy_geodata(dir)
        registry = load_registry(accuracy_registry(dir); geodata_root=root, log=false)
        rec(id; kw...) = begin
            r = synthetic_record(id, lat, lon)
            delete!(r, "ELEV")
            for (k, v) in kw
                r[String(k)] = v
            end
            r
        end
        records = [rec("empty"),                                   # 30 m assumed: relief 60 m
                   rec("near"; COORD_ACCURACY=0.0001),             # 11 m: flat
                   rec("text"; COORD_ACCURACY="0,0003"),           # 33 m, decimal comma
                   rec("own"; ELEV=95),                            # not the DEM elevation
                   rec("same"; ELEV=100, COORD_ACCURACY=0.0001),   # the DEM elevation already there
                   rec("metres"; COORD_ACCURACY=10),               # metres by mistake: 10 degrees
                   rec("words"; COORD_ACCURACY="about 10 m")]
        path = write_fixture(joinpath(dir, "in.xlsx"); records)
        submission = read_bold(path)
        try
            result = enrich_workbook(submission, registry, joinpath(dir, "out"); fields=["ELEV_ACCURACY", "ELEV"],
                                     identifier_header="SAMPLEID")
            p = result.preview
            acc = p[p.field .== "ELEV_ACCURACY", :]
            @test p.field[1:2] == ["ELEV", "ELEV_ACCURACY"]                 # accuracy after the elevation
            @test acc.status == ["fill", "fill", "fill", "no_value", "fill", "no_value", "no_value"]
            @test acc.proposed[1:3] == [61.0, 4.0, 61.0] && acc.proposed[5] == 4.0
            @test occursin("radius assumed", acc.detail[1]) && occursin("(COORD_ACCURACY)", acc.detail[2])
            @test occursin("is not the elevation of layer 'dem'", acc.detail[4])
            @test occursin("decimal degrees", acc.detail[6]) && occursin("not a number", acc.detail[7])
            enriched = read_bold(result.workbook)
            @test enriched.records[!, "ELEV"] == [100, 100, 100, 95, 100, 100, 100]
            @test isequal(enriched.records[!, "ELEV_ACCURACY"], [61, 4, 61, missing, 4, missing, missing])
            f = result.report["per_field"]["ELEV_ACCURACY"]
            @test f["filled"] == 4 && f["coord_accuracy_assumed"] == 1 && f["default_coord_accuracy_m"] == 30.0
            @test f["no_value_reasons"] == Dict("elev_not_from_layer" => 1, "coord_accuracy_too_large" => 1,
                                                "coord_accuracy_invalid" => 1)
            @test f["vertical_accuracy_m"] == Dict("dem" => 3.5)

            # Accuracy alone: only where the existing ELEV is the DEM elevation.
            alone = preview_enrichment(submission, registry; fields=["ELEV_ACCURACY"])
            @test alone.status == ["no_value", "no_value", "no_value", "no_value", "fill", "no_value", "no_value"]
            @test occursin("ELEV is empty", alone.detail[1])
            # Records with ELEV overwritten by the DEM get the accuracy too.
            over = preview_enrichment(submission, registry; fields=["ELEV", "ELEV_ACCURACY"], overwrite=["ELEV"])
            @test over.status[over.field .== "ELEV_ACCURACY"][4] == "fill"
        finally
            close(registry)
        end
    end
end
