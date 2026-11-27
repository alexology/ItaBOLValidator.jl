# Completion of higher taxonomic ranks from the BOLD Systems taxonomy API.
#
# For each record the lowest filled taxonomic column (SUBSPECIES ... PHYLUM) is
# looked up once per distinct name; only EMPTY higher columns receive the BOLD
# lineage. Filled columns are never changed: when they disagree with BOLD the
# record is reported as a conflict and nothing is filled for it. Homonyms
# (the same name in different kingdoms, phyla, classes, orders or families) are
# never resolved automatically.

"""BOLD taxonomic columns, from the highest rank to the lowest."""
const TAXON_COLUMNS = ("PHYLUM", "CLASS", "ORDER", "FAMILY", "SUBFAMILY", "TRIBE", "GENUS", "SPECIES",
                       "SUBSPECIES")
# Ranks compared to decide whether two BOLD entries with the same name are homonyms.
const HOMONYM_RANKS = ("kingdom", "phylum", "class", "order", "family")
const BOLD_API_URL = "https://portal.boldsystems.org/api"
# One term search per name; a full page may hide homonyms, so it is not trusted.
const TERMS_LIMIT = 1000
# Requests to BOLD are spaced process-wide, whatever the number of clients.
const BOLD_GATE = ReentrantLock()
const BOLD_LAST_REQUEST = Ref(0.0)
# Times of the requests of the last hour, for `max_per_hour` (process-wide too).
const BOLD_RECENT_REQUESTS = Float64[]
const BOLD_HOURLY_LIMIT = -1                 # marker status of a request refused by max_per_hour
const MAX_RESPONSE_BYTES = 8 * 2^20
const MAX_RETRY_AFTER = 60.0
"""Value of `source_layer` in preview rows produced by the taxonomy completion."""
const TAXONOMY_SOURCE = "BOLD taxonomy"
# Qualifiers that make a name an open identification rather than a taxon name.
const OPEN_NOMENCLATURE = Set(["sp", "sp.", "spp", "spp.", "cf", "cf.", "aff", "aff.", "nr", "nr.", "gr", "gr.",
                               "indet", "indet.", "ssp", "ssp.", "agg", "agg.", "s.l.", "s.str.", "complex"])

"""
    TaxonLookup

Result of one BOLD lookup: `status` is `:found`, `:not_found`, `:ambiguous`
(homonyms), `:error` (network or API failure) or `:skipped` (lookup limit
reached or BOLD temporarily refusing requests). `lineage` maps lower-case BOLD
ranks (`"kingdom"`, `"phylum"`, ..., `"subspecies"`) to names when found.
"""
struct TaxonLookup
    status::Symbol
    lineage::Dict{String,String}
    detail::String
end

"""
    BoldTaxonomyClient(; base_url, min_interval=1.0, timeout=20.0, max_retries=2,
                       max_lookups=100, cache_hours=168.0, cache_entries=20_000,
                       block_seconds=600.0, user_agent, fetch=nothing)

Rate-limited, caching client for the BOLD taxonomy API, safe to share between
threads and sessions. Requests of all clients of the process are serialised,
with at least the requesting client's `min_interval` seconds since the previous
one; HTTP 429 and 5xx responses are retried
`max_retries` times honouring `Retry-After` (at most 60 s); after a final
429/403 no request is sent for `block_seconds`. `max_lookups` caps the network
lookups of one [`complete_taxonomy`](@ref) run (cached names do not count);
`max_per_hour` (0: none) caps the requests of the whole process in any hour,
after which lookups are `:skipped`.
Found, not-found and ambiguous results are cached for `cache_hours`.

`fetch(url) -> (status::Int, headers::Vector{Pair{String,String}}, body::Vector{UInt8})`
replaces the HTTP transport (tests use it to work offline).
"""
mutable struct BoldTaxonomyClient
    base_url::String
    min_interval::Float64
    timeout::Float64
    max_retries::Int
    max_lookups::Int
    max_per_hour::Int
    cache_seconds::Float64
    cache_entries::Int
    block_seconds::Float64
    user_agent::String
    fetch::Any
    cache::Dict{Tuple{String,String},Tuple{Float64,TaxonLookup}}
    cache_lock::ReentrantLock
    last_request::Float64
    blocked_until::Float64
    requests::Int
end

function BoldTaxonomyClient(; base_url::AbstractString=BOLD_API_URL, min_interval::Real=1.0, timeout::Real=20.0,
                            max_retries::Integer=2, max_lookups::Integer=100, max_per_hour::Integer=0,
                            cache_hours::Real=168.0,
                            cache_entries::Integer=20_000, block_seconds::Real=600.0,
                            user_agent::AbstractString="ItaBOLValidator/0.1 (BOLD taxonomy completion)",
                            fetch=nothing)
    min_interval >= 0 && timeout > 0 && max_retries >= 0 && max_lookups >= 0 && cache_hours >= 0 &&
        cache_entries >= 0 && block_seconds >= 0 || throw(ArgumentError("BoldTaxonomyClient settings must not be negative"))
    startswith(base_url, "https://") || startswith(base_url, "http://127.0.0.1") ||
        throw(ArgumentError("base_url must use https"))
    max_per_hour >= 0 || throw(ArgumentError("max_per_hour must not be negative"))
    return BoldTaxonomyClient(rstrip(base_url, '/'), min_interval, timeout, max_retries, max_lookups, max_per_hour,
                              3600 * cache_hours, cache_entries, block_seconds, user_agent, fetch,
                              Dict{Tuple{String,String},Tuple{Float64,TaxonLookup}}(), ReentrantLock(),
                              0.0, 0.0, 0)
end

function Base.show(io::IO, c::BoldTaxonomyClient)
    print(io, "BoldTaxonomyClient(", c.base_url, ", ", length(c.cache), " cached, ", c.requests, " requests)")
end

function _http_get(client::BoldTaxonomyClient, url::AbstractString)
    client.fetch === nothing || return client.fetch(url)
    io = IOBuffer()
    response = Downloads.request(url; output=io, timeout=client.timeout, throw=false,
                                 headers=["User-Agent" => client.user_agent, "Accept" => "application/json"])
    response isa Downloads.Response || throw(response)
    return (response.status, response.headers, take!(io))
end

# One request at a time in the whole process, spaced by min_interval.
function _throttled_get(client, url)
    lock(BOLD_GATE) do
        if client.max_per_hour > 0
            now = time()
            filter!(t -> now - t < 3600, BOLD_RECENT_REQUESTS)
            length(BOLD_RECENT_REQUESTS) >= client.max_per_hour &&
                return (BOLD_HOURLY_LIMIT, Pair{String,String}[], UInt8[])
            # Recorded (and pruned above) only when a limit applies: the list stays bounded.
            push!(BOLD_RECENT_REQUESTS, now)
        end
        pause = BOLD_LAST_REQUEST[] + client.min_interval - time()
        pause > 0 && sleep(pause)
        try
            return _http_get(client, url)
        finally
            BOLD_LAST_REQUEST[] = client.last_request = time()
            client.requests += 1
        end
    end
end

function _retry_after(headers, default)
    for (k, v) in headers
        lowercase(k) == "retry-after" || continue
        s = tryparse(Float64, strip(v))
        s === nothing || return clamp(s, 0.0, MAX_RETRY_AFTER)
    end
    return min(default, MAX_RETRY_AFTER)
end

"""GET a JSON document: `(:ok, value)`, `(:error, message)` or `(:blocked, message)`."""
function _get_json(client, url)
    attempt = 0
    while true
        time() < client.blocked_until && return (:blocked, "BOLD is temporarily refusing requests")
        status, headers, body = try
            _throttled_get(client, url)
        catch err
            err isa InterruptException && rethrow()
            (0, Pair{String,String}[], Vector{UInt8}(codeunits(first(sprint(showerror, err), 200))))
        end
        status == BOLD_HOURLY_LIMIT &&
            return (:blocked, "hourly limit of $(client.max_per_hour) requests to BOLD reached; try again later")
        if status == 200
            length(body) <= MAX_RESPONSE_BYTES || return (:error, "BOLD response too large")
            value = try
                JSON3.read(body)
            catch
                return (:error, "BOLD returned invalid JSON")
            end
            return (:ok, value)
        end
        retryable = status == 0 || status == 429 || status >= 500
        if !retryable || attempt >= client.max_retries
            status in (403, 429) && (client.blocked_until = time() + client.block_seconds)
            return (status in (403, 429) ? :blocked : :error,
                    status == 0 ? "network error: " * String(body) : "BOLD answered HTTP $status")
        end
        attempt += 1
        sleep(_retry_after(headers, 2.0^attempt))
    end
end

"""Percent-encode a query parameter value (RFC 3986 unreserved characters kept)."""
function _escape_query(s::AbstractString)
    io = IOBuffer()
    for b in codeunits(s)
        if (0x30 <= b <= 0x39) || (0x41 <= b <= 0x5a) || (0x61 <= b <= 0x7a) || b in (0x2d, 0x2e, 0x5f, 0x7e)
            write(io, b)
        else
            print(io, '%', uppercase(string(b; base=16, pad=2)))
        end
    end
    return String(take!(io))
end

_standard(name) = lowercase(replace(strip(name), r"\s+" => "_"))
_string_lineage(path) = Dict{String,String}(string(k) => strip(string(v)) for (k, v) in pairs(path)
                                             if v isa AbstractString && !isempty(strip(v)))
_lineage_text(lineage) = join((lineage[r] for r in ("kingdom", HOMONYM_RANKS[2:end]...) if haskey(lineage, r)), " > ")

const LINEAGE_RANKS = ("kingdom", "phylum", "class", "order", "family", "subfamily", "tribe", "genus", "species",
                       "subspecies")

"""
Lineages of `name` at `rank` found in a term search, one per homonym group.

Every taxonomic entry whose path has `name` at `rank` counts, not only the entry
of the taxon itself: the search often lists only descendants (species of a
genus), and a homonym may appear only through its descendants. Paths are cut
at `rank`; entries of one group are merged, and a rank on which they disagree
is dropped rather than guessed.
"""
function _from_terms(json, rank, name)
    json isa AbstractVector || return nothing, 0
    key = _standard(name)
    upto = LINEAGE_RANKS[1:findfirst(==(rank), LINEAGE_RANKS)]
    groups = Dict{String,String}[]
    disputed = Set{String}[]
    # Same taxon when the higher ranks both lineages carry agree (and at least one is shared).
    compatible(a, b) = begin
        shared = [r for r in HOMONYM_RANKS if haskey(a, r) && haskey(b, r)]
        !isempty(shared) && all(r -> lowercase(a[r]) == lowercase(b[r]), shared)
    end
    for e in json
        e isa JSON3.Object || continue
        get(e, :scope, "") == "tax" || continue
        path = get(e, :tax_path, nothing)
        path isa JSON3.Object || continue
        full = _string_lineage(path)
        haskey(full, rank) && _standard(full[rank]) == key || continue
        lineage = Dict(r => full[r] for r in upto if haskey(full, r))
        k = findfirst(g -> compatible(g, lineage), groups)
        if k === nothing
            push!(groups, lineage)
            push!(disputed, Set{String}())
            continue
        end
        merged = groups[k]
        for (r, v) in lineage
            if !haskey(merged, r)
                r in disputed[k] || (merged[r] = v)
            elseif merged[r] != v
                delete!(merged, r)
                push!(disputed[k], r)
            end
        end
    end
    return groups, length(json)
end

"""
    lookup_taxon(client, rank, name) -> TaxonLookup

Look up `name` at the BOLD `rank` (`"phylum"` ... `"subspecies"`), from the cache
when possible. Name matching ignores case and spacing; the lineage carries BOLD's
spelling.
"""
function lookup_taxon(client::BoldTaxonomyClient, rank::AbstractString, name::AbstractString)
    rank = lowercase(rank)
    rank in lowercase.(TAXON_COLUMNS) || throw(ArgumentError("Unknown taxonomic rank $(repr(rank))"))
    key = (rank, _standard(name))
    hit = lock(client.cache_lock) do
        entry = get(client.cache, key, nothing)
        entry !== nothing && time() - entry[1] <= client.cache_seconds ? entry[2] : nothing
    end
    hit === nothing || return hit
    result = _lookup_remote(client, rank, String(strip(name)))
    if result.status in (:found, :not_found, :ambiguous) && client.cache_entries > 0
        lock(client.cache_lock) do
            if length(client.cache) >= client.cache_entries     # drop the oldest entry
                oldest = argmin(k -> client.cache[k][1], keys(client.cache))
                delete!(client.cache, oldest)
            end
            client.cache[key] = (time(), result)
        end
    end
    return result
end

function _lookup_remote(client, rank, name)
    esc = _escape_query
    status, json = _get_json(client, "$(client.base_url)/terms?partial_term=$(esc(name))&limit=$TERMS_LIMIT")
    status === :ok || return TaxonLookup(status === :blocked ? :skipped : :error, Dict{String,String}(), json)
    lineages, returned = _from_terms(json, rank, name)
    lineages === nothing && return TaxonLookup(:error, Dict{String,String}(), "unexpected BOLD term response")
    if length(lineages) > 1
        return TaxonLookup(:ambiguous, Dict{String,String}(),
                           "homonyms in BOLD: " * join(_lineage_text.(lineages), " | "))
    elseif returned >= TERMS_LIMIT
        # Entries are ranked by records: a homonym with few records (or the taxon
        # itself) may lie beyond a full page, so nothing is filled.
        return TaxonLookup(:ambiguous, Dict{String,String}(),
                           "cannot be verified: the BOLD term search returned its maximum of $TERMS_LIMIT entries, " *
                           "so homonyms cannot be excluded")
    elseif length(lineages) == 1
        return TaxonLookup(:found, only(lineages), "")
    end
    return TaxonLookup(:not_found, Dict{String,String}(), "not found in BOLD as $rank")
end

"""
    taxon_query(column, value) -> Union{Nothing,String}

The name to look up for a taxonomic cell, or `nothing` when the cell is empty
or not a plain name of that rank: SPECIES needs two words, SUBSPECIES at least
three, higher ranks one; open nomenclature (`sp.`, `cf.`, `aff.`, ...), digits
and symbols are not looked up.
"""
function taxon_query(column::AbstractString, value)
    (ismissing(value) || value === nothing) && return nothing
    v = strip(replace(string(value), r"\s+" => " "))
    (isempty(v) || length(v) > 120) && return nothing
    words = split(v, ' ')
    any(w -> lowercase(w) in OPEN_NOMENCLATURE || !occursin(r"^[\p{L}][\p{L}\-]*\.?$", w), words) && return nothing
    n = length(words)
    ok = column == "SPECIES" ? n == 2 || (n == 3 && lowercase(words[2]) in ("x", "×")) :
         column == "SUBSPECIES" ? n >= 3 : n == 1
    return ok ? String(v) : nothing
end

"""
    TaxonomyCompletion

Result of [`complete_taxonomy`](@ref): per record the queried column and name
(`nothing` when no column could be looked up) and the lookup, plus run counts.
"""
struct TaxonomyCompletion
    query_column::Vector{Union{Nothing,String}}
    query_name::Vector{Union{Nothing,String}}
    lookups::Vector{Union{Nothing,TaxonLookup}}
    unqueryable::Vector{String}          # per record: lower cells that could not be looked up
    distinct_names::Int
    network_lookups::Int
    retrieved_at::String
    source::String
end

"""
    taxonomy_queries(submission) -> (columns, names, unqueryable)

The lowest filled, look-up-able taxonomic column of each record and its name
(`nothing` when there is none, or when it is PHYLUM: no higher rank exists).
"""
function taxonomy_queries(submission)
    present = [c for c in TAXON_COLUMNS if c in submission.headers]
    n = length(submission.excel_rows)
    columns = Vector{Union{Nothing,String}}(nothing, n)
    names = Vector{Union{Nothing,String}}(nothing, n)
    unqueryable = fill("", n)
    for i in 1:n
        skipped = String[]
        for c in reverse(present)
            v = submission.records[i, c]
            _blank_value(v) && continue
            q = taxon_query(c, v)
            if q === nothing
                push!(skipped, "$c '$(first(strip(string(v)), 60))'")
                continue
            end
            # Nothing lies above PHYLUM: no lookup needed.
            c == "PHYLUM" || ((columns[i], names[i]) = (c, q))
            break
        end
        unqueryable[i] = join(skipped, ", ")
    end
    return columns, names, unqueryable
end

"""
    complete_taxonomy(submission, client=BoldTaxonomyClient()) -> TaxonomyCompletion

Look up each distinct (rank, name) of the submission (see [`taxonomy_queries`](@ref))
once, in workbook order, through `client` (rate-limited, cached). After
`client.max_lookups` network lookups the remaining names are `:skipped`.
Pass the result to [`preview_enrichment`](@ref) / [`enrich_workbook`](@ref) as
`taxonomy`.
"""
function complete_taxonomy(submission, client::BoldTaxonomyClient=BoldTaxonomyClient())
    columns, names, unqueryable = taxonomy_queries(submission)
    results = Dict{Tuple{String,String},TaxonLookup}()
    network = 0
    for (c, name) in zip(columns, names)
        c === nothing && continue
        key = (lowercase(c), _standard(name))
        haskey(results, key) && continue
        cached = lock(client.cache_lock) do
            e = get(client.cache, key, nothing)
            e !== nothing && time() - e[1] <= client.cache_seconds
        end
        if !cached && network >= client.max_lookups
            results[key] = TaxonLookup(:skipped, Dict{String,String}(),
                                       "lookup limit of $(client.max_lookups) names per run reached")
            continue
        end
        before = client.requests
        results[key] = lookup_taxon(client, lowercase(c), name)
        client.requests > before && (network += 1)
    end
    lookups = Union{Nothing,TaxonLookup}[c === nothing ? nothing : results[(lowercase(c), _standard(n))]
                                         for (c, n) in zip(columns, names)]
    stamp = Dates.format(Dates.now(Dates.UTC), "yyyy-mm-ddTHH:MM:SSZ")
    return TaxonomyCompletion(columns, names, lookups, unqueryable, length(results), network, stamp,
                              client.base_url)
end

_same_name(a, b) = lowercase(strip(string(a))) == lowercase(strip(string(b)))

"""
    taxon_case(column, value) -> Union{Nothing,String}

Standard form of a plain taxon name (see [`taxon_query`](@ref)): capital initial
for the genus and higher ranks, lower-case epithets, single spaces
(`"baetis"` → `"Baetis"`, `"bombus TERRESTRIS"` → `"Bombus terrestris"`);
`nothing` for values that are not plain names (open nomenclature is left alone).
"""
function taxon_case(column::AbstractString, value)
    q = taxon_query(column, value)
    q === nothing && return nothing
    words = split(q, ' ')
    return join([k == 1 ? uppercasefirst(lowercase(w)) : lowercase(w) for (k, w) in enumerate(words)], ' ')
end

# Filled names whose capitalisation differs from `standard(c)` get a `case_fixed` row.
function _case_rows!(rows, submission, i, columns, standard, detail)
    for c in columns
        original = submission.records[i, c]
        _blank_value(original) && continue
        fixed = standard(c)
        fixed === nothing && continue
        (_same_name(original, fixed) && string(original) != fixed) || continue
        push!(rows, (c, original, fixed, "case_fixed", detail))
    end
    return rows
end

"""Preview rows of one record: (column, original, proposed, status, detail)."""
function _taxonomy_rows(submission, completion::TaxonomyCompletion, i)
    rows = Tuple{String,Any,Any,String,String}[]
    present = [c for c in TAXON_COLUMNS if c in submission.headers]
    by_rule(c) = taxon_case(c, submission.records[i, c])
    column = completion.query_column[i]
    if column === nothing
        _case_rows!(rows, submission, i, present, by_rule, "standard capitalisation")
        isempty(completion.unqueryable[i]) && return rows
        lowest = findlast(c -> !_blank_value(submission.records[i, c]), TAXON_COLUMNS)
        for c in TAXON_COLUMNS[1:something(lowest, 1) - 1]
            _blank_value(submission.records[i, c]) || continue
            push!(rows, (c, missing, missing, "no_value", "no name to look up: " * completion.unqueryable[i]))
        end
        return rows
    end
    upto = present[1:findfirst(==(column), present)]
    higher = upto[1:end - 1]
    lookup = completion.lookups[i]::TaxonLookup
    query = "$column '$(completion.query_name[i])'"
    if lookup.status !== :found
        reason = lookup.status === :ambiguous ? "ambiguous" : lookup.status === :not_found ? "not found" :
                 lookup.status === :skipped ? "not looked up" : "lookup failed"
        _case_rows!(rows, submission, i, upto, by_rule, "standard capitalisation (name not confirmed by BOLD)")
        for c in higher
            _blank_value(submission.records[i, c]) || continue
            push!(rows, (c, missing, missing, "no_value", "$query: $reason ($(lookup.detail))"))
        end
        return rows
    end
    lineage = lookup.lineage
    conflicts = String[]
    for c in higher
        original = submission.records[i, c]
        bold = get(lineage, lowercase(c), nothing)
        _blank_value(original) || bold === nothing || _same_name(original, bold) ||
            push!(conflicts, "$c '$(strip(string(original)))' vs BOLD '$bold'")
    end
    note = isempty(lookup.detail) ? "" : "; " * lookup.detail
    # Same names written with other capitals take BOLD's spelling (also the queried cell);
    # a record in conflict with BOLD is left entirely as it is.
    isempty(conflicts) && _case_rows!(rows, submission, i, [column],
                                      c -> get(lineage, lowercase(c), nothing), "BOLD spelling")
    for c in higher
        original = submission.records[i, c]
        bold = get(lineage, lowercase(c), nothing)
        if !_blank_value(original)
            bold === nothing && continue
            status = !_same_name(original, bold) ? "conflict" :
                     string(original) == bold || !isempty(conflicts) ? "unchanged" : "case_fixed"
            push!(rows, (c, original, bold, status, status == "conflict" ? "from $query; existing value kept" :
                                                    status == "case_fixed" ? "BOLD spelling" : ""))
        elseif !isempty(conflicts)
            push!(rows, (c, missing, missing, "no_value", "not filled: $query conflicts with " * join(conflicts, ", ")))
        elseif bold === nothing
            push!(rows, (c, missing, missing, "no_value", "BOLD has no $c for $query"))
        else
            push!(rows, (c, missing, bold, "fill", "from $query" * note))
        end
    end
    return rows
end

"""
    record_taxonomy(values, client) -> NamedTuple

Taxonomy completion of one record given as `column => value` for the taxonomic
columns (others are ignored; absent ones count as empty), with exactly the rules
of [`preview_enrichment`](@ref): the lowest filled, look-up-able rank is looked
up in BOLD and only empty higher ranks are proposed; filled ranks that differ
from BOLD are conflicts and block the record; capitalisation is standardised.
Used by the review page when a taxonomic cell is edited.

Returns `(; column, name, status, detail, rows)`: the queried column and name
(`nothing` when there is none), the lookup `status` (`:found`, `:not_found`,
`:ambiguous`, `:error`, `:skipped`, or `:none` without a lookup) and its
`detail`, and `rows`, one `(; column, original, proposed, status, detail)` per
taxonomic cell concerned (statuses as in the preview: `fill`, `case_fixed`,
`unchanged`, `conflict`, `no_value`).
"""
function record_taxonomy(values::AbstractDict, client::BoldTaxonomyClient)
    cell(c) = (v = get(values, c, missing); v === nothing ? missing : v)
    record = (; headers=collect(TAXON_COLUMNS), excel_rows=[0],
              records=DataFrame([c => Any[cell(c)] for c in TAXON_COLUMNS]))
    completion = complete_taxonomy(record, client)
    lookup = completion.lookups[1]
    rows = [(; column=c, original=o, proposed=p, status=s, detail=d)
            for (c, o, p, s, d) in _taxonomy_rows(record, completion, 1)]
    return (; column=completion.query_column[1], name=completion.query_name[1],
            status=lookup === nothing ? :none : lookup.status, detail=lookup === nothing ? "" : lookup.detail, rows)
end

function _taxonomy_report(completion::TaxonomyCompletion, preview)
    rows = preview[coalesce.(preview.source_layer .== TAXONOMY_SOURCE, false), :]
    statuses = Dict{String,Int}()
    for l in completion.lookups
        l === nothing && continue
        statuses[string(l.status)] = get(statuses, string(l.status), 0) + 1
    end
    names = Dict{String,Vector{String}}()
    seen = Set{Tuple{String,String}}()
    for (c, n, l) in zip(completion.query_column, completion.query_name, completion.lookups)
        c === nothing && continue
        (c, n) in seen && continue
        push!(seen, (c, n))
        l.status === :found && continue
        push!(get!(names, string(l.status), String[]), "$c $n" * (isempty(l.detail) ? "" : " ($(l.detail))"))
    end
    per_rank = Dict{String,Any}()
    for c in TAXON_COLUMNS
        r = rows[rows.field .== c, :]
        nrow(r) == 0 && continue
        per_rank[c] = Dict("filled" => count(==("fill"), r.status), "already_matching" => count(==("unchanged"), r.status),
                           "conflict" => count(==("conflict"), r.status), "no_value" => count(==("no_value"), r.status),
                           "formula_preserved" => count(==("formula_preserved"), r.status),
                           "case_fixed" => count(==("case_fixed"), r.status))
    end
    return Dict{String,Any}(
        "source" => "BOLD Systems taxonomy API",
        "api" => completion.source,
        "retrieved_at" => completion.retrieved_at,
        "records_looked_up" => count(!isnothing, completion.query_column),
        "distinct_names" => completion.distinct_names,
        "network_lookups" => completion.network_lookups,
        "records_by_lookup_status" => statuses,
        "names_not_resolved" => names,
        "conflict_excel_rows" => unique(rows.excel_row[rows.status .== "conflict"]),
        "per_rank" => per_rank,
        "rule" => "only empty ranks above the lowest filled rank are filled; filled names only get standard " *
                  "capitalisation (BOLD spelling, else capital initial and lower-case epithets)",
    )
end
