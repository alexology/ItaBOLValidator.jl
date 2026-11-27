"""
Read BOLD5 specimen workbooks, validate coordinates without rewriting Excel files,
extract attributes and raster values from local geospatial datasets, complete
higher taxonomic ranks from the BOLD taxonomy API, and write enriched copies of
the workbook. The web interface is the separate `ItaBOLWeb` project in `web/`.
"""
module ItaBOLValidator

import CSV
import Dates
import Downloads
import JSON3
import XLSX
import ZipArchives
using DataFrames: DataFrame, nrow
using SHA: sha256
import TOML

include("coordinates.jl")
using .CoordinateValidation: CoordinateValue, CoordinatePair, validate_coordinate,
    validate_coordinates, isvalid

include("geo/GeoExtraction.jl")
using .GeoExtraction: GeoPoints, geopoints, GeoLayer, VectorLayer, RasterLayer, GeoCatalog,
    GeoDatasetError, layer_names, layer_info, extract_vector, extract_raster, extract_relief,
    extract_geodata, layer_outlines

export GEOGRAPHIC_HEADERS, BOLDSubmission, TemplateError, read_bold,
    CoordinateValidation, CoordinateValue, CoordinatePair, validate_coordinate,
    validate_coordinates, isvalid, validation_report, export_validation,
    GeoExtraction, GeoPoints, geopoints, GeoLayer, VectorLayer, RasterLayer, GeoCatalog,
    GeoDatasetError, layer_names, layer_info, extract_vector, extract_raster, extract_relief,
    extract_geodata,
    LayerRegistry, GeoRegistry, RegistryLayer, BoldFieldMapping, load_registry, registry_report,
    mapping_report, available_layers, layer_metadata, extract_layers, propose_bold_fields, layer_relief,
    BOLD_TARGET_COLUMNS, BOLD_PROTECTED_COLUMNS,
    preview_enrichment, enrich_workbook, WorkbookStructureError,
    TAXON_COLUMNS, TAXONOMY_SOURCE, BoldTaxonomyClient, TaxonLookup, TaxonomyCompletion, lookup_taxon,
    taxon_query, taxon_case, taxonomy_queries, complete_taxonomy, record_taxonomy, layer_outlines,
    ComplianceRules, ComplianceProfile, load_compliance, compliance_spec, check_compliance, compliance_summary,
    ReviewEdit, review_edit, save_reviewed, REVIEW_NUMERIC_COLUMNS, basemap_layer, csv_safe

include("registry/LayerRegistry.jl")
using .LayerRegistry: GeoRegistry, RegistryLayer, BoldFieldMapping, load_registry, registry_report,
    mapping_report, available_layers, layer_metadata, extract_layers, propose_bold_fields, layer_relief,
    BOLD_TARGET_COLUMNS, BOLD_PROTECTED_COLUMNS

include("parser.jl")
include("reports.jl")

"""Use the validated `COORD:LAT`/`COORD:LON` results of a parsed submission."""
GeoExtraction.geopoints(submission::BOLDSubmission) = GeoPoints(submission.coordinates)

include("enrichment/ooxml.jl")
include("taxonomy/bold_taxonomy.jl")
include("enrichment/workflow.jl")
include("enrichment/review.jl")
include("compliance/compliance.jl")

"""
    basemap_layer(registry; layer=nothing) -> Union{Nothing,String}

Id of the vector layer used for overview maps: `layer` when given (it must be
an available vector layer), otherwise the available vector layer with the most
features up to 500 (for example provinces rather than municipalities), or the
smallest one. `nothing` when no vector layer is available.
"""
function basemap_layer(registry::GeoRegistry; layer::Union{Nothing,AbstractString}=nothing)
    vectors = [l for l in registry.layers if l.status === :available && l.type === :vector]
    if layer !== nothing
        any(l -> l.id == layer, vectors) || throw(ArgumentError("Basemap layer $(repr(layer)) is not an available vector layer"))
        return String(layer)
    end
    isempty(vectors) && return nothing
    count_of(l) = (n = LayerRegistry._meta(l, :features); n isa Integer ? Int(n) : typemax(Int))
    small = [l for l in vectors if count_of(l) <= 500]
    return isempty(small) ? argmin(count_of, vectors).id : argmax(count_of, small).id
end

end
