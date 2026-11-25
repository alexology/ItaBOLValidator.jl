# Standalone parser/coordinate tests, independent of the later geospatial suites.
using Test
using ItaBOLValidator
import XLSX
import CSV
import TOML
using DataFrames: DataFrame, names, nrow
using SHA: sha256

include("fixtures.jl")
include("coordinates.jl")
include("parser.jl")
include("reports.jl")
include("template.jl")
