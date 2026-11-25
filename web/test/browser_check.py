"""Drive the real page in headless Chrome (Playwright): upload, enrich, download.

    python web/test/browser_check.py OUTDIR [path/to/chrome]

Starts web/test/browser_server.jl on 127.0.0.1, runs the user workflow, checks
the page and downloads, saves desktop and mobile screenshots in OUTDIR and
fails on any console error (including Content-Security-Policy violations).
Development check only; not part of Pkg.test.
"""
import os
import subprocess
import sys
from playwright.sync_api import sync_playwright

out = os.path.abspath(sys.argv[1])
chrome = sys.argv[2] if len(sys.argv) > 2 else None
os.makedirs(out, exist_ok=True)
here = os.path.dirname(os.path.abspath(__file__))
web = os.path.dirname(here)
# XLSX, ArchGDAL and GDAL are test-only dependencies of the web project; take
# them from the ItaBOLValidator project for this helper process.
env = dict(os.environ, JULIA_LOAD_PATH=os.pathsep.join(["@", os.path.dirname(web), "@stdlib"]))
server = subprocess.Popen(["julia", "--project=" + web, "--threads=2", os.path.join(here, "browser_server.jl"),
                           os.path.join(out, "data")], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
                          env=env)
try:
    line = ""
    while not line.startswith("READY"):
        line = server.stdout.readline()
        if not line:
            raise SystemExit("server did not start")
    _, port, workbook, taxa, review = line.rstrip("\n").split("\t")
    base = "http://127.0.0.1:" + port
    errors = []
    with sync_playwright() as p:
        browser = p.chromium.launch(executable_path=chrome) if chrome else p.chromium.launch(channel="chrome")
        page = browser.new_page(viewport={"width": 1280, "height": 900}, accept_downloads=True)
        page.on("console", lambda m: errors.append(m.text) if m.type == "error" else None)
        page.on("pageerror", lambda e: errors.append(str(e)))
        page.goto(base + "/")
        page.wait_for_selector("#limit-hint:not(:empty)")
        assert "COUNTRY/OCEAN" in page.text_content("#limit-hint")
        page.set_input_files("#file", workbook)
        page.click("#upload-button")
        page.wait_for_selector("#validation:not([hidden])")
        assert page.text_content("#v-records") == "4", page.text_content("#v-records")
        assert page.text_content("#v-valid") == "3"
        assert page.is_checked("input[name=overwrite][value=false]")      # preservation is the default
        assert page.locator("input[name=field]").count() == 2
        page.click("#enrich-button")
        page.wait_for_selector("#results:not([hidden])")
        summary = page.text_content("#summary")
        assert "Celle compilate" in summary and "4" in summary, summary
        assert page.is_disabled("#taxonomy")                              # no taxonomic columns in this file
        assert page.locator("#preview tbody tr").count() == 4             # changes only
        page.uncheck("#changes-only")
        assert page.locator("#preview tbody tr").count() == 8
        page.screenshot(path=os.path.join(out, "desktop.png"), full_page=True)
        with page.expect_download() as info:
            page.click("#dl-workbook")
        download = info.value
        assert download.suggested_filename.endswith("_enriched.xlsx"), download.suggested_filename
        download.save_as(os.path.join(out, download.suggested_filename))
        with page.expect_download() as info:
            page.click("#dl-report")
        assert info.value.suggested_filename.endswith("_report.toml")
        # IBV8: a failed deletion is reported as failed and the session is kept for a retry.
        page.route("**/api/discard", lambda route: route.abort())
        page.click("#discard")
        page.locator("#upload-status", has_text="Eliminazione non riuscita").wait_for()
        assert page.is_visible("#results") and page.is_visible("#run-row")
        page.unroute("**/api/discard")
        # The aborted request is logged by the browser on purpose; nothing else may be.
        aborted = [e for e in errors if "ERR_FAILED" in e]
        assert len(aborted) == 1, errors
        errors.remove(aborted[0])
        page.click("#discard")
        page.locator("#upload-status", has_text="I tuoi file sono stati eliminati").wait_for()
        # Taxonomy only: upload a workbook with taxonomic columns, untick the geographic fields.
        page.set_input_files("#file", taxa)
        page.click("#upload-button")
        page.locator("#upload-status", has_text="submission BOLD valida").wait_for()
        hint = page.text_content("#taxonomy-hint")
        assert page.is_checked("#taxonomy") and "3 record da completare" in hint, (page.is_checked("#taxonomy"), hint)
        for box in page.locator("input[name=field]").all():
            box.uncheck()
        page.click("#enrich-button")
        page.wait_for_selector("#results:not([hidden])")
        page.wait_for_selector("#taxonomy-results:not([hidden])")
        assert "PHYLUM" in page.text_content("#per-rank")
        assert "non trovati" in page.text_content("#unresolved")
        page.check("#changes-only")
        assert page.locator("#preview tbody tr").count() == 7             # T1: PHYLUM ... GENUS
        assert "da compilare" in page.text_content("#preview")
        page.uncheck("#changes-only")
        assert "conflitto" in page.text_content("#preview")
        page.screenshot(path=os.path.join(out, "taxonomy.png"), full_page=True)
        page.click("#discard")
        # Review page: opened from the link, real-time compliance, saving.
        page.set_input_files("#file", review)
        page.click("#upload-button")
        page.locator("#upload-status", has_text="submission BOLD valida").wait_for()
        with page.context.expect_page() as tab:
            page.click("#review-link")
        rp = tab.value
        rp.on("console", lambda m: errors.append(m.text) if m.type == "error" else None)
        rp.on("pageerror", lambda e: errors.append(str(e)))
        rp.locator("#review-status", has_text="record caricati").wait_for()
        counts = lambda: [rp.text_content("#count-" + k) for k in ("none", "bold", "itabol")]
        assert counts() == ["2", "1", "0"], counts()
        assert "2 siti sulla mappa" in rp.text_content("#map-note"), rp.text_content("#map-note")
        heads = rp.eval_on_selector_all("#grid thead th", "els => els.map(e => e.textContent)")
        def edit(i, column, value):
            td = rp.locator('#grid tr[data-i="%d"] td[data-j="%d"]' % (i, heads.index(column) - 2))
            td.click()
            rp.keyboard.press("Control+A")
            rp.keyboard.type(value)
            rp.keyboard.press("Enter")
            return td
        edit(1, "INST", "Museo")                                         # R2 becomes BOLD compliant
        assert counts() == ["1", "2", "0"], counts()
        assert rp.locator('#grid tr[data-i="1"] .badge').text_content() == "BOLD"
        td = rp.locator('#grid tr[data-i="2"] td[data-j="%d"]' % (heads.index("COORD:LAT") - 2))
        assert "virgola" in (td.get_attribute("title") or ""), td.get_attribute("title")
        edit(2, "COORD:LAT", "41.7")
        assert counts() == ["0", "3", "0"], counts()
        assert "3 siti sulla mappa" in rp.text_content("#map-note")
        rp.click("#save")
        rp.locator("#save-status", has_text="Salvate 2 celle").wait_for()
        assert "3 record BOLD conformi" in rp.text_content("#save-status"), rp.text_content("#save-status")
        assert "diverso" not in rp.text_content("#save-status")
        rp.screenshot(path=os.path.join(out, "review.png"), full_page=True)
        with rp.expect_download() as info:
            rp.click("#dl-reviewed")
        assert info.value.suggested_filename.endswith("_reviewed.xlsx")
        rp.close()
        mobile = browser.new_page(viewport={"width": 390, "height": 844})
        mobile.goto(base + "/")
        mobile.wait_for_selector("#limit-hint:not(:empty)")
        width = mobile.evaluate("document.documentElement.scrollWidth")
        assert width <= 390, "horizontal overflow on mobile: %s px" % width
        mobile.screenshot(path=os.path.join(out, "mobile.png"), full_page=True)
        browser.close()
    assert not errors, errors
    print("browser check passed; screenshots and download in", out)
finally:
    server.stdin.close()
    server.wait(timeout=120)
