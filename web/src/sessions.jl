# Upload sessions, the job limiter and workbook content checks.

struct RequestError <: Exception
    status::Int
    message::String
end

const SESSION_ID = r"^[0-9a-f]{32}$"

"""One upload. Its directory holds only `upload.xlsx` and, after enrichment, `result/`."""
mutable struct Session
    id::String
    dir::String
    filename::String               # sanitized original name, for download names only
    sha256::String
    last_access::Float64
    summary::Dict{String,Any}
    enriched::Union{Nothing,Dict{String,Any}}
    lock::ReentrantLock
end

"""
Counts running and waiting jobs; refuses work beyond both limits (HTTP 503).
With `release`, memory is collected and returned to the system whenever the
last running job ends (see `release_memory`).
"""
mutable struct JobLimiter
    condition::Threads.Condition
    running::Int
    waiting::Int
    max_running::Int
    max_waiting::Int
    release::Bool
end
JobLimiter(max_running, max_waiting; release::Bool=false) =
    JobLimiter(Threads.Condition(), 0, 0, max_running, max_waiting, release)

function with_job(f, limiter::JobLimiter)
    lock(limiter.condition) do
        if limiter.running >= limiter.max_running
            limiter.waiting >= limiter.max_waiting &&
                throw(RequestError(503, "Il server è occupato; riprova tra poco."))
            limiter.waiting += 1
            try
                while limiter.running >= limiter.max_running
                    wait(limiter.condition)
                end
            finally
                limiter.waiting -= 1
            end
        end
        limiter.running += 1
    end
    try
        # Geospatial work blocks its thread in GDAL; keep it off the HTTP tasks.
        return fetch(Threads.@spawn f())
    catch err
        err isa TaskFailedException ? throw(err.task.exception) : rethrow()
    finally
        idle = lock(limiter.condition) do
            limiter.running -= 1
            notify(limiter.condition)
            limiter.running == 0 && limiter.waiting == 0
        end
        limiter.release && idle && release_memory()
    end
end

new_session_id() = bytes2hex(rand(RandomDevice(), UInt8, 16))

function _safe_filename(name::AbstractString)
    base = replace(basename(replace(name, '\\' => '/')), r"[^A-Za-z0-9._-]" => "_")
    stem = first(replace(splitext(base)[1], r"^[._]+" => ""), 80)
    return isempty(stem) ? "workbook" : stem
end

const XLSX_MAIN = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"

"""
Check that `bytes` is a plain .xlsx package before any spreadsheet parser sees
it: ZIP structure, entry count, total uncompressed size (zip bombs), the
spreadsheet main part, no macros and, when `max_rows` is given, at most that many
`<row>` elements per worksheet, so that an oversized sheet is refused without
being parsed (the exact record count is checked after parsing).
"""
function check_workbook_bytes(bytes::Vector{UInt8}, max_uncompressed::Integer; max_rows::Integer=typemax(Int))
    length(bytes) >= 4 && bytes[1:4] == UInt8[0x50, 0x4b, 0x03, 0x04] ||
        throw(RequestError(422, "Il file non è un file .xlsx (firma ZIP assente)."))
    reader = try
        ZipArchives.ZipReader(bytes)
    catch
        throw(RequestError(422, "Il file non è un file .xlsx leggibile."))
    end
    n = ZipArchives.zip_nentries(reader)
    n <= 10_000 || throw(RequestError(422, "Il file contiene troppe parti."))
    total = sum((ZipArchives.zip_uncompressed_size(reader, i) for i in 1:n); init=UInt64(0))
    total <= max_uncompressed || throw(RequestError(413, "Il contenuto del file è troppo grande una volta decompresso."))
    names = ZipArchives.zip_names(reader)
    for name in names
        (startswith(name, "/") || occursin("..", name) || occursin('\\', name)) &&
            throw(RequestError(422, "Il file contiene un nome di parte non valido."))
    end
    ("[Content_Types].xml" in names && "xl/workbook.xml" in names) ||
        throw(RequestError(422, "Il file non è un file Excel (.xlsx)."))
    any(name -> lowercase(name) == "xl/vbaproject.bin", names) &&
        throw(RequestError(422, "Non sono accettati file con macro."))
    types = try
        ZipArchives.zip_readentry(reader, "[Content_Types].xml", String)
    catch
        throw(RequestError(422, "Impossibile leggere i tipi di contenuto del file."))
    end
    occursin(XLSX_MAIN, types) || throw(RequestError(422, "Sono accettati solo file .xlsx (non .xlsm né modelli)."))
    for name in names
        startswith(name, "xl/worksheets/") && endswith(name, ".xml") || continue
        xml = ZipArchives.zip_readentry(reader, name, String)
        count(r"<(?:\w+:)?row[\s>/]", xml) <= max_rows ||
            throw(RequestError(413, "Il file ha troppe righe: il limite è di $(max_rows) righe per foglio."))
    end
    return nothing
end
