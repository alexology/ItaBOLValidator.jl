# User edits made while reviewing a workbook, written by the same targeted
# OOXML editing as the enrichment.

"""Columns whose edited values are written as numbers when they are decimal numbers."""
const REVIEW_NUMERIC_COLUMNS = ("COORD:LAT", "COORD:LON", "ELEV", "DEPTH", "ELEV_ACCURACY", "DEPTH_ACCURACY",
                                "COORD_ACCURACY")
const MAX_EDIT_TEXT = 32_767        # Excel's cell text limit

"""
    ReviewEdit(row, column, value)

A user edit: Excel `row` of a record, exact `column` header and the new value
(`nothing` clears the cell). Build it with [`review_edit`](@ref).
"""
struct ReviewEdit
    row::Int
    column::String
    value::Union{Nothing,String,Float64}
end

"""
    review_edit(row, column, raw) -> ReviewEdit

Normalise an edited value: empty or whitespace-only text clears the cell; numbers
and, in numeric columns ($(join(REVIEW_NUMERIC_COLUMNS, ", "))), decimal text with
a dot become numbers; any other text is kept exactly as typed, so that invalid
values remain visible to the compliance checks instead of being corrected.
"""
function review_edit(row::Integer, column::AbstractString, raw)
    value = if raw === nothing || ismissing(raw)
        nothing
    elseif raw isa Bool
        throw(ArgumentError("Edited values must be text or numbers"))
    elseif raw isa Real
        isfinite(raw) || throw(ArgumentError("Edited numbers must be finite"))
        Float64(raw)
    elseif raw isa AbstractString
        if isempty(strip(raw))
            nothing
        elseif column in REVIEW_NUMERIC_COLUMNS && occursin(DECIMAL_NUMBER, strip(raw)) &&
               isfinite(parse(Float64, strip(raw)))
            parse(Float64, strip(raw))
        else
            length(raw) <= MAX_EDIT_TEXT || throw(ArgumentError("Text longer than $MAX_EDIT_TEXT characters"))
            String(raw)
        end
    else
        throw(ArgumentError("Edited values must be text or numbers"))
    end
    return ReviewEdit(Int(row), String(column), value)
end

"""
    save_reviewed(submission, edits, path) -> String

Write a copy of the submission's workbook to the NEW file `path` with `edits`
applied to the `Submissions` sheet: only the edited cells change (their style is
kept), every other part keeps identical bytes. Edits must target record rows and
existing headers, at most once per cell; formula cells are refused. The result
is re-read and compared cell by cell before it is moved into place.
"""
function save_reviewed(submission::BOLDSubmission, edits::AbstractVector{ReviewEdit}, path::AbstractString)
    destination = abspath(path)
    ispath(destination) && throw(ArgumentError("Output file already exists: $destination"))
    isdir(dirname(destination)) || throw(ArgumentError("Output directory must exist: $(dirname(destination))"))
    columns = Dict(h => c for (h, c) in zip(submission.headers, submission.column_numbers))
    rows = Set(submission.excel_rows)
    names, entries, part, xml = _sheet_xml(submission)
    formulas = _formula_cells(xml, rows)
    cells = CellEdit[]
    seen = Set{Tuple{Int,String}}()
    for e in edits
        e.row in rows || throw(ArgumentError("Row $(e.row) is not a specimen record"))
        haskey(columns, e.column) || throw(ArgumentError("Unknown column $(repr(e.column))"))
        (e.row, e.column) in seen && throw(ArgumentError("Cell $(e.column) of row $(e.row) edited twice"))
        push!(seen, (e.row, e.column))
        (e.row, columns[e.column]) in formulas &&
            throw(ArgumentError("Cell $(e.column) of row $(e.row) holds a formula and cannot be edited here"))
        push!(cells, CellEdit(e.row, columns[e.column], e.value))
    end
    edited = _edit_sheet(xml, cells)
    staging = tempname(dirname(destination); cleanup=false) * ".xlsx"
    try
        _write_package(staging, names, entries, Dict(part => Vector{UInt8}(codeunits(edited))))
        _verify_enriched(submission, staging, cells, names, entries, part)
        _file_sha256(submission.source_path) == submission.source_sha256 ||
            throw(ArgumentError("Source workbook changed while saving; output discarded."))
        mv(staging, destination)
    finally
        isfile(staging) && rm(staging)
    end
    return destination
end
