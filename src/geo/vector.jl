const POLYGONAL_TYPES = (GDAL.wkbPolygon, GDAL.wkbMultiPolygon, GDAL.wkbCurvePolygon,
                         GDAL.wkbMultiSurface, GDAL.wkbUnknown)

"""Feature IDs and bounding boxes of every polygon, for layers without a spatial index."""
struct EnvelopeIndex
    fids::Vector{Int64}
    boxes::Vector{NTuple{4,Float64}}   # (xmin, ymin, xmax, ymax)
end

# One sequential pass that keeps only FIDs and envelopes (32 bytes per feature);
# geometries are read again by FID only for the tiles that need them.
function _envelope_index(layer)
    fids = Int64[]
    boxes = NTuple{4,Float64}[]
    envelope = Ref(GDAL.OGREnvelope(0, 0, 0, 0))
    for feature in layer
        try
            geometry = GDAL.ogr_f_getgeometryref(feature)
            geometry == C_NULL && continue
            GDAL.ogr_g_getenvelope(geometry, envelope)
            e = envelope[]
            push!(fids, ArchGDAL.getfid(feature))
            push!(boxes, (e.MinX, e.MinY, e.MaxX, e.MaxY))
        finally
            ArchGDAL.destroy(feature)
        end
    end
    return EnvelopeIndex(fids, boxes)
end

"""An open polygon layer with its CRS transformation; use only while holding `lock`."""
mutable struct VectorHandle
    config::VectorLayer
    dataset::Union{Nothing,ArchGDAL.IDataset}
    layer::Union{Nothing,ArchGDAL.IFeatureLayer}
    transform::CoordinateTransform
    crs::String
    extent::Union{Nothing,NTuple{4,Float64}}   # (xmin, ymin, xmax, ymax); nothing for empty layers
    field_indices::Vector{Int}
    priority_index::Int
    spatial_index::Bool
    feature_count::Int
    envelopes::Union{Nothing,EnvelopeIndex}   # fallback index for layers without one
    lock::ReentrantLock
end

# Only local file formats are opened: no VRT, WMS or /vsicurl/ indirection.
const VECTOR_DRIVERS = ["GPKG", "ESRI Shapefile"]
const RASTER_DRIVERS = ["GTiff"]

function _open_dataset(path, flag, what)
    isfile(path) || throw(GeoDatasetError("$what dataset not found: $path"))
    drivers = flag == ArchGDAL.OF_VECTOR ? VECTOR_DRIVERS : RASTER_DRIVERS
    try
        return ArchGDAL.read(path; flags=flag | ArchGDAL.OF_READONLY | ArchGDAL.OF_VERBOSE_ERROR,
                             alloweddrivers=drivers)
    catch err
        err isa GDAL.GDALError || rethrow()
        throw(GeoDatasetError("Cannot open $what dataset $path: $(strip(err.msg))"))
    end
end

function _dataset_srs(borrowed::Ptr{Cvoid}, assume_crs, path)
    if borrowed == C_NULL
        assume_crs === nothing && throw(GeoDatasetError(
            "Dataset $path declares no CRS; set assume_crs only if the CRS is known"))
        return _srs_from_text(assume_crs)
    end
    assume_crs === nothing || throw(GeoDatasetError(
        "Dataset $path declares a CRS; assume_crs is only allowed for datasets without one"))
    return _clone_srs(borrowed)
end

function _field_index(defn, name, path)
    index = Int(GDAL.ogr_fd_getfieldindex(defn, name))
    # OGR field lookup is case-insensitive; configured names must match exactly.
    if index < 0 || GDAL.ogr_fld_getnameref(GDAL.ogr_fd_getfielddefn(defn, index)) != name
        available = [GDAL.ogr_fld_getnameref(GDAL.ogr_fd_getfielddefn(defn, i))
                     for i in 0:(GDAL.ogr_fd_getfieldcount(defn) - 1)]
        throw(GeoDatasetError("Attribute $(repr(name)) not found in $path; fields: $(join(available, ", "))"))
    end
    return index
end

function _open_vector(config::VectorLayer)
    dataset = _open_dataset(config.path, ArchGDAL.OF_VECTOR, "Vector")
    try
        names = [ArchGDAL.getname(ArchGDAL.getlayer(dataset, i)) for i in 0:(ArchGDAL.nlayer(dataset) - 1)]
        layer = if config.layer === nothing
            length(names) == 1 || throw(GeoDatasetError(
                "$(config.path) has $(length(names)) layers ($(join(names, ", "))); set layer explicitly"))
            ArchGDAL.getlayer(dataset, 0)
        else
            config.layer in names || throw(GeoDatasetError(
                "Layer $(repr(config.layer)) not found in $(config.path); layers: $(join(names, ", "))"))
            ArchGDAL.getlayer(dataset, something(findfirst(==(config.layer), names)) - 1)
        end
        geomtype = GDAL.ogr_gt_flatten(GDAL.ogr_l_getgeomtype(layer))
        geomtype in POLYGONAL_TYPES || throw(GeoDatasetError(
            "Layer $(ArchGDAL.getname(layer)) in $(config.path) is not polygonal ($geomtype)"))
        srs = _dataset_srs(GDAL.ogr_l_getspatialref(layer), config.assume_crs, config.path)
        defn = GDAL.ogr_l_getlayerdefn(layer)
        fields = [_field_index(defn, a, config.path) for a in config.attributes]
        priority = config.overlap_attribute === nothing ? -1 : _field_index(defn, config.overlap_attribute, config.path)
        count = Int(ArchGDAL.nfeature(layer, true))
        extent = if count == 0
            nothing
        else
            env = ArchGDAL.envelope(layer, true)
            (env.MinX, env.MinY, env.MaxX, env.MaxY)
        end
        indexed = ArchGDAL.testcapability(layer, "FastSpatialFilter")
        envelopes = !indexed && ArchGDAL.testcapability(layer, "RandomRead") ? _envelope_index(layer) : nothing
        return VectorHandle(config, dataset, layer, CoordinateTransform(_wgs84(), srs), _crs_label(srs),
                            extent, fields, priority, indexed, count, envelopes, ReentrantLock())
    catch
        ArchGDAL.destroy(dataset)
        rethrow()
    end
end

function _close!(handle::VectorHandle)
    lock(handle.lock) do
        handle.layer = nothing
        dataset = handle.dataset
        if dataset !== nothing
            ArchGDAL.destroy(dataset)
            handle.dataset = nothing
        end
    end
    return nothing
end

"""A polygon read for one tile; geometry tests use the GEOS prepared geometry."""
mutable struct Candidate
    fid::Int64
    xmin::Float64
    ymin::Float64
    xmax::Float64
    ymax::Float64
    geometry::ArchGDAL.IGeometry
    prepared::ArchGDAL.IPreparedGeometry
    values::Vector{Any}
    priority::Any
    area::Float64          # NaN until needed by an area policy
    bytes::Int             # WKB size, used to bound the cache
end

# Prepared polygons are reused across the tiles of one extraction: large
# polygons (regions with full-resolution coastlines) would otherwise be read
# and prepared again for every tile. Bounded by total WKB size, LRU eviction.
const CANDIDATE_CACHE_BYTES = Ref(64 * 2^20)

mutable struct CandidateCache
    entries::Dict{Int64,Candidate}
    used::Dict{Int64,Int}
    bytes::Int
    tick::Int
end
CandidateCache() = CandidateCache(Dict{Int64,Candidate}(), Dict{Int64,Int}(), 0, 0)

function _remember!(cache::CandidateCache, c::Candidate)
    cache.entries[c.fid] = c
    cache.used[c.fid] = cache.tick
    cache.bytes += c.bytes
    return c
end

function _trim!(cache::CandidateCache)
    cache.bytes <= CANDIDATE_CACHE_BYTES[] && return cache
    for fid in sort!(collect(keys(cache.used)); by=f -> cache.used[f])
        cache.used[fid] == cache.tick && continue          # needed by the current tile
        c = pop!(cache.entries, fid)
        delete!(cache.used, fid)
        cache.bytes -= c.bytes
        _release!(c)
        cache.bytes <= CANDIDATE_CACHE_BYTES[] && break
    end
    return cache
end

function _release!(cache::CandidateCache)
    foreach(_release!, values(cache.entries))
    empty!(cache.entries)
    empty!(cache.used)
    cache.bytes = 0
    return nothing
end

_field_value(feature::ArchGDAL.AbstractFeature, index::Integer) = something(ArchGDAL.getfield(feature, index), missing)

"""Build a candidate from a feature (destroyed here); `nothing` for non-areal geometry."""
function _candidate(handle::VectorHandle, feature::ArchGDAL.AbstractFeature)
    try
        geometry = ArchGDAL.getgeom(feature)
        geometry.ptr == C_NULL && return nothing
        if ArchGDAL.isempty(geometry) || ArchGDAL.geomdim(geometry) < 2
            ArchGDAL.destroy(geometry)
            return nothing
        end
        env = ArchGDAL.envelope(geometry)
        values = Any[_field_value(feature, i) for i in handle.field_indices]
        priority = handle.priority_index < 0 ? nothing : _field_value(feature, handle.priority_index)
        return Candidate(ArchGDAL.getfid(feature), env.MinX, env.MinY, env.MaxX, env.MaxY, geometry,
                         ArchGDAL.preparegeom(geometry), values, priority, NaN, Int(ArchGDAL.wkbsize(geometry)))
    finally
        ArchGDAL.destroy(feature)
    end
end

function _cached!(candidates, cache::CandidateCache, fid)
    c = get(cache.entries, fid, nothing)
    c === nothing && return false
    cache.used[fid] = cache.tick
    push!(candidates, c)
    return true
end

function _read_candidates(handle::VectorHandle, bbox, cache::CandidateCache)
    layer = handle.layer::ArchGDAL.IFeatureLayer
    candidates = Candidate[]
    cache.tick += 1
    index = handle.envelopes
    if index !== nothing
        x0, y0, x1, y1 = bbox
        for (fid, (a, b, c, d)) in zip(index.fids, index.boxes)
            (a <= x1 && c >= x0 && b <= y1 && d >= y0) || continue
            _cached!(candidates, cache, fid) && continue
            feature = ArchGDAL.unsafe_getfeature(layer, fid)
            feature.ptr == C_NULL && throw(GeoDatasetError("Feature $fid disappeared from $(handle.config.path)"))
            new = _candidate(handle, feature)
            new === nothing || push!(candidates, _remember!(cache, new))
        end
        return candidates
    end
    # OGR uses the layer's own spatial index (GeoPackage R-tree, Shapefile .qix).
    ArchGDAL.setspatialfilter!(layer, bbox...)
    try
        for feature in layer
            if _cached!(candidates, cache, ArchGDAL.getfid(feature))
                ArchGDAL.destroy(feature)
                continue
            end
            new = _candidate(handle, feature)
            new === nothing || push!(candidates, _remember!(cache, new))
        end
    finally
        ArchGDAL.clearspatialfilter!(layer)
    end
    return candidates
end

"""Split point indices into spatially compact tiles (recursive median split)."""
function _tiles(indices::Vector{Int}, x, y, max_points::Int, max_size::Float64)
    tiles = Vector{Vector{Int}}()
    stack = [indices]
    while !isempty(stack)
        tile = pop!(stack)
        isempty(tile) && continue
        xmin, xmax = extrema(x[i] for i in tile)
        ymin, ymax = extrema(y[i] for i in tile)
        width, height = xmax - xmin, ymax - ymin
        if length(tile) == 1 || (width == 0 && height == 0) ||
           (length(tile) <= max_points && max(width, height) <= max_size)
            push!(tiles, tile)
            continue
        end
        coordinate = width >= height ? x : y
        sort!(tile; by=i -> coordinate[i])
        middle = length(tile) ÷ 2
        push!(stack, tile[1:middle], tile[(middle + 1):end])
    end
    return tiles
end

function _release!(c::Candidate)
    ArchGDAL.destroy(c.prepared)
    ArchGDAL.destroy(c.geometry)
    return nothing
end

function _area!(c::Candidate)
    isnan(c.area) && (c.area = ArchGDAL.geomarea(c.geometry))
    return c.area
end

# Deterministic total orders: the primary key, then the lowest feature ID.
_by_priority(c::Candidate) = ismissing(c.priority) || c.priority === nothing ? (1, 0) : (0, c.priority)

_has_priority(c::Candidate) = !(ismissing(c.priority) || c.priority === nothing ||
                                (c.priority isa AbstractFloat && isnan(c.priority)))

# max_attribute compares without negating, so typemin(Int64) cannot overflow:
# candidates with a value first, then the largest value, then the lowest FID.
function _max_priority(matches::Vector{Candidate})
    for c in matches
        _has_priority(c) && !(c.priority isa Real) && throw(GeoDatasetError(
            "max_attribute requires a numeric overlap_attribute; got $(typeof(c.priority))"))
    end
    better(a, b) = _has_priority(a) != _has_priority(b) ? _has_priority(a) :
                   _has_priority(a) && a.priority != b.priority ? a.priority > b.priority : a.fid < b.fid
    return reduce((best, c) -> better(c, best) ? c : best, matches)
end

function _select(policy::Symbol, matches::Vector{Candidate})
    policy === :lowest_fid && return argmin(c -> c.fid, matches)
    policy === :highest_fid && return argmax(c -> c.fid, matches)
    policy === :smallest_area && return argmin(c -> (_area!(c), c.fid), matches)
    policy === :largest_area && return argmin(c -> (-_area!(c), c.fid), matches)
    policy === :min_attribute && return argmin(c -> (_by_priority(c), c.fid), matches)
    policy === :max_attribute && return _max_priority(matches)
    throw(ArgumentError("Unhandled overlap policy $policy"))
end

"""Return `(inside, boundary)` for one point against the tile candidates."""
function _classify!(inside, boundary, candidates, probe, px, py, tolerance)
    empty!(inside)
    empty!(boundary)
    for c in candidates
        (c.xmin - tolerance <= px <= c.xmax + tolerance && c.ymin - tolerance <= py <= c.ymax + tolerance) || continue
        # For a point, contains() means the interior; intersects() adds the boundary.
        if ArchGDAL.contains(c.prepared, probe)
            push!(inside, c)
        elseif ArchGDAL.intersects(c.prepared, probe)
            push!(boundary, c)
        end
    end
    return inside, boundary
end

function _vector_rows(handle::VectorHandle, points::GeoPoints)
    config = handle.config
    n = length(points)
    x, y, pstatus = _project(handle.transform, points)
    status = Vector{Symbol}(undef, n)
    fid = Vector{Union{Missing,Int64}}(missing, n)
    match_fids = [Int64[] for _ in 1:n]
    on_boundary = falses(n)
    values = [Vector{Any}(missing, n) for _ in config.attributes]
    tolerance = config.boundary_tolerance
    pending = Int[]
    for i in 1:n
        if pstatus[i] !== :ok
            status[i] = pstatus[i] === :transform_failed ? :transform_failed : :invalid_coordinate
        elseif handle.extent === nothing
            status[i] = :outside_extent
        else
            xmin, ymin, xmax, ymax = handle.extent
            if xmin - tolerance <= x[i] <= xmax + tolerance && ymin - tolerance <= y[i] <= ymax + tolerance
                push!(pending, i)
            else
                status[i] = :outside_extent
            end
        end
    end
    isempty(pending) && return (; x, y, status, fid, match_fids, on_boundary, values)
    xmin, ymin, xmax, ymax = handle.extent
    max_size = something(config.tile_size, max(xmax - xmin, ymax - ymin) / 16)
    inside, boundary = Candidate[], Candidate[]
    probe = ArchGDAL.createpoint(0.0, 0.0)
    cache = CandidateCache()
    try
    for tile in _tiles(pending, x, y, config.tile_points, max_size)
        bx0, bx1 = extrema(x[i] for i in tile)
        by0, by1 = extrema(y[i] for i in tile)
        pad = max(tolerance, 1e-9 * max(1.0, abs(bx0), abs(bx1), abs(by0), abs(by1)))
        candidates = _read_candidates(handle, (bx0 - pad, by0 - pad, bx1 + pad, by1 + pad), cache)
        for i in tile
            ArchGDAL.setpoint!(probe, 0, x[i], y[i])
            if tolerance > 0
                shape = ArchGDAL.buffer(probe, tolerance, 8)
                try
                    _classify!(inside, boundary, candidates, shape, x[i], y[i], tolerance)
                finally
                    ArchGDAL.destroy(shape)
                end
            else
                _classify!(inside, boundary, candidates, probe, x[i], y[i], tolerance)
            end
            on_boundary[i] = !isempty(boundary)
            selected = if config.boundary === :exclude
                inside
            elseif config.boundary === :include
                vcat(inside, boundary)
            else
                isempty(inside) ? boundary : inside
            end
            match_fids[i] = sort!([c.fid for c in selected])
            if isempty(selected)
                status[i] = isempty(boundary) ? :no_match : :boundary
                continue
            end
            if length(selected) > 1 && config.overlap === :ambiguous
                status[i] = :ambiguous
                continue
            end
            chosen = length(selected) == 1 ? only(selected) : _select(config.overlap, selected)
            status[i] = any(c -> c === chosen, inside) ? :inside : :boundary
            fid[i] = chosen.fid
            for (k, column) in enumerate(values)
                column[i] = chosen.values[k]
            end
        end
        _trim!(cache)
    end
    finally
        # GEOS/OGR memory is invisible to Julia's GC: free the geometries now
        # instead of waiting for finalizers.
        _release!(cache)
        ArchGDAL.destroy(probe)
    end
    return (; x, y, status, fid, match_fids, on_boundary, values)
end

_narrow(values::Vector{Any}) = isempty(values) ? Union{Missing,Any}[] : map(identity, values)
_optional(v::Vector{Float64}) = Union{Missing,Float64}[isnan(a) ? missing : a for a in v]

function _vector_frame(handle::VectorHandle, points::GeoPoints)
    rows = _vector_rows(handle, points)
    frame = DataFrame(point=collect(1:length(points)), status=String.(rows.status),
                      x=_optional(rows.x), y=_optional(rows.y), fid=rows.fid,
                      n_matches=length.(rows.match_fids), match_fids=rows.match_fids,
                      on_boundary=collect(rows.on_boundary))
    for (name, column) in zip(handle.config.columns, rows.values)
        frame[!, name] = _narrow(column)
    end
    return frame
end
