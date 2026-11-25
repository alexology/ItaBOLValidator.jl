# Regression tests for the defects IBV1, IBV3-IBV5 found in the independent review
# of 2026-11-24 (IBV2 is a web defect, tested in web/test/runtests.jl).

@testset "IBV1: GDAL mask bands are honoured" begin
    mktempdir() do dir
        gt = [10.0, 1.0, 0.0, 42.0, 0.0, -1.0]                     # two 1-degree pixels, 10-12 E, 41-42 N
        pts = GeoPoints([41.5, 41.5], [10.5, 11.5])
        # Per-dataset mask (internal or .msk): first pixel invalid.
        masked = write_raster(joinpath(dir, "masked.tif"), reshape(Int16[123, 456], 2, 1); gt, crs="EPSG:4326")
        AG.read(masked; flags=AG.OF_UPDATE | AG.OF_RASTER) do ds
            band = AG.getband(ds, 1)
            GDAL.gdalcreatemaskband(band.ptr, GDAL.GMF_PER_DATASET)
            mask = GDAL.gdalgetmaskband(band.ptr)
            values = UInt8[0, 255]
            GDAL.gdalrasterio(mask, GDAL.GF_Write, 0, 0, 2, 1, values, 2, 1, GDAL.GDT_Byte, 0, 0)
        end
        catalog = GeoCatalog([RasterLayer("masked", masked; kind=:continuous)])
        try
            r = extract_raster(pts, catalog, "masked")
            @test r.status == ["masked", "ok"]
            @test ismissing(r.value[1]) && r.value[2] == 456
        finally
            close(catalog)
        end
        # Alpha band: transparent pixel invalid, any non-zero alpha valid.
        alpha = joinpath(dir, "alpha.tif")
        AG.create(alpha; driver=AG.getdriver("GTiff"), width=2, height=1, nbands=2, dtype=UInt8,
                  options=["ALPHA=YES"]) do ds
            set_geotransform!(ds, gt)
            AG.setproj!(ds, AG.toWKT(AG.importUserInput("EPSG:4326")))
            AG.write!(AG.getband(ds, 1), reshape(UInt8[7, 9], 2, 1))
            AG.write!(AG.getband(ds, 2), reshape(UInt8[128, 0], 2, 1))
        end
        catalog = GeoCatalog([RasterLayer("alpha", alpha; kind=:categorical)])
        try
            r = extract_raster(pts, catalog, "alpha")
            @test r.status == ["ok", "masked"] && r.value[1] == 7 && ismissing(r.value[2])
        finally
            close(catalog)
        end
        # A mask derived from NoData follows the layer's explicit NoData policy instead.
        nd = write_raster(joinpath(dir, "nodata.tif"), reshape(Int16[123, 456], 2, 1); gt, crs="EPSG:4326",
                          nodata=123)
        catalog = GeoCatalog([RasterLayer("dataset", nd; kind=:continuous),
                              RasterLayer("none", nd; kind=:continuous, nodata=:none)])
        try
            @test extract_raster(pts, catalog, "dataset").status == ["nodata", "ok"]
            @test extract_raster(pts, catalog, "none").status == ["ok", "ok"]
        finally
            close(catalog)
        end
    end
end

@testset "IBV3: a duplicate BOLD mapping does not break the export" begin
    mktempdir() do dir
        root, config, path, _ = enrichment_fixture(dir)
        open(config, "a") do io
            write(io, "\n[[bold_fields]]\ncolumn = \"COUNTRY/OCEAN\"\nlayers = [\"zones\"]\n")
        end
        registry = load_registry(config; geodata_root=root, log=false)
        try
            dups = [m for m in registry.mappings if m.column == "COUNTRY/OCEAN"]
            @test [m.status for m in dups] == [:active, :invalid]
            submission = read_bold(path)
            result = enrich_workbook(submission, registry, joinpath(dir, "out"); fields=["COUNTRY/OCEAN"])
            @test isfile(result.workbook)
            @test result.report["per_field"]["COUNTRY/OCEAN"]["layers"] == ["cells", "zones"]
        finally
            close(registry)
        end
    end
end

@testset "IBV4: reserved output names are refused" begin
    mktempdir() do dir
        root = geodata_root(dir)
        for name in ("point", "coordinate_status")
            config = joinpath(dir, "layers_$name.toml")
            write(config, replace(LAYERS_TOML, "output = \"cell_name\"" => "output = \"$name\""))
            registry = load_registry(config; geodata_root=root, log=false)
            try
                layer = only(l for l in registry.layers if l.id == "cells")
                @test layer.status === :invalid && any(p -> occursin("reserved", p), layer.problems)
                frame = extract_layers(GeoPoints([41.5], [11.5]), registry)
                @test frame.point == [1] && frame.coordinate_status == ["valid"]
            finally
                close(registry)
            end
        end
    end
end

@testset "IBV5: max_attribute at the Int64 limits" begin
    mktempdir() do dir
        fields = (name=AG.OFTString, rank=AG.OFTInteger64)
        features = [(wkt=box(0, 0, 10, 10), name="min", rank=typemin(Int64)),
                    (wkt=box(0, 0, 10, 10), name="one", rank=Int64(1)),
                    (wkt=box(0, 0, 10, 10), name="none", rank=missing)]
        path = write_polygons(joinpath(dir, "ranks.gpkg"), features; crs="EPSG:4326", fields)
        pick(policy) = begin
            catalog = GeoCatalog([VectorLayer("r", path; attributes=["name"], overlap=policy, overlap_attribute="rank")])
            try
                only(extract_vector(GeoPoints([5.0], [5.0]), catalog, "r").name)
            finally
                close(catalog)
            end
        end
        @test pick(:max_attribute) == "one"
        @test pick(:min_attribute) == "min"
        top = [(wkt=box(0, 0, 10, 10), name="max", rank=typemax(Int64)),
               (wkt=box(0, 0, 10, 10), name="min", rank=typemin(Int64)),
               (wkt=box(0, 0, 10, 10), name="max2", rank=typemax(Int64))]       # tie: lowest FID wins
        path = write_polygons(joinpath(dir, "top.gpkg"), top; crs="EPSG:4326", fields)
        @test pick(:max_attribute) == "max"
    end
end
