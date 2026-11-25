@testset "BOLD workbook parser" begin
    mktempdir() do dir
        path = joinpath(dir, "specimens.xlsx")
        headers = synthetic_headers()
        # Reorder and offset the columns so geography is not at a fixed position.
        headers = vcat(headers[40:end], reverse(headers[1:39]))
        records = [synthetic_record("0001", " 41.90 ", "12.50"),
                   synthetic_record("duplicate", missing, 12.1),
                   synthetic_record("duplicate", 95, "12,1"),
                   synthetic_record(missing, 42.1, missing)]
        write_fixture(path; headers, records, start_column=2, blank_after=1)
        before = read(path)
        parsed = read_bold(path)
        @test read(path) == before
        @test parsed.sheet_names == ["Submissions", "Instructions"]
        @test parsed.header_row == 3
        @test parsed.headers == headers
        @test parsed.column_numbers == collect(2:51)
        @test names(parsed.records) == headers
        @test size(parsed.records) == (4, 50)
        @test parsed.excel_rows == [4, 6, 7, 8]
        for (i, record) in enumerate(records), h in headers
            @test isequal(parsed.records[i, h], get(record, h, missing))
        end
        @test parsed.records[1, "COORD:LAT"] == " 41.90 "
        @test isvalid(parsed.coordinates[1])
        @test parsed.coordinates[2].latitude.status === :missing
        @test parsed.coordinates[3].latitude.status === :out_of_range
        @test parsed.coordinates[3].longitude.status === :invalid_format
        @test parsed.coordinates[4].longitude.status === :missing
        @test isequal(read_bold(path; header_row=3).records, parsed.records)
        @test_throws TemplateError read_bold(path; header_row=2)
        @test_throws TemplateError read_bold(path; header_row=1000)
        @test_throws TemplateError read_bold(path; max_header_rows=2)
        @test_throws ArgumentError read_bold(path; max_header_rows=0)
        @test_throws ArgumentError read_bold(path; header_row=0)

        @testset "Invalid schemas" begin
            for (filename, altered) in (
                ("wrong_case", replace(headers, "COORD:LAT" => "coord:lat")),
                ("whitespace", replace(headers, "COUNTRY/OCEAN" => "COUNTRY/OCEAN ")),
                ("missing_geo", replace(headers, "HABITAT" => "OTHER")),
                ("duplicate", replace(headers, "NOTES" => "SAMPLEID")),
                ("49_columns", filter(!=("NOTES"), headers)),
                ("51_columns", vcat(headers, "EXTRA")),
                ("empty_header", replace(headers, "NOTES" => "")),
            )
                bad = write_fixture(joinpath(dir, "$filename.xlsx"); headers=altered)
                @test_throws TemplateError read_bold(bad)
            end
            bad_sheet = write_fixture(joinpath(dir, "wrong_sheet.xlsx"); sheet_name="submissions")
            @test_throws TemplateError read_bold(bad_sheet)
            outside = write_fixture(joinpath(dir, "outside.xlsx"); records=records[1:1], outside_value=true)
            @test_throws TemplateError read_bold(outside)
            upper = write_fixture(joinpath(dir, "uppercase.XLSX"))
            @test nrow(read_bold(upper).records) == 0
            @test_throws ArgumentError read_bold(joinpath(dir, "missing.xlsx"))
            txt = joinpath(dir, "not_excel.txt")
            write(txt, "not a workbook")
            @test_throws ArgumentError read_bold(txt)
        end

        @testset "Empty and formula records" begin
            empty_path = write_fixture(joinpath(dir, "empty.xlsx"))
            empty = read_bold(empty_path)
            @test size(empty.records) == (0, 50)
            @test isempty(empty.coordinates)
            @test isempty(empty.excel_rows)
            @test nrow(validation_report(empty)) == 0
            formula = write_fixture(joinpath(dir, "formula.xlsx"); records=records[1:1],
                                    coordinate_formula=true, metadata_formula=true)
            parsed_formula = read_bold(formula)
            @test parsed_formula.coordinates[1].latitude.status === :formula
            @test !isvalid(parsed_formula.coordinates[1])
            @test parsed_formula.records[1, "NOTES"] == 2
            no_cache = write_fixture(joinpath(dir, "no_cache.xlsx"); formula_only=true)
            no_cache_parsed = read_bold(no_cache)
            @test nrow(no_cache_parsed.records) == 1
            @test no_cache_parsed.excel_rows == [4]
            @test no_cache_parsed.coordinates[1].latitude.status === :missing
            error_path = write_fixture(joinpath(dir, "error.xlsx"); coordinate_error=true)
            error_parsed = read_bold(error_path)
            @test nrow(error_parsed.records) == 1
            @test error_parsed.records[1, "COORD:LAT"] == "#N/A"
            @test error_parsed.coordinates[1].latitude.status === :invalid_format
            @test validation_report(error_parsed).raw_latitude == ["#N/A"]
        end
    end
end

@testset "Thousands of specimens" begin
    mktempdir() do dir
        records = [synthetic_record(lpad(string(i), 6, '0'), 35.0 + i / 10000, 12.5) for i in 1:5000]
        path = write_fixture(joinpath(dir, "large.xlsx"); records, blank_after=2500)
        original_hash = open(sha256, path)
        parsed = read_bold(path)
        @test size(parsed.records) == (5000, 50)
        @test parsed.records[!, "SAMPLEID"] == [r["SAMPLEID"] for r in records]
        @test parsed.excel_rows == vcat(collect(4:2503), collect(2505:5004))
        @test all(isvalid, parsed.coordinates)
        @test open(sha256, path) == original_hash
    end
end
