# CRS handling through GDAL's C API. ArchGDAL 0.10 passes `pointer(v)` without
# `GC.@preserve` in `transform!`, `getgeotransform` and `invgeotransform`; on
# Julia 1.13 this silently returned the default geotransform inside compiled
# functions. These wrappers pass rooted arrays to GDAL.jl instead.

"""An owned OGR spatial reference, always using longitude/x before latitude/y."""
mutable struct SpatialReference
    ptr::GDAL.OGRSpatialReferenceH
    function SpatialReference(ptr::GDAL.OGRSpatialReferenceH)
        ptr == C_NULL && throw(GeoDatasetError("GDAL returned an empty spatial reference"))
        # Traditional GIS order makes axis 1 easting/longitude for every CRS,
        # including EPSG:4326, whose authority order is latitude first.
        GDAL.osrsetaxismappingstrategy(ptr, GDAL.OAMS_TRADITIONAL_GIS_ORDER)
        srs = new(ptr)
        finalizer(_release!, srs)
        return srs
    end
end

function _release!(srs::SpatialReference)
    if srs.ptr != C_NULL
        GDAL.osrrelease(srs.ptr)
        srs.ptr = C_NULL
    end
    return nothing
end

Base.unsafe_convert(::Type{Ptr{Cvoid}}, srs::SpatialReference) = srs.ptr

"""Copy a spatial reference owned by a dataset or layer."""
_clone_srs(borrowed::Ptr{Cvoid}) = SpatialReference(GDAL.osrclone(borrowed))

"""Build a spatial reference from user input such as `"EPSG:32633"` or WKT."""
function _srs_from_text(text::AbstractString)
    ptr = GDAL.osrnewspatialreference(C_NULL)
    try
        GDAL.osrsetfromuserinput(ptr, text)
    catch err
        GDAL.osrrelease(ptr)
        err isa GDAL.GDALError || rethrow()
        throw(GeoDatasetError("Invalid CRS definition $(repr(text)): $(strip(err.msg))"))
    end
    return SpatialReference(ptr)
end

_wgs84() = _srs_from_text("EPSG:4326")

"""Return a short CRS label, preferring `AUTHORITY:CODE`."""
function _crs_label(srs::SpatialReference)
    name = something(GDAL.osrgetname(srs.ptr), "unnamed CRS")
    authority = GDAL.osrgetauthorityname(srs.ptr, C_NULL)
    code = GDAL.osrgetauthoritycode(srs.ptr, C_NULL)
    authority === nothing || code === nothing || return "$authority:$code ($name)"
    return name
end

"""An owned OGR coordinate transformation from WGS84 to a dataset CRS."""
mutable struct CoordinateTransform
    ptr::GDAL.OGRCoordinateTransformationH
    source::SpatialReference
    target::SpatialReference
    function CoordinateTransform(source::SpatialReference, target::SpatialReference)
        ptr = try
            GDAL.octnewcoordinatetransformation(source.ptr, target.ptr)
        catch err
            err isa GDAL.GDALError || rethrow()
            throw(GeoDatasetError("Cannot transform WGS84 to $(_crs_label(target)): $(strip(err.msg))"))
        end
        ptr == C_NULL && throw(GeoDatasetError("Cannot transform WGS84 to $(_crs_label(target))"))
        transform = new(ptr, source, target)
        finalizer(_release!, transform)
        return transform
    end
end

function _release!(transform::CoordinateTransform)
    if transform.ptr != C_NULL
        GDAL.octdestroycoordinatetransformation(transform.ptr)
        transform.ptr = C_NULL
    end
    return nothing
end

"""
Transform valid WGS84 points into the dataset CRS in one GDAL call.
Return `(x, y, status)`; `status` is `:ok`, `:transform_failed` or the
coordinate validation status of an invalid input point.
"""
function _project(transform::CoordinateTransform, points::GeoPoints)
    n = length(points)
    status = Vector{Symbol}(undef, n)
    valid = Int[]
    for i in 1:n
        if points.status[i] === :valid
            push!(valid, i)
            status[i] = :ok
        else
            status[i] = points.status[i]
        end
    end
    x = fill(NaN, n)
    y = fill(NaN, n)
    m = length(valid)
    m == 0 && return x, y, status
    xs = points.longitude[valid]
    ys = points.latitude[valid]
    zs = zeros(m)
    success = zeros(Cint, m)
    try
        GDAL.octtransformex(transform.ptr, m, xs, ys, zs, success)
    catch err
        # GDAL.jl throws when PROJ reports any failed point; the per-point
        # success flags are still filled, so failures are handled below.
        err isa GDAL.GDALError || rethrow()
    end
    for (k, i) in enumerate(valid)
        if success[k] != 0 && isfinite(xs[k]) && isfinite(ys[k])
            x[i] = xs[k]
            y[i] = ys[k]
        else
            status[i] = :transform_failed
        end
    end
    return x, y, status
end
