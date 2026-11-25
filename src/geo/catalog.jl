"""
    GeoCatalog(layers::AbstractVector{<:GeoLayer})

A set of configured local layers whose GDAL datasets are opened on first use
and then reused. Each open dataset has its own lock, so concurrent tasks may
share a catalog; calls on one layer are serialized because GDAL handles are
not thread-safe. Call `close(catalog)` to release all datasets.
"""
mutable struct GeoCatalog
    layers::Vector{GeoLayer}
    index::Dict{String,Int}
    handles::Dict{String,Union{VectorHandle,RasterHandle}}
    lock::ReentrantLock
    isopen::Bool
end

function GeoCatalog(layers::AbstractVector{<:GeoLayer})
    index = Dict{String,Int}()
    for (i, layer) in enumerate(layers)
        haskey(index, layer.name) && throw(ArgumentError("Duplicate layer name $(layer.name)"))
        index[layer.name] = i
    end
    return GeoCatalog(collect(GeoLayer, layers), index, Dict{String,Union{VectorHandle,RasterHandle}}(),
                      ReentrantLock(), true)
end

"""Return configured layer names in configuration order."""
layer_names(catalog::GeoCatalog) = [layer.name for layer in catalog.layers]

Base.isopen(catalog::GeoCatalog) = catalog.isopen

function Base.close(catalog::GeoCatalog)
    lock(catalog.lock) do
        catalog.isopen = false
        foreach(_close!, values(catalog.handles))
        empty!(catalog.handles)
    end
    return nothing
end

function Base.show(io::IO, catalog::GeoCatalog)
    print(io, "GeoCatalog(", length(catalog.layers), " layers, ", length(catalog.handles), " open",
          catalog.isopen ? "" : ", closed", ")")
end

_open(config::VectorLayer) = _open_vector(config)
_open(config::RasterLayer) = _open_raster(config)

function _handle(catalog::GeoCatalog, name::AbstractString)
    return lock(catalog.lock) do
        catalog.isopen || throw(ArgumentError("GeoCatalog is closed"))
        i = get(catalog.index, name, 0)
        i == 0 && throw(ArgumentError("Unknown layer $(repr(name)); layers: $(join(layer_names(catalog), ", "))"))
        get!(() -> _open(catalog.layers[i]), catalog.handles, name)
    end
end

function _with_handle(f, catalog::GeoCatalog, name)
    handle = _handle(catalog, name)
    return lock(handle.lock) do
        handle.dataset === nothing && throw(ArgumentError("GeoCatalog is closed"))
        f(handle)
    end
end

function _with_layer(f, config::GeoLayer)
    catalog = GeoCatalog([config])
    try
        return _with_handle(f, catalog, config.name)
    finally
        close(catalog)
    end
end

"""
    layer_info(catalog, name) -> NamedTuple

Open the layer if needed and report its kind, path, every file GDAL opened
(`files`, including sidecars), driver, CRS and key properties:
extent, feature count, native spatial-index support and whether the in-memory
envelope index replaces it for vectors; size, block
window, geotransform, pixel type and NoData for rasters.
"""
layer_info(catalog::GeoCatalog, name::AbstractString) = _with_handle(_info, catalog, name)

_dataset(h) = h.dataset::ArchGDAL.IDataset
_info(h::VectorHandle) = (; kind=:vector, path=h.config.path, files=ArchGDAL.filelist(_dataset(h)),
                           driver=ArchGDAL.shortname(ArchGDAL.getdriver(_dataset(h))), crs=h.crs, extent=h.extent,
                           features=h.feature_count, spatial_index=h.spatial_index,
                           envelope_index=h.envelopes !== nothing)
_info(h::RasterHandle{T}) where {T} = (; kind=:raster, path=h.config.path, files=ArchGDAL.filelist(_dataset(h)),
                                        driver=ArchGDAL.shortname(ArchGDAL.getdriver(_dataset(h))), crs=h.crs,
                                        bands=ArchGDAL.nraster(_dataset(h)), band=h.config.band,
                                        width=h.width, height=h.height, window=h.window,
                                        geotransform=h.geotransform, pixel_type=T, nodata=h.nodata)

_vector_handle(h::VectorHandle, name) = h
_vector_handle(::RasterHandle, name) = throw(ArgumentError("Layer $name is a raster layer"))
_raster_handle(h::RasterHandle, name) = h
_raster_handle(::VectorHandle, name) = throw(ArgumentError("Layer $name is a vector layer"))

"""
    extract_vector(points, layer::VectorLayer) -> DataFrame
    extract_vector(points, catalog::GeoCatalog, name) -> DataFrame

Find the polygon containing each WGS84 point and copy its configured attributes.
Points are transformed to the layer CRS in one batch and grouped into compact
tiles; each tile issues one OGR spatial-filter query, which uses the layer's
spatial index (GeoPackage R-tree, Shapefile `.qix`) when present. Layers
without one get an in-memory index of feature envelopes when the dataset is
opened, and candidate polygons are then read by feature ID.

One row per input point, in input order: `point`, `status`, `x`/`y` (layer CRS),
`fid` of the selected polygon, `n_matches`, `match_fids` (all matching FIDs,
sorted), `on_boundary`, then one column per attribute. `status` is one of
`inside`, `boundary`, `ambiguous`, `no_match`, `outside_extent`,
`transform_failed` or `invalid_coordinate`; only `inside` and `boundary`
rows carry attribute values. Attribute nulls are `missing`.
"""
extract_vector(points, config::VectorLayer) = _with_layer(h -> _vector_frame(h, geopoints(points)), config)
extract_vector(points, catalog::GeoCatalog, name::AbstractString) =
    _with_handle(h -> _vector_frame(_vector_handle(h, name), geopoints(points)), catalog, name)

"""
    extract_raster(points, layer::RasterLayer) -> DataFrame
    extract_raster(points, catalog::GeoCatalog, name) -> DataFrame

Sample the raster pixel containing each WGS84 point, located through the full
affine inverse of the geotransform (rotation terms included). Points exactly on
an internal pixel edge belong to the pixel to the right/below; the right and
bottom outer edges are outside. Only the blocks containing points are read.

One row per input point: `point`, `status`, `x`/`y` (raster CRS), zero-based
GDAL `pixel`/`line`, `value`, and `label` for categorical layers with categories.
`status` is `ok`, `nodata`, `outside_coverage`, `transform_failed` or
`invalid_coordinate`. Categorical values keep the band's integer type;
continuous values are `Float64` with scale/offset applied.
"""
extract_raster(points, config::RasterLayer) = _with_layer(h -> _raster_frame(h, geopoints(points)), config)
extract_raster(points, catalog::GeoCatalog, name::AbstractString) =
    _with_handle(h -> _raster_frame(_raster_handle(h, name), geopoints(points)), catalog, name)

_frame(h::VectorHandle, points) = _vector_frame(h, points)
_frame(h::RasterHandle, points) = _raster_frame(h, points)

# Columns copied into the combined table; the per-layer functions return more.
_summary_columns(h::VectorHandle) = ["status", "fid", h.config.columns...]
_summary_columns(h::RasterHandle) = h.categories === nothing ? ["status", "value"] : ["status", "value", "label"]

"""
    extract_geodata(points, catalog::GeoCatalog, names=layer_names(catalog)) -> DataFrame
    extract_geodata(points, layers::AbstractVector{<:GeoLayer}) -> DataFrame

Extract several layers for the same points, one dataset at a time, and return
one row per point: `point`, `latitude`, `longitude`, `coordinate_status`, then
`<layer>.status` and the layer's values (`<layer>.fid` and `<layer>.<attribute>`
for vectors, `<layer>.value` and optional `<layer>.label` for rasters).
"""
function extract_geodata(points, catalog::GeoCatalog, names::AbstractVector{<:AbstractString}=layer_names(catalog))
    length(unique(names)) == length(names) || throw(ArgumentError("Duplicate selected layers"))
    pts = geopoints(points)
    result = DataFrame(point=collect(1:length(pts)),
                       latitude=Union{Missing,Float64}[s === :valid ? v : missing for (v, s) in zip(pts.latitude, pts.status)],
                       longitude=Union{Missing,Float64}[s === :valid ? v : missing for (v, s) in zip(pts.longitude, pts.status)],
                       coordinate_status=String.(pts.status))
    for name in names
        _with_handle(catalog, name) do handle
            frame = _frame(handle, pts)
            for column in _summary_columns(handle)
                result[!, "$name.$column"] = frame[!, column]
            end
        end
    end
    return result
end

function extract_geodata(points, layers::AbstractVector{<:GeoLayer})
    catalog = GeoCatalog(layers)
    try
        return extract_geodata(points, catalog)
    finally
        close(catalog)
    end
end
