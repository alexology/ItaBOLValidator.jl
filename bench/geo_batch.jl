# Batch extraction benchmark on synthetic data.
# Run: julia --project=. bench/geo_batch.jl [npoints]
using ItaBOLValidator
using Random: MersenneTwister
import ArchGDAL as AG
import GDAL

include(joinpath(@__DIR__, "..", "test", "geo_fixtures.jl"))

npoints = length(ARGS) >= 1 ? parse(Int, ARGS[1]) : 100_000
dir = mktempdir()

# 10,000 UTM polygons (100 x 100 grid of 4 km cells), each densified to ~160 vertices.
function grid_layer(path, driver)
    AG.create(path; driver=AG.getdriver(driver)) do ds
        layer = AG.createlayer(name="grid", dataset=ds, geom=AG.wkbPolygon, spatialref=AG.importUserInput("EPSG:32633"))
        AG.addfielddefn!(layer, "code", AG.OFTInteger)
        for i in 0:99, j in 0:99
            x0, y0 = 300000 + 4000i, 4500000 + 4000j
            g = AG.fromWKT(box(x0, y0, x0 + 4000, y0 + 4000))
            AG.segmentize!(g, 100.0)
            AG.addfeature(layer) do f
                AG.setgeom!(f, g)
                AG.setfield!(f, 0, Int32(100i + j))
            end
        end
    end
    return path
end

gpkg = grid_layer(joinpath(dir, "grid.gpkg"), "GPKG")
shp = grid_layer(joinpath(dir, "grid.shp"), "ESRI Shapefile")
raster = write_large_raster(joinpath(dir, "large.tif"); size=8192, block=256)

rng = MersenneTwister(1)
xs = 300000 .+ 400000 .* rand(rng, npoints)
ys = 4500000 .+ 400000 .* rand(rng, npoints)
points = points_from("EPSG:32633", xs, ys)
rx = 500000 .+ 81920 .* rand(rng, npoints)
ry = 4800000 .- 81920 .* rand(rng, npoints)
rpoints = points_from("EPSG:32633", rx, ry)

function measure(label, f)
    f()                                     # compile and warm caches
    GC.gc()
    stats = @timed f()
    println(rpad(label, 42), round(stats.time; digits=2), " s, ",
            round(stats.bytes / 2^20; digits=1), " MiB allocated")
    return stats.value
end

println("Points: $npoints, threads: $(Threads.nthreads())")
catalog = GeoCatalog([VectorLayer("gpkg", gpkg; attributes=["code"], overlap=:lowest_fid),
                      VectorLayer("shp", shp; attributes=["code"], overlap=:lowest_fid),
                      RasterLayer("dem", raster; kind=:continuous)])
for name in ("gpkg", "shp")
    r = measure("vector $name (10,000 polygons)", () -> extract_vector(points, catalog, name))
    @assert all(==("inside"), r.status) || all(in(("inside", "boundary")), r.status)
end
r = measure("raster 8192 x 8192 Int16 DEFLATE tiled", () -> extract_raster(rpoints, catalog, "dem"))
@assert all(==("ok"), r.status)
close(catalog)
println("Peak RSS: ", round(Sys.maxrss() / 2^20; digits=1), " MiB")
