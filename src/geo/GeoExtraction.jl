"""
Point extraction from local Shapefile, GeoPackage and GeoTIFF datasets through
ArchGDAL/GDAL. No remote GIS service is contacted. Input points are WGS84
(EPSG:4326) and are transformed to each dataset's own CRS.
"""
module GeoExtraction

import ArchGDAL
import GDAL
using DataFrames: DataFrame
using ..CoordinateValidation: CoordinatePair, validate_coordinates, isvalid

export GeoPoints, geopoints, GeoLayer, VectorLayer, RasterLayer, GeoCatalog, GeoDatasetError,
    layer_names, layer_info, extract_vector, extract_raster, extract_relief, extract_geodata, layer_outlines

include("points.jl")
include("config.jl")
include("crs.jl")
include("vector.jl")
include("raster.jl")
include("catalog.jl")
include("outlines.jl")

end
