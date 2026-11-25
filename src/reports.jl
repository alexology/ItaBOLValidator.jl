"""
    validation_report(submission; identifier_header=nothing) -> DataFrame

Return one row per specimen, in input order, including its Excel row number, raw
coordinate values, parsed coordinates, statuses and pair validity. Optionally
copy an identifier column selected by its exact name into `specimen_id`.
Duplicate or missing identifiers are never changed or used as row keys.
"""
function validation_report(submission::BOLDSubmission; identifier_header::Union{Nothing,AbstractString}=nothing)
    if identifier_header !== nothing && !(identifier_header in submission.headers)
        throw(ArgumentError("Unknown exact identifier header: $identifier_header"))
    end
    report = DataFrame(
        excel_row=copy(submission.excel_rows),
        raw_latitude=copy(submission.records[!, "COORD:LAT"]),
        raw_longitude=copy(submission.records[!, "COORD:LON"]),
        latitude=Union{Missing,Float64}[p.latitude.value for p in submission.coordinates],
        longitude=Union{Missing,Float64}[p.longitude.value for p in submission.coordinates],
        latitude_status=String[string(p.latitude.status) for p in submission.coordinates],
        longitude_status=String[string(p.longitude.status) for p in submission.coordinates],
        valid=Bool[isvalid(p) for p in submission.coordinates],
    )
    if identifier_header !== nothing
        report[!, :specimen_id] = copy(submission.records[!, identifier_header])
    end
    return report
end

"""
    csv_safe(value)

Spreadsheet-safe value for CSV sidecars (OWASP "CSV injection"): text starting
with `=`, `+`, `-`, `@`, a tab or a carriage return gets a leading apostrophe, so
that a spreadsheet opening the CSV shows it as text instead of running it as a
formula; plain decimal numbers written as text (`-3.2`) and non-text values are
unchanged. Only CSV files are affected: workbooks keep their values as they are.
"""
function csv_safe(value)
    value isa AbstractString || return value
    isempty(value) && return value
    first(value) in ('=', '+', '-', '@', '\t', '\r') || return value
    occursin(r"^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$", value) && return value
    return "'" * value
end

_csv_safe_cell(_, value) = csv_safe(value)

"""
    export_validation(submission, directory; identifier_header=nothing) -> String

Create a NEW directory containing `original.xlsx` (a byte-for-byte copy),
`coordinates.csv` (a validation sidecar, not a BOLD upload), and `manifest.toml`.
Refuse existing destinations, including the source directory. Verify the copied
workbook's SHA-256 against the parsed source before publishing the directory.
No workbook is reserialized or enriched in this phase. Treat the parsed result
as read-only until export; CSV is an inspection/interchange format, not a backup
of Excel types or formatting. Open spreadsheet CSV imports as text when needed.
"""
function export_validation(submission::BOLDSubmission, directory::AbstractString;
                           identifier_header::Union{Nothing,AbstractString}=nothing)
    report = validation_report(submission; identifier_header)
    destination = abspath(directory)
    ispath(destination) && throw(ArgumentError("Output directory already exists: $destination"))
    parent = dirname(destination)
    isdir(parent) || throw(ArgumentError("Output parent directory must already exist: $parent"))
    staging = mktempdir(parent; prefix="itabold-")
    try
        original = joinpath(staging, "original.xlsx")
        cp(submission.source_path, original; force=false, follow_symlinks=true)
        _file_sha256(original) == submission.source_sha256 ||
            throw(ArgumentError("Source workbook changed since parsing; export refused."))
        CSV.write(joinpath(staging, "coordinates.csv"), report; transform=_csv_safe_cell)
        manifest = Dict{String,Any}(
            "schema_version" => 1,
            "application" => "ItaBOLValidator",
            "preservation" => "byte-for-byte original; validation sidecar only",
            "workbook" => "original.xlsx",
            "source_sha256" => submission.source_sha256,
            "worksheet" => "Submissions",
            "worksheet_names" => submission.sheet_names,
            "header_row" => submission.header_row,
            "headers" => submission.headers,
            "column_numbers" => submission.column_numbers,
            "record_count" => nrow(report),
            "valid_coordinate_count" => count(identity, report.valid),
            "report" => "coordinates.csv",
        )
        identifier_header === nothing || (manifest["identifier_header"] = String(identifier_header))
        open(joinpath(staging, "manifest.toml"), "w") do io
            TOML.print(io, manifest; sorted=true)
        end
        mv(staging, destination; force=false)
    finally
        isdir(staging) && rm(staging; recursive=true)
    end
    return destination
end
