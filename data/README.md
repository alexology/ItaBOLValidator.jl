# Local geodata (development)

Directory for local GeoPackage, Shapefile and GeoTIFF datasets during
development. `config/layers.toml` uses it as its `geodata_root`. Dataset files and
uploaded workbooks are not included in the package and are ignored by Git.

In production the datasets live in an administrator-approved directory such as
`/srv/itabol/geodata`, passed as `geodata_root` / `ITABOL_GEODATA_ROOT`; see
`README.md` ("Geographic dataset configuration") and `web/README.md`.

## Elevation: TINITALY 1.1 (INGV)

`config/layers.toml` expects the DEM at `dem/tinitaly_1_1.tif`.

- Dataset: TINITALY 1.1, 10 m DEM of Italy, Tarquini S., Isola I., Favalli M.,
  Battistini A., Dotta G. (2023), INGV, <https://doi.org/10.13127/tinitaly/1.1>.
  Licence CC BY 4.0: cite it as above in reports and publications.
- Official download: <https://tinitaly.pi.ingv.it/Download_Area1_1.html>,
  193 zipped tiles of 50 × 50 km (for example `data_1.1/w48060_s10/w48060_s10.zip`,
  about 78 MB; name = `w` + northing and easting of the lower-left corner in units
  of 10 km). Each tile is an uncompressed Float32 GeoTIFF of 5010 × 5010 cells,
  EPSG:32632, NoData -9999 (sea and outside Italy), with 10 cells of overlap
  between neighbours.
- WCS (GeoServer, WCS 2.0.1/1.1.x):
  `https://tinitaly.pi.ingv.it/TINItaly_1_1/wcs`, coverage
  `TINItaly_1_1__tinitaly_dem`, native grid origin 312500 E / 5222500 N, 10 m,
  100750 × 129250 cells. Useful to fetch a small area; a request aligned to the
  native grid with `format=image/tiff` returns the tile values unchanged (no
  resampling). The application never calls it at run time: datasets must be local.

Build one tiled, compressed GeoTIFF from the downloaded tiles (GDAL ≥ 3.1):

```sh
gdalbuildvrt -srcnodata -9999 -vrtnodata -9999 tinitaly_1_1.vrt w*_s10/w*_s10.tif
gdal_translate -of GTiff -co TILED=YES -co BLOCKXSIZE=512 -co BLOCKYSIZE=512 \
  -co COMPRESS=DEFLATE -co PREDICTOR=3 -co BIGTIFF=YES tinitaly_1_1.vrt tinitaly_1_1.tif
```

The same can be done from Julia with `ArchGDAL.gdalbuildvrt` and
`ArchGDAL.gdaltranslate`. `-srcnodata` keeps the NoData margin of one tile from
covering valid cells of its neighbour. Before building, check that every tile
declares NoData -9999 (TINITALY 1.0 used 0, which is a valid elevation). Then
check the result with `load_registry` and a few known places.

Checked on 2026-11-23 with tiles `w48060` and `w48065` (Pisa area): the 10-column
overlap is identical in both tiles, the mosaic reproduces every cell of both
sources, compressed size is 102 MiB for two tiles (192 MiB uncompressed), and a
WCS extract of 20 × 20 km matched the tile cell for cell. Expect roughly 10 GB for
the whole country (not measured).
