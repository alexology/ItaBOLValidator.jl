# Per-record BOLD / ItaBOL compliance from a declarative rule file
# (config/compliance.toml). The web page evaluates the same rules in JavaScript
# for real-time feedback; this implementation is the reference used for saved
# workbooks and reports.

const COMPLIANCE_KINDS = ("required", "any_of", "unique", "vocabulary", "date", "number", "coordinates", "pattern")
const ISO_DATE = r"^(\d{4})-(\d{2})-(\d{2})$"
const DECIMAL_NUMBER = r"^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$"

"""One rule of a compliance profile (see `config/compliance.toml`)."""
struct ComplianceRule
    kind::String
    columns::Vector{String}
    values::Union{Nothing,Set{String}}        # vocabulary, lower-case
    regex::Union{Nothing,Regex}
    required::Bool                            # coordinates
    severity::Symbol                          # :error or :warning
    note::String
end

"""A named set of rules with its version; `defined=false` marks nothing compliant."""
struct ComplianceProfile
    id::String
    title::String
    version::String
    defined::Bool
    sources::Vector{String}
    rules::Vector{ComplianceRule}
    raw::Vector{Dict{String,Any}}             # rules as written, with lists resolved (for the page)
end

"""The BOLD and ItaBOL profiles loaded by [`load_compliance`](@ref)."""
struct ComplianceRules
    path::String
    bold::ComplianceProfile
    itabol::ComplianceProfile
end

function _profile(id, d, lists)
    d isa AbstractDict || throw(ArgumentError("[$id] must be a table"))
    defined = get(d, "defined", false)
    defined isa Bool || throw(ArgumentError("$id.defined must be true or false"))
    version = string(get(d, "version", ""))
    defined && isempty(strip(version)) && throw(ArgumentError("$id.version is required when $id.defined = true"))
    rules = ComplianceRule[]
    raw = Dict{String,Any}[]
    entries = get(d, "rules", Any[])
    entries isa AbstractVector || throw(ArgumentError("$id.rules must be an array of tables"))
    for (k, r) in enumerate(entries)
        r isa AbstractDict || throw(ArgumentError("$id.rules[$k] must be a table"))
        kind = string(get(r, "kind", ""))
        kind in COMPLIANCE_KINDS || throw(ArgumentError("$id.rules[$k]: unknown kind $(repr(kind)); allowed: $(join(COMPLIANCE_KINDS, ", "))"))
        severity = Symbol(get(r, "severity", "error"))
        severity in (:error, :warning) || throw(ArgumentError("$id.rules[$k]: severity must be error or warning"))
        columns = if kind == "coordinates"
            lat, lon = get(r, "latitude", nothing), get(r, "longitude", nothing)
            lat isa AbstractString && lon isa AbstractString ||
                throw(ArgumentError("$id.rules[$k]: coordinates needs latitude and longitude columns"))
            String[lat, lon]
        else
            c = get(r, "columns", nothing)
            c isa AbstractVector && !isempty(c) && all(x -> x isa AbstractString, c) ||
                throw(ArgumentError("$id.rules[$k]: columns must be a non-empty list of column names"))
            String.(c)
        end
        kind == "unique" && length(columns) != 1 && throw(ArgumentError("$id.rules[$k]: unique takes one column"))
        values = nothing
        if kind == "vocabulary"
            list = get(r, "values", nothing)
            if list === nothing
                name = get(r, "list", nothing)
                name isa AbstractString && haskey(lists, name) ||
                    throw(ArgumentError("$id.rules[$k]: vocabulary needs values or a list defined in [lists]"))
                list = lists[name]
            end
            list isa AbstractVector && all(x -> x isa AbstractString, list) ||
                throw(ArgumentError("$id.rules[$k]: vocabulary values must be strings"))
            values = Set(lowercase(strip(v)) for v in list)
        end
        regex = nothing
        if kind == "pattern"
            p = get(r, "regex", nothing)
            p isa AbstractString || throw(ArgumentError("$id.rules[$k]: pattern needs regex"))
            regex = try
                Regex(p)
            catch err
                throw(ArgumentError("$id.rules[$k]: invalid regex: $(sprint(showerror, err))"))
            end
        end
        required = get(r, "required", false)
        required isa Bool || throw(ArgumentError("$id.rules[$k]: required must be true or false"))
        rule = ComplianceRule(kind, columns, values, regex, required, severity, string(get(r, "note", "")))
        push!(rules, rule)
        push!(raw, Dict{String,Any}("kind" => kind, "columns" => columns, "severity" => string(severity),
                                    "required" => required, "note" => rule.note,
                                    "values" => values === nothing ? nothing : sort!(collect(values)),
                                    "regex" => regex === nothing ? nothing : string(get(r, "regex", ""))))
    end
    defined && isempty(rules) && id == "itabol" && throw(ArgumentError("itabol.defined = true needs rules"))
    sources = String.(get(d, "sources", String[]))
    return ComplianceProfile(id, string(get(d, "title", id)), version, defined, sources, rules, raw)
end

"""
    load_compliance(path) -> ComplianceRules

Read the compliance rule file (format in `config/compliance.toml`). Throws
`ArgumentError` for an invalid file: compliance rules are administrator
configuration and must be correct before the server starts.
"""
function load_compliance(path::AbstractString)
    isfile(path) || throw(ArgumentError("Compliance rule file not found: $path"))
    d = try
        TOML.parsefile(path)
    catch err
        throw(ArgumentError("Invalid compliance rule file $path: $(sprint(showerror, err))"))
    end
    get(d, "schema_version", nothing) == 1 || throw(ArgumentError("$path: schema_version must be 1"))
    lists = get(d, "lists", Dict{String,Any}())
    return ComplianceRules(abspath(path), _profile("bold", get(d, "bold", nothing), lists),
                           _profile("itabol", get(d, "itabol", nothing), lists))
end

"""The rules as plain data (for the web page, which evaluates them in real time)."""
function compliance_spec(rules::ComplianceRules)
    profile(p) = Dict{String,Any}("id" => p.id, "title" => p.title, "version" => p.version, "defined" => p.defined,
                                  "sources" => p.sources, "rules" => p.raw)
    return Dict{String,Any}("bold" => profile(rules.bold), "itabol" => profile(rules.itabol))
end

_cell_blank(v) = ismissing(v) || v === nothing || (v isa AbstractString && isempty(strip(v)))
_cell_text(v) = v isa AbstractString ? strip(v) : string(v)

function _is_date(v)
    v isa Dates.Date && return true
    v isa AbstractString || return false
    m = match(ISO_DATE, strip(v))
    m === nothing && return false
    y, mo, d = parse.(Int, m.captures)
    return 1 <= mo <= 12 && 1 <= d <= Dates.daysinmonth(y, mo)
end

_is_number(v) = (v isa Real && !(v isa Bool) && isfinite(v)) ||
                (v isa AbstractString && occursin(DECIMAL_NUMBER, strip(v)) && isfinite(parse(Float64, strip(v))))

"""
    check_compliance(headers, records, rules) -> NamedTuple

Evaluate every record (a row of `records`, a `DataFrame` with `headers` as
columns) against both profiles. Returns `(; bold, itabol, problems)`: two
`Vector{Bool}` and, per record, a vector of `(profile, column, code, severity)`.
Codes: `missing`, `missing_any`, `duplicate`, `not_in_vocabulary`,
`invalid_date`, `not_a_number`, `pattern_mismatch`, `coordinates_incomplete`,
`coordinates_missing` and the coordinate statuses of [`validate_coordinate`](@ref)
prefixed by `latitude_`/`longitude_`. A record is ItaBOL compliant only when the
ItaBOL profile is defined and the record is also BOLD compliant.
"""
function check_compliance(headers::AbstractVector{<:AbstractString}, records, rules::ComplianceRules)
    n = size(records, 1)
    present = Set(headers)
    cell(i, c) = c in present ? records[i, c] : missing
    problems = [NamedTuple{(:profile, :column, :code, :severity),Tuple{String,String,String,Symbol}}[] for _ in 1:n]
    failed = Dict("bold" => falses(n), "itabol" => falses(n))
    for profile in (rules.bold, rules.itabol)
        profile.defined || continue
        add!(i, column, code, rule) = begin
            push!(problems[i], (profile=profile.id, column, code, severity=rule.severity))
            rule.severity === :error && (failed[profile.id][i] = true)
        end
        for rule in profile.rules
            k = rule.kind
            if k == "unique"
                c = only(rule.columns)
                counts = Dict{String,Int}()
                for i in 1:n
                    v = cell(i, c)
                    _cell_blank(v) || (key = lowercase(_cell_text(v)); counts[key] = get(counts, key, 0) + 1)
                end
                for i in 1:n
                    v = cell(i, c)
                    _cell_blank(v) || counts[lowercase(_cell_text(v))] > 1 && add!(i, c, "duplicate", rule)
                end
                continue
            end
            for i in 1:n
                if k == "required"
                    for c in rule.columns
                        _cell_blank(cell(i, c)) && add!(i, c, "missing", rule)
                    end
                elseif k == "any_of"
                    all(c -> _cell_blank(cell(i, c)), rule.columns) && add!(i, join(rule.columns, "|"), "missing_any", rule)
                elseif k == "vocabulary"
                    for c in rule.columns
                        v = cell(i, c)
                        _cell_blank(v) || lowercase(_cell_text(v)) in rule.values || add!(i, c, "not_in_vocabulary", rule)
                    end
                elseif k == "date"
                    for c in rule.columns
                        v = cell(i, c)
                        _cell_blank(v) || _is_date(v) || add!(i, c, "invalid_date", rule)
                    end
                elseif k == "number"
                    for c in rule.columns
                        v = cell(i, c)
                        _cell_blank(v) || _is_number(v) || add!(i, c, "not_a_number", rule)
                    end
                elseif k == "pattern"
                    for c in rule.columns
                        v = cell(i, c)
                        _cell_blank(v) || occursin(rule.regex, _cell_text(v)) || add!(i, c, "pattern_mismatch", rule)
                    end
                elseif k == "coordinates"
                    lat_c, lon_c = rule.columns
                    lat, lon = cell(i, lat_c), cell(i, lon_c)
                    if _cell_blank(lat) && _cell_blank(lon)
                        rule.required && add!(i, "$lat_c|$lon_c", "coordinates_missing", rule)
                    elseif _cell_blank(lat) || _cell_blank(lon)
                        add!(i, _cell_blank(lat) ? lat_c : lon_c, "coordinates_incomplete", rule)
                    else
                        pair = validate_coordinates(lat, lon)
                        pair.latitude.status === :valid || add!(i, lat_c, "latitude_$(pair.latitude.status)", rule)
                        pair.longitude.status === :valid || add!(i, lon_c, "longitude_$(pair.longitude.status)", rule)
                    end
                end
            end
        end
    end
    bold = .!failed["bold"]
    itabol = rules.itabol.defined ? bold .& .!failed["itabol"] : falses(n)
    rules.bold.defined || (bold .= false)
    return (; bold=Vector{Bool}(bold), itabol=Vector{Bool}(itabol), problems)
end

check_compliance(submission::BOLDSubmission, rules::ComplianceRules) =
    check_compliance(submission.headers, submission.records, rules)

"""Counts of [`check_compliance`](@ref) results, for reports."""
function compliance_summary(result, rules::ComplianceRules)
    n = length(result.bold)
    codes = Dict{String,Int}()
    for ps in result.problems, p in ps
        key = "$(p.profile):$(p.column):$(p.code)"
        codes[key] = get(codes, key, 0) + 1
    end
    return Dict{String,Any}(
        "records" => n,
        "bold_compliant" => count(result.bold),
        "itabol_compliant" => count(result.itabol),
        "not_compliant" => count(.!result.bold),
        "bold_profile" => "$(rules.bold.title) $(rules.bold.version)",
        "itabol_profile" => rules.itabol.defined ? "$(rules.itabol.title) $(rules.itabol.version)" : "not defined",
        "problems" => codes,
    )
end
