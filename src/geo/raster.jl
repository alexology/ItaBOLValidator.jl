# Supported band types: GDAL data type => (Julia buffer type, buffer GDAL type).
# Float16 bands (GDAL >= 3.11) are converted exactly to Float32 by GDAL.
const RASTER_TYPES = Dict(
    GDAL.GDT_Byte => (UInt8, GDAL.GDT_Byte), GDAL.GDT_Int8 => (Int8, GDAL.GDT_Int8),
    GDAL.GDT_UInt16 => (UInt16, GDAL.GDT_UInt16), GDAL.GDT_Int16 => (Int16, GDAL.GDT_Int16),
    GDAL.GDT_UInt32 => (UInt32, GDAL.GDT_UInt32), GDAL.GDT_Int32 => (Int32, GDAL.GDT_Int32),
    GDAL.GDT_UInt64 => (UInt64, GDAL.GDT_UInt64), GDAL.GDT_Int64 => (Int64, GDAL.GDT_Int64),
    GDAL.GDT_Float16 => (Float32, GDAL.GDT_Float32),
    GDAL.GDT_Float32 => (Float32, GDAL.GDT_Float32), GDAL.GDT_Float64 => (Float64, GDAL.GDT_Float64),
)

# Above this many pixels per natural block, windows are capped (large strips).
const MAX_WINDOW_PIXELS = 1 << 22

"""An open raster band with georeferencing; use only while holding `lock`."""
mutable struct RasterHandle{T<:Real}
    config::RasterLayer
    dataset::Union{Nothing,ArchGDAL.IDataset}
    band::Ptr{Cvoid}                       # owned by `dataset`
    buffer_type::GDAL.GDALDataType
    transform::CoordinateTransform
    crs::String
    geotransform::NTuple{6,Float64}
    inverse::NTuple{6,Float64}
    width::Int
    height::Int
    window::Tuple{Int,Int}
    nodata::Union{Nothing,T}
    scale::Float64
    offset::Float64
    categories::Union{Nothing,Dict{Int64,String}}
    mask::Ptr{Cvoid}                       # GDAL mask band to honour, or C_NULL (owned by `dataset`)
    lock::ReentrantLock
end

"""
The band's GDAL mask (RFC 15) when it carries information beyond NoData: a
per-dataset or per-band mask (internal or `.msk`) or an alpha band. Masks
derived from the NoData value are left to the layer's explicit `nodata` policy.
"""
function _mask_band(band)
    flags = GDAL.gdalgetmaskflags(band)
    (flags & GDAL.GMF_ALL_VALID != 0 || flags & GDAL.GMF_NODATA != 0) && return C_NULL
    return GDAL.gdalgetmaskband(band)
end

"""Invert a GDAL affine geotransform (pixel/line -> x/y) without approximation."""
function _invert(gt::NTuple{6,Float64})
    det = gt[2] * gt[6] - gt[3] * gt[5]
    (isfinite(det) && det != 0) || throw(GeoDatasetError("Raster geotransform is not invertible: $gt"))
    a, b, d, e = gt[6] / det, -gt[3] / det, -gt[5] / det, gt[2] / det
    return (-(a * gt[1] + b * gt[4]), a, b, -(d * gt[1] + e * gt[4]), d, e)
end

"""Return fractional `(pixel, line)` for a point, using the full affine inverse."""
@inline function _pixel_line(inv::NTuple{6,Float64}, x::Float64, y::Float64)
    return inv[1] + inv[2] * x + inv[3] * y, inv[4] + inv[5] * x + inv[6] * y
end

# Snap values within 1e-9 pixel of a grid line to it, so points exactly on a
# pixel edge are not moved across by the floating-point inverse; then floor.
@inline function _pixel_index(p::Float64)
    r = round(p)
    return Int(abs(p - r) <= 1e-9 ? r : floor(p))
end

function _representable(::Type{T}, value::Real) where {T<:Integer}
    value isa Integer && return typemin(T) <= value <= typemax(T) ? T(value) : nothing
    isfinite(value) && isinteger(value) && typemin(T) <= value <= typemax(T) || return nothing
    return T(value)
end
_representable(::Type{T}, value::Real) where {T<:AbstractFloat} = T(value)

function _dataset_nodata(band, ::Type{T}) where {T}
    has = Ref{Cint}(0)
    value = if T === Int64
        GDAL.gdalgetrasternodatavalueasint64(band, has)
    elseif T === UInt64
        GDAL.gdalgetrasternodatavalueasuint64(band, has)
    else
        GDAL.gdalgetrasternodatavalue(band, has)
    end
    has[] == 0 && return nothing
    # A declared NoData value outside the band type can never occur in it.
    return _representable(T, value)
end

function _raster_nodata(config::RasterLayer, band, ::Type{T}) where {T}
    nodata = config.nodata
    nodata === :none && return nothing
    nodata isa Symbol && return _dataset_nodata(band, T)
    value = _representable(T, nodata)
    value === nothing && throw(GeoDatasetError(
        "nodata=$(config.nodata) cannot occur in the $(T) band of $(config.path)"))
    return value
end

function _category_names(band)
    names = GDAL.gdalgetrastercategorynames(band)
    return Dict{Int64,String}(Int64(i - 1) => name for (i, name) in enumerate(names) if !isempty(name))
end

function _open_raster(config::RasterLayer)
    dataset = _open_dataset(config.path, ArchGDAL.OF_RASTER, "Raster")
    try
        count = ArchGDAL.nraster(dataset)
        config.band <= count || throw(GeoDatasetError("$(config.path) has $count band(s); band $(config.band) requested"))
        band = GDAL.gdalgetrasterband(dataset, config.band)
        gdt = GDAL.gdalgetrasterdatatype(band)
        haskey(RASTER_TYPES, gdt) || throw(GeoDatasetError("Unsupported raster data type $gdt in $(config.path)"))
        T, buffer_type = RASTER_TYPES[gdt]
        config.kind === :categorical && !(T <: Integer) && throw(GeoDatasetError(
            "Categorical raster $(config.path) must have an integer band, not $T"))
        gt = zeros(6)
        GDAL.gdalgetgeotransform(dataset, gt) == GDAL.CE_None ||
            throw(GeoDatasetError("Raster $(config.path) has no affine geotransform"))
        geotransform = NTuple{6,Float64}(gt)
        srs = _dataset_srs(GDAL.gdalgetspatialref(dataset), config.assume_crs, config.path)
        bx, by = Ref{Cint}(0), Ref{Cint}(0)
        GDAL.gdalgetblocksize(band, bx, by)
        width, height = Int(GDAL.gdalgetrasterbandxsize(band)), Int(GDAL.gdalgetrasterbandysize(band))
        window = (Int(bx[]), Int(by[]))
        if window[1] * window[2] > MAX_WINDOW_PIXELS
            window = (min(window[1], 2048), min(window[2], 2048))
        end
        categories = config.categories === :dataset ? _category_names(band) : config.categories
        scale = config.apply_scale ? GDAL.gdalgetrasterscale(band, C_NULL) : 1.0
        offset = config.apply_scale ? GDAL.gdalgetrasteroffset(band, C_NULL) : 0.0
        return RasterHandle{T}(config, dataset, band, buffer_type, CoordinateTransform(_wgs84(), srs),
                               _crs_label(srs), geotransform, _invert(geotransform), width, height, window,
                               _raster_nodata(config, band, T), scale, offset, categories, _mask_band(band),
                               ReentrantLock())
    catch
        ArchGDAL.destroy(dataset)
        rethrow()
    end
end

function _close!(handle::RasterHandle)
    lock(handle.lock) do
        handle.band = C_NULL
        handle.mask = C_NULL
        dataset = handle.dataset
        if dataset !== nothing
            ArchGDAL.destroy(dataset)
            handle.dataset = nothing
        end
    end
    return nothing
end

_is_nodata(value::AbstractFloat, nodata) = isnan(value) || (nodata !== nothing && value == nodata)
_is_nodata(value::Integer, nodata) = nodata !== nothing && value == nodata

function _read_window!(handle::RasterHandle, buffer, xoff, yoff, xsize, ysize)
    # GDAL fills the buffer row-major: pixel (c, r) is at r * xsize + c.
    result = GDAL.gdalrasterio(handle.band, GDAL.GF_Read, xoff, yoff, xsize, ysize, buffer,
                               xsize, ysize, handle.buffer_type, 0, 0)
    result == GDAL.CE_None || throw(GeoDatasetError("Failed to read raster window from $(handle.config.path)"))
    return buffer
end

function _read_mask!(handle::RasterHandle, buffer::Vector{UInt8}, xoff, yoff, xsize, ysize)
    result = GDAL.gdalrasterio(handle.mask, GDAL.GF_Read, xoff, yoff, xsize, ysize, buffer,
                               xsize, ysize, GDAL.GDT_Byte, 0, 0)
    result == GDAL.CE_None || throw(GeoDatasetError("Failed to read the raster mask of $(handle.config.path)"))
    return buffer
end

function _raster_rows(handle::RasterHandle{T}, points::GeoPoints) where {T}
    n = length(points)
    x, y, pstatus = _project(handle.transform, points)
    status = Vector{Symbol}(undef, n)
    pixel = Vector{Union{Missing,Int}}(missing, n)
    line = Vector{Union{Missing,Int}}(missing, n)
    raw = Vector{Union{Missing,T}}(missing, n)
    for i in 1:n
        if pstatus[i] !== :ok
            status[i] = pstatus[i] === :transform_failed ? :transform_failed : :invalid_coordinate
            continue
        end
        pf, lf = _pixel_line(handle.inverse, x[i], y[i])
        if !(0 <= pf < handle.width + 1 && 0 <= lf < handle.height + 1)
            status[i] = :outside_coverage
            continue
        end
        p, l = _pixel_index(pf), _pixel_index(lf)
        if 0 <= p < handle.width && 0 <= l < handle.height
            pixel[i], line[i] = p, l
            status[i] = :pending
        else
            status[i] = :outside_coverage
        end
    end
    tw, th = handle.window
    nwx = cld(handle.width, tw)
    pending = [i for i in 1:n if status[i] === :pending]
    key(i) = (line[i] ÷ th) * nwx + pixel[i] ÷ tw
    sort!(pending; by=key)
    buffer = Vector{T}(undef, tw * th)
    masked = handle.mask != C_NULL
    mask = masked ? Vector{UInt8}(undef, tw * th) : UInt8[]
    k = 1
    while k <= length(pending)
        window = key(pending[k])
        last = k
        while last < length(pending) && key(pending[last + 1]) == window
            last += 1
        end
        xoff, yoff = (window % nwx) * tw, (window ÷ nwx) * th
        xsize, ysize = min(tw, handle.width - xoff), min(th, handle.height - yoff)
        _read_window!(handle, buffer, xoff, yoff, xsize, ysize)
        masked && _read_mask!(handle, mask, xoff, yoff, xsize, ysize)
        for i in view(pending, k:last)
            at = (line[i] - yoff) * xsize + (pixel[i] - xoff) + 1
            value = buffer[at]
            # Mask value 0 marks an invalid pixel (GDAL RFC 15); any other value is valid.
            if masked && mask[at] == 0
                status[i] = :masked
            elseif _is_nodata(value, handle.nodata)
                status[i] = :nodata
            else
                status[i] = :ok
                raw[i] = value
            end
        end
        k = last + 1
    end
    return (; x, y, status, pixel, line, raw)
end

"""
Length of one raster CRS unit in metres for north-up rasters in a projected CRS
(for example 1.0 for UTM), or `nothing` when distances in metres cannot be
measured on the grid (geographic CRS, rotated geotransform).
"""
function _metres_per_unit(handle::RasterHandle)
    gt = handle.geotransform
    (gt[3] == 0 && gt[5] == 0) || return nothing
    srs = handle.transform.target.ptr
    GDAL.osrisprojected(srs) == 0 && return nothing
    unit = GDAL.osrgetlinearunits(srs, C_NULL)
    return isfinite(unit) && unit > 0 ? Float64(unit) : nothing
end

# Window radii above this many pixels are refused (a 1001 x 1001 window at most).
const MAX_RELIEF_PIXELS = 500

function _relief_rows(handle::RasterHandle{T}, points::GeoPoints, radius::AbstractVector{<:Real}) where {T}
    n = length(points)
    length(radius) == n || throw(DimensionMismatch("one radius per point is required"))
    rows = _raster_rows(handle, points)
    status = copy(rows.status)
    relief = Vector{Union{Missing,Float64}}(missing, n)
    metres = _metres_per_unit(handle)
    gt = handle.geotransform
    convert(v) = Float64(v) * handle.scale + handle.offset
    for i in 1:n
        status[i] === :ok || continue
        r = Float64(radius[i])
        if metres === nothing
            status[i] = :unsupported_crs
            continue
        end
        if !(isfinite(r) && r >= 0)
            status[i] = :invalid_radius
            continue
        end
        dx, dy = abs(gt[2]) * metres, abs(gt[6]) * metres
        rx, ry = ceil(Int, r / dx), ceil(Int, r / dy)
        if max(rx, ry) > MAX_RELIEF_PIXELS
            status[i] = :radius_too_large
            continue
        end
        p, l = rows.pixel[i]::Int, rows.line[i]::Int
        xoff, yoff = max(0, p - rx), max(0, l - ry)
        xsize, ysize = min(handle.width, p + rx + 1) - xoff, min(handle.height, l + ry + 1) - yoff
        buffer = Vector{T}(undef, xsize * ysize)
        _read_window!(handle, buffer, xoff, yoff, xsize, ysize)
        mask = handle.mask != C_NULL ? _read_mask!(handle, Vector{UInt8}(undef, xsize * ysize), xoff, yoff, xsize, ysize) : nothing
        z0 = convert(rows.raw[i])
        best = 0.0
        for c in 0:ysize-1, b in 0:xsize-1
            at = c * xsize + b + 1
            # Cell centres within the radius (in metres) of the point; its own cell always counts.
            cx, cy = (xoff + b + 0.5 - (rows.x[i] - gt[1]) / gt[2]) * dx, (yoff + c + 0.5 - (rows.y[i] - gt[4]) / gt[6]) * dy
            (xoff + b == p && yoff + c == l) || cx^2 + cy^2 <= r^2 || continue
            v = buffer[at]
            (mask !== nothing && mask[at] == 0) && continue
            _is_nodata(v, handle.nodata) && continue
            best = max(best, abs(convert(v) - z0))
        end
        relief[i] = best
    end
    value = Union{Missing,Float64}[status[i] === :ok ? convert(rows.raw[i]) : missing for i in 1:n]
    return DataFrame(point=collect(1:n), status=String.(status), value=value, relief=relief,
                     radius=Float64.(radius))
end

function _raster_frame(handle::RasterHandle, points::GeoPoints)
    rows = _raster_rows(handle, points)
    frame = DataFrame(point=collect(1:length(points)), status=String.(rows.status),
                      x=_optional(rows.x), y=_optional(rows.y), pixel=rows.pixel, line=rows.line)
    if handle.config.kind === :categorical
        frame.value = rows.raw
        categories = handle.categories
        if categories !== nothing
            frame.label = Union{Missing,String}[ismissing(v) ? missing : get(categories, v, missing)
                                                for v in rows.raw]
        end
    else
        frame.value = Union{Missing,Float64}[ismissing(v) ? missing : Float64(v) * handle.scale + handle.offset
                                             for v in rows.raw]
    end
    return frame
end
