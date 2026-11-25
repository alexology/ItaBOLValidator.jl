"""
    GeoPoints(latitudes, longitudes)
    GeoPoints(pairs::AbstractVector{CoordinatePair})

WGS84 (EPSG:4326) decimal-degree points in input order. Raw values are validated
with [`validate_coordinates`](@ref); latitude and longitude are never swapped,
clamped or inferred. Invalid points are kept, with `NaN` coordinates and a
`status` such as `:latitude_out_of_range`, so every output row still lines up
with its input point. Valid points have status `:valid`.
"""
struct GeoPoints
    latitude::Vector{Float64}
    longitude::Vector{Float64}
    status::Vector{Symbol}

    function GeoPoints(latitude::Vector{Float64}, longitude::Vector{Float64}, status::Vector{Symbol})
        n = length(latitude)
        length(longitude) == n && length(status) == n ||
            throw(DimensionMismatch("latitude, longitude and status must have equal lengths"))
        for i in 1:n
            status[i] === :valid || continue
            lat, lon = latitude[i], longitude[i]
            isfinite(lat) && isfinite(lon) && abs(lat) <= 90 && abs(lon) <= 180 ||
                throw(ArgumentError("Point $i is marked valid but is not a WGS84 coordinate"))
        end
        return new(latitude, longitude, status)
    end
end

function _pair_status(pair::CoordinatePair)
    isvalid(pair) && return :valid
    pair.latitude.status === :valid || return Symbol("latitude_", pair.latitude.status)
    return Symbol("longitude_", pair.longitude.status)
end

function GeoPoints(pairs::AbstractVector{CoordinatePair})
    n = length(pairs)
    lat = fill(NaN, n)
    lon = fill(NaN, n)
    status = Vector{Symbol}(undef, n)
    for (i, pair) in enumerate(pairs)
        status[i] = _pair_status(pair)
        if status[i] === :valid
            lat[i] = pair.latitude.value
            lon[i] = pair.longitude.value
        end
    end
    return GeoPoints(lat, lon, status)
end

function GeoPoints(latitudes::AbstractVector, longitudes::AbstractVector)
    length(latitudes) == length(longitudes) ||
        throw(DimensionMismatch("latitudes and longitudes must have equal lengths"))
    return GeoPoints([validate_coordinates(a, b) for (a, b) in zip(latitudes, longitudes)])
end

Base.length(points::GeoPoints) = length(points.status)

function Base.show(io::IO, points::GeoPoints)
    valid = count(==(:valid), points.status)
    print(io, "GeoPoints(", length(points), " points, ", valid, " valid)")
end

"""
    geopoints(x) -> GeoPoints

Convert extraction input to [`GeoPoints`](@ref). Accepts `GeoPoints`, a vector of
`CoordinatePair`, a `(latitudes, longitudes)` tuple, or a parsed `BOLDSubmission`.
"""
geopoints(points::GeoPoints) = points
geopoints(pairs::AbstractVector{CoordinatePair}) = GeoPoints(pairs)
geopoints(columns::Tuple{AbstractVector,AbstractVector}) = GeoPoints(columns[1], columns[2])
geopoints(x) = throw(ArgumentError(
    "Unsupported point input $(typeof(x)); pass GeoPoints, CoordinatePair values, " *
    "(latitudes, longitudes) or a BOLDSubmission"))
