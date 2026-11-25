# Targeted editing of one worksheet inside an .xlsx (OOXML) package.
#
# The workbook is never rebuilt from a DataFrame and never re-serialized by
# XLSX.jl. Every package part except the `Submissions` worksheet XML is copied
# with identical bytes; inside that part only the edited <c> elements change.
# New text is written as inline strings, so sharedStrings.xml is untouched, and
# each edited cell keeps its style index.

"""A value to write at a 1-based Excel row and column."""
struct CellEdit
    row::Int
    column::Int
    value::Union{String,Float64,Nothing}     # nothing clears the cell (its style is kept)
end

"""Workbook structure that prevents a safe targeted edit."""
struct WorkbookStructureError <: Exception
    message::String
end
Base.showerror(io::IO, err::WorkbookStructureError) = print(io, err.message)

const ATTRIBUTE = r"([\w:.-]+)\s*=\s*(?:\"([^\"]*)\"|'([^']*)')"

function _attributes(tag::AbstractString)
    attrs = Dict{String,String}()
    for m in eachmatch(ATTRIBUTE, tag)
        attrs[something(m.captures[1], "")] = something(m.captures[2], m.captures[3], "")
    end
    return attrs
end

_unescape(s) = replace(s, "&lt;" => "<", "&gt;" => ">", "&quot;" => "\"", "&apos;" => "'", "&amp;" => "&")

function _column_letters(column::Int)
    letters = Char[]
    while column > 0
        column, r = divrem(column - 1, 26)
        pushfirst!(letters, 'A' + r)
    end
    return String(letters)
end

function _column_number(letters::AbstractString)
    n = 0
    for c in letters
        n = 26n + (c - 'A' + 1)
    end
    return n
end

function _split_ref(ref::AbstractString)
    m = match(r"^\$?([A-Z]{1,3})\$?([0-9]+)$", ref)
    m === nothing && throw(WorkbookStructureError("Unsupported cell reference $(repr(ref))"))
    return parse(Int, something(m.captures[2], "")), _column_number(something(m.captures[1], ""))
end

"""Read all entries of an .xlsx package, keeping their order."""
function _read_package(bytes::Vector{UInt8})
    reader = ZipArchives.ZipReader(bytes)
    names = ZipArchives.zip_names(reader)
    length(unique(names)) == length(names) || throw(WorkbookStructureError("Duplicate entries in the workbook package"))
    entries = Dict{String,Vector{UInt8}}(name => ZipArchives.zip_readentry(reader, name) for name in names)
    return names, entries
end

"""Return the package path of the worksheet named `sheet`."""
function _worksheet_part(entries, sheet::AbstractString)
    workbook = String(copy(get(entries, "xl/workbook.xml", UInt8[])))
    isempty(workbook) && throw(WorkbookStructureError("xl/workbook.xml not found"))
    rid = nothing
    for m in eachmatch(r"<(?:\w+:)?sheet\b[^>]*>", workbook)
        attrs = _attributes(m.match)
        _unescape(get(attrs, "name", "")) == sheet || continue
        keys_id = [k for k in keys(attrs) if endswith(k, ":id")]
        length(keys_id) == 1 || throw(WorkbookStructureError("Sheet $sheet has no relationship id"))
        rid = attrs[only(keys_id)]
    end
    rid === nothing && throw(WorkbookStructureError("Worksheet $sheet not found in workbook.xml"))
    rels = String(copy(get(entries, "xl/_rels/workbook.xml.rels", UInt8[])))
    for m in eachmatch(r"<(?:\w+:)?Relationship\b[^>]*>", rels)
        attrs = _attributes(m.match)
        get(attrs, "Id", "") == rid || continue
        get(attrs, "TargetMode", "Internal") == "External" &&
            throw(WorkbookStructureError("Worksheet $sheet is an external part"))
        target = _unescape(attrs["Target"])
        part = startswith(target, "/") ? target[2:end] : normpath(joinpath("xl", target))
        part = replace(part, '\\' => '/')
        haskey(entries, part) || throw(WorkbookStructureError("Worksheet part $part is missing"))
        return part
    end
    throw(WorkbookStructureError("Relationship $rid for worksheet $sheet not found"))
end

"""One <c> element: its column, byte range in the row content, attributes and content."""
struct CellSpan
    column::Int
    range::UnitRange{Int}
    attributes::Dict{String,String}
    content::String
end

struct RowSpan
    row::Int
    tag::UnitRange{Int}          # start tag (or self-closing tag)
    content::UnitRange{Int}      # between start and end tag; empty for <row/>
    selfclosing::Bool
    prefix::String
end

const ROW_TAG = r"<(\w+:)?row\b[^>]*?(/?)>"
const CELL = r"<(?:\w+:)?c\b([^>]*?)(?:/>|>(.*?)</(?:\w+:)?c>)"s

function _sheet_data(xml::String)
    m = match(r"<(?:\w+:)?sheetData\b[^>]*?(/?)>", xml)
    m === nothing && throw(WorkbookStructureError("Worksheet has no sheetData"))
    m.captures[1] == "/" && return m.offset:(m.offset - 1)
    start = m.offset + ncodeunits(m.match)
    close = findnext(r"</(?:\w+:)?sheetData>", xml, start)
    close === nothing && throw(WorkbookStructureError("Unterminated sheetData"))
    return start:(first(close) - 1)
end

function _rows(xml::String, data::UnitRange{Int})
    rows = RowSpan[]
    position = first(data)
    previous = 0
    while true
        m = findnext(ROW_TAG, xml, position)
        (m === nothing || first(m) > last(data)) && break
        tag = xml[m]
        tm = match(ROW_TAG, tag)
        prefix = something(tm.captures[1], "")
        attrs = _attributes(tag)
        row = haskey(attrs, "r") ? parse(Int, attrs["r"]) : previous + 1
        if tm.captures[2] == "/"
            push!(rows, RowSpan(row, m, (last(m) + 1):last(m), true, prefix))
            position = last(m) + 1
        else
            close = findnext("</$(prefix)row>", xml, last(m) + 1)
            close === nothing && throw(WorkbookStructureError("Unterminated row $row"))
            push!(rows, RowSpan(row, m, (last(m) + 1):(first(close) - 1), false, prefix))
            position = last(close) + 1
        end
        previous = row
    end
    return rows
end

function _cells(content::AbstractString)
    cells = CellSpan[]
    previous = 0
    for m in eachmatch(CELL, content)
        attrs = _attributes(something(m.captures[1], ""))
        column = haskey(attrs, "r") ? _split_ref(attrs["r"])[2] : previous + 1
        push!(cells, CellSpan(column, m.offset:(m.offset + ncodeunits(m.match) - 1), attrs,
                              something(m.captures[2], "")))
        previous = column
    end
    return cells
end

_has_formula(cell::CellSpan) = occursin(r"<(?:\w+:)?f\b", cell.content)

"""Return the set of (row, column) cells that contain formulas, among `rows`."""
function _formula_cells(xml::String, rows::AbstractSet{Int})
    found = Set{Tuple{Int,Int}}()
    for span in _rows(xml, _sheet_data(xml))
        span.row in rows || continue
        for cell in _cells(SubString(xml, span.content))
            _has_formula(cell) && push!(found, (span.row, cell.column))
        end
    end
    return found
end

const INVALID_XML = r"[\x00-\x08\x0B\x0C\x0E-\x1F￾￿]"

function _escape_text(s::AbstractString)
    occursin(INVALID_XML, s) && throw(ArgumentError("Text contains characters not allowed in XML: $(repr(s))"))
    return replace(s, "&" => "&amp;", "<" => "&lt;", ">" => "&gt;")
end

function _number_text(x::Float64)
    isfinite(x) || throw(ArgumentError("Cannot write non-finite number $x"))
    return isinteger(x) && abs(x) < 1e15 ? string(Int64(x)) : string(x)
end

function _cell_xml(edit::CellEdit, prefix::String, style::Union{Nothing,String})
    ref = _column_letters(edit.column) * string(edit.row)
    s = style === nothing ? "" : " s=\"$style\""
    p = prefix
    edit.value === nothing && return "<$(p)c r=\"$ref\"$s/>"
    if edit.value isa Float64
        return "<$(p)c r=\"$ref\"$s><$(p)v>$(_number_text(edit.value))</$(p)v></$(p)c>"
    end
    text = edit.value
    space = text != strip(text) || occursin('\n', text) ? " xml:space=\"preserve\"" : ""
    return "<$(p)c r=\"$ref\"$s t=\"inlineStr\"><$(p)is><$(p)t$space>$(_escape_text(text))</$(p)t></$(p)is></$(p)c>"
end

function _edit_row(xml::String, span::RowSpan, edits::Vector{CellEdit})
    content = span.selfclosing ? "" : xml[span.content]
    cells = _cells(content)
    tag = xml[span.tag]
    row_attrs = _attributes(tag)
    row_style = get(row_attrs, "customFormat", "0") in ("1", "true") ? get(row_attrs, "s", nothing) : nothing
    replacements = Tuple{UnitRange{Int},String}[]   # ranges in `content`
    inserted = false
    for edit in sort(edits; by=e -> e.column)
        i = findfirst(c -> c.column == edit.column, cells)
        if i === nothing
            next = findfirst(c -> c.column > edit.column, cells)
            at = next === nothing ? something(findfirst(r"<(?:\w+:)?extLst\b", content), ncodeunits(content) + 1:ncodeunits(content)) :
                 cells[next].range
            push!(replacements, (first(at):(first(at) - 1), _cell_xml(edit, span.prefix, row_style)))
            inserted = true
        else
            cell = cells[i]
            _has_formula(cell) && throw(WorkbookStructureError(
                "Refusing to replace the formula in $(_column_letters(edit.column))$(edit.row)"))
            push!(replacements, (cell.range, _cell_xml(edit, span.prefix, get(cell.attributes, "s", nothing))))
        end
    end
    sort!(replacements; by=r -> (first(r[1]), length(r[1])))
    io = IOBuffer()
    position = 1
    for (range, text) in replacements
        print(io, SubString(content, position, first(range) - 1), text)
        position = last(range) + 1
    end
    print(io, SubString(content, position))
    new_content = String(take!(io))
    # spans is an optional hint; drop it when a cell is added outside the old span.
    new_tag = inserted ? replace(tag, r"\s+spans\s*=\s*(?:\"[^\"]*\"|'[^']*')" => "") : tag
    if span.selfclosing
        new_tag = replace(new_tag, r"\s*/>$" => ">")
        return new_tag * new_content * "</$(span.prefix)row>"
    end
    return new_tag * new_content
end

"""Apply cell edits to worksheet XML; every target row must already exist."""
function _edit_sheet(xml::String, edits::Vector{CellEdit})
    isempty(edits) && return xml
    by_row = Dict{Int,Vector{CellEdit}}()
    for e in edits
        push!(get!(by_row, e.row, CellEdit[]), e)
    end
    length(unique((e.row, e.column) for e in edits)) == length(edits) ||
        throw(ArgumentError("Duplicate cell edits"))
    rows = _rows(xml, _sheet_data(xml))
    found = Set(r.row for r in rows)
    missing_rows = setdiff(keys(by_row), found)
    isempty(missing_rows) || throw(WorkbookStructureError("Rows not present in the worksheet: $(sort!(collect(missing_rows)))"))
    io = IOBuffer()
    position = 1
    for span in rows
        haskey(by_row, span.row) || continue
        stop = span.selfclosing ? last(span.tag) : last(span.content)
        print(io, SubString(xml, position, first(span.tag) - 1), _edit_row(xml, span, by_row[span.row]))
        position = stop + 1
    end
    print(io, SubString(xml, position))
    return String(take!(io))
end

"""Write a package with the same entry order, replacing only `replaced` parts."""
function _write_package(path, names, entries, replaced::Dict{String,Vector{UInt8}})
    ZipArchives.ZipWriter(path) do w
        for name in names
            if endswith(name, "/")
                ZipArchives.zip_mkdir(w, name)
                continue
            end
            ZipArchives.zip_newfile(w, name; compress=true)
            write(w, get(replaced, name, entries[name]))
            ZipArchives.zip_commitfile(w)
        end
    end
    return path
end
