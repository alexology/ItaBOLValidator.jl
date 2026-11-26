"""
Web interface (Genie.jl) for enriching BOLD specimen workbooks with metadata
from server-side geospatial layers and with higher taxonomic ranks from the
BOLD taxonomy API. All processing is delegated to ItaBOLValidator (`read_bold`,
`load_registry`, `complete_taxonomy`, `enrich_workbook`); this package adds only
HTTP handling, sessions, limits and the page (in Italian).
"""
module ItaBOLWeb

import Genie
import HTTP
import JSON3
import Sockets
import TOML
import ZipArchives
using Random: RandomDevice
using ItaBOLValidator: read_bold, load_registry, enrich_workbook, TemplateError,
    WorkbookStructureError, GeoRegistry, BOLD_TARGET_COLUMNS, isvalid, BoldTaxonomyClient,
    complete_taxonomy, taxonomy_queries, TAXON_COLUMNS, ComplianceRules, load_compliance, compliance_spec,
    check_compliance, compliance_summary, review_edit, save_reviewed
import ItaBOLValidator

export WebConfig, config_from_env, serve, shutdown

include("config.jl")
include("sessions.jl")
include("limits.jl")
include("server.jl")
include("review.jl")
include("memory.jl")

end
