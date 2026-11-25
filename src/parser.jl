"""The exact BOLD geographic headers; their positions are discovered in each file."""
const GEOGRAPHIC_HEADERS = (
    "COUNTRY/OCEAN", "PROVINCE/STATE", "REGION", "SECTOR", "SITE",
    "COORD:LAT", "COORD:LON", "ELEV", "DEPTH", "ELEV_ACCURACY",
    "DEPTH_ACCURACY", "COORD_SOURCE", "COORD_ACCURACY", "HABITAT",
)

"""An invalid or ambiguous BOLD worksheet schema."""
struct TemplateError <: Exception
    message::String
end
Base.showerror(io::IO, err::TemplateError) = print(io, err.message)

"""
A read-only parse result with all 50 original columns in `records`, the original
Excel row numbers in `excel_rows`, and separate coordinate validation results.
`source_sha256` binds subsequent exports to the workbook that was parsed.
The DataFrame contains XLSX-decoded values (Excel errors kept as text), not
Excel display strings or formula expressions.
The workbook itself remains the authority for formatting and formulas.
"""
struct BOLDSubmission
    source_path::String
    source_sha256::String
    sheet_names::Vector{String}
    header_row::Int
    headers::Vector{String}
    column_numbers::Vector{Int}
    excel_rows::Vector{Int}
    records::DataFrame
    coordinates::Vector{CoordinatePair}
end

_file_sha256(path) = open(io -> bytes2hex(sha256(io)), path, "r")
_blank(value) = ismissing(value) || value === nothing || (value isa AbstractString && isempty(strip(value)))

# XLSX 0.13 exposes cells through getcell/getdata, but not occupied column indices.
# Keep this single access to SheetRow internals bounded by the tested compat range.
_occupied_columns(row) = sort!(collect(keys(row.rowcells)))
_has_formula(cell) = cell isa XLSX.Cell && cell.formula
function _read_value(row, column)
    cell = XLSX.getcell(row, column)
    # XLSX's default getdata maps Excel errors to missing; keep their visible token.
    return XLSX.iserror(cell) ? XLSX.geterror(cell) : row[column]
end

function _header_schema(row)
    occupied = _occupied_columns(row)
    valued = filter(col -> !_blank(_read_value(row, col)), occupied)
    isempty(valued) && throw(TemplateError("Header row is empty."))
    columns = collect(first(valued):last(valued))
    values = Any[_read_value(row, col) for col in columns]
    length(columns) == 50 || throw(TemplateError("Submissions must have exactly 50 columns; found $(length(columns))."))
    all(x -> x isa AbstractString && !_blank(x), values) ||
        throw(TemplateError("All 50 headers must be nonempty text, with no gaps."))
    headers = String.(values)
    length(unique(headers)) == 50 || throw(TemplateError("Duplicate column headers are not allowed."))
    absent = filter(h -> !(h in headers), GEOGRAPHIC_HEADERS)
    isempty(absent) || throw(TemplateError("Missing exact geographic headers: $(join(absent, ", "))."))
    any(col -> _has_formula(XLSX.getcell(row, col)) || XLSX.iserror(XLSX.getcell(row, col)), columns) &&
        throw(TemplateError("Column headers must be literal text, not formulas or Excel errors."))
    return headers, columns
end

function _coordinate_cell(row, column, axis)
    cell = XLSX.getcell(row, column)
    # Cached formula results can be stale; they are never used for enrichment.
    _has_formula(cell) && return CoordinateValue(missing, :formula)
    XLSX.iserror(cell) && return CoordinateValue(missing, :invalid_format)
    return validate_coordinate(row[column], axis)
end

"""
    read_bold(path; header_row=nothing, max_header_rows=100) -> BOLDSubmission

Read the case-sensitive `Submissions` worksheet in mode `r`, in one row pass.
Automatically find a header containing all 14 exact geographic names within the
first `max_header_rows` Excel rows, or require an explicit `header_row`.
Require 50 unique, contiguous, nonempty text headers; other header names are
retained verbatim. No specimen identifier name is assumed. Fully blank rows are
skipped, including formatted empty rows; interior gaps do not end the table.
Records retain their order and original Excel row numbers. Populated cells outside
the header span are rejected instead of silently discarding metadata.
Formula coordinates are flagged `:formula`, even with a numeric cached value.
"""
function read_bold(path::AbstractString; header_row::Union{Nothing,Integer}=nothing,
                   max_header_rows::Integer=100)
    max_header_rows > 0 || throw(ArgumentError("max_header_rows must be positive"))
    (header_row === nothing || header_row > 0) || throw(ArgumentError("header_row must be positive"))
    isfile(path) || throw(ArgumentError("Workbook file does not exist: $path"))
    source = realpath(path)
    lowercase(splitext(source)[2]) == ".xlsx" || throw(ArgumentError("Expected an .xlsx workbook"))
    digest = _file_sha256(source)
    result = XLSX.openxlsx(source; mode="r", enable_cache=false) do book
        sheets = XLSX.sheetnames(book)
        "Submissions" in sheets || throw(TemplateError("Required worksheet 'Submissions' was not found."))
        headers = String[]
        columns = Int[]
        buffers = Vector{Any}[]
        rows = Int[]
        coordinates = CoordinatePair[]
        found_row = 0
        lat_column = lon_column = 0
        best_headers = String[]
        best_score = 0
        for row in XLSX.eachrow(book["Submissions"]::XLSX.Worksheet)
            number = XLSX.row_number(row)
            if found_row == 0
                if header_row === nothing
                    number > max_header_rows && break
                    values = Any[_read_value(row, col) for col in _occupied_columns(row)]
                    score = count(h -> any(v -> isequal(h, v), values), GEOGRAPHIC_HEADERS)
                    if score > best_score
                        best_score = score
                        best_headers = String[v for v in values if v isa AbstractString]
                    end
                    score == length(GEOGRAPHIC_HEADERS) || continue
                else
                    number < header_row && continue
                    number == header_row || break
                end
                headers, columns = _header_schema(row)
                buffers = [Any[] for _ in headers]
                found_row = number
                index = Dict(h => col for (h, col) in zip(headers, columns))
                lat_column = index["COORD:LAT"]
                lon_column = index["COORD:LON"]
                continue
            end
            for col in _occupied_columns(row)
                if !(first(columns) <= col <= last(columns)) &&
                   (!_blank(_read_value(row, col)) || _has_formula(XLSX.getcell(row, col)))
                    throw(TemplateError("Unlabelled value outside the 50 columns at Excel row $number, column $col."))
                end
            end
            values = Any[_read_value(row, col) for col in columns]
            # A formula without a cache is still a populated record.
            all(_blank, values) && !any(col -> _has_formula(XLSX.getcell(row, col)), columns) && continue
            for (buffer, value) in zip(buffers, values)
                push!(buffer, value)
            end
            push!(rows, number)
            push!(coordinates, CoordinatePair(
                _coordinate_cell(row, lat_column, :latitude),
                _coordinate_cell(row, lon_column, :longitude)))
        end
        if found_row == 0
            absent = filter(h -> !(h in best_headers), GEOGRAPHIC_HEADERS)
            detail = header_row === nothing ? "within the first $max_header_rows rows; missing exact headers: $(join(absent, ", "))" : "at Excel row $header_row"
            throw(TemplateError("BOLD header not found $detail."))
        end
        records = DataFrame(buffers, headers; copycols=false)
        return BOLDSubmission(source, digest, sheets, found_row, headers, columns, rows, records, coordinates)
    end
    _file_sha256(source) == digest || throw(ArgumentError("Source workbook changed while it was being parsed; retry with an immutable upload."))
    return result
end
