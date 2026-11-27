"use strict";

// Review page: overview map, editable table and real-time BOLD / ItaBOL
// compliance. The rules come from the server (config/compliance.toml) and are
// evaluated here exactly as ItaBOLValidator.check_compliance does in Julia.

const $ = (id) => document.getElementById(id);
const PAGE_SIZE = 50;
const COLORS = { itabol: "#E69F00", bold: "#0072B2", none: "#ffffff" };   // Okabe–Ito, colour-blind safe
const DECIMAL = /^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$/;
const ISO_DATE = /^(\d{4})-(\d{2})-(\d{2})$/;

const S = {
  session: null, data: null, values: [], base: [], edits: new Map(), changed: new Set(), formulas: new Set(),
  status: [], problems: [], cellProblems: [], unique: [], page: 0, visible: [], selected: -1,
  latCol: -1, lonCol: -1, idCol: -1, rowText: [], map: null, points: null, markers: []
};

// ---------------------------------------------------------------------------
// Helpers

function setStatus(id, text, kind) {
  const el = $(id);
  el.textContent = text || "";
  el.className = "status" + (kind ? " " + kind : "");
}

async function request(url, options) {
  const res = await fetch(url, options);
  let body = null;
  try { body = await res.json(); } catch (e) { body = null; }
  if (!res.ok) throw new Error((body && body.error) || ("Richiesta non riuscita (HTTP " + res.status + ")."));
  return body;
}

const blank = (v) => v === null || v === undefined || (typeof v === "string" && v.trim() === "");
const text = (v) => (typeof v === "string" ? v.trim() : String(v));
const display = (v) => (v === null || v === undefined ? "" : String(v));
const key = (i, j) => i + "," + j;

function isDate(v) {
  if (typeof v !== "string") return false;
  const m = ISO_DATE.exec(v.trim());
  if (!m) return false;
  const y = +m[1], mo = +m[2], d = +m[3];
  if (mo < 1 || mo > 12 || d < 1) return false;
  return d <= new Date(Date.UTC(y, mo, 0)).getUTCDate();
}

function isNumber(v) {
  if (typeof v === "number") return Number.isFinite(v);
  return typeof v === "string" && DECIMAL.test(v.trim()) && Number.isFinite(parseFloat(v.trim()));
}

// Mirror of ItaBOLValidator.validate_coordinate.
function coordinateStatus(raw, axis) {
  if (blank(raw)) return { status: "missing" };
  let value;
  if (typeof raw === "number") {
    value = raw;
  } else {
    const t = String(raw).trim();
    if (!DECIMAL.test(t)) return { status: "invalid_format" };
    value = parseFloat(t);
  }
  if (!Number.isFinite(value)) return { status: "nonfinite" };
  const limit = axis === "latitude" ? 90 : 180;
  return Math.abs(value) <= limit ? { status: "valid", value } : { status: "out_of_range", value };
}

// Italian explanation of a coordinate problem, with the usual causes.
function coordinateMessage(axis, status, raw, other) {
  const name = axis === "latitude" ? "Latitudine" : "Longitudine";
  const t = display(raw).trim();
  if (status === "invalid_format") {
    if (/,/.test(t) && DECIMAL.test(t.replace(",", "."))) return name + ": usa il punto come separatore decimale, non la virgola";
    if (/[°'"′″NSEWOnsewo]|\d\s+\d/.test(t)) return name + ": sembra in gradi/minuti/secondi o con N/S/E/W; converti in gradi decimali (es. 43.7230, sud e ovest negativi)";
    return name + ": non è un numero in gradi decimali";
  }
  if (status === "nonfinite") return name + ": valore non finito";
  if (status === "out_of_range") {
    const v = Math.abs(parseFloat(t));
    if (v > 1000) return name + ": " + t + " sembra una coordinata proiettata (es. UTM in metri), non gradi decimali WGS84";
    if (axis === "latitude" && other !== null && Math.abs(other) <= 90) return name + ": fuori da ±90; latitudine e longitudine forse invertite";
    return name + ": fuori intervallo (latitudine ±90, longitudine ±180)";
  }
  return name + ": " + status;
}

// Downloads go through fetch with the session id in a header, never in a URL
// (URLs end up in proxy logs, browser history and Referer headers).
async function downloadFile(session, file) {
  const res = await fetch("/api/download?file=" + encodeURIComponent(file), { headers: { "X-Session": session } });
  if (!res.ok) {
    let body = null;
    try { body = await res.json(); } catch (e) { body = null; }
    throw new Error((body && body.error) || ("Download non riuscito (HTTP " + res.status + ")."));
  }
  const blob = await res.blob();
  const match = /filename="([^"]+)"/.exec(res.headers.get("Content-Disposition") || "");
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = match ? match[1] : file;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 30000);
}

function bindDownload(id, file, session, statusId) {
  const el = document.getElementById(id);
  el.href = "#";
  el.onclick = (event) => {
    event.preventDefault();
    downloadFile(session(), file).catch((err) => setStatus(statusId, err.message, "error"));
  };
}

// ---------------------------------------------------------------------------
// Compliance

function profiles() {
  const r = S.data.rules;
  return [r.bold, r.itabol].filter((p) => p.defined);
}

const col = (name) => S.data.headers.indexOf(name);
const cell = (i, name) => { const j = col(name); return j < 0 ? null : S.values[i][j]; };

function uniqueKey(v) { return blank(v) ? null : text(v).toLowerCase(); }

function buildUniqueIndex() {
  S.unique = [];
  for (const p of profiles()) {
    for (const rule of p.rules) {
      if (rule.kind !== "unique") continue;
      const name = rule.columns[0];
      const counts = new Map();
      for (let i = 0; i < S.values.length; i++) {
        const k = uniqueKey(cell(i, name));
        if (k !== null) counts.set(k, (counts.get(k) || 0) + 1);
      }
      S.unique.push({ profile: p.id, rule, name, counts });
    }
  }
}

function messageFor(code, column, rule, i) {
  const cols = column.split("|").join(" o ");
  switch (code) {
    case "missing": return column + ": campo obbligatorio vuoto";
    case "missing_any": return rule.note || "serve almeno uno tra " + cols;
    case "duplicate": return column + ": valore duplicato nel file";
    case "not_in_vocabulary":
      return column + ": " + JSON.stringify(text(cell(i, column))) +
        (column === "COUNTRY/OCEAN" ? " non è nell'elenco dei paesi/oceani BOLD (nome inglese completo, es. Italy)"
                                    : " non è tra i valori ammessi");
    case "invalid_date": return column + ": data non nel formato AAAA-MM-GG";
    case "not_a_number": return column + ": non è un numero decimale (usa il punto)";
    case "pattern_mismatch": return column + ": formato non valido" + (rule.note ? " (" + rule.note + ")" : "");
    case "coordinates_incomplete": return "latitudine e longitudine vanno compilate insieme";
    case "coordinates_missing": return rule.note || "coordinate obbligatorie mancanti";
    case "coordinates_zero": return "coordinate 0, 0: probabilmente mancanti, verifica";
    default: return column + ": " + code;
  }
}

function evaluateRow(i) {
  const found = [];
  const failed = { bold: false, itabol: false };
  for (const p of profiles()) {
    const add = (column, code, rule, message) => {
      found.push({ profile: p.id, column, code, severity: rule.severity,
                   message: (p.id === "itabol" ? "[ItaBOL] " : "") + (message || messageFor(code, column, rule, i)) });
      if (rule.severity === "error") failed[p.id] = true;
    };
    for (const rule of p.rules) {
      const k = rule.kind;
      if (k === "unique") {
        const u = S.unique.find((x) => x.rule === rule);
        const v = uniqueKey(cell(i, rule.columns[0]));
        if (v !== null && u.counts.get(v) > 1) add(rule.columns[0], "duplicate", rule);
      } else if (k === "required") {
        for (const c of rule.columns) if (blank(cell(i, c))) add(c, "missing", rule);
      } else if (k === "any_of") {
        if (rule.columns.every((c) => blank(cell(i, c)))) add(rule.columns.join("|"), "missing_any", rule);
      } else if (k === "vocabulary") {
        for (const c of rule.columns) {
          const v = cell(i, c);
          if (!blank(v) && !rule.values.includes(text(v).toLowerCase())) add(c, "not_in_vocabulary", rule);
        }
      } else if (k === "date") {
        for (const c of rule.columns) { const v = cell(i, c); if (!blank(v) && !isDate(v)) add(c, "invalid_date", rule); }
      } else if (k === "number") {
        for (const c of rule.columns) { const v = cell(i, c); if (!blank(v) && !isNumber(v)) add(c, "not_a_number", rule); }
      } else if (k === "pattern") {
        const re = new RegExp(rule.regex);
        for (const c of rule.columns) { const v = cell(i, c); if (!blank(v) && !re.test(text(v))) add(c, "pattern_mismatch", rule); }
      } else if (k === "coordinates") {
        const [latC, lonC] = rule.columns;
        const lat = cell(i, latC), lon = cell(i, lonC);
        if (blank(lat) && blank(lon)) {
          if (rule.required) add(latC + "|" + lonC, "coordinates_missing", rule);
        } else if (blank(lat) || blank(lon)) {
          add(blank(lat) ? latC : lonC, "coordinates_incomplete", rule);
        } else {
          const a = coordinateStatus(lat, "latitude"), b = coordinateStatus(lon, "longitude");
          const otherLon = typeof b.value === "number" ? b.value : null;
          if (a.status !== "valid") add(latC, "latitude_" + a.status, rule, coordinateMessage("latitude", a.status, lat, otherLon));
          if (b.status !== "valid") add(lonC, "longitude_" + b.status, rule, coordinateMessage("longitude", b.status, lon, null));
          if (a.status === "valid" && b.status === "valid" && a.value === 0 && b.value === 0) {
            add(latC + "|" + lonC, "coordinates_zero", { severity: "warning" });
          }
        }
      }
    }
  }
  const bold = S.data.rules.bold.defined && !failed.bold;
  const itabol = S.data.rules.itabol.defined && bold && !failed.itabol;
  S.status[i] = itabol ? "itabol" : bold ? "bold" : "none";
  S.problems[i] = found;
  const byCell = new Map();
  for (const p of found) {
    for (const c of p.column.split("|")) {
      const j = col(c);
      if (j < 0) continue;
      if (!byCell.has(j)) byCell.set(j, []);
      byCell.get(j).push(p);
    }
  }
  S.cellProblems[i] = byCell;
}

function evaluateAll() {
  buildUniqueIndex();
  for (let i = 0; i < S.values.length; i++) evaluateRow(i);
  updateCounts();
}

function updateCounts() {
  const c = { none: 0, bold: 0, itabol: 0 };
  for (const s of S.status) c[s]++;
  $("count-none").textContent = c.none;
  $("count-bold").textContent = c.bold;
  $("count-itabol").textContent = c.itabol;
}

// ---------------------------------------------------------------------------
// Table

const statusLabel = { itabol: "ItaBOL", bold: "BOLD", none: "—" };
const statusTitle = { itabol: "Conforme ItaBOL (e BOLD)", bold: "Conforme BOLD", none: "Non conforme" };

function computeVisible() {
  const f = $("filter").value;
  const q = $("search").value.trim().toLowerCase();
  S.visible = [];
  for (let i = 0; i < S.values.length; i++) {
    const s = S.status[i];
    if (f === "none" && s !== "none") continue;
    if (f === "bold" && s !== "bold") continue;
    if (f === "itabol" && s !== "itabol") continue;
    if (f === "edited" && !rowEdited(i)) continue;
    if (q && !S.rowText[i].includes(q)) continue;
    S.visible.push(i);
  }
  const pages = Math.max(1, Math.ceil(S.visible.length / PAGE_SIZE));
  S.page = Math.min(S.page, pages - 1);
}

function rowEdited(i) {
  for (let j = 0; j < S.data.headers.length; j++) if (S.edits.has(key(i, j))) return true;
  return false;
}

function updateRowText(i) { S.rowText[i] = S.values[i].map(display).join(" ").toLowerCase(); }

function renderHeader(table) {
  const thead = document.createElement("thead");
  const tr = document.createElement("tr");
  for (const name of ["Stato", "Riga", ...S.data.headers]) {
    const th = document.createElement("th");
    th.textContent = name;
    tr.appendChild(th);
  }
  thead.appendChild(tr);
  table.appendChild(thead);
}

function paintRow(tr, i) {
  const s = S.status[i];
  tr.className = "row-" + s + (i === S.selected ? " row-selected" : "");
  const badge = tr.firstChild;
  badge.firstChild.textContent = statusLabel[s];
  badge.firstChild.className = "badge badge-" + s;
  const msgs = S.problems[i].map((p) => (p.severity === "warning" ? "Avviso: " : "") + p.message);
  badge.title = statusTitle[s] + (msgs.length ? "\n• " + msgs.join("\n• ") : "");
  const cells = tr.querySelectorAll("td[data-j]");
  for (const td of cells) {
    const j = +td.dataset.j;
    const probs = S.cellProblems[i].get(j);
    td.classList.toggle("cell-problem", !!probs && probs.some((p) => p.severity === "error"));
    td.classList.toggle("cell-warning", !!probs && probs.every((p) => p.severity === "warning"));
    td.classList.toggle("cell-edited", S.edits.has(key(i, j)));
    td.title = probs ? probs.map((p) => p.message).join("\n") : "";
  }
}

function renderTable() {
  computeVisible();
  const table = $("grid");
  table.replaceChildren();
  renderHeader(table);
  const tbody = document.createElement("tbody");
  const start = S.page * PAGE_SIZE;
  for (const i of S.visible.slice(start, start + PAGE_SIZE)) {
    const tr = document.createElement("tr");
    tr.dataset.i = i;
    const badge = document.createElement("td");
    badge.className = "badge-cell";
    badge.appendChild(document.createElement("span"));
    tr.appendChild(badge);
    const rowCell = document.createElement("td");
    rowCell.className = "num row-number";
    rowCell.textContent = S.data.excel_rows[i];
    tr.appendChild(rowCell);
    S.values[i].forEach((v, j) => {
      const td = document.createElement("td");
      td.dataset.j = j;
      td.textContent = display(v);
      if (S.formulas.has(key(i, j))) {
        td.className = "cell-formula";
        td.title = "Cella con formula: non modificabile qui";
      } else {
        td.contentEditable = "plaintext-only";
        if (td.contentEditable !== "plaintext-only") td.contentEditable = "true";
        td.spellcheck = false;
        if (S.changed.has(key(i, j))) td.classList.add("cell-enriched");
      }
      tr.appendChild(td);
    });
    paintRow(tr, i);
    tbody.appendChild(tr);
  }
  if (!S.visible.length) {
    const tr = document.createElement("tr");
    const td = document.createElement("td");
    td.colSpan = S.data.headers.length + 2;
    td.textContent = "Nessun record con questo filtro.";
    tr.appendChild(td);
    tbody.appendChild(tr);
  }
  table.appendChild(tbody);
  const pages = Math.max(1, Math.ceil(S.visible.length / PAGE_SIZE));
  $("page-info").textContent = "pagina " + (S.page + 1) + " di " + pages + " · " + S.visible.length + " record";
  $("prev-page").disabled = S.page === 0;
  $("next-page").disabled = S.page >= pages - 1;
}

function onCellInput(event) {
  const td = event.target.closest("td[data-j]");
  if (!td || td.classList.contains("cell-formula")) return;
  const tr = td.parentElement;
  const i = +tr.dataset.i, j = +td.dataset.j;
  const typed = td.textContent.replace(/\r?\n/g, " ");
  const old = S.values[i][j];
  const base = S.base[i][j];
  // An edit equal to the starting value is no edit.
  const same = display(base) === typed || (blank(base) && typed.trim() === "");
  S.values[i][j] = same ? base : typed;
  if (same) S.edits.delete(key(i, j)); else S.edits.set(key(i, j), typed);
  // Uniqueness: update the counts and re-check the rows sharing the old or new value.
  const affected = new Set([i]);
  for (const u of S.unique) {
    if (col(u.name) !== j) continue;
    const before = uniqueKey(old), after = uniqueKey(S.values[i][j]);
    if (before === after) continue;
    if (before !== null) u.counts.set(before, u.counts.get(before) - 1);
    if (after !== null) u.counts.set(after, (u.counts.get(after) || 0) + 1);
    for (let r = 0; r < S.values.length; r++) {
      const k = uniqueKey(S.values[r][j]);
      if (k !== null && (k === before || k === after)) affected.add(r);
    }
  }
  for (const r of affected) evaluateRow(r);
  updateRowText(i);
  for (const r of affected) {
    const row = $("grid").querySelector('tr[data-i="' + r + '"]');
    if (row) paintRow(row, r);
  }
  updateCounts();
  updateDirty();
  scheduleMapDraw();
}

function updateDirty() {
  const n = S.edits.size;
  $("save").disabled = n === 0;
  $("dirty-info").textContent = n ? n + " celle modificate, non ancora salvate" : "Nessuna modifica da salvare";
}

function selectRecord(i, scroll) {
  S.selected = i;
  const pos = S.visible.indexOf(i);
  if (pos < 0) {
    $("filter").value = "all";
    $("search").value = "";
    computeVisible();
  }
  S.page = Math.floor(S.visible.indexOf(i) / PAGE_SIZE);
  renderTable();
  drawMap();
  const row = $("grid").querySelector('tr[data-i="' + i + '"]');
  if (row && scroll) row.scrollIntoView({ block: "center", behavior: "smooth" });
}

// ---------------------------------------------------------------------------
// Map (Leaflet with OpenStreetMap tiles; one circle per record with valid coordinates)

const ITALY = [[35.5, 6.5], [47.1, 18.6]];

function validPoint(i) {
  if (S.latCol < 0 || S.lonCol < 0) return null;
  const a = coordinateStatus(S.values[i][S.latCol], "latitude");
  const b = coordinateStatus(S.values[i][S.lonCol], "longitude");
  return a.status === "valid" && b.status === "valid" ? [b.value, a.value] : null;
}

function fitView() {
  if (!S.map) return;
  const pts = [];
  for (let i = 0; i < S.values.length; i++) {
    const p = validPoint(i);
    if (p) pts.push([p[1], p[0]]);
  }
  if (!pts.length) S.map.fitBounds(ITALY);
  else if (pts.length === 1) S.map.setView(pts[0], 13);
  else S.map.fitBounds(pts, { padding: [30, 30], maxZoom: 15 });
}

let drawPending = false;
function scheduleMapDraw() {
  if (drawPending) return;
  drawPending = true;
  requestAnimationFrame(() => { drawPending = false; drawMap(); });
}

function resizeCanvas() { if (S.map) S.map.invalidateSize(); }

function tipText(i) {
  const id = S.idCol >= 0 ? display(S.values[i][S.idCol]) : "";
  const p = validPoint(i);
  return (id || "Riga " + S.data.excel_rows[i]) + " · " + statusTitle[S.status[i]] +
    (p ? " · " + p[1].toFixed(5) + ", " + p[0].toFixed(5) : "");
}

function drawMap() {
  if (!S.map) return;
  let shown = 0;
  for (let i = 0; i < S.values.length; i++) {
    const p = validPoint(i);
    let m = S.markers[i];
    if (!p) {
      if (m) { m.remove(); S.markers[i] = null; }
      continue;
    }
    shown++;
    const selected = i === S.selected;
    const style = { radius: selected ? 9 : 6.5, fillColor: COLORS[S.status[i]], fillOpacity: 1,
                    color: "#222222", weight: selected ? 3 : 1.5 };
    if (!m) {
      m = L.circleMarker([p[1], p[0]], style).addTo(S.points);
      m.bindTooltip("", { direction: "top", offset: [0, -6] });
      m.on("mouseover", () => {
        // Text from the workbook: a DOM node with textContent, never HTML.
        const tip = document.createElement("span");
        tip.textContent = tipText(i);
        m.setTooltipContent(tip);
      });
      m.on("click", () => selectRecord(i, true));
      S.markers[i] = m;
    } else {
      m.setLatLng([p[1], p[0]]);
      m.setStyle(style);
    }
  }
  // ItaBOL-compliant points on top, then BOLD-compliant ones, the selected record last.
  for (const s of ["none", "bold", "itabol"]) {
    for (let i = 0; i < S.markers.length; i++) if (S.markers[i] && S.status[i] === s) S.markers[i].bringToFront();
  }
  if (S.selected !== null && S.selected !== undefined && S.markers[S.selected]) S.markers[S.selected].bringToFront();
  const missing = S.values.length - shown;
  $("map-note").textContent = shown + " siti sulla mappa" +
    (missing ? "; " + missing + " record senza coordinate decimali valide non sono mostrati" : "") +
    ". Sfondo: OpenStreetMap (zoom con la rotellina o i pulsanti, trascina per spostarti; " +
    "fai clic su un punto per aprire il record nella tabella).";
}

function setupMap() {
  S.map = L.map("map", { zoomControl: false, minZoom: 3, maxZoom: 19, preferCanvas: true });
  L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", {
    maxZoom: 19,
    // OSM's tile usage policy asks for a referrer: the origin only, not the page address.
    referrerPolicy: "strict-origin",
    attribution: '&copy; <a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noopener">OpenStreetMap</a> contributors'
  }).addTo(S.map);
  S.map.attributionControl.setPrefix(false);
  S.points = L.featureGroup().addTo(S.map);
  S.markers = [];
  S.map.fitBounds(ITALY);
  $("zoom-in").addEventListener("click", () => S.map.zoomIn());
  $("zoom-out").addEventListener("click", () => S.map.zoomOut());
  $("zoom-fit").addEventListener("click", fitView);
  window.addEventListener("resize", resizeCanvas);
}

// ---------------------------------------------------------------------------
// Save

async function save() {
  const edits = [];
  for (const [k, value] of S.edits) {
    const [i, j] = k.split(",").map(Number);
    edits.push({ row: S.data.excel_rows[i], column: S.data.headers[j], value });
  }
  $("save").disabled = true;
  setStatus("save-status", "Salvataggio di " + edits.length + " celle …");
  try {
    const r = await request("/api/review", {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ session: S.session, base_sha256: S.data.base_sha256, edits })
    });
    const c = r.compliance;
    const local = { bold: 0, itabol: 0 };
    for (const s of S.status) { if (s !== "none") local.bold++; if (s === "itabol") local.itabol++; }
    const agree = local.bold === c.bold_compliant && local.itabol === c.itabol_compliant;
    setStatus("save-status", "Salvate " + r.edits + " celle in un nuovo file. Verifica sul server: " +
      c.bold_compliant + " record BOLD conformi, " + c.itabol_compliant + " ItaBOL conformi, " + c.not_compliant +
      " non conformi" + (agree ? "." : " (diverso dal conteggio nella pagina: ricarica la revisione)."), agree ? "ok" : "error");
    for (const id of ["dl-reviewed", "dl-review-report"]) $(id).hidden = false;
    // The saved file is the new starting point: later saves add to it.
    for (const k of S.edits.keys()) S.changed.add(k);
    S.edits.clear();
    S.base = S.values.map((r) => r.slice());
    S.data.base_sha256 = r.base_sha256;
    S.data.base = "reviewed";
    describeRules();
    renderTable();
    updateDirty();
    $("dirty-info").textContent = "Modifiche salvate: il file revisionato è il nuovo punto di partenza.";
  } catch (err) {
    setStatus("save-status", err.message, "error");
  } finally {
    $("save").disabled = S.edits.size === 0;
  }
}

// ---------------------------------------------------------------------------
// Start

function describeRules() {
  const r = S.data.rules;
  const bold = r.bold.defined ? r.bold.title + " (regole del " + r.bold.version + ")" : "BOLD: regole non definite";
  const itabol = r.itabol.defined ? r.itabol.title + " versione " + r.itabol.version
                                  : "ItaBOL: criteri non ancora definiti, nessun record può risultare ItaBOL conforme";
  const base = { enriched: " (versione arricchita).", original: " (versione caricata, non arricchita).",
                 reviewed: " (ultima revisione salvata, con le modifiche precedenti)." };
  $("rules-note").textContent = "Conformità valutata con " + bold + "; " + itabol + ". File: " + S.data.filename +
    (base[S.data.base] || ".");
}

async function init() {
  // The session id arrives in the URL fragment; keep it in this tab's storage and
  // remove it from the address bar, so that it stays out of the browser history.
  let id = (location.hash || "").replace(/^#/, "");
  if (/^[0-9a-f]{32}$/.test(id)) {
    try { sessionStorage.setItem("itabol-session", id); } catch (e) { /* storage disabled */ }
    history.replaceState(null, "", location.pathname);
  } else {
    try { id = sessionStorage.getItem("itabol-session") || ""; } catch (e) { id = ""; }
  }
  if (!/^[0-9a-f]{32}$/.test(id)) {
    setStatus("review-status", "Sessione mancante: apri questa pagina dal pulsante \"Revisione\" dopo aver caricato un file.", "error");
    return;
  }
  S.session = id;
  setupMap();
  $("grid").addEventListener("input", onCellInput);
  $("grid").addEventListener("keydown", (e) => {
    if (e.key === "Enter" && e.target.closest("td[data-j]")) { e.preventDefault(); e.target.blur(); }
  });
  $("filter").addEventListener("change", () => { S.page = 0; renderTable(); });
  $("search").addEventListener("input", () => { S.page = 0; renderTable(); });
  $("prev-page").addEventListener("click", () => { S.page--; renderTable(); });
  $("next-page").addEventListener("click", () => { S.page++; renderTable(); });
  $("save").addEventListener("click", save);
  bindDownload("dl-reviewed", "reviewed", () => S.session, "save-status");
  bindDownload("dl-review-report", "review_report", () => S.session, "save-status");
  window.addEventListener("beforeunload", (e) => {
    if (S.edits.size) { e.preventDefault(); e.returnValue = ""; }
  });
  try {
    const data = await request("/api/table", { headers: { "X-Session": id } });
    S.data = data;
    S.base = data.rows.map((r) => r.slice());
    S.values = data.rows.map((r) => r.slice());
    S.changed = new Set(data.changed.map(([i, j]) => key(i, j)));
    S.formulas = new Set(data.formulas.map(([i, j]) => key(i, j)));
    S.latCol = col("COORD:LAT"); S.lonCol = col("COORD:LON"); S.idCol = col("SAMPLEID");
    S.rowText = [];
    for (let i = 0; i < S.values.length; i++) updateRowText(i);
    evaluateAll();
    describeRules();
    renderTable();
    updateDirty();
    resizeCanvas();
    fitView();
    drawMap();
    if (data.saved) {
      for (const el of ["dl-reviewed", "dl-review-report"]) $(el).hidden = false;
    }
    setStatus("review-status", S.values.length + " record caricati.", "ok");
  } catch (err) {
    setStatus("review-status", err.message, "error");
  }
}

document.addEventListener("DOMContentLoaded", init);
