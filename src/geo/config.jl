"""An invalid, missing or unsupported local geospatial dataset or layer configuration."""
struct GeoDatasetError <: Exception
    message::String
end
Base.showerror(io::IO, err::GeoDatasetError) = print(io, err.message)

"""Configuration of one local dataset sampled by points."""
abstract type GeoLayer end

const LAYER_NAME = r"^[A-Za-z][A-Za-z0-9_-]*$"
const BOUNDARY_POLICIES = (:exclude, :include, :prefer_inside)
const OVERLAP_POLICIES = (:ambiguous, :lowest_fid, :highest_fid, :smallest_area,
                          :largest_area, :min_attribute, :max_attribute)
const RASTER_KINDS = (:categorical, :continuous)
"""Fixed columns of `extract_vector` results; attribute columns may not reuse them."""
const VECTOR_COLUMNS = ("point", "status", "x", "y", "fid", "n_matches", "match_fids", "on_boundary")

_attribute_source(a::AbstractString) = String(a)
_attribute_source(a::Pair{<:AbstractString,<:AbstractString}) = String(first(a))
_attribute_source(a) = throw(ArgumentError("Attributes must be names or \"field\" => \"column\" pairs; got $(repr(a))"))
_attribute_column(a::AbstractString) = String(a)
_attribute_column(a::Pair{<:AbstractString,<:AbstractString}) = String(last(a))
_attribute_column(a) = _attribute_source(a)

function _check_name(name)
    occursin(LAYER_NAME, name) || throw(ArgumentError(
        "Layer name $(repr(name)) must start with a letter and contain only letters, digits, '_' or '-'"))
    return String(name)
end

_choice(value::AbstractString, allowed, what) = _choice(Symbol(value), allowed, what)
function _choice(value::Symbol, allowed, what)
    value in allowed || throw(ArgumentError("Unknown $what $(repr(value)); expected one of $(join(allowed, ", "))"))
    return value
end

_optional_string(::Nothing) = nothing
_optional_string(x::AbstractString) = (isempty(x) && throw(ArgumentError("Empty strings are not allowed")); String(x))

"""
    VectorLayer(name, path; attributes, overlap, layer=nothing, overlap_attribute=nothing,
                boundary=:exclude, boundary_tolerance=0.0, assume_crs=nothing,
                tile_size=nothing, tile_points=4096)

Point-in-polygon extraction from a Shapefile, GeoPackage or other OGR polygon layer.

- `attributes`: exact, case-sensitive field names copied from the selected polygon,
  or `field => column` pairs to choose the output column name. Output names must
  not repeat or use the reserved names in `VECTOR_COLUMNS`.
- `layer`: layer name; required when the dataset contains more than one layer.
- `overlap` (required, no default): how one polygon is selected when several match.
  `:ambiguous` returns no values; `:lowest_fid`/`:highest_fid` pick by feature ID;
  `:smallest_area`/`:largest_area` by planar area in the layer CRS;
  `:min_attribute`/`:max_attribute` by `overlap_attribute` (missing values last).
  All ties are broken by the lowest feature ID.
- `boundary`: `:exclude` reports boundary points without values; `:include` treats
  boundary polygons as matches; `:prefer_inside` uses them only without an
  interior match.
- `boundary_tolerance`: distance in layer CRS units within which a point counts
  as being on a boundary. `0` means exact GEOS topology.
- `assume_crs`: CRS for datasets that declare none (for example a Shapefile
  without `.prj`). It is refused when the dataset declares its own CRS.
- `tile_size`, `tile_points`: batching limits in layer CRS units and points.
  They change performance, never results.
"""
struct VectorLayer <: GeoLayer
    name::String
    path::String
    layer::Union{Nothing,String}
    attributes::Vector{String}
    columns::Vector{String}
    overlap::Symbol
    overlap_attribute::Union{Nothing,String}
    boundary::Symbol
    boundary_tolerance::Float64
    assume_crs::Union{Nothing,String}
    tile_size::Union{Nothing,Float64}
    tile_points::Int
end

function VectorLayer(name::AbstractString, path::AbstractString;
                     attributes::AbstractVector, overlap::Union{Symbol,AbstractString},
                     layer::Union{Nothing,AbstractString}=nothing,
                     overlap_attribute::Union{Nothing,AbstractString}=nothing,
                     boundary::Union{Symbol,AbstractString}=:exclude, boundary_tolerance::Real=0.0,
                     assume_crs::Union{Nothing,AbstractString}=nothing,
                     tile_size::Union{Nothing,Real}=nothing, tile_points::Integer=4096)
    attrs = String[_attribute_source(a) for a in attributes]
    columns = String[_attribute_column(a) for a in attributes]
    (any(isempty, attrs) || any(isempty, columns)) && throw(ArgumentError("Empty attribute name in layer $name"))
    length(unique(attrs)) == length(attrs) || throw(ArgumentError("Duplicate attributes in layer $name"))
    length(unique(columns)) == length(columns) || throw(ArgumentError("Duplicate output columns in layer $name"))
    reserved = intersect(columns, VECTOR_COLUMNS)
    isempty(reserved) || throw(ArgumentError(
        "Output columns $(join(reserved, ", ")) are reserved; rename them with \"field\" => \"column\""))
    policy = _choice(overlap, OVERLAP_POLICIES, "overlap policy")
    by_attribute = policy in (:min_attribute, :max_attribute)
    by_attribute && overlap_attribute === nothing &&
        throw(ArgumentError("overlap=$policy requires overlap_attribute"))
    !by_attribute && overlap_attribute !== nothing &&
        throw(ArgumentError("overlap_attribute is only used with :min_attribute or :max_attribute"))
    isfinite(boundary_tolerance) && boundary_tolerance >= 0 ||
        throw(ArgumentError("boundary_tolerance must be finite and non-negative"))
    tile_size === nothing || (isfinite(tile_size) && tile_size > 0) ||
        throw(ArgumentError("tile_size must be positive"))
    tile_points >= 1 || throw(ArgumentError("tile_points must be at least 1"))
    return VectorLayer(_check_name(name), String(path), _optional_string(layer), attrs, columns, policy,
                       _optional_string(overlap_attribute), _choice(boundary, BOUNDARY_POLICIES, "boundary policy"),
                       Float64(boundary_tolerance), _optional_string(assume_crs),
                       tile_size === nothing ? nothing : Float64(tile_size), Int(tile_points))
end

"""
    RasterLayer(name, path; kind, band=1, nodata=:dataset, categories=nothing,
                apply_scale=true, assume_crs=nothing)

Point sampling of one GeoTIFF (or other GDAL raster) band at the pixel that
contains each point. No interpolation or resampling is performed.

- `kind` (required): `:categorical` keeps native integer codes and requires an
  integer band; `:continuous` returns `Float64`, with band scale/offset applied
  when `apply_scale=true`.
- `nodata`: `:dataset` uses the band's NoData value, `:none` ignores it, or a
  number overrides it. NaN is always NoData in floating-point bands.
- `categories`: `nothing`, `:dataset` (GDAL category names, code = index - 1),
  or a `Dict` from integer code to label. Categorical layers only.
- `assume_crs`: CRS for rasters without one; refused when the raster declares one.
"""
struct RasterLayer <: GeoLayer
    name::String
    path::String
    kind::Symbol
    band::Int
    nodata::Union{Symbol,Real}
    categories::Union{Nothing,Symbol,Dict{Int64,String}}
    apply_scale::Bool
    assume_crs::Union{Nothing,String}
end

function RasterLayer(name::AbstractString, path::AbstractString; kind::Union{Symbol,AbstractString},
                     band::Integer=1, nodata::Union{Symbol,AbstractString,Real}=:dataset,
                     categories::Union{Nothing,Symbol,AbstractString,AbstractDict}=nothing,
                     apply_scale::Bool=true, assume_crs::Union{Nothing,AbstractString}=nothing)
    k = _choice(kind, RASTER_KINDS, "raster kind")
    band >= 1 || throw(ArgumentError("band must be at least 1"))
    nd = if nodata isa Real
        nodata isa Bool && throw(ArgumentError("nodata must be :dataset, :none or a number"))
        nodata
    else
        _choice(nodata, (:dataset, :none), "nodata mode")
    end
    cats = if categories === nothing
        nothing
    elseif categories isa AbstractDict
        Dict{Int64,String}(Int64(c) => String(label) for (c, label) in categories)
    else
        _choice(categories, (:dataset,), "categories source")
    end
    cats !== nothing && k !== :categorical &&
        throw(ArgumentError("categories are only allowed for categorical rasters"))
    return RasterLayer(_check_name(name), String(path), k, Int(band), nd, cats, apply_scale,
                       _optional_string(assume_crs))
end
