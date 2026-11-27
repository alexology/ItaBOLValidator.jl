# ItaBOLValidator.jl

ItaBOLValidator reads BOLD Systems specimen submission workbooks (BOLD5 template),
validates their coordinates and enriches the geographic columns with values
extracted from **local, administrator-installed** geospatial datasets
(GeoPackage, Shapefile, GeoTIFF). It produces a new enriched workbook, a
processing report and a cell-by-cell preview; the uploaded workbook is never
modified. A Genie.jl web interface lives in [`web/`](web/README.md).

This project is part of an experimental effort, assisted by AI, to develop a
shared Julia environment for biodiversity workflows. Performance is a goal;
no performance advantage is claimed without measurements. The package is local
and has not been registered or published; it is released under the MIT licence
(see [License](#license)).

**Status.** All automated suites pass (see [Tests](#tests)). Polygon extraction
has been checked on the real ISTAT 2026 boundaries (see [Performance](#performance));
rasters only on synthetic data; specimens are synthetic records on the real,
empty BOLD5 template. It has **not** been run on a Linux VPS, with real
elevation, bathymetry or land-cover rasters, or with real submissions. Treat it
as ready for a staging trial, not as production-proven.

Contents: [Installation](#installation) · [Quick start](#quick-start) ·
[BOLD template requirements](#bold-template-requirements) ·
[Geographic datasets](#geographic-dataset-configuration) ·
[Supported fields](#supported-enrichment-fields) · [Workflow](#processing-workflow) ·
[Extraction engine](#extraction-engine) · [Reproducibility](#scientific-reproducibility) ·
[Limitations](#limitations) · [Performance](#performance) · [Tests](#tests) ·
[Troubleshooting](#troubleshooting)

## Installation

Tested with **Julia 1.13.4** on Windows 11. `[compat]` declares Julia 1.10, but
1.10–1.12 and Linux have not been tested. GDAL (3.13 via `GDAL_jll`) and PROJ are
installed by Julia's package manager; no system GDAL is needed.

```sh
cd ItaBOLValidator.jl
julia --project=. -e 'using Pkg; Pkg.instantiate()'
```

In PowerShell, run `using Pkg; Pkg.instantiate()` inside `julia --project=.` to
avoid quoting problems. Main dependencies: ArchGDAL 0.10.12, GDAL.jl 1.13,
XLSX 0.13.4 (compat pinned to 0.13: `src/parser.jl` uses two internal adapters),
DataFrames, CSV, ZipArchives (also used by XLSX), SHA and TOML.

## Quick start

```julia
using ItaBOLValidator

registry = load_registry("config/layers.toml"; geodata_root="/srv/itabol/geodata")
registry_report(registry)          # status, version, source, CRS, extent... per layer
mapping_report(registry)           # which BOLD columns are active

submission = read_bold("specimens.xlsx")
preview = preview_enrichment(submission, registry; identifier_header="SAMPLEID")

result = enrich_workbook(submission, registry, "enriched_output";
                         fields=["COUNTRY/OCEAN", "REGION", "ELEV"],   # default: all active
                         overwrite=String[],                          # default: preserve
                         identifier_header="SAMPLEID")
result.workbook                    # enriched_output/enriched.xlsx
close(registry)
```

`enriched_output/` (a new directory; existing paths are refused) contains:

| File | Content |
| --- | --- |
| `enriched.xlsx` | The original package with only the filled/overwritten cells changed |
| `report.toml` | Counts, reasons for missing values, unmapped categories, ambiguous rows, datasets and versions |
| `changes.csv` | The preview: every specimen × selected field, original, proposed, source, status, detail |

Validation without enrichment (phase 1) is still available:
`validation_report(submission)` and `export_validation(submission, dir)` (byte
copy of the workbook plus a coordinate CSV and a manifest).

## BOLD template requirements

- `.xlsx` workbook with an exact, case-sensitive `Submissions` sheet.
- One header row of 50 unique, contiguous, nonempty literal text names; position
  and order may vary. All 14 geographic names must be present:

  ```text
  COUNTRY/OCEAN  PROVINCE/STATE  REGION  SECTOR  SITE
  COORD:LAT  COORD:LON  ELEV  DEPTH  ELEV_ACCURACY
  DEPTH_ACCURACY  COORD_SOURCE  COORD_ACCURACY  HABITAT
  ```

- The header is found automatically in the first 100 rows
  (`read_bold(path; header_row=3)` or `max_header_rows=200` otherwise). Missing or
  duplicate names, wrong column counts and values outside the header span are errors.
- Empty rows are skipped without ending the table; original Excel row numbers are
  kept as stable record references. Identifiers are not required to be unique.
- The supplied empty template is an unchanged test fixture:
  `test/data/BOLD5_BCDM_Specimen_Submission_SinglePage.xlsx` (one sheet, headers in
  `A1:AX1`, a drawing with embedded media, custom column widths, no validations
  and no formulas).

Coordinates come only from `COORD:LAT` and `COORD:LON`, as WGS84 decimal degrees
(dot decimal separator, optional sign/exponent; ranges inclusive). Statuses:
`valid`, `missing`, `invalid_format` (decimal comma, DMS, hemisphere letters,
Excel errors...), `nonfinite`, `out_of_range`, `formula` (cached formula results
are never trusted). Coordinates are never swapped, clamped, inferred or rewritten;
invalid points are kept and reported, never enriched.

## Geographic dataset configuration

Layers are declared by the server administrator in a TOML registry; users cannot
add or change them. [`config/layers.toml`](config/layers.toml) is a commented
example with country, Italian region and province polygons, a DEM, bathymetry,
land cover and habitat rasters. Its paths, attributes, versions and sources are
placeholders to replace with the installed datasets.

```toml
schema_version = 1
geodata_root = "../data"          # optional; must lie inside the approved root

[[layers]]
id = "italy_region"               # unique, lowercase
name = "Italian region"
type = "vector"                   # or "raster"
path = "admin/istat_regions.shp"  # relative to the geodata root
attribute = "DEN_REG"             # exact, case-sensitive field
output = "region"                 # output field name
overlap = "ambiguous"             # required for vectors
boundary = "exclude"
version = "2024-01-01"
source = "ISTAT, CC BY 3.0"
enabled = true

[[bold_fields]]
column = "PROVINCE/STATE"          # in Italy the Regione (see "Supported enrichment fields")
layers = ["italy_region"]          # first layer with a value wins
```

Per-layer keys:

| Key | Layers | Meaning |
| --- | --- | --- |
| `id`, `name`, `type`, `path`, `output`, `version`, `source` | all | required identity, provenance and output name |
| `enabled`, `description`, `assume_crs` | all | `assume_crs` only for datasets that declare no CRS |
| `attribute`, `layer` | vector | field to extract; GeoPackage layer name |
| `overlap` | vector | `ambiguous`, `lowest_fid`, `highest_fid`, `smallest_area`, `largest_area`, `min_attribute`/`max_attribute` (+ `overlap_attribute`); ties → lowest FID |
| `boundary`, `boundary_tolerance` | vector | `exclude` (default), `include`, `prefer_inside`; tolerance in layer CRS units |
| `kind`, `band`, `nodata`, `apply_scale` | raster | `categorical`/`continuous`; band (default 1); `"dataset"`, `"none"` or a number |
| `categories` | categorical | `"dataset"` or a code → label table, for display only |
| `value_map` | vector, categorical | explicit table from extracted value/code to output value |
| `unit`, `conversion`, `valid_min`, `valid_max`, `digits`, `measure` | continuous | output unit; `{from = "cm"}` or `{factor, offset}`; range check; rounding; `elevation`, `depth` or `other` |

**Validation at startup** (`load_registry`): TOML syntax and schema (unknown keys
are errors), file existence, vector attributes (exact case) and raster bands,
CRS presence and validity (a transformation from WGS84 must exist), polygonal
geometry, integer bands for categorical layers. Problems are reported per layer
(`invalid`, `unavailable`, `disabled`) and logged; valid layers stay usable and the
application keeps running. Paths must be relative, without `..`, and must stay
inside the approved geodata directory after resolving symbolic links and every
file GDAL opens (sidecars included). Only the GPKG, ESRI Shapefile and GTiff
drivers are allowed, so VRT, WMS or `/vsicurl/` indirection cannot reach other
files or the network.

**Installing datasets.** Copy files under the geodata root (read-only for the
service user), keep each dataset's original name or a versioned one
(`istat_regions_2024.shp`), make sure Shapefiles include `.prj` (or set
`assume_crs`), and build a spatial index for large Shapefiles
(`ogrinfo file.shp -sql "CREATE SPATIAL INDEX ON file"`; GeoPackages have an
R-tree). Rasters should be tiled GeoTIFFs (for example
`gdal_translate -co TILED=YES -co COMPRESS=DEFLATE in.tif out.tif`); untiled
single-strip files are read in capped windows but can be slow. Then update
`version`/`source` and restart the service; check `registry_report`.

## Supported enrichment fields

| BOLD column | Allowed source | Rule |
| --- | --- | --- |
| `COUNTRY/OCEAN`, `PROVINCE/STATE`, `REGION`, `SECTOR`, `SITE` | polygon layers only | the attribute of the polygon containing the point; administrative regions never come from rasters |
| `ELEV` | continuous raster, `unit = "m"`, `measure = "elevation"` | DEM value at the pixel containing the point |
| `DEPTH` | continuous raster, `unit = "m"`, `measure = "depth"` | a DEM can never fill DEPTH; with the default land check, DEPTH is not proposed where the ELEV layer reports > 0 m |
| `HABITAT` | categorical raster or vector **with an explicit `value_map`** | land-cover codes or labels are never used as BOLD terms by themselves; unmapped codes stay empty and are reported |
| `ELEV_ACCURACY` | elevation rasters (as for `ELEV`) in a projected CRS, with `vertical_accuracy` | see below; only where the record's ELEV is that layer's elevation |
| `COORD:LAT`, `COORD:LON`, `COORD_SOURCE`, `COORD_ACCURACY`, `DEPTH_ACCURACY` | never | refused by the registry and by the workflow |

**ELEV_ACCURACY** (metres, BCDM "accuracy of the elevation value") combines the
two sources of error of an elevation read from a DEM at the specimen's
coordinates:

```text
ELEV_ACCURACY = ceil( sqrt( vertical_accuracy^2 + relief^2 ) )
```

- `vertical_accuracy`: the RMSE of the model, declared on the layer (TINITALY:
  3.5 m, Tarquini et al. 2007, https://doi.org/10.4401/ag-4424).
- `relief`: the largest difference between the elevation at the point and any
  valid DEM cell whose centre lies within the coordinate uncertainty, i.e. how
  much the elevation can change if the specimen was anywhere in that circle.
  The radius is `COORD_ACCURACY`, which BCDM gives in **decimal degrees**
  (converted with 111,320 m per degree, the largest length of a degree, so the
  radius is never underestimated); when it is empty, the mapping's
  `default_coord_accuracy` (30 m in the shipped registries) is assumed and the
  report says so (`coord_accuracy_assumed`, and "radius assumed" in each
  change's `detail`).
- No value when: COORD_ACCURACY is not a number (`coord_accuracy_invalid`);
  the radius exceeds `max_coord_accuracy` (5000 m; typically metres written
  instead of degrees: `coord_accuracy_too_large`); the record's final ELEV is
  not the DEM elevation of the same layer, for instance a value measured in the
  field (`elev_not_from_layer`); the DEM has no value at the point.

Example (TINITALY): a point in the plain near Pisa with COORD_ACCURACY empty gets 4 m; near the
top of the Gran Sasso, 0.0003 degrees (33 m) of uncertainty give 31 m.
`layer_relief(points, registry, id; radius)` and `extract_relief` expose the
relief computation.

Which administrative level feeds each column is a registry decision. The
example follows the BCDM definitions: `PROVINCE/STATE` is "the state, province,
territory, or prefecture within the given country", i.e. the first level below
the country, which in Italy is the **Regione** (ISTAT `DEN_REG`, e.g. Toscana);
`REGION` is "park, county, district, lake or river", i.e. the level below, the
**Provincia / Città metropolitana** (ISTAT `DEN_UTS`, e.g. Pisa). `SECTOR` is
"the lake, conservation area or sector of park" where the organism was
collected, so it is **not** the Comune: it needs a layer of lakes or protected
areas (e.g. EUAP, Natura 2000) mapped explicitly. `SITE` stays with the
collector. BOLD refers to the Getty Thesaurus of Geographic Names for
states/provinces: ISTAT's bilingual names (e.g. "Valle d'Aosta/Vallée d'Aoste",
"Trentino-Alto Adige/Südtirol") may need a `value_map` to the Getty form.

## Processing workflow

1. `read_bold` parses the workbook in read mode and records its SHA-256.
2. Valid points are transformed once per layer from WGS84 to the layer CRS.
3. Each mapping tries its layers in order; the first value supplied wins.
   Statuses explain absences: `outside_extent`/`outside_coverage`, `no_match`,
   `boundary`, `ambiguous`, `nodata`, `masked`, `unmapped`, `out_of_range`,
   `transform_failed`, `invalid_coordinate`.
4. For each specimen and selected field: empty cell → `fill`; non-empty cell →
   `preserved` (default), `overwrite` (only for fields listed in `overwrite`) or
   `unchanged` (already equal); formula cells → `formula_preserved` (never
   replaced); no reliable value → `no_value`; invalid coordinates →
   `invalid_coordinates`. Missing information stays missing.
5. `enrich_workbook` copies every package part byte for byte and edits only the
   target `<c>` elements of the `Submissions` worksheet (inline strings, original
   cell style kept). Before publishing, it re-reads the result and compares every
   cell with the original and the intended edits, checks that all other parts are
   identical, and verifies that the source workbook has not changed.

Verified independently: the enriched files open in Microsoft Excel 16 (read-only
automation) and openpyxl 3.1.5 with values, formulas, styles, the second sheet and
the template drawing intact.

## Taxonomy completion (BOLD taxonomy API)

`complete_taxonomy(submission, client)` fills **empty higher ranks only**
(`PHYLUM`, `CLASS`, `ORDER`, `FAMILY`, `SUBFAMILY`, `TRIBE`, `GENUS`, `SPECIES`)
from the lowest filled rank of each record; pass the result to
`preview_enrichment`/`enrich_workbook` as `taxonomy` (with `fields=String[]` to
run it alone).

```julia
client = BoldTaxonomyClient()                 # 1 request/s, cache 7 days, 100 names per run
completion = complete_taxonomy(submission, client)
result = enrich_workbook(submission, registry, "out"; taxonomy=completion)
```

`record_taxonomy(values, client)` applies the same rules to one record given
as `column => value` (the review page uses it when a taxonomic cell is edited)
and returns the lookup and one row per concerned rank (`fill`, `case_fixed`,
`unchanged`, `conflict`, `no_value`).

Rules:

- The query is the lowest filled rank holding a plain name (SUBSPECIES ≥ 3 words,
  SPECIES 2, higher ranks 1). Open nomenclature (`sp.`, `cf.`, `aff.`, `nr.`, …),
  digits and symbols are not looked up; the next filled higher rank is used.
  When it is PHYLUM nothing is looked up.
- Only empty ranks **above** the query are filled; lower ranks are never touched.
  Filled ranks are never changed: equal to BOLD (case ignored) → `unchanged`;
  different → `conflict`, and nothing is filled for that record.
- Homonyms are never resolved: when BOLD has the same name in different kingdoms,
  phyla, classes, orders or families, the record gets `no_value` with the
  candidate lineages. Example: *Prunella* (Lamiaceae and Prunellidae).
- Names are matched ignoring case and spacing; written values use BOLD's spelling.
- Source: one request `GET /api/terms?partial_term=<name>&limit=1000`. Every
  taxonomic entry whose path holds the name at the queried rank counts (BOLD often
  lists only the species of a genus); paths of one taxon are merged and ranks on
  which they disagree are left empty. Entries are ranked by number of records, so
  a full page (1,000 entries) could hide a homonym or the taxon itself: such a
  name is reported as not verifiable and nothing is filled. (*Bombus*, with 339
  entries, fits easily.)
- Limits: one request at a time in the whole process (all clients), `min_interval` seconds apart
  (default 1 s); HTTP 429/5xx retried twice honouring `Retry-After` (≤ 60 s);
  after a final 429/403 no request is sent for 10 minutes (lookups `skipped`);
  `max_lookups` distinct new names per run (default 100), cached names excluded;
  results cached for 7 days.
- The report has a `taxonomy` section: API, retrieval time (UTC), lookups,
  unresolved names, conflict rows and counts per rank. BOLD's taxonomy changes
  over time; keep the report with the enriched workbook.
- Privacy: only taxon names are sent to BOLD; coordinates and other metadata are
  not.

Checked against the live API on 2026-11-24 with four names (four requests):
*Bombus terrestris* (Animalia … Bombini > Bombus), *Prunella* (homonym:
Plantae/Aves), *baetis* (Baetidae > Baetinae > Baetis; the term search lists only
its species) and *Quercus robur* (Fagaceae > Quercoideae > Quercus).

## Compliance checks and review

`load_compliance("config/compliance.toml")` reads two rule profiles;
`check_compliance(submission, rules)` evaluates every record:

- **BOLD compliant**: passes every error rule of `[bold]`. BOLD has not published
  the required BCDM fields (the BCDM README lists them as pending), so the
  profile uses the minimum for a new record from the BOLD v4 Handbook — SAMPLEID,
  FIELDID or MUSEUMID, INST, PHYLUM, COUNTRY/OCEAN — plus BCDM formats: unique
  SAMPLEID, COUNTRY/OCEAN from BOLD's country registry (268 names),
  IDENTIFICATION_METHOD from the BCDM vocabulary, dates `YYYY-MM-DD`, numeric
  ELEV/DEPTH/accuracies, coordinates in decimal degrees (pair complete,
  latitude ±90, longitude ±180). Sources and commit are listed in the file.
- **ItaBOL compliant** (criteria of 2026-11-27): BOLD compliant and passes
  every error rule of `[itabol]`: coordinates required (decimal degrees, both
  filled, in range) and identification at least to genus or species (GENUS,
  SPECIES or SUBSPECIES filled).
- Rule kinds: `required`, `any_of`, `unique`, `vocabulary`, `date`, `number`,
  `coordinates`, `pattern`; `severity = "warning"` reports without failing.
- WGS84 cannot be verified from numbers: decimal format and ranges are checked,
  and the review page explains the usual errors (comma decimal separator,
  degrees-minutes-seconds, projected UTM values, swapped latitude/longitude).

`review_edit` and `save_reviewed(submission, edits, path)` write user edits to a
new workbook with the same targeted cell editing as the enrichment (cleared
cells keep their style; formula cells are refused; the result is re-read and
compared). `layer_outlines(catalog, id)` returns simplified WGS84 outlines of a
local polygon layer for offline overview maps (display only), and `basemap_layer`
chooses the layer (the web app's review map uses OpenStreetMap instead).

## Extraction engine

The workflow uses a reusable engine (`GeoExtraction`), also usable directly:

```julia
points = GeoPoints(latitudes, longitudes)           # or a BOLDSubmission
extract_vector(points, VectorLayer("reg", "regions.gpkg"; attributes=["DEN_REG"], overlap=:ambiguous))
extract_raster(points, RasterLayer("dem", "dem.tif"; kind=:continuous))
catalog = GeoCatalog([layer1, layer2]); extract_geodata(points, catalog); close(catalog)
```

- **CRS.** Input is EPSG:4326; every dataset's CRS is read from the file and
  points are transformed with OGR/PROJ in traditional GIS axis order (x =
  longitude). Failed points (outside a projection's domain) become
  `transform_failed`; tests check UTM round trips, LAEA and a closed-form Web
  Mercator formula.
- **Polygons.** Points are grouped into compact tiles; each tile issues one
  spatial-filter query (GeoPackage R-tree, Shapefile `.qix`, or an in-memory
  envelope index built at open for unindexed layers) and tests candidates with
  GEOS prepared geometries. `contains` means the interior; boundary points are
  distinguished and handled by the `boundary` policy; holes are respected.
- **Rasters.** The pixel is found with the full affine inverse of the
  geotransform (rotation terms included); points on an internal pixel edge
  belong to the pixel right/below, the outer right/bottom edges are outside.
  Only the blocks containing points are read. Values are never interpolated;
  categorical codes keep the band's integer type; NoData (declared value, NaN,
  or an override) gives `nodata`; a GDAL mask band that does not derive from NoData
  (per-dataset or per-band mask, `.msk`, alpha channel) is honoured: mask value 0 gives `masked`.
- **Handles.** A `GeoCatalog` opens each dataset once and serializes its use with a
  per-dataset lock; `close` releases everything. Per-tile GEOS/OGR geometries
  are freed explicitly.

ArchGDAL 0.10 note: `getgeotransform`, `setgeotransform!`, `invgeotransform` and
`transform!` pass `pointer(array)` without `GC.@preserve`; on Julia 1.13 inside
compiled functions this silently returned the default geotransform. The engine
calls GDAL.jl with rooted arrays instead (see `src/geo/crs.jl`).

## Scientific reproducibility

- Every report records the source and enriched SHA-256, the fields, the
  overwrite list, options, and for every dataset its id, name, version and
  source; `changes.csv` records the source layer and reason for every cell.
- Results depend only on the input, the registry and the dataset files: overlap
  and tie rules are deterministic (FID order), tiling never changes results
  (tested), and no network service is queried.
- Keep the registry and datasets under version control or in dated, read-only
  directories; never replace a dataset in place without changing `version`.
- Values are copied as stored in the datasets (optionally rounded with `digits`
  and converted with documented factors); no value is inferred or interpolated.

## Limitations

- Only point-in-polygon and pixel sampling for the values themselves; no
  buffers around imprecise coordinates and no nearest-feature search.
  `COORD_ACCURACY` is used only for ELEV_ACCURACY (the relief within it).
- CRS transformations use PROJ without network grids: datum shifts such as Monte
  Mario → WGS84 use the parameters in the CRS definition (metre-level accuracy),
  not NTv2/grid files.
- `smallest_area`/`largest_area` use planar areas in the layer CRS (degrees² for
  geographic layers).
- The DEPTH land check relies on an ELEV layer; inland waters need a dedicated
  depth dataset and `depth_land_check=false`.
- Formulas elsewhere in the sheet keep cached results until a spreadsheet program
  recalculates (`worksheet_formulas` in the report counts them).
- Only `.xlsx` (no `.xls`, `.xlsm`, `.ods`); worksheet XML with cells lacking `r`
  references is supported, rows missing from the sheet are not.
- No validation of BOLD vocabulary beyond explicit `value_map` tables.
- Taxonomy completion needs outbound HTTPS to portal.boldsystems.org and follows
  BOLD's current taxonomy, which is not versioned; homonyms and conflicts are
  left to the user. The BOLD API publishes no rate limit; the client stays at
  one request per second by default.
- Memory: the whole workbook and its worksheet XML are held in memory (see below).

## Performance

`bench/enrichment_scaling.jl` builds synthetic layers in EPSG:32632 (one
20,000-vertex country polygon, 20 regions, 110 provinces, 8,000 × 12,000 Int16 DEM
and UInt8 habitat rasters, tiled and DEFLATE-compressed) and workbooks from the
real BOLD5 template with 20 filled columns, then enriches five fields (country,
region, province, ELEV, HABITAT) in a fresh process per size, after a warm-up
that excludes compilation. Windows 11, i7-9750H, Julia 1.13.4, 2 threads,
`GDAL_CACHEMAX=256`:

| Specimens | Workbook | `read_bold` | `enrich_workbook` | Peak RSS |
| ---: | ---: | ---: | ---: | ---: |
| 100 | 0.1 MB | 0.02 s | 0.29 s | 782 MB |
| 1,000 | 0.2 MB | 0.10 s | 0.99 s | 895 MB |
| 10,000 | 1.4 MB | 0.96 s | 4.09 s | 1,097 MB |
| 100,000 | 13.1 MB | 9.91 s | 31.72 s | 2,199 MB |

The process uses about 770–785 MB after loading the packages and a warm-up; the
increase comes from the workbook (held in memory and re-read for verification),
the extraction tables and GDAL's block cache.

Times include the full re-read verification of the enriched workbook.
**These are synthetic results.** Real national datasets have far more vertices
(municipal and coastline boundaries), less compressible rasters and larger
files, so extraction will be slower; measure with the installed datasets before
setting `ITABOL_MAX_RECORDS`. `bench/geo_batch.jl` measures the engine alone
(100,000 points, 10,000 polygons).

**Real ISTAT boundaries.** `bench/real_boundaries.jl` uses the ISTAT
"Limiti 01/01/2026" Shapefiles at full resolution (7,896 municipalities, 110
provinces/metropolitan cities, 20 regions, 5 geographic divisions; EPSG:32632;
no `.qix`, so the in-memory envelope index is used). Same machine, 2 threads:

- the registry validated all four layers in 1.9 s;
- 13/13 reference places gave the expected region, province and municipality,
  including the exclave Campione d'Italia and Lampedusa; San Marino, the
  Vatican, Lugano and the open sea gave `no_match` (ISTAT names Aosta Valley's
  supra-municipal unit `Valle d'Aosta/Vallée d'Aoste`);
- an independent even-odd ray-casting implementation agreed with the engine on
  **5,000/5,000** random points (1,187 inside a municipality);
- extracting all four layers took 0.98 s for 1,000 points, 1.53 s for 10,000 and
  2.6 s for 100,000 (peak RSS 1.1 GB); enriching template workbooks with four
  fields took 2.6 s (1,000 specimens), 3.9 s (10,000) and 26.8 s plus 10.0 s
  reading (100,000; peak RSS 1.9 GB).

Rasters were not part of this real-data test (no real DEM or land cover was
available). Before this review, polygons were re-read and re-prepared for every
tile; with these coastlines that cost 12.5 s even for 1,000 points. A bounded
LRU cache of prepared polygons (64 MB of geometry per extraction) fixed it.

## Tests

```sh
julia --project=. --threads=2 test/runtests.jl          # all core suites
julia --project=. test/run_pkg_tests.jl                 # same, isolated Pkg.test
julia --project=. --check-bounds=yes test/runtests_phase1.jl   # parser only
julia --project=web --threads=2 -e 'using Pkg; Pkg.test()'     # web integration
python web/test/browser_check.py OUTDIR                 # headless Chrome UI check (Playwright)
```

Results on Julia 1.13.4, Windows 11, 2 threads (2026-11-23):

| Suite | Result |
| --- | --- |
| `Pkg.test()` (bounds checking on): parser, coordinates, real-template, engine, registry, enrichment, taxonomy (offline fake of the BOLD API), compliance, review edits, map outlines | **4,509/4,509** passed |
| `test/runtests_phase1.jl` with `--check-bounds=yes` | **608/608** passed |
| Web integration (`Pkg.test()` in `web/`) | **185/185** passed |
| Headless Chrome workflow (`browser_check.py`, Playwright 1.x + Chrome) | passed, no console or CSP errors, no horizontal overflow at 390 px |
| Excel 16 (COM, read-only) and openpyxl 3.1.5 on enriched files, including the real template with its drawing and an overwrite run | values, formulas, styles and sheets as expected |
| Static checks (`pkgcheck`: Aqua 8/8, ExplicitImports, docstrings) | clean; JET: 0 findings in `web/`, 2 in the core, both inside XLSX.jl's union-typed `eachrow` iterator (cannot occur with the cache disabled) |

Not executed: Linux, Julia 1.10–1.12, the national DEM (only two TINITALY 1.1 tiles checked, see
[data/README.md](data/README.md)), a real bathymetry or land-cover raster,
real specimen submissions, an upload to BOLD, a deployment behind nginx/systemd.
`pkgcheck` also reports no Git repository, which is a pending decision rather
than a defect.

All data are synthetic or generated at test time; no network access is needed.

## Troubleshooting

| Symptom | Cause and remedy |
| --- | --- |
| Layer `unavailable` | File missing under the geodata root; check `path` relative to the root |
| Layer `invalid`: "declares no CRS" | Shapefile without `.prj`; add it or set `assume_crs` |
| Layer `invalid`: attribute not found | Field names are case-sensitive; the message lists the available fields |
| Mapping `invalid` | See `mapping_report`: e.g. ELEV without `measure = "elevation"`, HABITAT without `value_map` |
| Many `outside_coverage`/`outside_extent` | Points outside the dataset; check coordinate order in the workbook (latitude in `COORD:LAT`) |
| `boundary` statuses | Points exactly on borders; use `boundary = "prefer_inside"` or a small `boundary_tolerance` |
| `unmapped` in HABITAT | Code missing from `value_map`; the report lists codes and counts |
| `TemplateError` | Workbook does not match the BOLD5 header contract (see above) |
| `WorkbookStructureError` | Unusual worksheet XML (e.g. missing rows); the original is untouched, report the file |
| Slow raster extraction | Untiled or very large blocks; re-tile the GeoTIFF |
| High memory | Lower `GDAL_CACHEMAX`, limit records, enable one job at a time |

## License

MIT (see [`LICENSE`](LICENSE)); it covers the code, including `web/`. Geographic
datasets are not distributed with the package and keep their own licences: record
each one in the `source` field of the registry and honour its attribution terms
in reports and publications (for example TINITALY 1.1 is CC BY 4.0 and must be
cited as indicated by INGV).

## Project layout

```text
src/ItaBOLValidator.jl        package entry point
src/parser.jl, coordinates.jl, reports.jl   BOLD parsing, validation, phase-1 export
src/geo/                      extraction engine (points, CRS, vector, raster, catalog)
src/registry/                 layer registry, validation, BOLD mappings
src/enrichment/               preview, OOXML cell editing, enriched workbook, report
config/layers.toml            example registry
bench/                        synthetic benchmarks
test/                         synthetic tests; test/data holds the empty BOLD5 template
web/                          Genie.jl web interface (separate project), systemd/nginx files
deploy/                       Docker image, Compose + Caddy files, production layers.toml (see deploy/README.md)
.github/workflows/            container image (ghcr.io) and Linux tests
data/                         local datasets (not distributed)
```
