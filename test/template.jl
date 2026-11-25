# Exact schema read from the user-supplied, empty BOLD5 workbook. This snapshot is
# a test expectation only: production code continues to discover columns by name.
const PROVIDED_BOLD5_HEADERS = [
    "SAMPLEID", "FIELDID", "MUSEUMID", "COLLECTION_CODE", "INST", "FUNDING_SRC",
    "PHYLUM", "CLASS", "ORDER", "FAMILY", "SUBFAMILY", "TRIBE", "GENUS",
    "SPECIES", "SUBSPECIES", "IDENTIFIED_BY", "IDENTIFICATION_METHOD", "TAXONOMY_NOTES",
    "SEX", "REPRODUCTION", "LIFE_STAGE", "SHORT_NOTE", "NOTES", "VOUCHER_TYPE",
    "TISSUE_TYPE", "SPECIMEN_LINKOUT", "ASSOCIATED_TAXA", "ASSOCIATED_SPECIMENS",
    "COLLECTORS", "COLLECTION_DATE_START", "COLLECTION_DATE_END", "COUNTRY/OCEAN",
    "PROVINCE/STATE", "REGION", "SECTOR", "SITE", "COORD:LAT", "COORD:LON",
    "ELEV", "DEPTH", "ELEV_ACCURACY", "DEPTH_ACCURACY", "COORD_SOURCE",
    "COORD_ACCURACY", "COLLECTION_TIME", "HABITAT", "SAMPLING_PROTOCOL",
    "COLLECTION_NOTES", "SITE_CODE", "COLLECTION_EVENT_ID",
]
const PROVIDED_BOLD5_SHA256 = "ba79e98f0ca64d3127b68eadd77427a3c5066d9a3d55e37589c7c3e8e263af89"

_template_xml_text(value) = replace(string(value), '&' => "&amp;", '<' => "&lt;", '>' => "&gt;")

function populated_template_fixture(source, destination, rows)
    # Fixture construction only, NOT an enriched-workbook writer. Use XLSX's
    # pinned ZIP implementation to append a few synthetic inline-string/numeric
    # cells. Leave every other OOXML part, and all existing sheet XML, intact.
    archive = XLSX.ZipArchives.ZipReader(read(source))
    sheet_part = "xl/worksheets/sheet1.xml"  # verified layout of this one fixture
    sheet_xml = XLSX.ZipArchives.zip_readentry(archive, sheet_part, String)
    cells = IOBuffer()
    for (number, record) in rows
        print(cells, "<row r=\"", number, "\">")
        for (column, header) in enumerate(PROVIDED_BOLD5_HEADERS)
            value = get(record, header, missing)
            ismissing(value) && continue
            ref = string(XLSX.CellRef(number, column))
            if value isa Real
                print(cells, "<c r=\"", ref, "\"><v>", value, "</v></c>")
            else
                print(cells, "<c r=\"", ref, "\" t=\"inlineStr\"><is><t xml:space=\"preserve\">",
                      _template_xml_text(value), "</t></is></c>")
            end
        end
        print(cells, "</row>")
    end
    @assert count("</sheetData>", sheet_xml) == 1
    modified = replace(sheet_xml, "</sheetData>" => String(take!(cells)) * "</sheetData>"; count=1)
    # Keep the original A1:AX1 dimension intentionally: actual rows must be read,
    # even when an Excel producer leaves its used-range hint stale.
    XLSX.ZipArchives.ZipWriter(destination) do writer
        for name in XLSX.ZipArchives.zip_names(archive)
            XLSX.ZipArchives.zip_newfile(writer, name)
            write(writer, name == sheet_part ? codeunits(modified) :
                  XLSX.ZipArchives.zip_readentry(archive, name))
        end
    end
    return destination
end

@testset "Provided BOLD5 template" begin
    template = joinpath(@__DIR__, "data", "BOLD5_BCDM_Specimen_Submission_SinglePage.xlsx")
    before = read(template)
    @test bytes2hex(sha256(before)) == PROVIDED_BOLD5_SHA256
    parsed = read_bold(template)
    @test parsed.source_sha256 == PROVIDED_BOLD5_SHA256
    @test parsed.sheet_names == ["Submissions"]
    @test parsed.header_row == 1
    @test parsed.headers == PROVIDED_BOLD5_HEADERS
    @test parsed.column_numbers == collect(1:50)
    @test names(parsed.records) == PROVIDED_BOLD5_HEADERS
    @test size(parsed.records) == (0, 50)
    @test isempty(parsed.coordinates)
    @test isempty(parsed.excel_rows)

    archive = XLSX.ZipArchives.ZipReader(before)
    parts = XLSX.ZipArchives.zip_names(archive)
    @test any(startswith("xl/drawings/"), parts)
    @test any(startswith("xl/media/"), parts)
    sheet_xml = XLSX.ZipArchives.zip_readentry(archive, "xl/worksheets/sheet1.xml", String)
    @test occursin("<cols>", sheet_xml)
    @test occursin("<drawing", sheet_xml)

    mktempdir() do dir
        empty_export = export_validation(parsed, joinpath(dir, "empty"); identifier_header="SAMPLEID")
        @test read(joinpath(empty_export, "original.xlsx")) == before
        @test nrow(CSV.read(joinpath(empty_export, "coordinates.csv"), DataFrame)) == 0
        @test TOML.parsefile(joinpath(empty_export, "manifest.toml"))["header_row"] == 1

        first_record = Dict{String,Any}(h => "preserved-$h" for h in PROVIDED_BOLD5_HEADERS)
        merge!(first_record, Dict("SAMPLEID" => "000001", "FIELDID" => "000010", "MUSEUMID" => "000099",
            "COUNTRY/OCEAN" => "Italy", "PROVINCE/STATE" => "Roma", "REGION" => "Lazio",
            "COORD:LAT" => " 41.9028 ", "COORD:LON" => 12.4964, "ELEV" => 25,
            "DEPTH" => missing, "HABITAT" => "urban", "NOTES" => "àèìòù <tag> & original metadata",
            "COLLECTION_TIME" => "09:15", "COLLECTION_EVENT_ID" => "event-0001"))
        rows = [
            (2, first_record),
            (3, Dict{String,Any}("SAMPLEID" => "000001", "COORD:LON" => 12.5, "SITE_CODE" => "duplicate-id")),
            (5, Dict{String,Any}("SAMPLEID" => "000003", "COORD:LAT" => 91, "COORD:LON" => "12,5")),
            (6, Dict{String,Any}("COORD:LAT" => 0, "COORD:LON" => 0, "NOTES" => "missing identifier retained")),
        ]
        populated = populated_template_fixture(template, joinpath(dir, "populated.xlsx"), rows)
        filled_archive = XLSX.ZipArchives.ZipReader(read(populated))
        @test XLSX.ZipArchives.zip_names(filled_archive) == parts
        for name in parts
            name == "xl/worksheets/sheet1.xml" && continue
            @test XLSX.ZipArchives.zip_readentry(filled_archive, name) == XLSX.ZipArchives.zip_readentry(archive, name)
        end
        populated_bytes = read(populated)
        filled = read_bold(populated)
        @test filled.header_row == 1
        @test filled.headers == PROVIDED_BOLD5_HEADERS
        @test size(filled.records) == (4, 50)
        @test filled.excel_rows == [2, 3, 5, 6]
        for (i, (_, record)) in enumerate(rows), h in PROVIDED_BOLD5_HEADERS
            @test isequal(filled.records[i, h], get(record, h, missing))
        end
        @test filled.coordinates[1].latitude.value == 41.9028
        @test [isvalid(p) for p in filled.coordinates] == [true, false, false, true]
        @test filled.coordinates[2].latitude.status === :missing
        @test filled.coordinates[3].latitude.status === :out_of_range
        @test filled.coordinates[3].longitude.status === :invalid_format
        report = validation_report(filled; identifier_header="SAMPLEID")
        @test isequal(report.specimen_id, ["000001", "000001", "000003", missing])
        @test report.excel_row == [2, 3, 5, 6]
        output = export_validation(filled, joinpath(dir, "filled"); identifier_header="SAMPLEID")
        @test read(joinpath(output, "original.xlsx")) == populated_bytes
        @test read(populated) == populated_bytes
        @test isequal(read_bold(joinpath(output, "original.xlsx")).records, filled.records)
    end
    @test read(template) == before
end
