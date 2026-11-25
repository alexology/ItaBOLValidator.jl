# Simplified polygon outlines in WGS84 for overview maps drawn from local data.

function _collect_rings!(rings, g::Ptr{Cvoid})
    t = GDAL.ogr_gt_flatten(GDAL.ogr_g_getgeometrytype(g))
    if t == GDAL.wkbPolygon || t == GDAL.wkbMultiPolygon || t == GDAL.wkbGeometryCollection
        for k in 0:(GDAL.ogr_g_getgeometrycount(g) - 1)
            _collect_rings!(rings, GDAL.ogr_g_getgeometryref(g, k))
        end
    elseif t == GDAL.wkbLineString || t == GDAL.wkbLinearRing
        n = GDAL.ogr_g_getpointcount(g)
        n >= 4 || return rings
        ring = Vector{Float64}(undef, 2n)
        for i in 1:n
            ring[2i - 1] = GDAL.ogr_g_getx(g, i - 1)
            ring[2i] = GDAL.ogr_g_gety(g, i - 1)
        end
        push!(rings, ring)
    end
    return rings
end

function _simplified_rings(layer, tolerance)
    GDAL.ogr_l_setspatialfilter(layer.ptr, C_NULL)
    GDAL.ogr_l_resetreading(layer.ptr)
    rings = Vector{Float64}[]
    for feature in layer
        try
            g = GDAL.ogr_f_getgeometryref(feature)
            g == C_NULL && continue
            s = GDAL.ogr_g_simplifypreservetopology(g, tolerance)
            s == C_NULL && continue
            try
                _collect_rings!(rings, s)
            finally
                GDAL.ogr_g_destroygeometry(s)
            end
        finally
            ArchGDAL.destroy(feature)
        end
    end
    return rings
end

function _rings_to_wgs84(back::CoordinateTransform, rings)
    total = sum(r -> length(r) ÷ 2, rings; init=0)
    xs, ys = Vector{Float64}(undef, total), Vector{Float64}(undef, total)
    k = 0
    for r in rings, i in 1:2:length(r)
        k += 1
        xs[k], ys[k] = r[i], r[i + 1]
    end
    zs = zeros(total)
    ok = zeros(Cint, total)
    try
        total > 0 && GDAL.octtransformex(back.ptr, total, xs, ys, zs, ok)
    catch err
        err isa GDAL.GDALError || rethrow()      # per-point flags are still filled
    end
    out = Vector{Float64}[]
    k = 0
    for r in rings
        m = length(r) ÷ 2
        good = all(j -> ok[k + j] != 0 && isfinite(xs[k + j]) && isfinite(ys[k + j]), 1:m)
        if good
            ring = Vector{Float64}(undef, 2m)
            for j in 1:m
                ring[2j - 1] = round(xs[k + j]; digits=5)
                ring[2j] = round(ys[k + j]; digits=5)
            end
            push!(out, ring)
        end
        k += m
    end
    return out
end

"""
    layer_outlines(catalog, name; tolerance=nothing, max_vertices=300_000) -> NamedTuple

Simplified outlines of the polygons of vector layer `name`, in WGS84
longitude/latitude, for overview maps: `(; rings, tolerance)`, where each ring is
a flat vector `[lon1, lat1, lon2, lat2, ...]` rounded to 5 decimals. The
topology-preserving simplification uses `tolerance` in layer CRS units (default
0.01 for geographic CRSs, 1000 for projected ones), doubled until the outlines
have at most `max_vertices` vertices. Rings that cannot be transformed are
dropped. If the vertex count stops decreasing (every ring is already minimal), the
outlines are returned above `max_vertices`. For display only: never use the
outlines for point-in-polygon tests.
"""
function layer_outlines(catalog::GeoCatalog, name::AbstractString; tolerance::Union{Nothing,Real}=nothing,
                        max_vertices::Integer=300_000)
    return _with_handle(catalog, name) do handle
        h = _vector_handle(handle, name)
        h.layer === nothing && return (; rings=Vector{Float64}[], tolerance=0.0)
        geographic = GDAL.osrisgeographic(h.transform.target.ptr) != 0
        tol = Float64(something(tolerance, geographic ? 0.01 : 1000.0))
        tol > 0 || throw(ArgumentError("tolerance must be positive"))
        back = CoordinateTransform(h.transform.target, h.transform.source)
        try
            # Rings never shrink below 4 vertices, so stop once doubling no longer helps.
            previous = typemax(Int)
            for _ in 1:40
                rings = _simplified_rings(h.layer, tol)
                vertices = sum(r -> length(r) ÷ 2, rings; init=0)
                (vertices <= max_vertices || vertices >= previous) &&
                    return (; rings=_rings_to_wgs84(back, rings), tolerance=tol)
                previous = vertices
                tol *= 2
            end
            return (; rings=_rings_to_wgs84(back, _simplified_rings(h.layer, tol)), tolerance=tol)
        finally
            _release!(back)
        end
    end
end
