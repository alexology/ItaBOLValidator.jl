"""
Administrator-maintained registry of local geospatial layers, configured in TOML.
It validates every layer at startup, reports problems without failing the whole
application, confines dataset paths to an approved geodata directory, and maps
extracted values to BOLD geographic columns. Extraction is delegated unchanged
to `GeoExtraction`, so new layers need only configuration.
"""
module LayerRegistry

import TOML
using DataFrames: DataFrame
using ..GeoExtraction: GeoLayer, VectorLayer, RasterLayer, GeoCatalog, GeoDatasetError, GeoPoints,
    geopoints, layer_info, extract_vector, extract_raster

export GeoRegistry, RegistryLayer, BoldFieldMapping, load_registry, registry_report, mapping_report,
    available_layers, layer_metadata, extract_layers, propose_bold_fields,
    BOLD_TARGET_COLUMNS, BOLD_PROTECTED_COLUMNS

const SCHEMA_VERSION = 1

"""BOLD geographic columns that layers may propose values for."""
const BOLD_TARGET_COLUMNS = ("COUNTRY/OCEAN", "PROVINCE/STATE", "REGION", "SECTOR", "SITE",
                             "ELEV", "DEPTH", "HABITAT")
const BOLD_NUMERIC_COLUMNS = ("ELEV", "DEPTH")
# Quantity a continuous layer must declare (`measure`) to fill each numeric column:
# a terrain model is never read as a sampling depth, nor bathymetry as elevation.
const BOLD_MEASURES = Dict("ELEV" => "elevation", "DEPTH" => "depth")
const MEASURES = ("elevation", "depth", "other")
# Administrative and place columns come only from authoritative polygons.
const BOLD_POLYGON_COLUMNS = ("COUNTRY/OCEAN", "PROVINCE/STATE", "REGION", "SECTOR", "SITE")

"""BOLD geographic columns never filled from layers, with the reason."""
const BOLD_PROTECTED_COLUMNS = Dict(
    "COORD:LAT" => "coordinates come from the submission and are never rewritten",
    "COORD:LON" => "coordinates come from the submission and are never rewritten",
    "COORD_SOURCE" => "the coordinate source is known only to the submitter",
    "COORD_ACCURACY" => "accuracy cannot be derived from layer or raster resolution",
    "ELEV_ACCURACY" => "accuracy cannot be derived from raster resolution alone",
    "DEPTH_ACCURACY" => "accuracy cannot be derived from raster resolution alone",
)

const LENGTH_UNITS = Dict("mm" => 1e-3, "cm" => 1e-2, "dm" => 0.1, "m" => 1.0, "km" => 1e3, "ft" => 0.3048)
const IDENTIFIER = r"^[a-z][a-z0-9_]*$"
const OUTPUT_NAME = r"^[A-Za-z][A-Za-z0-9_]*$"
# Service columns of `extract_layers`/`propose_bold_fields`; a layer output must not replace them.
const RESERVED_OUTPUTS = ("point", "coordinate_status")

const TOP_KEYS = Set(["schema_version", "geodata_root", "layers", "bold_fields"])
const COMMON_KEYS = Set(["id", "name", "type", "path", "output", "version", "source", "enabled",
                         "description", "assume_crs"])
const VECTOR_KEYS = Set(["layer", "attribute", "overlap", "overlap_attribute", "boundary",
                         "boundary_tolerance", "value_map"])
const RASTER_KEYS = Set(["band", "kind", "nodata", "categories", "value_map", "apply_scale", "measure", "digits",
                         "unit", "conversion", "valid_min", "valid_max"])
const MAPPING_KEYS = Set(["column", "layers"])

"""
One configured layer and its validation result. `status` is `:available`,
`:disabled` (`enabled = false`), `:unavailable` (dataset file missing) or
`:invalid` (configuration, path, CRS, attribute or band problem); `problems`
explains anything other than `:available` or `:disabled`.
"""
mutable struct RegistryLayer
    id::String
    name::String
    type::Symbol                     # :vector, :raster or :unknown
    kind::Symbol                     # :polygon, :categorical, :continuous or :unknown
    path::String                     # as configured, relative to the geodata root
    resolved::Union{Nothing,String}
    output::String
    version::String
    source::String
    description::String
    enabled::Bool
    unit::Union{Nothing,String}
    factor::Float64
    offset::Float64
    valid_min::Float64
    valid_max::Float64
    measure::Union{Nothing,String}
    digits::Union{Nothing,Int}
    value_map::Union{Nothing,Dict{Any,Any}}
    engine::Union{Nothing,GeoLayer}
    status::Symbol
    problems::Vector{String}
    metadata::Union{Nothing,NamedTuple}
end

"""
A BOLD column filled from the first listed layer with a value for each point.
`status` is `:active`, `:inactive` (no listed layer available) or `:invalid`.
"""
struct BoldFieldMapping
    column::String
    layers::Vector{String}
    status::Symbol
    problems::Vector{String}
end

"""
The validated registry. `problems` lists file-level issues (syntax, schema,
geodata root). Only `:available` layers are opened for extraction; call
`close(registry)` to release their datasets.
"""
struct GeoRegistry
    config_path::String
    geodata_root::Union{Nothing,String}
    layers::Vector{RegistryLayer}
    mappings::Vector{BoldFieldMapping}
    problems::Vector{String}
    catalog::GeoCatalog
end

Base.close(registry::GeoRegistry) = close(registry.catalog)

function Base.show(io::IO, registry::GeoRegistry)
    counts = Dict(s => count(l -> l.status === s, registry.layers) for s in (:available, :disabled, :unavailable, :invalid))
    print(io, "GeoRegistry(", length(registry.layers), " layers: ", counts[:available], " available, ",
          counts[:disabled], " disabled, ", counts[:unavailable], " unavailable, ", counts[:invalid], " invalid; ",
          count(m -> m.status === :active, registry.mappings), " active BOLD mappings")
    isempty(registry.problems) || print(io, "; ", length(registry.problems), " configuration problems")
    print(io, ")")
end

"""Return the ids of available layers in configuration order."""
available_layers(registry::GeoRegistry) = [l.id for l in registry.layers if l.status === :available]

# ---------------------------------------------------------------------------
# Paths

_canonical(path) = Sys.iswindows() ? lowercase(path) : path

function _inside(root::AbstractString, path::AbstractString)
    r, p = splitpath(_canonical(normpath(root))), splitpath(_canonical(normpath(path)))
    return length(p) >= length(r) && p[1:length(r)] == r
end

"""Resolve a configured relative path inside the real geodata root, or return a problem."""
function _confine(root::AbstractString, path::AbstractString)
    isempty(path) && return nothing, "path is empty"
    occursin('\0', path) && return nothing, "path contains a NUL character"
    (isabspath(path) || startswith(path, "/") || startswith(path, "\\") || occursin(r"^[A-Za-z]:", path)) &&
        return nothing, "path must be relative to the geodata root: $path"
    any(==(".."), splitpath(replace(path, '\\' => '/'))) &&
        return nothing, "path must not contain '..': $path"
    candidate = normpath(joinpath(root, path))
    _inside(root, candidate) || return nothing, "path escapes the geodata root: $path"
    if ispath(candidate)
        # Symbolic links and junctions must also stay inside the root.
        real = realpath(candidate)
        _inside(root, real) || return nothing, "path resolves outside the geodata root: $path"
        return real, nothing
    end
    return candidate, nothing
end

# ---------------------------------------------------------------------------
# Schema helpers

_typename(::Type{String}) = "a string"
_typename(::Type{Bool}) = "true or false"
_typename(::Type{Int64}) = "an integer"
_typename(::Type{Union{Int64,Float64}}) = "a number"
_typename(::Type{<:AbstractDict}) = "a table"
_typename(::Type{<:AbstractVector}) = "an array"
_typename(T) = string(T)

function _take(problems, entry, key, ::Type{T}; required=false, default=nothing) where {T}
    if !haskey(entry, key)
        required && push!(problems, "missing required key '$key'")
        return default
    end
    value = entry[key]
    if !(value isa T) || (value isa Bool && !(Bool <: T))
        push!(problems, "'$key' must be $(_typename(T))")
        return default
    end
    value isa AbstractString && isempty(strip(value)) && required &&
        (push!(problems, "'$key' must not be empty"); return default)
    return value
end

const Number64 = Union{Int64,Float64}

function _unknown_keys(problems, entry, allowed, what)
    unknown = sort!(collect(setdiff(keys(entry), allowed)))
    isempty(unknown) || push!(problems, "unknown $what keys: $(join(unknown, ", "))")
    return nothing
end

function _value_map(problems, table, integer_keys::Bool)
    table === nothing && return nothing
    mapping = Dict{Any,Any}()
    for (key, value) in table
        value isa Union{String,Number64} && !(value isa Bool) ||
            (push!(problems, "value_map values must be strings or numbers"); continue)
        if integer_keys
            code = tryparse(Int64, key)
            code === nothing && (push!(problems, "value_map key '$key' is not an integer code"); continue)
            mapping[code] = value
        else
            mapping[key] = value
        end
    end
    isempty(mapping) && push!(problems, "value_map is empty")
    return mapping
end

function _categories(problems, table)
    table === nothing && return nothing
    table == "dataset" && return :dataset
    table isa AbstractDict || (push!(problems, "'categories' must be \"dataset\" or a table"); return nothing)
    labels = Dict{Int64,String}()
    for (key, value) in table
        code = tryparse(Int64, key)
        (code !== nothing && value isa String) ||
            (push!(problems, "categories must map integer codes to strings"); continue)
        labels[code] = value
    end
    return labels
end

function _conversion(problems, table, unit)
    table === nothing && return 1.0, 0.0
    table isa AbstractDict || (push!(problems, "'conversion' must be a table"); return 1.0, 0.0)
    _unknown_keys(problems, table, Set(["from", "factor", "offset"]), "conversion")
    if haskey(table, "from")
        (haskey(table, "factor") || haskey(table, "offset")) &&
            push!(problems, "conversion uses either 'from' or 'factor'/'offset', not both")
        from = table["from"]
        from isa String && haskey(LENGTH_UNITS, from) ||
            (push!(problems, "conversion 'from' must be one of $(join(sort!(collect(keys(LENGTH_UNITS))), ", "))"); return 1.0, 0.0)
        unit !== nothing && haskey(LENGTH_UNITS, unit) ||
            (push!(problems, "conversion 'from' requires a length 'unit' to convert to"); return 1.0, 0.0)
        return LENGTH_UNITS[from] / LENGTH_UNITS[unit], 0.0
    end
    factor = _take(problems, table, "factor", Number64; required=true, default=1.0)
    offset = _take(problems, table, "offset", Number64; default=0.0)
    (isfinite(factor) && factor != 0 && isfinite(offset)) ||
        push!(problems, "conversion factor must be finite and nonzero, offset finite")
    unit === nothing && push!(problems, "a conversion requires 'unit' (the unit after conversion)")
    return Float64(factor), Float64(offset)
end

_symbol_or(value, default) = value === nothing ? default : Symbol(value)

"""Build the engine configuration; collect problems instead of throwing."""
function _engine(problems, entry, type, id, resolved)
    try
        common = (; assume_crs=_take(problems, entry, "assume_crs", String))
        if type === :vector
            attribute = _take(problems, entry, "attribute", String; required=true)
            overlap = _take(problems, entry, "overlap", String; required=true)
            (attribute === nothing || overlap === nothing) && return nothing
            return VectorLayer(id, resolved; attributes=[attribute => "value"], overlap,
                               layer=_take(problems, entry, "layer", String),
                               overlap_attribute=_take(problems, entry, "overlap_attribute", String),
                               boundary=_take(problems, entry, "boundary", String; default="exclude"),
                               boundary_tolerance=_take(problems, entry, "boundary_tolerance", Number64; default=0.0),
                               common...)
        else
            kind = _take(problems, entry, "kind", String; required=true)
            kind === nothing && return nothing
            nodata = get(entry, "nodata", "dataset")
            nodata isa Union{String,Number64} && !(nodata isa Bool) ||
                (push!(problems, "'nodata' must be \"dataset\", \"none\" or a number"); return nothing)
            categories = _categories(problems, get(entry, "categories", nothing))
            return RasterLayer(id, resolved; kind, band=_take(problems, entry, "band", Int64; default=1),
                               nodata=nodata isa String ? Symbol(nodata) : nodata, categories,
                               apply_scale=_take(problems, entry, "apply_scale", Bool; default=true), common...)
        end
    catch err
        err isa ArgumentError || rethrow()
        push!(problems, err.msg)
        return nothing
    end
end

function _parse_layer(entry, root)
    problems = String[]
    entry isa AbstractDict || return nothing
    id = _take(problems, entry, "id", String; required=true, default="")
    isempty(id) || occursin(IDENTIFIER, id) ||
        push!(problems, "id '$id' must be lowercase letters, digits or '_', starting with a letter")
    type = _symbol_or(_take(problems, entry, "type", String; required=true), :unknown)
    type in (:vector, :raster, :unknown) || (push!(problems, "type must be \"vector\" or \"raster\""); type = :unknown)
    allowed = union(COMMON_KEYS, type === :vector ? VECTOR_KEYS : type === :raster ? RASTER_KEYS : Set{String}())
    type === :unknown || _unknown_keys(problems, entry, allowed, "$type layer")
    output = _take(problems, entry, "output", String; required=true, default="")
    isempty(output) || occursin(OUTPUT_NAME, output) ||
        push!(problems, "output '$output' must start with a letter and contain letters, digits or '_'")
    output in RESERVED_OUTPUTS &&
        push!(problems, "output '$output' is reserved for the extraction table; choose another name")
    path = _take(problems, entry, "path", String; required=true, default="")
    enabled = _take(problems, entry, "enabled", Bool; default=true)
    unit = _take(problems, entry, "unit", String)
    kind = :unknown
    factor, offset, vmin, vmax, value_map = 1.0, 0.0, -Inf, Inf, nothing
    measure, digits = nothing, nothing
    if type === :vector
        kind = :polygon
        value_map = _value_map(problems, _take(problems, entry, "value_map", AbstractDict), false)
    elseif type === :raster
        kind = _symbol_or(get(entry, "kind", nothing), :unknown)
        if kind === :continuous
            haskey(entry, "value_map") && push!(problems, "value_map is only for categorical rasters and vectors")
            factor, offset = _conversion(problems, get(entry, "conversion", nothing), unit)
            vmin = Float64(_take(problems, entry, "valid_min", Number64; default=-Inf))
            vmax = Float64(_take(problems, entry, "valid_max", Number64; default=Inf))
            vmin <= vmax || push!(problems, "valid_min must not exceed valid_max")
            measure = _take(problems, entry, "measure", String)
            measure === nothing || measure in MEASURES ||
                push!(problems, "measure must be one of $(join(MEASURES, ", "))")
            digits = _take(problems, entry, "digits", Int64)
            digits === nothing || 0 <= digits <= 15 || push!(problems, "digits must be between 0 and 15")
        elseif kind === :categorical
            for key in ("unit", "conversion", "valid_min", "valid_max", "measure", "digits")
                haskey(entry, key) && push!(problems, "'$key' is only for continuous rasters")
            end
            value_map = _value_map(problems, _take(problems, entry, "value_map", AbstractDict), true)
        end
    end
    resolved = nothing
    root === nothing && push!(problems, "no usable geodata root")
    if root !== nothing && !isempty(path)
        resolved, problem = _confine(root, path)
        problem === nothing || push!(problems, problem)
    end
    engine = isempty(problems) && type !== :unknown ? _engine(problems, entry, type, id, resolved) : nothing
    layer = RegistryLayer(id, _take(problems, entry, "name", String; required=true, default=""), type, kind, path,
                          resolved, output, _take(problems, entry, "version", String; required=true, default=""),
                          _take(problems, entry, "source", String; required=true, default=""),
                          _take(problems, entry, "description", String; default=""), enabled, unit, factor,
                          offset, vmin, vmax, measure, digits === nothing ? nothing : Int(digits), value_map,
                          engine, :invalid, problems, nothing)
    isempty(problems) || (layer.engine = nothing)
    return layer
end

# ---------------------------------------------------------------------------
# Dataset validation

function _validate_dataset!(layer::RegistryLayer, root::AbstractString)
    layer.status === :invalid && return layer
    if !layer.enabled
        layer.status = :disabled
        return layer
    end
    if !isfile(layer.resolved)
        layer.status = :unavailable
        push!(layer.problems, "dataset file not found: $(layer.path)")
        return layer
    end
    catalog = GeoCatalog(GeoLayer[layer.engine::GeoLayer])
    try
        info = layer_info(catalog, layer.id)
        outside = filter(f -> !_inside(root, ispath(f) ? realpath(f) : f), info.files)
        if !isempty(outside)
            push!(layer.problems, "dataset uses files outside the geodata root: $(join(outside, ", "))")
            layer.status = :invalid
        else
            layer.metadata = info
            layer.status = :available
        end
    catch err
        err isa GeoDatasetError || err isa ArgumentError || rethrow()
        push!(layer.problems, sprint(showerror, err))
        layer.status = :invalid
    finally
        close(catalog)
    end
    return layer
end

function _parse_mapping(entry, layers::Dict{String,RegistryLayer})
    problems = String[]
    entry isa AbstractDict || return BoldFieldMapping("", String[], :invalid, ["mapping must be a table"])
    _unknown_keys(problems, entry, MAPPING_KEYS, "bold_fields")
    column = _take(problems, entry, "column", String; required=true, default="")
    ids = _take(problems, entry, "layers", AbstractVector; required=true, default=String[])
    all(x -> x isa String, ids) || (push!(problems, "'layers' must be an array of layer ids"); ids = String[])
    isempty(ids) && haskey(entry, "layers") && push!(problems, "'layers' must not be empty")
    length(unique(ids)) == length(ids) || push!(problems, "'layers' lists a layer twice")
    if haskey(BOLD_PROTECTED_COLUMNS, column)
        push!(problems, "$column is not filled from layers: $(BOLD_PROTECTED_COLUMNS[column])")
    elseif !isempty(column) && !(column in BOLD_TARGET_COLUMNS)
        push!(problems, "unknown BOLD column '$column'; allowed: $(join(BOLD_TARGET_COLUMNS, ", "))")
    end
    numeric = column in BOLD_NUMERIC_COLUMNS
    for id in ids
        layer = get(layers, id, nothing)
        layer === nothing && (push!(problems, "unknown layer '$id'"); continue)
        if numeric
            layer.kind === :continuous && layer.unit == "m" ||
                push!(problems, "$column needs a continuous raster with unit = \"m\"; layer '$id' is $(layer.kind)" *
                                (layer.kind === :continuous ? " in $(something(layer.unit, "unspecified units"))" : ""))
            layer.measure == get(BOLD_MEASURES, column, nothing) || push!(problems,
                "$column needs measure = \"$(BOLD_MEASURES[column])\"; layer '$id' declares $(repr(layer.measure))")
        elseif layer.kind === :continuous
            push!(problems, "$column is text; continuous raster '$id' cannot fill it")
        elseif column in BOLD_POLYGON_COLUMNS && layer.type !== :vector
            push!(problems, "$column comes only from polygon layers; '$id' is a $(layer.kind) raster")
        elseif (layer.kind === :categorical || column == "HABITAT") && layer.value_map === nothing
            # Category codes, labels or attributes are never BOLD habitat terms by themselves.
            push!(problems, "layer '$id' needs an explicit value_map to fill $column")
        end
    end
    isempty(problems) || return BoldFieldMapping(column, ids, :invalid, problems)
    unusable = [id for id in ids if layers[id].status !== :available]
    notes = ["layer '$id' is $(layers[id].status)" for id in unusable]
    return BoldFieldMapping(column, ids, length(unusable) == length(ids) ? :inactive : :active, notes)
end

"""
    load_registry(config_path; geodata_root=nothing, log=true) -> GeoRegistry

Read and validate a layer registry (see `config/layers.toml`). Never throws for
configuration or dataset problems: invalid or unavailable layers and mappings
are reported in the result (and logged with `@warn` when `log=true`) while
valid layers remain usable.

Dataset paths must be relative and stay inside the geodata root after resolving
`..`, symbolic links and every file GDAL opens. The root is `geodata_root`, given
by the application, or the file's `geodata_root` (relative to the TOML file);
when both are given the file's root must lie inside the application's.
"""
function load_registry(config_path::AbstractString; geodata_root::Union{Nothing,AbstractString}=nothing,
                       log::Bool=true)
    problems = String[]
    config = try
        isfile(config_path) || throw(SystemError("configuration file not found", 2))
        TOML.parsefile(config_path)
    catch err
        err isa TOML.ParserError || err isa SystemError || err isa Base.IOError || rethrow()
        push!(problems, "cannot read $config_path: $(sprint(showerror, err))")
        Dict{String,Any}()
    end
    isempty(problems) && _unknown_keys(problems, config, TOP_KEYS, "top-level")
    if isempty(config) || get(config, "schema_version", nothing) != SCHEMA_VERSION
        isempty(config) || push!(problems, "schema_version must be $SCHEMA_VERSION")
    end
    root = _root(problems, config, config_path, geodata_root)
    entries = get(config, "layers", Any[])
    entries isa AbstractVector || (push!(problems, "'layers' must be an array of tables"); entries = Any[])
    layers = RegistryLayer[]
    seen_ids, seen_outputs = Set{String}(), Set{String}()
    for (i, entry) in enumerate(entries)
        layer = _parse_layer(entry, root)
        layer === nothing && (push!(problems, "layers[$i] is not a table"); continue)
        if layer.id in seen_ids
            push!(layer.problems, "duplicate layer id '$(layer.id)'")
        end
        if layer.output in seen_outputs
            push!(layer.problems, "duplicate output '$(layer.output)'")
        end
        isempty(layer.id) || push!(seen_ids, layer.id)
        isempty(layer.output) || push!(seen_outputs, layer.output)
        layer.status = isempty(layer.problems) ? :pending : :invalid
        layer.status === :invalid || root === nothing || _validate_dataset!(layer, root)
        push!(layers, layer)
    end
    by_id = Dict(l.id => l for l in layers if !isempty(l.id) && count(m -> m.id == l.id, layers) == 1)
    mapping_entries = get(config, "bold_fields", Any[])
    mapping_entries isa AbstractVector || (push!(problems, "'bold_fields' must be an array of tables"); mapping_entries = Any[])
    mappings = BoldFieldMapping[]
    for entry in mapping_entries
        mapping = _parse_mapping(entry, by_id)
        if any(m -> m.column == mapping.column, mappings)
            mapping = BoldFieldMapping(mapping.column, mapping.layers, :invalid,
                                       vcat(mapping.problems, "duplicate mapping for $(mapping.column)"))
        end
        push!(mappings, mapping)
    end
    registry = GeoRegistry(abspath(config_path), root, layers, mappings, problems,
                           GeoCatalog(GeoLayer[l.engine for l in layers if l.status === :available]))
    log && _log(registry)
    return registry
end

function _root(problems, config, config_path, approved)
    configured = get(config, "geodata_root", nothing)
    configured === nothing || configured isa String ||
        (push!(problems, "'geodata_root' must be a string"); return nothing)
    base = approved === nothing ? nothing : _real_directory(problems, approved, "approved geodata root")
    approved !== nothing && base === nothing && return nothing
    if configured === nothing
        base === nothing && push!(problems, "no geodata root: pass geodata_root or set it in the file")
        return base
    end
    path = isabspath(configured) ? configured : joinpath(dirname(abspath(config_path)), configured)
    root = _real_directory(problems, path, "geodata_root")
    root === nothing && return nothing
    if base !== nothing && !_inside(base, root)
        push!(problems, "geodata_root $root is outside the approved directory $base")
        return nothing
    end
    return root
end

function _real_directory(problems, path, what)
    isdir(path) || (push!(problems, "$what is not a directory: $path"); return nothing)
    return realpath(path)
end

function _log(registry::GeoRegistry)
    for p in registry.problems
        @warn "Geospatial registry: $p"
    end
    for l in registry.layers, p in l.problems
        @warn "Geospatial layer '$(l.id)' is $(l.status): $p"
    end
    for m in registry.mappings
        m.status === :active && continue
        @warn "BOLD mapping for $(m.column) is $(m.status): $(join(m.problems, "; "))"
    end
    return nothing
end

# ---------------------------------------------------------------------------
# Reporting

function _meta(layer, key)
    metadata = layer.metadata
    return metadata === nothing ? missing : get(metadata, key, missing)
end
_text(x) = ismissing(x) || x === nothing ? missing : string(x)
_text(x::Unsigned) = string(BigInt(x))     # 255, not 0xff

"""
    registry_report(registry) -> DataFrame

One row per configured layer: identity, provenance, status and problems, plus
dataset metadata for available layers (driver, CRS, extent or raster size,
feature count, spatial index, pixel type, NoData) and the BOLD columns it feeds.
"""
function registry_report(registry::GeoRegistry)
    feeds(id) = join([m.column for m in registry.mappings if id in m.layers && m.status !== :invalid], ", ")
    ls = registry.layers
    return DataFrame(
        id=[l.id for l in ls], name=[l.name for l in ls], type=[string(l.type) for l in ls],
        kind=[string(l.kind) for l in ls], status=[string(l.status) for l in ls], enabled=[l.enabled for l in ls],
        path=[l.path for l in ls], version=[l.version for l in ls], source=[l.source for l in ls],
        output=[l.output for l in ls], unit=Union{Missing,String}[something(l.unit, missing) for l in ls],
        bold_columns=[feeds(l.id) for l in ls],
        driver=Union{Missing,String}[_text(_meta(l, :driver)) for l in ls],
        crs=Union{Missing,String}[_text(_meta(l, :crs)) for l in ls],
        extent=Union{Missing,String}[_text(_meta(l, :extent)) for l in ls],
        features=Union{Missing,Int}[_meta(l, :features) for l in ls],
        spatial_index=Union{Missing,Bool}[_meta(l, :spatial_index) for l in ls],
        width=Union{Missing,Int}[_meta(l, :width) for l in ls],
        height=Union{Missing,Int}[_meta(l, :height) for l in ls],
        band=Union{Missing,Int}[_meta(l, :band) for l in ls],
        pixel_type=Union{Missing,String}[_text(_meta(l, :pixel_type)) for l in ls],
        nodata=Union{Missing,String}[_text(_meta(l, :nodata)) for l in ls],
        problems=[join(l.problems, "; ") for l in ls],
    )
end

"""Return one row per BOLD mapping: column, ordered layers, status and problems."""
mapping_report(registry::GeoRegistry) = DataFrame(
    column=[m.column for m in registry.mappings], layers=[join(m.layers, ", ") for m in registry.mappings],
    status=[string(m.status) for m in registry.mappings], problems=[join(m.problems, "; ") for m in registry.mappings])

function _layer(registry::GeoRegistry, id)
    i = findfirst(l -> l.id == id, registry.layers)
    i === nothing && throw(ArgumentError("Unknown layer '$id'"))
    return registry.layers[i]
end

"""Return configuration, status, provenance and dataset metadata of one layer."""
function layer_metadata(registry::GeoRegistry, id::AbstractString)
    l = _layer(registry, id)
    return (; l.id, l.name, l.type, l.kind, l.status, l.enabled, l.path, l.version, l.source, l.description,
            l.output, l.unit, l.factor, l.offset, l.valid_min, l.valid_max, l.measure, l.digits,
            has_value_map=l.value_map !== nothing,
            problems=copy(l.problems), dataset=l.metadata)
end

# ---------------------------------------------------------------------------
# Extraction

const VALUE_STATUSES = ("inside", "boundary", "ok")

function _layer_values(registry::GeoRegistry, layer::RegistryLayer, points::GeoPoints)
    frame = layer.type === :vector ? extract_vector(points, registry.catalog, layer.id) :
            extract_raster(points, registry.catalog, layer.id)
    n = length(points)
    raw = frame.value
    status = copy(frame.status)
    value = Vector{Any}(missing, n)
    value_map = layer.value_map
    for i in 1:n
        (status[i] in VALUE_STATUSES && !ismissing(raw[i])) || continue
        v = raw[i]
        # Blank text is no information; it must not become a "populated" cell.
        v isa AbstractString && isempty(strip(v)) && continue
        if value_map !== nothing
            key = layer.type === :vector ? string(v) : v
            mapped = get(value_map, key, missing)
            ismissing(mapped) && (status[i] = "unmapped"; continue)
            value[i] = mapped
        elseif layer.kind === :continuous
            converted = v * layer.factor + layer.offset
            layer.valid_min <= converted <= layer.valid_max || (status[i] = "out_of_range"; continue)
            value[i] = layer.digits === nothing ? converted : round(converted; digits=layer.digits)
        else
            value[i] = v
        end
    end
    narrowed = isempty(value) ? value : map(identity, value)
    return narrowed, status, raw
end

"""
    extract_layers(points, registry; layers=available_layers(registry)) -> DataFrame

Extract registry layers by id. One row per point: `point`, `coordinate_status`,
then for each layer `<output>` (after value mapping or unit conversion),
`<output>.status` and, when a mapping or conversion applies, `<output>.raw`.
Statuses are the extraction statuses plus `unmapped` (no value_map entry) and
`out_of_range` (outside `valid_min`/`valid_max` after conversion).
"""
function extract_layers(points, registry::GeoRegistry; layers::AbstractVector{<:AbstractString}=available_layers(registry))
    pts = geopoints(points)
    result = DataFrame(point=collect(1:length(pts)), coordinate_status=String.(pts.status))
    for id in layers
        layer = _layer(registry, id)
        layer.status === :available || throw(ArgumentError("Layer '$id' is $(layer.status)"))
        layer.output in RESERVED_OUTPUTS && throw(ArgumentError("Layer '$id' uses the reserved output '$(layer.output)'"))
        value, status, raw = _layer_values(registry, layer, pts)
        result[!, layer.output] = value
        result[!, "$(layer.output).status"] = status
        if layer.value_map !== nothing || layer.factor != 1 || layer.offset != 0
            result[!, "$(layer.output).raw"] = raw
        end
    end
    return result
end

"""
    propose_bold_fields(points, registry) -> DataFrame

Proposed values for each active BOLD mapping: for every point, the first listed
available layer with a value supplies the column. Returns `point`,
`coordinate_status` and, per BOLD column, the value, `<column>.source` (layer
id) and `<column>.status` (`proposed` or `no_value`). Values are proposals for
a sidecar; workbooks are never modified, and protected columns such as
coordinate or elevation accuracy are never produced.
"""
function propose_bold_fields(points, registry::GeoRegistry)
    pts = geopoints(points)
    active = [m for m in registry.mappings if m.status === :active]
    needed = unique(id for m in active for id in m.layers if _layer(registry, id).status === :available)
    extracted = extract_layers(pts, registry; layers=needed)
    result = DataFrame(point=collect(1:length(pts)), coordinate_status=String.(pts.status))
    n = length(pts)
    for m in active
        value = Vector{Any}(missing, n)
        source = Vector{Union{Missing,String}}(missing, n)
        for id in m.layers
            id in needed || continue
            column = extracted[!, _layer(registry, id).output]
            for i in 1:n
                ismissing(value[i]) && !ismissing(column[i]) || continue
                value[i] = column[i]
                source[i] = id
            end
        end
        result[!, m.column] = isempty(value) ? value : map(identity, value)
        result[!, "$(m.column).source"] = source
        result[!, "$(m.column).status"] = [ismissing(s) ? "no_value" : "proposed" for s in source]
    end
    return result
end

end
