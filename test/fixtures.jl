# Only the 14 supplied geographic names are authoritative. These other headers
# are synthetic; this fixture does not pretend to be the actual BOLD5 template.
function synthetic_headers()
    return vcat(["SAMPLEID", "FIELD ID", "NOTES", "COLLECTION DATE"],
                ["SYNTHETIC METADATA $i" for i in 1:32], collect(GEOGRAPHIC_HEADERS))
end

function synthetic_record(id, latitude, longitude)
    return Dict{String,Any}(
        "SAMPLEID" => id, "FIELD ID" => "field-$id", "NOTES" => "existing metadata; àèìòù",
        "COLLECTION DATE" => "2026-01-02", "COORD:LAT" => latitude,
        "COORD:LON" => longitude, "COUNTRY/OCEAN" => "Italy", "REGION" => "Lazio",
        "SITE" => "unaltered site", "HABITAT" => "woodland", "ELEV" => 123,
        "SYNTHETIC METADATA 32" => "last non-geographic field",
    )
end

function write_fixture(path; headers=synthetic_headers(), records=Dict{String,Any}[],
                       header_row=3, start_column=1, blank_after=0, sheet_name="Submissions",
                       outside_value=false, coordinate_formula=false, metadata_formula=false,
                       coordinate_error=false, formula_only=false)
    XLSX.openxlsx(path; mode="w") do book
        sheet = book[1]
        XLSX.renamesheet!(sheet, sheet_name)
        sheet[1, start_column] = "Synthetic workbook: no real specimen data"
        for (j, h) in enumerate(headers)
            sheet[header_row, start_column + j - 1] = h
        end
        for (i, record) in enumerate(records)
            row = header_row + i + (blank_after > 0 && i > blank_after ? 1 : 0)
            for (j, h) in enumerate(headers)
                value = get(record, h, missing)
                ismissing(value) || (sheet[row, start_column + j - 1] = value)
            end
        end
        lastrow = header_row + length(records) + (blank_after > 0 ? 1 : 0)
        # Formatting and extra worksheet content must survive exports untouched.
        XLSX.setFont(sheet, XLSX.CellRef(header_row, start_column); bold=true, color="red")
        XLSX.setFill(sheet, XLSX.CellRef(header_row, start_column); pattern="solid", fgColor="yellow")
        XLSX.setColumnWidth(sheet, "A"; width=28)
        if coordinate_formula
            col = start_column + findfirst(==("COORD:LAT"), headers) - 1
            XLSX.setFormula(sheet, XLSX.CellRef(header_row + 1, col), "40+2"; value=42.0)
        end
        if metadata_formula
            col = start_column + findfirst(==("NOTES"), headers) - 1
            XLSX.setFormula(sheet, XLSX.CellRef(header_row + 1, col), "1+1"; value=2)
        end
        if coordinate_error
            col = start_column + findfirst(==("COORD:LAT"), headers) - 1
            # XLSX has no public setter for a literal Excel error. This synthetic
            # cell serializes as t="e" with <v>#N/A</v>, without a formula/cache.
            ref = XLSX.CellRef(header_row + 1, col)
            XLSX.setdata!(sheet, XLSX.Cell(ref, UInt64(XLSX.XL_NA), UInt32(0),
                                         UInt16(0), XLSX.CT_ERROR, false))
        end
        if formula_only
            col = start_column + findfirst(==("NOTES"), headers) - 1
            XLSX.setFormula(sheet, XLSX.CellRef(header_row + 1, col), "1+1")
        end
        outside_value && (sheet[header_row + 1, start_column + length(headers)] = "must not be lost")
        other = XLSX.addsheet!(book, "Instructions")
        other["A1"] = "Preserve this worksheet"
        other["B3"] = "Reference information"
        # A styled empty tail must not become a specimen record.
        sheet[lastrow + 2, start_column] = ""
        XLSX.setFont(sheet, XLSX.CellRef(lastrow + 2, start_column); italic=true)
    end
    return path
end
