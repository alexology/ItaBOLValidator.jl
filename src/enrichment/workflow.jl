# BOLD metadata enrichment: proposals from the layer registry, a per-cell
# preview, and a new enriched workbook written by targeted OOXML edits.

const PREVIEW_STATUSES = ("fill", "overwrite", "preserved", "unchanged", "no_value",
                          "invalid_coordinates", "formula_preserved", "conflict", "case_fixed")

# Layer statuses grouped into report categories.
const REASONS = Dict(
    "outside_extent" => "outside_coverage", "outside_coverage" => "outside_coverage",
    "ambiguous" => "ambiguous", "boundary" => "boundary", "no_match" => "no_match",
    "nodata" => "nodata", "masked" => "nodata", "unmapped" => "unmapped", "out_of_range" => "out_of_range",
    "transform_failed" => "transform_failed", "invalid_coordinate" => "invalid_coordinates",
    "inside" => "null_value", "ok" => "null_value", "elevation_above_sea" => "elevation_above_sea")

function _selected_fields(registry::GeoRegistry, fields, overwrite)
    active = Dict(m.column => m for m in registry.mappings if m.status === :active)
    chosen = fields === nothing ? [m.column for m in registry.mappings if m.status === :active] : String.(collect(fields))
    length(unique(chosen)) == length(chosen) || throw(ArgumentError("Duplicate fields selected"))
    for f in chosen
        haskey(BOLD_PROTECTED_COLUMNS, f) && throw(ArgumentError("$f cannot be enriched: $(BOLD_PROTECTED_COLUMNS[f])"))
        f in BOLD_TARGET_COLUMNS || throw(ArgumentError("Unknown BOLD field $(repr(f))"))
        haskey(active, f) || throw(ArgumentError("No active layer mapping for $f; see mapping_report(registry)"))
    end
    over = String.(collect(overwrite))
    extra = setdiff(over, chosen)
    isempty(extra) || throw(ArgumentError("Overwrite requested for unselected fields: $(join(extra, ", "))"))
    return chosen, Set(over), [active[f] for f in chosen]
end

_layer_entry(registry, id) = only(l for l in registry.layers if l.id == id)
_blank_value(v) = ismissing(v) || v === nothing || (v isa AbstractString && isempty(strip(v)))

function _same_value(original, proposed)
    original isa Real && proposed isa Real && return original == proposed
    return strip(string(original)) == strip(string(proposed))
end

function _sheet_xml(submission::BOLDSubmission)
    bytes = read(submission.source_path)
    bytes2hex(sha256(bytes)) == submission.source_sha256 ||
        throw(ArgumentError("Source workbook changed since parsing; enrichment refused."))
    names, entries = _read_package(bytes)
    part = _worksheet_part(entries, "Submissions")
    return names, entries, part, String(copy(entries[part]))
end

"""Proposals per field and record: value, source layer and reason when absent."""
function _proposals(submission, registry, mappings; depth_land_check::Bool)
    points = GeoPoints(submission.coordinates)
    n = length(points)
    elevation = [m for m in registry.mappings if m.column == "ELEV" && m.status === :active]
    ids = String[]
    # The elevation layers are read for the land check only when DEPTH is selected.
    land_check = depth_land_check && any(m -> m.column == "DEPTH", mappings)
    for m in vcat(mappings, land_check ? elevation : BoldFieldMapping[])
        for id in m.layers
            _layer_entry(registry, id).status === :available && !(id in ids) && push!(ids, id)
        end
    end
    table = isempty(ids) ? DataFrame() : extract_layers(points, registry; layers=ids)
    output(id) = _layer_entry(registry, id).output
    proposals = Dict{String,Any}()
    for m in mappings
        value = Vector{Any}(missing, n)
        source = Vector{Union{Missing,String}}(missing, n)
        detail = fill("", n)
        reason = fill("", n)
        for i in 1:n
            notes = String[]
            for id in m.layers
                id in ids || (push!(notes, "$id: $(_layer_entry(registry, id).status)"); continue)
                v = table[i, output(id)]
                status = table[i, "$(output(id)).status"]
                if !ismissing(v)
                    value[i], source[i] = v, id
                    break
                end
                push!(notes, "$id: $status")
                category = get(REASONS, status, status)
                # Report the first informative reason, not merely being outside a fallback layer.
                (isempty(reason[i]) || (reason[i] == "outside_coverage" && category != "outside_coverage")) &&
                    (reason[i] = category)
            end
            detail[i] = join(notes, "; ")
        end
        if m.column == "DEPTH" && depth_land_check && !isempty(elevation)
            for i in 1:n
                ismissing(value[i]) && continue
                for id in only(elevation).layers
                    id in ids || continue
                    e = table[i, output(id)]
                    if !ismissing(e) && e > 0
                        detail[i] = "$id: elevation $(e) m above sea level; DEPTH from $(source[i]) not used"
                        value[i], source[i], reason[i] = missing, missing, "elevation_above_sea"
                        break
                    end
                end
            end
        end
        raw = Dict(id => ("$(output(id)).raw" in names(table) ? table[!, "$(output(id)).raw"] : nothing) for id in m.layers if id in ids)
        statuses = Dict(id => table[!, "$(output(id)).status"] for id in m.layers if id in ids)
        proposals[m.column] = (; value, source, detail, reason, raw, statuses)
    end
    return points, proposals, ids
end

"""
    preview_enrichment(submission, registry; fields=nothing, overwrite=String[],
                       identifier_header=nothing, depth_land_check=true, taxonomy=nothing) -> DataFrame

One row per specimen and selected BOLD field, in workbook order: `excel_row`,
`specimen_id` (from the exact `identifier_header`, otherwise `missing`), `field`,
`original`, `proposed`, `source_layer`, `status` and `detail`.

`fields` selects BOLD columns with an active registry mapping (default: all).
Non-empty cells are never replaced unless their field is listed in `overwrite`.
Statuses: `fill` (empty cell gets a value), `overwrite`, `preserved` (existing
value kept), `unchanged` (existing value equals the proposal), `no_value`
(no reliable geographic value; see `detail`), `invalid_coordinates` and
`formula_preserved` (formula cells are never replaced).

With `depth_land_check`, DEPTH is not proposed where the ELEV mapping reports
an elevation above 0 m, so inland (freshwater) samples never receive a marine
depth. Disable it only with a depth dataset suitable for those waters.

`taxonomy`, the result of [`complete_taxonomy`](@ref), adds rows for the empty
taxonomic columns above each record's lowest filled rank (`source_layer` is
`TAXONOMY_SOURCE`): `fill`, `unchanged` (filled rank equals BOLD), `conflict`
(filled rank differs from BOLD: kept, and nothing is filled for that record) or
`no_value` (not found, homonyms, lookup failure or no such rank in BOLD; see
`detail`) or `case_fixed`: a filled name written with non-standard capitals is
rewritten in BOLD's spelling, or by the rule "capital initial for the genus and
higher ranks, lower-case epithets" (see [`taxon_case`](@ref)) when BOLD did not
confirm it; nothing else in a filled taxonomic cell is ever changed, and a
record in conflict with BOLD is left as it is. Pass `fields=String[]` to
complete only the taxonomy.
"""
function preview_enrichment(submission::BOLDSubmission, registry::GeoRegistry; fields=nothing,
                            overwrite=String[], identifier_header::Union{Nothing,AbstractString}=nothing,
                            depth_land_check::Bool=true, taxonomy::Union{Nothing,TaxonomyCompletion}=nothing)
    return _preview(submission, registry; fields, overwrite, identifier_header, depth_land_check, taxonomy)[1]
end

function _preview(submission, registry; fields, overwrite, identifier_header, depth_land_check, taxonomy)
    if identifier_header !== nothing && !(identifier_header in submission.headers)
        throw(ArgumentError("Unknown exact identifier header: $identifier_header"))
    end
    chosen, over, mappings = _selected_fields(registry, fields, overwrite)
    isempty(chosen) && taxonomy === nothing && throw(ArgumentError("Nothing to enrich: no field selected"))
    if taxonomy !== nothing
        length(taxonomy.query_column) == length(submission.excel_rows) ||
            throw(ArgumentError("The taxonomy completion belongs to another submission"))
        absent = setdiff(TAXON_COLUMNS, submission.headers)
        isempty(absent) || throw(ArgumentError("Taxonomic columns missing: $(join(absent, ", "))"))
    end
    _, _, _, xml = _sheet_xml(submission)
    columns = Dict(h => c for (h, c) in zip(submission.headers, submission.column_numbers))
    formulas = _formula_cells(xml, Set(submission.excel_rows))
    points, proposals, used = _proposals(submission, registry, mappings; depth_land_check)
    n = length(points)
    rows = (excel_row=Int[], specimen_id=Any[], field=String[], original=Any[], proposed=Any[],
            source_layer=Union{Missing,String}[], status=String[], detail=String[])
    edits = CellEdit[]
    function add_row!(row, i, field, original, proposed, source, status, detail)
        push!(rows.excel_row, row)
        push!(rows.specimen_id, identifier_header === nothing ? missing : submission.records[i, identifier_header])
        push!(rows.field, field)
        push!(rows.original, original)
        push!(rows.proposed, proposed)
        push!(rows.source_layer, source)
        push!(rows.status, status)
        push!(rows.detail, detail)
    end
    for i in 1:n
      for field in chosen
        p = proposals[field]
        original = submission.records[i, field]
        proposed = p.value[i]
        row, column = submission.excel_rows[i], columns[field]
        status = if (row, column) in formulas
            "formula_preserved"
        elseif points.status[i] !== :valid
            "invalid_coordinates"
        elseif ismissing(proposed)
            "no_value"
        elseif _blank_value(original)
            "fill"
        elseif _same_value(original, proposed)
            "unchanged"
        elseif field in over
            "overwrite"
        else
            "preserved"
        end
        detail = status == "invalid_coordinates" ? "coordinates: $(points.status[i])" :
                 status == "no_value" ? p.detail[i] : ""
        add_row!(row, i, field, original, proposed, p.source[i], status, detail)
        if status in ("fill", "overwrite")
            push!(edits, CellEdit(row, column, proposed isa Real ? Float64(proposed) : string(proposed)))
        end
      end
      taxonomy === nothing && continue
      for (field, original, proposed, status, detail) in _taxonomy_rows(submission, taxonomy, i)
        row, column = submission.excel_rows[i], columns[field]
        if status in ("fill", "case_fixed") && (row, column) in formulas
            status, detail = "formula_preserved", "formula cell; BOLD value $(proposed) not written"
        end
        add_row!(row, i, field, original, proposed, TAXONOMY_SOURCE, status, detail)
        status in ("fill", "case_fixed") && push!(edits, CellEdit(row, column, string(proposed)))
      end
    end
    preview = DataFrame(rows)
    context = (; chosen, over, points, proposals, used, edits, taxonomy)
    return preview, context
end

function _report(submission, registry, preview, context, workbook_sha, options)
    statuses = preview.status
    count_status(s) = count(==(s), statuses)
    valid = count(==(:valid), context.points.status)
    per_field = Dict{String,Any}()
    for field in context.chosen
        rows = preview.field .== field
        p = context.proposals[field]
        reasons = Dict{String,Int}()
        for (i, s) in enumerate(preview.status[rows])
            s == "no_value" && (reasons[p.reason[i]] = get(reasons, p.reason[i], 0) + 1)
        end
        unmapped = Dict{String,Int}()
        for (id, raw) in p.raw
            raw === nothing && continue
            for (i, st) in enumerate(p.statuses[id])
                st == "unmapped" && ismissing(p.value[i]) || continue
                key = "$id:$(raw[i])"
                unmapped[key] = get(unmapped, key, 0) + 1
            end
        end
        ambiguous_rows = [submission.excel_rows[i] for i in eachindex(p.reason) if p.reason[i] == "ambiguous" && ismissing(p.value[i])]
        per_field[field] = Dict{String,Any}(
            "populated" => count(in(("fill", "overwrite")), preview.status[rows]),
            "filled" => count(==("fill"), preview.status[rows]),
            "overwritten" => count(==("overwrite"), preview.status[rows]),
            "existing_preserved" => count(==("preserved"), preview.status[rows]),
            "already_matching" => count(==("unchanged"), preview.status[rows]),
            "formula_preserved" => count(==("formula_preserved"), preview.status[rows]),
            "no_value" => count(==("no_value"), preview.status[rows]),
            "no_value_reasons" => reasons,
            "unmapped_categories" => unmapped,
            "ambiguous_excel_rows" => ambiguous_rows,
            "layers" => _layer_entry_ids(registry, field),
            "overwrite_enabled" => field in context.over,
        )
    end
    # A specimen is outside coverage when every layer of every selected field is outside it.
    outside = 0
    for i in eachindex(context.points.status)
        isempty(context.chosen) && break
        context.points.status[i] === :valid || continue
        all(f -> context.proposals[f].reason[i] == "outside_coverage" && ismissing(context.proposals[f].value[i]),
            context.chosen) && (outside += 1)
    end
    datasets = [Dict{String,Any}("id" => l.id, "name" => l.name, "version" => l.version, "source" => l.source,
                                 "path" => l.path, "type" => string(l.type), "kind" => string(l.kind),
                                 "fields" => [f for f in context.chosen if l.id in _layer_entry_ids(registry, f)])
                for l in registry.layers if l.id in context.used]
    report = Dict{String,Any}(
        "schema_version" => 1,
        "application" => "ItaBOLValidator",
        "source_workbook" => basename(submission.source_path),
        "source_sha256" => submission.source_sha256,
        "enriched_workbook" => "enriched.xlsx",
        "enriched_sha256" => workbook_sha,
        "registry" => registry.config_path,
        "fields" => context.chosen,
        "overwrite_fields" => sort!(collect(context.over)),
        "options" => options,
        "input_specimens" => length(context.points),
        "valid_coordinates" => valid,
        "invalid_coordinates" => length(context.points) - valid,
        "fields_populated" => count_status("fill") + count_status("overwrite"),
        "values_filled" => count_status("fill"),
        "values_overwritten" => count_status("overwrite"),
        "taxon_names_recapitalised" => count_status("case_fixed"),
        "existing_values_preserved" => count_status("preserved"),
        "existing_values_matching" => count_status("unchanged"),
        "formula_cells_preserved" => count_status("formula_preserved"),
        "no_value" => count_status("no_value"),
        "specimens_outside_coverage" => outside,
        "per_field" => per_field,
        "datasets" => datasets,
    )
    context.taxonomy === nothing || (report["taxonomy"] = _taxonomy_report(context.taxonomy, preview))
    return report
end

# The active mapping of a field: duplicates are kept in the registry as invalid entries.
_layer_entry_ids(registry, field) = first(m for m in registry.mappings if m.column == field && m.status === :active).layers

"""Re-read the enriched workbook and check structure, order and every cell."""
function _verify_enriched(submission, path, edits, names, entries, part)
    enriched = read_bold(path; header_row=submission.header_row)
    enriched.headers == submission.headers && enriched.column_numbers == submission.column_numbers &&
        enriched.sheet_names == submission.sheet_names ||
        throw(WorkbookStructureError("Enriched workbook changed the BOLD header structure"))
    enriched.excel_rows == submission.excel_rows ||
        throw(WorkbookStructureError("Enriched workbook lost or reordered records"))
    expected = Dict((e.row, e.column) => e.value for e in edits)
    columns = Dict(h => c for (h, c) in zip(submission.headers, submission.column_numbers))
    for (i, row) in enumerate(submission.excel_rows), h in submission.headers
        key = (row, columns[h])
        actual = enriched.records[i, h]
        if haskey(expected, key)
            want = expected[key]
            ok = want isa Float64 ? (actual isa Real && actual == want) :
                 want === nothing ? ismissing(actual) : isequal(actual, want)
            ok || throw(WorkbookStructureError("Cell $h at row $row was not written as expected"))
        else
            isequal(actual, submission.records[i, h]) ||
                throw(WorkbookStructureError("Cell $h at row $row changed unexpectedly"))
        end
    end
    new_names, new_entries = _read_package(read(path))
    new_names == names || throw(WorkbookStructureError("Package entries changed"))
    for name in names
        name == part && continue
        new_entries[name] == entries[name] || throw(WorkbookStructureError("Package part $name changed"))
    end
    return nothing
end

"""
    enrich_workbook(submission, registry, directory; fields=nothing, overwrite=String[],
                    identifier_header=nothing, depth_land_check=true, taxonomy=nothing) -> NamedTuple

Create the NEW `directory` with `enriched.xlsx`, `changes.csv` (the
[`preview_enrichment`](@ref) table) and `report.toml`. The original workbook is
read only and must still match its parse-time SHA-256.

The enriched workbook is the original package with only the `fill`/`overwrite`
cells of the `Submissions` sheet changed: all other sheets, styles, shared
strings and package parts keep identical bytes, records keep their rows and
order, and edited cells keep their style. Before publishing, the result is
re-read and every cell is compared with the original and the intended edits.

The report also gives `worksheet_formulas`: formulas in the sheet keep their
cached results until a spreadsheet program recalculates them.
The report counts specimens, valid/invalid coordinates, populated, preserved
and matching values, specimens outside all selected layers, missing values by
reason, unmapped categories, ambiguous assignments (Excel rows) and lists the
datasets (id, name, version, source) used; with `taxonomy` (see
[`preview_enrichment`](@ref)) a `taxonomy` section gives the API, retrieval
time, lookups, unresolved names, conflicts and counts per rank.
Returns `(; directory, workbook, report, preview)`.
"""
function enrich_workbook(submission::BOLDSubmission, registry::GeoRegistry, directory::AbstractString;
                         fields=nothing, overwrite=String[], identifier_header::Union{Nothing,AbstractString}=nothing,
                         depth_land_check::Bool=true, taxonomy::Union{Nothing,TaxonomyCompletion}=nothing)
    destination = abspath(directory)
    ispath(destination) && throw(ArgumentError("Output directory already exists: $destination"))
    parent = dirname(destination)
    isdir(parent) || throw(ArgumentError("Output parent directory must already exist: $parent"))
    preview, context = _preview(submission, registry; fields, overwrite, identifier_header, depth_land_check,
                                taxonomy)
    names, entries, part, xml = _sheet_xml(submission)
    edited = _edit_sheet(xml, context.edits)
    staging = mktempdir(parent; prefix="itabold-enrich-")
    local report
    try
        workbook = joinpath(staging, "enriched.xlsx")
        _write_package(workbook, names, entries, Dict(part => Vector{UInt8}(codeunits(edited))))
        _verify_enriched(submission, workbook, context.edits, names, entries, part)
        options = Dict{String,Any}("depth_land_check" => depth_land_check, "taxonomy" => taxonomy !== nothing,
                                   "identifier_header" => something(identifier_header, ""))
        report = _report(submission, registry, preview, context, _file_sha256(workbook), options)
        # Cached results of formulas elsewhere in the sheet are not recalculated
        # here; Excel or LibreOffice recalculates them when the file is opened.
        report["worksheet_formulas"] = count(_ -> true, eachmatch(r"<(?:\w+:)?f\b", xml))
        CSV.write(joinpath(staging, "changes.csv"), preview; transform=_csv_safe_cell)
        open(io -> TOML.print(io, report; sorted=true), joinpath(staging, "report.toml"), "w")
        _file_sha256(submission.source_path) == submission.source_sha256 ||
            throw(ArgumentError("Source workbook changed during enrichment; output discarded."))
        mv(staging, destination; force=false)
    finally
        isdir(staging) && rm(staging; recursive=true)
    end
    return (; directory=destination, workbook=joinpath(destination, "enriched.xlsx"), report, preview)
end
