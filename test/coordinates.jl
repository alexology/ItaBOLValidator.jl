@testset "Coordinate validation" begin
    @test isvalid(validate_coordinates(41.9, 12.5))
    @test isvalid(validate_coordinates(-90, -180))
    @test isvalid(validate_coordinates(90, 180))
    @test isvalid(validate_coordinates(0, 0))
    for (token, expected) in [("  +41.9  ", 41.9), ("4.19e1", 41.9),
                              (".5", 0.5), ("-0.25", -0.25), ("42.", 42.0)]
        value = validate_coordinate(token, :latitude)
        @test value.status === :valid
        @test value.value == expected
    end
    for token in (missing, nothing, "", " \t\n ")
        result = validate_coordinate(token, :latitude)
        @test result.status === :missing
        @test ismissing(result.value)
    end
    for token in (true, false, "41,9", "41°54'", "41.9 N", "N41.9", "12 30", "Italy",
                  "NaN", "Inf", "0x12", "1_000", "1e", "--2", "1+1", 1 + 2im, [42])
        result = validate_coordinate(token, :latitude)
        @test result.status === :invalid_format
        @test ismissing(result.value)
    end
    for token in (NaN, Inf, -Inf, "1e9999")
        @test validate_coordinate(token, :longitude).status === :nonfinite
    end
    for (token, axis) in ((90.00001, :latitude), (-90.00001, :latitude),
                           (180.00001, :longitude), (-180.00001, :longitude),
                           ("91", :latitude), (typemin(Int), :latitude),
                           (big"90.000000000000000000001", :latitude))
        result = validate_coordinate(token, axis)
        @test result.status === :out_of_range
        @test ismissing(result.value)
    end
    @test !isvalid(validate_coordinates(missing, 12))
    @test !isvalid(validate_coordinates(42, missing))
    @test !isvalid(validate_coordinates(missing, missing))
    @test !isvalid(validate_coordinates(42, 181))
    @test_throws ArgumentError validate_coordinate(42, :northing)
end
