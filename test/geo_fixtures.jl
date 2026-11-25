# Synthetic geospatial datasets for the extraction tests. Everything is written
# to a temporary directory; no real or remote data is used.
import ArchGDAL
import GDAL

const AG = ArchGDAL

# ArchGDAL's setgeotransform! passes an unrooted pointer; call GDAL with the array.
function set_geotransform!(dataset, gt::Vector{Float64})
    @assert GDAL.gdalsetgeotransform(dataset, gt) == GDAL.CE_None
    return dataset
end

function srs_handle(code)
    h = GDAL.osrnewspatialreference(C_NULL)
    GDAL.osrsetfromuserinput(h, code)
    GDAL.osrsetaxismappingstrategy(h, GDAL.OAMS_TRADITIONAL_GIS_ORDER)
    return h
end

"""Transform (x, y) points between CRSs with GDAL; used to place test points."""
function reproject_points(xs, ys, from, to)
    s, t = srs_handle(from), srs_handle(to)
    ct = GDAL.octnewcoordinatetransformation(s, t)
    x, y = Float64.(xs), Float64.(ys)
    ok = zeros(Cint, length(x))
    GDAL.octtransformex(ct, length(x), x, y, zeros(length(x)), ok)
    GDAL.octdestroycoordinatetransformation(ct)
    GDAL.osrrelease(s)
    GDAL.osrrelease(t)
    @assert all(!=(0), ok)
    return x, y
end

"""WGS84 GeoPoints for points given in a projected CRS."""
function points_from(crs, xs, ys)
    lon, lat = reproject_points(xs, ys, crs, "EPSG:4326")
    return GeoPoints(lat, lon)
end

box(x0, y0, x1, y1) = "POLYGON(($x0 $y0, $x1 $y0, $x1 $y1, $x0 $y1, $x0 $y0))"

"""
Write a polygon layer. `features` are NamedTuples with `wkt` and field values;
`missing` writes a null field. Returns the dataset path.
"""
function write_polygons(path, features; driver="GPKG", crs="EPSG:32633", layer="zones",
                        fields=(name=AG.OFTString, code=AG.OFTInteger, rank=AG.OFTReal), write_prj=true)
    AG.create(path; driver=AG.getdriver(driver)) do ds
        spatialref = crs === nothing ? AG.SpatialRef() : AG.importUserInput(crs)
        lyr = AG.createlayer(name=layer, dataset=ds, geom=AG.wkbPolygon, spatialref=spatialref)
        for (fname, ftype) in pairs(fields)
            AG.addfielddefn!(lyr, String(fname), ftype)
        end
        for f in features
            AG.addfeature(lyr) do feature
                AG.setgeom!(feature, AG.fromWKT(f.wkt))
                for (i, fname) in enumerate(keys(fields))
                    value = getproperty(f, fname)
                    ismissing(value) ? AG.setfieldnull!(feature, i - 1) : AG.setfield!(feature, i - 1, value)
                end
            end
        end
    end
    if !write_prj
        rm(replace(path, r"\.shp$" => ".prj"); force=true)
    end
    return path
end

# UTM 33N zones: A and B share the edge x = 400000; C overlaps both; D has a hole.
const UTM_ZONES = [
    (wkt=box(300000, 4600000, 400000, 4700000), name="A", code=Int32(1), rank=2.0),
    (wkt=box(400000, 4600000, 500000, 4700000), name="B", code=Int32(2), rank=1.0),
    (wkt=box(350000, 4650000, 420000, 4690000), name=missing, code=Int32(3), rank=3.0),
    (wkt="POLYGON((600000 4600000, 700000 4600000, 700000 4700000, 600000 4700000, 600000 4600000)," *
         "(630000 4630000, 670000 4630000, 670000 4670000, 630000 4670000, 630000 4630000))",
     name="D", code=Int32(4), rank=missing),
]

# EPSG:4326 one-degree cells over 10-14 E, 40-44 N; cell code = 100*lat0 + lon0.
function degree_cells()
    cells = NamedTuple[]
    for lat0 in 40:43, lon0 in 10:13
        push!(cells, (wkt=box(lon0, lat0, lon0 + 1, lat0 + 1), name="cell_$(lat0)_$(lon0)",
                      code=Int32(100 * lat0 + lon0), rank=Float64(lon0)))
    end
    return cells
end

"""Write a raster from a (width, height) matrix; `gt` is the GDAL geotransform."""
function write_raster(path, data::AbstractMatrix{T}; gt, crs="EPSG:32633", nodata=nothing,
                      options=String[], categories=nothing, scale=nothing, offset=nothing) where {T}
    width, height = size(data)
    AG.create(path; driver=AG.getdriver("GTiff"), width=width, height=height, nbands=1, dtype=T,
              options=options) do ds
        set_geotransform!(ds, gt)
        crs === nothing || AG.setproj!(ds, AG.toWKT(AG.importUserInput(crs)))
        band = AG.getband(ds, 1)
        nodata === nothing || AG.setnodatavalue!(band, nodata)
        categories === nothing || AG.setcategorynames!(band, categories)
        scale === nothing || AG.setscale!(band, scale)
        offset === nothing || AG.setoffset!(band, offset)
        AG.write!(band, data)
    end
    return path
end

"""Build all fixtures in `dir` and return their paths."""
function geo_fixtures(dir)
    paths = Dict{Symbol,String}()
    paths[:utm_gpkg] = write_polygons(joinpath(dir, "zones.gpkg"), UTM_ZONES)
    paths[:utm_shp] = write_polygons(joinpath(dir, "zones.shp"), UTM_ZONES; driver="ESRI Shapefile")
    paths[:noprj_shp] = write_polygons(joinpath(dir, "noprj.shp"), UTM_ZONES; driver="ESRI Shapefile",
                                       write_prj=false)
    paths[:cells] = write_polygons(joinpath(dir, "cells.gpkg"), degree_cells(); crs="EPSG:4326", layer="cells")
    # The same UTM polygons reprojected exactly as WKT are not needed: a LAEA
    # layer checks transformation to a second projected CRS.
    laea = map(UTM_ZONES[1:2]) do f
        xs, ys = reproject_points([f.wkt == UTM_ZONES[1].wkt ? 350000 : 450000], [4650000], "EPSG:32633", "EPSG:3035")
        (wkt=box(xs[1] - 1000, ys[1] - 1000, xs[1] + 1000, ys[1] + 1000), name=f.name, code=f.code, rank=f.rank)
    end
    paths[:laea] = write_polygons(joinpath(dir, "laea.gpkg"), laea; crs="EPSG:3035")
    mercator = [(wkt=box(-2.0e7, -2.0e7, 2.0e7, 2.0e7), name="world", code=Int32(1), rank=1.0)]
    paths[:mercator] = write_polygons(joinpath(dir, "mercator.gpkg"), mercator; crs="EPSG:3857")
    # Two layers in one GeoPackage, to test explicit layer selection.
    path = joinpath(dir, "two_layers.gpkg")
    write_polygons(path, UTM_ZONES[1:1]; layer="first")
    AG.read(path; flags=AG.OF_UPDATE) do ds
        lyr = AG.createlayer(name="second", dataset=ds, geom=AG.wkbPolygon,
                             spatialref=AG.importUserInput("EPSG:32633"))
        AG.addfielddefn!(lyr, "name", AG.OFTString)
        AG.addfeature(lyr) do feature
            AG.setgeom!(feature, AG.fromWKT(UTM_ZONES[2].wkt))
            AG.setfield!(feature, 0, "second-B")
        end
    end
    paths[:two_layers] = path
    paths[:lines] = joinpath(dir, "lines.gpkg")
    AG.create(paths[:lines]; driver=AG.getdriver("GPKG")) do ds
        lyr = AG.createlayer(name="lines", dataset=ds, geom=AG.wkbLineString,
                             spatialref=AG.importUserInput("EPSG:4326"))
        AG.addfeature(lyr) do feature
            AG.setgeom!(feature, AG.fromWKT("LINESTRING(10 40, 11 41)"))
        end
    end

    # Categorical UInt8, 600 x 500 pixels of 100 m, tiled and DEFLATE-compressed.
    # Class = 1 + (pixel ÷ 100) + 10 * (line ÷ 100); 255 is NoData in one 10 x 10 patch.
    classes = [UInt8(1 + p ÷ 100 + 10 * (l ÷ 100)) for p in 0:599, l in 0:499]
    classes[11:20, 11:20] .= 0xff
    paths[:classes] = write_raster(joinpath(dir, "classes.tif"), classes;
                                   gt=[300000.0, 100.0, 0.0, 4700000.0, 0.0, -100.0], nodata=255,
                                   options=["TILED=YES", "COMPRESS=DEFLATE", "BLOCKXSIZE=128", "BLOCKYSIZE=128"],
                                   categories=["none", "forest", "grassland"])
    # Continuous Float32 in EPSG:4326 with 0.01 degree pixels over 10-12 E, 40-42 N:
    # value = lon + lat / 100 at pixel centres, NaN and -9999 NoData patches.
    temps = [Float32(10 + (p + 0.5) * 0.01 + (42 - (l + 0.5) * 0.01) / 100) for p in 0:199, l in 0:199]
    temps[1:5, 1:5] .= NaN32
    temps[6:10, 1:5] .= -9999f0
    paths[:temps] = write_raster(joinpath(dir, "temps.tif"), temps; gt=[10.0, 0.01, 0.0, 42.0, 0.0, -0.01],
                                 crs="EPSG:4326", nodata=-9999, options=["COMPRESS=LZW"])
    # Scaled Int16 elevation: physical value = 0.5 * raw + 100.
    paths[:scaled] = write_raster(joinpath(dir, "scaled.tif"), Int16[10 20; 30 40];
                                  gt=[10.0, 1.0, 0.0, 42.0, 0.0, -1.0], crs="EPSG:4326", scale=0.5, offset=100.0)
    # Rotated geotransform in EPSG:4326 (30 degree rotation, non-square pixels).
    θ = π / 6
    rotated_gt = [11.0, 0.02 * cos(θ), -0.01 * sin(θ), 41.0, 0.02 * sin(θ), 0.01 * cos(θ) * -1]
    paths[:rotated] = write_raster(joinpath(dir, "rotated.tif"), [Int32(1000 * p + l) for p in 0:19, l in 0:29];
                                   gt=rotated_gt, crs="EPSG:4326")
    paths[:no_crs] = write_raster(joinpath(dir, "no_crs.tif"), UInt8[1 2; 3 4];
                                  gt=[300000.0, 100.0, 0.0, 4700000.0, 0.0, -100.0], crs=nothing)
    paths[:laea_raster] = write_raster(joinpath(dir, "laea.tif"), UInt16[1 2; 3 4];
                                       gt=[4.0e6, 1.0e6, 0.0, 3.0e6, 0.0, -1.0e6], crs="EPSG:3035")
    for T in (UInt8, Int8, UInt16, Int16, UInt32, Int32, Int64, UInt64, Float32, Float64)
        data = T[T(1) T(2) T(3); T(4) T(5) T(6)]   # 2 x 3: pixel 0..1, line 0..2
        extreme = T <: Integer ? typemax(T) : T(1.5e30)
        data[2, 3] = extreme
        paths[Symbol("type_", T)] = write_raster(joinpath(dir, "type_$(T).tif"), data;
                                                 gt=[10.0, 1.0, 0.0, 42.0, 0.0, -1.0], crs="EPSG:4326",
                                                 nodata=T <: Integer ? nothing : -1)
    end
    return paths, rotated_gt
end

"""A large tiled, compressed raster written block by block."""
function write_large_raster(path; size=4096, block=256)
    AG.create(path; driver=AG.getdriver("GTiff"), width=size, height=size, nbands=1, dtype=Int16,
              options=["TILED=YES", "COMPRESS=DEFLATE", "BLOCKXSIZE=$block", "BLOCKYSIZE=$block",
                       "BIGTIFF=IF_SAFER"]) do ds
        set_geotransform!(ds, [500000.0, 10.0, 0.0, 4800000.0, 0.0, -10.0])
        AG.setproj!(ds, AG.toWKT(AG.importUserInput("EPSG:32633")))
        band = AG.getband(ds, 1)
        buffer = Matrix{Int16}(undef, size, block)
        for y0 in 0:block:(size - 1)
            for l in 1:block, p in 1:size
                buffer[p, l] = Int16(((p - 1) ÷ block) + 100 * ((y0 + l - 1) ÷ block))
            end
            AG.write!(band, buffer, 0, y0, size, block)
        end
    end
    return path
end
