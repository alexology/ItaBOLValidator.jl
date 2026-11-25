"use strict";

const state = { session: null, preview: [], fields: [], taxonomy: null };
const $ = (id) => document.getElementById(id);

const STATUS_LABELS = {
  fill: "da compilare", overwrite: "da sovrascrivere", preserved: "conservato", unchanged: "già uguale",
  no_value: "nessun valore", invalid_coordinates: "coordinate non valide", formula_preserved: "formula conservata",
  conflict: "conflitto", case_fixed: "maiuscole corrette"
};
const REASON_LABELS = {
  outside_coverage: "fuori copertura", ambiguous: "ambiguo", boundary: "sul confine", no_match: "nessuna corrispondenza",
  nodata: "dato assente", unmapped: "categoria non mappata", out_of_range: "fuori intervallo",
  transform_failed: "trasformazione non riuscita", invalid_coordinates: "coordinate non valide",
  null_value: "valore nullo", elevation_above_sea: "quota sopra il livello del mare"
};
const COORD_LABELS = {
  latitude: "latitudine", longitude: "longitudine", missing: "mancante", invalid_format: "formato non valido",
  out_of_range: "fuori intervallo", nonfinite: "non finita"
};
const LOOKUP_LABELS = {
  found: "trovati", not_found: "non trovati", ambiguous: "omonimi", error: "errore di consultazione",
  skipped: "non consultati (limite o BOLD non disponibile)"
};

const label = (map, key) => map[key] || key.replace(/_/g, " ");

// Details come from the engine in English (they are also written to the CSV
// and the report); the page shows them in Italian.
const LAYER_STATUS_LABELS = Object.assign({}, REASON_LABELS, {
  outside_extent: "fuori copertura", invalid_coordinate: "coordinate non valide", inside: "valore nullo",
  ok: "valore nullo", unavailable: "layer non disponibile", disabled: "layer disattivato", invalid: "layer non valido",
  masked: "pixel escluso dalla maschera del raster"
});
const DETAIL_RULES = [
  [/^coordinates: (\w+)$/, (m, s) => "coordinate: " + coordLabel(s)],
  [/elevation (\S+) m above sea level; DEPTH from (\S+) not used/,
   (m, e, s) => "quota " + e + " m sopra il livello del mare; DEPTH da " + s + " non usata"],
  [/^formula cell; BOLD value (.*) not written$/, (m, v) => "cella con formula; valore BOLD " + v + " non scritto"],
  [/^no name to look up: /, () => "nessun nome da cercare: "],
  [/^not filled: /, () => "non compilato: "],
  [/ conflicts with /g, () => " è in conflitto con "],
  [/ vs BOLD /g, () => " contro BOLD "],
  [/; existing value kept/, () => "; valore esistente conservato"],
  [/^from /, () => "da "],
  [/^BOLD spelling$/, () => "grafia BOLD"],
  [/^standard capitalisation \(name not confirmed by BOLD\)$/, () => "iniziale maiuscola, epiteti minuscoli (nome non confermato da BOLD)"],
  [/^standard capitalisation$/, () => "iniziale maiuscola, epiteti minuscoli"],
  [/^BOLD has no (\w+) for /, (m, r) => "BOLD non ha " + r + " per "],
  [/: ambiguous \(/, () => ": ambiguo ("],
  [/: not found \(/, () => ": non trovato ("],
  [/: not looked up \(/, () => ": non consultato ("],
  [/: lookup failed \(/, () => ": consultazione non riuscita ("],
  [/not found in BOLD as (\w+)/g, (m, r) => "non trovato in BOLD come " + r],
  [/homonyms in BOLD: /g, () => "omonimi in BOLD: "],
  [/cannot be verified: the BOLD term search returned its maximum of (\d+) entries, so homonyms cannot be excluded/g,
   (m, n) => "non verificabile: la ricerca BOLD ha restituito il massimo di " + n + " voci, gli omonimi non si possono escludere"],
  [/lookup limit of (\d+) names per run reached/g, (m, n) => "raggiunto il limite di " + n + " nomi per esecuzione"],
  [/BOLD is temporarily refusing requests/g, () => "BOLD sta temporaneamente rifiutando le richieste"],
  [/hourly limit of (\d+) requests to BOLD reached; try again later/g,
   (m, n) => "raggiunto il limite di " + n + " richieste orarie a BOLD del server; riprova più tardi"],
  [/BOLD answered HTTP (\d+)/g, (m, c) => "BOLD ha risposto HTTP " + c],
  [/network error: /g, () => "errore di rete: "],
  [/BOLD returned invalid JSON/g, () => "BOLD ha restituito un JSON non valido"],
  [/BOLD response too large/g, () => "risposta di BOLD troppo grande"],
  [/unexpected BOLD term response/g, () => "risposta di BOLD inattesa"]
];
function translateDetail(text) {
  if (!text) return text;
  let out = text;
  for (const [re, fn] of DETAIL_RULES) out = out.replace(re, fn);
  // Geographic notes: "layer: status; layer: status".
  return out.replace(/(^|; )([\w.-]+): ([a-z_]+)(?=;|$)/g,
                     (m, sep, id, st) => sep + id + ": " + label(LAYER_STATUS_LABELS, st));
}
function coordLabel(key) {
  const [axis, ...rest] = key.split("_");
  return label(COORD_LABELS, axis) + " " + label(COORD_LABELS, rest.join("_"));
}

function setStatus(id, text, kind) {
  const el = $(id);
  el.textContent = text || "";
  el.className = "status" + (kind ? " " + kind : "");
}

async function request(url, options) {
  const res = await fetch(url, options);
  let body = null;
  try { body = await res.json(); } catch (e) { body = null; }
  if (!res.ok) {
    throw new Error((body && body.error) || ("Richiesta non riuscita (HTTP " + res.status + ")."));
  }
  return body;
}

function cell(tr, value, cls) {
  const td = document.createElement("td");
  td.textContent = value === null || value === undefined ? "" : String(value);
  if (cls) td.className = cls;
  tr.appendChild(td);
  return td;
}

function header(table, names) {
  const tr = document.createElement("tr");
  for (const n of names) {
    const th = document.createElement("th");
    th.textContent = n;
    tr.appendChild(th);
  }
  const thead = document.createElement("thead");
  thead.appendChild(tr);
  table.appendChild(thead);
  const tbody = document.createElement("tbody");
  table.appendChild(tbody);
  return tbody;
}

function renderFields(fields, existing) {
  const box = $("fields");
  box.replaceChildren();
  state.fields = fields;
  if (!fields.length) {
    const p = document.createElement("p");
    p.className = "hint";
    p.textContent = "Su questo server non ci sono layer geografici disponibili.";
    box.appendChild(p);
    return;
  }
  for (const f of fields) {
    const lab = document.createElement("label");
    lab.className = "choice";
    const input = document.createElement("input");
    input.type = "checkbox";
    input.name = "field";
    input.value = f.column;
    input.checked = true;
    lab.appendChild(input);
    const text = document.createElement("span");
    const count = existing && existing[f.column] ? " — " + existing[f.column] + " valori già presenti" : "";
    text.textContent = f.column + count;
    const layers = document.createElement("span");
    layers.className = "field-layers";
    layers.textContent = " da " + f.layers.map((l) => l.name + " (" + l.version + ")").join(", poi ");
    text.appendChild(layers);
    lab.appendChild(text);
    box.appendChild(lab);
  }
}

function renderTaxonomyOption(summary) {
  const available = state.taxonomy && state.taxonomy.available;
  const box = $("taxonomy");
  $("taxonomy-fieldset").hidden = !available;
  if (!available) { box.checked = false; return; }
  const t = summary.taxonomy;
  if (!t.columns_present) {
    box.checked = false;
    box.disabled = true;
    $("taxonomy-hint").textContent = " — il file non ha tutte le colonne tassonomiche BOLD";
    return;
  }
  box.disabled = false;
  box.checked = t.records_to_complete > 0;
  $("taxonomy-hint").textContent = " — " + t.records_to_complete + " record da completare, " + t.distinct_names +
    " nomi distinti da cercare (al massimo " + state.taxonomy.max_lookups + " consultazioni per esecuzione)";
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
  const el = $(id);
  el.href = "#";
  el.onclick = (event) => {
    event.preventDefault();
    downloadFile(session(), file).catch((err) => setStatus(statusId, err.message, "error"));
  };
}

// Short summary next to the run button; the options themselves stay in section 2.
function summarizeOptions() {
  if (!state.session) { $("options-summary").textContent = ""; return; }
  const fields = Array.from(document.querySelectorAll("input[name=field]:checked")).map((i) => i.value);
  const overwrite = document.querySelector("input[name=overwrite]:checked").value === "true";
  const taxonomy = !$("taxonomy-fieldset").hidden && $("taxonomy").checked;
  $("options-summary").textContent =
    (fields.length ? "Campi geografici: " + fields.join(", ") + (overwrite ? " (sovrascrivendo i valori esistenti)" : " (solo celle vuote)")
                   : "Nessun campo geografico") +
    "; tassonomia BOLD: " + (taxonomy ? "sì" : "no") + ". Le opzioni si cambiano nella sezione 2, qui sotto.";
}

function resetResults() {
  $("results").hidden = true;
  $("results-placeholder").hidden = false;
  $("results-section").classList.add("disabled");
}

async function upload(event) {
  event.preventDefault();
  const file = $("file").files[0];
  if (!file) return;
  if (!file.name.toLowerCase().endsWith(".xlsx")) {
    setStatus("upload-status", "Scegli un file .xlsx.", "error");
    return;
  }
  $("upload-button").disabled = true;
  $("enrich-button").disabled = true;
  $("config-section").classList.add("disabled");
  $("validation").hidden = true;
  resetResults();
  setStatus("upload-status", "Caricamento e validazione di " + file.name + " …");
  try {
    const body = await request("/api/upload", {
      method: "POST",
      headers: {
        "Content-Type": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "X-Filename": encodeURIComponent(file.name).replace(/%20/g, " ")
      },
      body: file
    });
    state.session = body.session;
    for (const id of ["review-link", "review-link-2"]) $(id).href = "/review#" + body.session;
    $("run-row").hidden = false;
    $("v-filename").textContent = body.filename;
    $("v-records").textContent = body.records;
    $("v-valid").textContent = body.valid_coordinates;
    const details = Object.entries(body.invalid_by_status || {}).map(([k, v]) => coordLabel(k) + ": " + v);
    $("v-invalid").textContent = body.invalid_coordinates + (details.length ? " (" + details.join("; ") + ")" : "");
    $("validation").hidden = false;
    renderFields(body.fields, body.existing_values);
    renderTaxonomyOption(body);
    $("config-section").classList.remove("disabled");
    const usable = body.fields.length > 0 || (state.taxonomy && state.taxonomy.available);
    $("enrich-button").disabled = body.records === 0 || !usable;
    summarizeOptions();
    setStatus("upload-status", body.records === 0 ? "Il file è valido ma non contiene record di campioni."
                                                   : "Il file è una submission BOLD valida.", "ok");
  } catch (err) {
    setStatus("upload-status", err.message, "error");
  } finally {
    $("upload-button").disabled = false;
  }
}

function kvTable(table, labels, values) {
  table.replaceChildren();
  const tbody = document.createElement("tbody");
  for (const [key, text] of Object.entries(labels)) {
    const tr = document.createElement("tr");
    const th = document.createElement("th");
    th.textContent = text;
    tr.appendChild(th);
    cell(tr, values[key], "num");
    tbody.appendChild(tr);
  }
  table.appendChild(tbody);
}

function renderSummary(result) {
  kvTable($("summary"), {
    input_specimens: "Record di campioni", valid_coordinates: "Coordinate valide",
    invalid_coordinates: "Coordinate non valide o mancanti", fields_populated: "Celle compilate",
    values_filled: "Celle vuote compilate", values_overwritten: "Valori esistenti sovrascritti",
    taxon_names_recapitalised: "Nomi tassonomici con maiuscole corrette",
    existing_values_preserved: "Valori esistenti conservati", existing_values_matching: "Valori esistenti già uguali",
    formula_cells_preserved: "Celle con formula non modificate", no_value: "Nessun valore affidabile disponibile",
    specimens_outside_coverage: "Campioni fuori da tutti i layer selezionati"
  }, result.summary);

  const pf = $("per-field");
  pf.replaceChildren();
  const body = header(pf, ["Campo", "Compilati", "Conservati", "Senza valore", "Motivi", "Categorie non mappate", "Ambigui (righe Excel)"]);
  for (const [field, s] of Object.entries(result.per_field)) {
    const tr = document.createElement("tr");
    cell(tr, field);
    cell(tr, s.populated, "num");
    cell(tr, s.existing_preserved, "num");
    cell(tr, s.no_value, "num");
    cell(tr, Object.entries(s.no_value_reasons).map(([k, v]) => label(REASON_LABELS, k) + ": " + v).join("; "));
    cell(tr, Object.entries(s.unmapped_categories).map(([k, v]) => k + " (" + v + ")").join("; "));
    cell(tr, s.ambiguous_excel_rows.slice(0, 50).join(", ") + (s.ambiguous_excel_rows.length > 50 ? " …" : ""));
    body.appendChild(tr);
  }
  if (!Object.keys(result.per_field).length) {
    const tr = document.createElement("tr");
    cell(tr, "Nessun campo geografico selezionato.").colSpan = 7;
    body.appendChild(tr);
  }

  const ds = $("datasets");
  ds.replaceChildren();
  const dbody = header(ds, ["Layer", "Versione", "Fonte", "Campi"]);
  for (const d of result.datasets) {
    const tr = document.createElement("tr");
    cell(tr, d.name);
    cell(tr, d.version);
    cell(tr, d.source);
    cell(tr, d.fields.join(", "));
    dbody.appendChild(tr);
  }
  const t = result.taxonomy;
  if (t) {
    const tr = document.createElement("tr");
    cell(tr, t.source);
    cell(tr, "consultata il " + t.retrieved_at);
    cell(tr, t.api);
    cell(tr, Object.keys(t.per_rank).join(", "));
    dbody.appendChild(tr);
  }
  renderTaxonomy(t);
}

function renderTaxonomy(t) {
  $("taxonomy-results").hidden = !t;
  if (!t) return;
  const statuses = Object.entries(t.records_by_lookup_status).map(([k, v]) => label(LOOKUP_LABELS, k) + ": " + v);
  $("taxonomy-note").textContent = t.records_looked_up + " record con un nome da cercare, " + t.distinct_names +
    " nomi distinti, " + t.network_lookups + " consultazioni a BOLD (gli altri dalla cache). Record: " +
    (statuses.join("; ") || "nessuno") + "." +
    (t.conflict_excel_rows.length ? " Conflitti alle righe Excel " + t.conflict_excel_rows.slice(0, 50).join(", ") +
                                    (t.conflict_excel_rows.length > 50 ? " …" : "") + "." : "");
  const pr = $("per-rank");
  pr.replaceChildren();
  const body = header(pr, ["Rango", "Compilati", "Maiuscole corrette", "Già uguali", "Conflitti", "Senza valore", "Formule conservate"]);
  for (const rank of state.taxonomy.columns) {
    const s = t.per_rank[rank];
    if (!s) continue;
    const tr = document.createElement("tr");
    cell(tr, rank);
    cell(tr, s.filled, "num");
    cell(tr, s.case_fixed, "num");
    cell(tr, s.already_matching, "num");
    cell(tr, s.conflict, "num");
    cell(tr, s.no_value, "num");
    cell(tr, s.formula_preserved, "num");
    body.appendChild(tr);
  }
  const un = $("unresolved");
  un.replaceChildren();
  const entries = Object.entries(t.names_not_resolved);
  un.hidden = !entries.length;
  if (!entries.length) return;
  const ubody = header(un, ["Esito", "Nomi"]);
  for (const [status, names] of entries) {
    const tr = document.createElement("tr");
    cell(tr, label(LOOKUP_LABELS, status));
    cell(tr, names.slice(0, 30).map(translateDetail).join("; ") + (names.length > 30 ? " …" : ""));
    ubody.appendChild(tr);
  }
}

function renderPreview() {
  const only = $("changes-only").checked;
  const changing = ["fill", "overwrite", "case_fixed"];
  const rows = state.preview.filter((r) => !only || changing.includes(r.status));
  const table = $("preview");
  table.replaceChildren();
  const body = header(table, ["Riga Excel", "ID campione", "Campo", "Valore originale", "Valore proposto", "Fonte", "Esito", "Dettaglio"]);
  for (const r of rows) {
    const tr = document.createElement("tr");
    cell(tr, r.excel_row, "num");
    cell(tr, r.specimen_id);
    cell(tr, r.field);
    cell(tr, r.original);
    cell(tr, r.proposed);
    cell(tr, r.source_layer === "BOLD taxonomy" ? "Tassonomia BOLD" : r.source_layer);
    cell(tr, label(STATUS_LABELS, r.status), "st-" + r.status);
    cell(tr, translateDetail(r.detail));
    body.appendChild(tr);
  }
  if (!rows.length) {
    const tr = document.createElement("tr");
    const td = cell(tr, only ? "Nessuna cella cambierà." : "Nessuna riga.");
    td.colSpan = 8;
    body.appendChild(tr);
  }
}

async function enrich(event) {
  event.preventDefault();
  const fields = Array.from(document.querySelectorAll("input[name=field]:checked")).map((i) => i.value);
  const taxonomy = !$("taxonomy-fieldset").hidden && $("taxonomy").checked;
  if (!fields.length && !taxonomy) {
    setStatus("enrich-status", "Seleziona almeno un campo o il completamento della tassonomia.", "error");
    return;
  }
  const overwrite = document.querySelector("input[name=overwrite]:checked").value === "true";
  $("enrich-button").disabled = true;
  resetResults();
  setStatus("enrich-status", taxonomy
    ? "Consultazione della tassonomia BOLD (circa un nome al secondo), estrazione dei valori geografici e scrittura del file …"
    : "Estrazione dei valori geografici e scrittura del file …");
  try {
    const result = await request("/api/enrich", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ session: state.session, fields: fields, overwrite: overwrite, taxonomy: taxonomy })
    });
    state.preview = result.preview;
    renderSummary(result);
    renderPreview();
    const shown = result.preview.length < result.preview_total
      ? "La pagina mostra " + result.preview.length + " righe su " + result.preview_total +
        " (prima tutte le modifiche); il CSV le contiene tutte. "
      : "";
    $("preview-note").textContent = shown + result.preview_changes + " celle cambieranno.";
    $("results").hidden = false;
    $("results-placeholder").hidden = true;
    $("results-section").classList.remove("disabled");
    setStatus("enrich-status", "Arricchimento completato: i risultati e i download sono nella sezione 3.", "ok");
    $("results-section").scrollIntoView({ behavior: "smooth", block: "start" });
  } catch (err) {
    setStatus("enrich-status", err.message, "error");
  } finally {
    $("enrich-button").disabled = false;
  }
}

async function discard() {
  if (!state.session) return;
  $("discard").disabled = true;
  try {
    // {discarded: false} means the session had already expired: nothing is left either.
    await request("/api/discard", {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ session: state.session })
    });
  } catch (err) {
    // Keep the session so that the user can retry; never claim a deletion that did not happen.
    setStatus("upload-status", "Eliminazione non riuscita: " + err.message + " Riprova; in ogni caso i file vengono " +
      "eliminati automaticamente dopo " + (state.retention || 60) + " minuti di inattività.", "error");
    return;
  } finally {
    $("discard").disabled = false;
  }
  state.session = null;
  resetResults();
  $("run-row").hidden = true;
  $("options-summary").textContent = "";
  $("validation").hidden = true;
  $("config-section").classList.add("disabled");
  $("enrich-button").disabled = true;
  $("fields").replaceChildren();
  setStatus("enrich-status", "");
  setStatus("upload-status", "I tuoi file sono stati eliminati dal server.", "ok");
}

async function init() {
  $("upload-form").addEventListener("submit", upload);
  $("file").addEventListener("change", () => {
    const f = $("file").files[0];
    $("file-name").textContent = f ? f.name : "Nessun file selezionato";
  });
  $("enrich-form").addEventListener("submit", enrich);
  $("enrich-form").addEventListener("change", summarizeOptions);
  $("changes-only").addEventListener("change", renderPreview);
  $("discard").addEventListener("click", discard);
  for (const [id, file] of [["dl-workbook", "workbook"], ["dl-report", "report"], ["dl-changes", "changes"]]) {
    bindDownload(id, file, () => state.session, "enrich-status");
  }
  try {
    const info = await request("/api/fields");
    state.retention = info.retention_minutes;
    state.taxonomy = info.taxonomy;
    $("taxonomy-fieldset").hidden = !info.taxonomy.available;
    $("limit-hint").textContent = "Dimensione massima del file: " + info.max_upload_mb + " MB. " +
      (info.fields.length ? "Campi geografici disponibili: " + info.fields.map((f) => f.column).join(", ") + ". "
                          : "Nessun layer geografico disponibile. ") +
      (info.taxonomy.available ? "Completamento della tassonomia BOLD disponibile. " : "") +
      "Al massimo " + info.max_records + " campioni per file. I file caricati e i risultati vengono eliminati " +
      "dal server dopo " + info.retention_minutes + " minuti di inattività, o subito con il pulsante in fondo ai risultati.";
  } catch (err) {
    setStatus("upload-status", err.message, "error");
  }
}

document.addEventListener("DOMContentLoaded", init);
