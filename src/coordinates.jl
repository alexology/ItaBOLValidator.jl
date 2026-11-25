"""Strict decimal-degree validation, independent of workbook parsing."""
module CoordinateValidation

import Base: isvalid

export CoordinateValue, CoordinatePair, validate_coordinate, validate_coordinates, isvalid

"""A parsed coordinate and its status; only `:valid` carries a numeric value."""
struct CoordinateValue
    value::Union{Missing,Float64}
    status::Symbol
end

"""Latitude and longitude validation results, in that order."""
struct CoordinatePair
    latitude::CoordinateValue
    longitude::CoordinateValue
end

"""Return whether both coordinates are valid decimal degrees."""
isvalid(pair::CoordinatePair) = pair.latitude.status === :valid && pair.longitude.status === :valid

const DECIMAL_DEGREES = r"^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$"

"""
    validate_coordinate(raw, axis::Symbol) -> CoordinateValue

Validate `:latitude` in [-90, 90] or `:longitude` in [-180, 180]. Accept finite
real numbers (excluding Bool) and decimal strings with a dot and optional exponent.
Whitespace-only strings, `nothing` and `missing` have status `:missing`.
Other statuses are `:invalid_format`, `:nonfinite`, and `:out_of_range`.
No coordinate is corrected, rounded, swapped, or written back to the input.
"""
function validate_coordinate(raw, axis::Symbol)
    axis in (:latitude, :longitude) || throw(ArgumentError("axis must be :latitude or :longitude"))
    if ismissing(raw) || raw === nothing
        return CoordinateValue(missing, :missing)
    end
    if raw isa AbstractString
        token = strip(raw)
        isempty(token) && return CoordinateValue(missing, :missing)
        occursin(DECIMAL_DEGREES, token) || return CoordinateValue(missing, :invalid_format)
        value = tryparse(Float64, token)
        # A syntactically valid decimal can still exceed Float64's parser range;
        # Julia versions differ on returning nothing versus Inf for overflow.
        value === nothing && return CoordinateValue(missing, :nonfinite)
    elseif raw isa Real && !(raw isa Bool)
        # Check in the original numeric type before reducing precision to Float64.
        isfinite(raw) || return CoordinateValue(missing, :nonfinite)
        limit = axis === :latitude ? 90 : 180
        -limit <= raw <= limit || return CoordinateValue(missing, :out_of_range)
        value = Float64(raw)
    else
        return CoordinateValue(missing, :invalid_format)
    end
    isfinite(value) || return CoordinateValue(missing, :nonfinite)
    limit = axis === :latitude ? 90 : 180
    abs(value) <= limit || return CoordinateValue(missing, :out_of_range)
    return CoordinateValue(value, :valid)
end

"""Validate a latitude/longitude pair without geographic inference or mutation."""
validate_coordinates(latitude, longitude) = CoordinatePair(
    validate_coordinate(latitude, :latitude), validate_coordinate(longitude, :longitude))

end
