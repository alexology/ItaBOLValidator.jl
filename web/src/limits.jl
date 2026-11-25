# Per-client limits for an open service without accounts: requests per time
# window for the expensive endpoints, requests in progress at the same time and
# open sessions per client. A client is its IP address (the last entry of
# X-Forwarded-For when the server runs behind a trusted proxy).

"""Endpoints with a per-client rate limit, by (method, path)."""
const LIMITED_ENDPOINTS = Dict(
    ("POST", "/api/upload") => :upload,
    ("POST", "/api/enrich") => :enrich,
    ("POST", "/api/review") => :review,
    ("GET", "/api/table") => :read,
    ("GET", "/api/download") => :read,
)

"""Request times per (client, kind) and requests in progress per client."""
mutable struct ClientLimits
    lock::ReentrantLock
    events::Dict{Tuple{String,Symbol},Vector{Float64}}
    inflight::Dict{String,Int}
end
ClientLimits() = ClientLimits(ReentrantLock(), Dict{Tuple{String,Symbol},Vector{Float64}}(), Dict{String,Int}())

function _rate(config, kind::Symbol)
    kind === :upload && return config.rate_uploads
    kind === :enrich && return config.rate_enrichments
    kind === :review && return config.rate_saves
    return config.rate_reads
end

"""
The client of a request: the peer address, or with `trust_forwarded` the last
address of `X-Forwarded-For`, which a proxy such as Caddy appends (enable it only
when the server is reachable through that proxy alone).
"""
function client_address(config, stream::HTTP.Stream)
    if config.trust_forwarded
        forwarded = HTTP.header(stream.message, "X-Forwarded-For")
        if !isempty(forwarded)
            last_hop = strip(last(split(forwarded, ',')))
            isempty(last_hop) || return String(first(last_hop, 64))
        end
    end
    return string(stream.stream.peerip)
end

"""
Record one request of `kind` by `client`; return 0 when allowed, otherwise the
seconds until a request is allowed again (nothing is recorded).
"""
function admit!(limits::ClientLimits, client::AbstractString, kind::Symbol, max_requests::Integer,
                window::Real; now::Float64=time())
    max_requests <= 0 && return 0                         # limit disabled
    return lock(limits.lock) do
        times = get!(Vector{Float64}, limits.events, (String(client), kind))
        filter!(t -> now - t < window, times)
        if length(times) >= max_requests
            return max(1, ceil(Int, window - (now - first(times))))
        end
        push!(times, now)
        return 0
    end
end

"""Start a request of `client`; false when it already has `max_inflight` in progress."""
function enter!(limits::ClientLimits, client::AbstractString, max_inflight::Integer)
    max_inflight <= 0 && return true
    return lock(limits.lock) do
        n = get(limits.inflight, client, 0)
        n >= max_inflight && return false
        limits.inflight[String(client)] = n + 1
        return true
    end
end

function leave!(limits::ClientLimits, client::AbstractString)
    lock(limits.lock) do
        n = get(limits.inflight, client, 0) - 1
        n <= 0 ? delete!(limits.inflight, client) : (limits.inflight[client] = n)
    end
    return nothing
end

"""Forget request times older than `window` (called by the cleanup sweep)."""
function prune!(limits::ClientLimits, window::Real; now::Float64=time())
    lock(limits.lock) do
        for (key, times) in collect(limits.events)
            filter!(t -> now - t < window, times)
            isempty(times) && delete!(limits.events, key)
        end
    end
    return nothing
end

const LOOPBACK_NAMES = ("127.0.0.1", "localhost", "::1")

"""
Accepted `Host` names: the configured allow-list; without one, only loopback
names when the server listens on loopback (a malicious page using DNS
rebinding cannot reach a development server), otherwise any host, with a warning.
"""
function accepted_hosts(config)
    isempty(config.allowed_hosts) || return Set(lowercase.(config.allowed_hosts))
    config.host in LOOPBACK_NAMES && return Set(LOOPBACK_NAMES)
    @warn "ITABOL_ALLOWED_HOSTS is empty: requests with any Host header are accepted. Set it to the public domain."
    return Set{String}()
end
