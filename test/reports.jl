@testset "Validation report and workbook preservation" begin
    mktempdir() do dir
        records = [synthetic_record("0001", "41.9", 12.5),
                   synthetic_record("0001", missing, "invalid"),
                   synthetic_record(missing, 90.1, 14.2)]
        source = write_fixture(joinpath(dir, "original.xlsx"); records)
        original_bytes = read(source)
        parsed = read_bold(source)
        report = validation_report(parsed; identifier_header="SAMPLEID")
        @test report.excel_row == [4, 5, 6]
        @test isequal(report.specimen_id, ["0001", "0001", missing])
        @test report.latitude_status == ["valid", "missing", "out_of_range"]
        @test report.longitude_status == ["valid", "invalid_format", "valid"]
        @test report.valid == [true, false, false]
        report.raw_latitude[1] = "changed report only"
        @test parsed.records[1, "COORD:LAT"] == "41.9"
        @test_throws ArgumentError validation_report(parsed; identifier_header="sampleid")

        output = export_validation(parsed, joinpath(dir, "validation"); identifier_header="SAMPLEID")
        @test sort(readdir(output)) == ["coordinates.csv", "manifest.toml", "original.xlsx"]
        @test read(source) == original_bytes
        @test read(joinpath(output, "original.xlsx")) == original_bytes
        @test open(sha256, joinpath(output, "original.xlsx")) == open(sha256, source)
        copied = read_bold(joinpath(output, "original.xlsx"))
        @test isequal(copied.records, parsed.records)
        @test copied.sheet_names == parsed.sheet_names
        manifest = TOML.parsefile(joinpath(output, "manifest.toml"))
        @test manifest["record_count"] == 3
        @test manifest["valid_coordinate_count"] == 1
        @test manifest["source_sha256"] == bytes2hex(sha256(original_bytes))
        @test manifest["headers"] == parsed.headers
        @test manifest["column_numbers"] == parsed.column_numbers
        @test manifest["identifier_header"] == "SAMPLEID"
        csv_report = CSV.read(joinpath(output, "coordinates.csv"), DataFrame;
                              types=Dict(:specimen_id => String, :raw_latitude => String))
        @test isequal(csv_report.specimen_id, ["0001", "0001", missing])
        @test csv_report.latitude_status == ["valid", "missing", "out_of_range"]
        @test_throws ArgumentError export_validation(parsed, output)
        @test_throws ArgumentError export_validation(parsed, dirname(source))
        @test_throws ArgumentError export_validation(parsed, source)
        @test_throws ArgumentError export_validation(parsed, joinpath(dir, "nonexistent", "output"))
        @test read(source) == original_bytes

        # A mutated/replaced source cannot be paired with a stale parse result.
        write_fixture(source; records=[synthetic_record("changed", 40, 12)])
        changed_bytes = read(source)
        stale_output = joinpath(dir, "stale")
        @test_throws ArgumentError export_validation(parsed, stale_output)
        @test !ispath(stale_output)
        @test !any(startswith("itabold-"), readdir(dir))
        @test read(source) == changed_bytes

        empty_path = write_fixture(joinpath(dir, "empty.xlsx"))
        empty_output = export_validation(read_bold(empty_path), joinpath(dir, "empty_report"))
        @test TOML.parsefile(joinpath(empty_output, "manifest.toml"))["record_count"] == 0
        @test nrow(CSV.read(joinpath(empty_output, "coordinates.csv"), DataFrame)) == 0
    end
end
