# Development helper for browser_check.py: serve synthetic test data on loopback.
#   julia --project=web --threads=2 web/test/browser_server.jl DIR
import XLSX
using ItaBOLWeb
include(joinpath(@__DIR__, "fixtures.jl"))

dir = ARGS[1]
root, registry, workbook = web_fixture(dir)
taxa = taxonomy_fixture(dir)
review = review_fixture(dir)
# BOLD is replaced by the offline fake of the integration tests.
server = serve(WebConfig(; registry, geodata_root=root, host="127.0.0.1", port=0, work_dir=joinpath(dir, "work"),
                         bold_min_interval=0, taxonomy_fetch=fake_bold(Ref(0))); async=true)
println("READY\t", server.port, "\t", workbook, "\t", taxa, "\t", review)
flush(stdout)
try
    readline(stdin)          # stop when the controlling process closes stdin
finally
    shutdown(server)
end
