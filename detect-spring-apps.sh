#!/usr/bin/env bash
#
# detect-spring-apps.sh
# ---------------------
# Inventory Spring applications running on one or many Tanzu Cloud Foundry
# (Tanzu Application Service / PCF) foundations and report them as a terminal
# table, a CSV file, and a self-contained interactive HTML report.
#
# Detection: an app counts as Spring when its *detected* buildpack (read from
# the app's current droplet) is the Java buildpack. This is the practical ~95%
# filter for Spring on TAS. With --probe, each candidate's route is hit at
# /cloudfoundryapplication; a 200/401/403 upgrades the app to CONFIRMED Spring
# Boot. Platform/system apps are excluded by org name.
#
# Talks to the Cloud Controller v3 API via `cf curl`, so it works against any
# foundation you can `cf login` to -- no Tanzu Hub access required.
#
# Requires: cf (v8+), jq (1.6+). Optional: column (pretty table), curl (--probe).
# Written to run on bash 3.2 (stock macOS) and Linux jump hosts -- no
# associative arrays; jq performs all GUID->name joins.

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults / globals
# ---------------------------------------------------------------------------
PROBE=false
CONFIG=""
API=""
CF_USER=""
EXCLUDE_ORGS="system,p-spring-cloud-services,p-dataflow"
INCLUDE_SYSTEM=false
CONCURRENCY=8
PROBE_TIMEOUT=5

WANT_TABLE=true
WANT_CSV=true
WANT_HTML=true
DEBUG=false

TS="$(date +%Y%m%dT%H%M%S)"
CSV_FILE="spring-apps-${TS}.csv"
HTML_FILE="spring-apps-${TS}.html"

PROG="$(basename "$0")"

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
die()  { printf 'Error: %s\n' "$*" >&2; exit 1; }
warn() { printf 'Warning: %s\n' "$*" >&2; }
log()  { printf '%s\n' "$*" >&2; }
dbg()  { $DEBUG && printf 'debug: %s\n' "$*" >&2 || true; }
need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

# Indirect variable read that works on bash 3.2 (no ${!name} reliance).
get_var() { eval "printf '%s' \"\${$1-}\""; }

usage() {
  cat <<EOF
$PROG -- detect Spring apps across Tanzu Cloud Foundry foundations

USAGE
  $PROG [options]                       # use the foundation you're logged into
  $PROG --config foundations.json [..]  # sweep many foundations
  $PROG --api https://api.sys.ex.com -u user [..]

CONNECTION
  (no flags)            Use the current 'cf' session (run 'cf login' first).
  --config FILE         JSON array of foundations: [{ "name","api",
                        "username","skip_ssl"? }, ...]. Passwords come from env
                        vars CF_PASSWORD_<NAME> (NAME upper-cased, non-alnum ->
                        '_') with fallback CF_PASSWORD. Never hardcode secrets.
  --api URL             Ad-hoc single foundation API endpoint.
  -u, --user NAME       Username for --api (password via CF_PASSWORD or prompt).
  --skip-ssl            Skip TLS validation for --api.

DETECTION
  --probe               Also hit /cloudfoundryapplication on each candidate's
                        route to CONFIRM Spring Boot (needs network access to
                        the app routes). Without it, matches are labeled LIKELY.
  --exclude-orgs LIST   Comma-separated org names to treat as platform/system
                        and exclude. Default: $EXCLUDE_ORGS
  --include-system      Do not exclude any orgs.
  --concurrency N       Parallel probe/route workers (default $CONCURRENCY).
  --probe-timeout S     Per-probe timeout in seconds (default $PROBE_TIMEOUT).

OUTPUT (table + CSV + HTML are all produced by default)
  --csv FILE            CSV path (default $CSV_FILE).
  --no-csv              Do not write CSV.
  --html FILE           HTML path (default $HTML_FILE).
  --no-html             Do not write HTML.
  --no-table            Do not print the terminal table.
  --debug               Print per-foundation diagnostics (counts, sample
                        droplet path, detected buildpack names) to stderr.
  -h, --help            Show this help.

EXAMPLES
  cf login -a https://api.sys.dc1.example.com && $PROG
  $PROG --probe --csv prod-spring.csv
  CF_PASSWORD_PROD_DC1=secret $PROG --config foundations.json --probe
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
SKIP_SSL=false
while [ $# -gt 0 ]; do
  case "$1" in
    --probe)          PROBE=true ;;
    --config)         CONFIG="${2:-}"; shift ;;
    --api)            API="${2:-}"; shift ;;
    -u|--user)        CF_USER="${2:-}"; shift ;;
    --skip-ssl)       SKIP_SSL=true ;;
    --exclude-orgs)   EXCLUDE_ORGS="${2:-}"; shift ;;
    --include-system) INCLUDE_SYSTEM=true ;;
    --concurrency)    CONCURRENCY="${2:-}"; shift ;;
    --probe-timeout)  PROBE_TIMEOUT="${2:-}"; shift ;;
    --csv)            CSV_FILE="${2:-}"; WANT_CSV=true; shift ;;
    --no-csv)         WANT_CSV=false ;;
    --html)           HTML_FILE="${2:-}"; WANT_HTML=true; shift ;;
    --no-html)        WANT_HTML=false ;;
    --no-table)       WANT_TABLE=false ;;
    --debug)          DEBUG=true ;;
    -h|--help)        usage; exit 0 ;;
    *)                die "unknown option: $1 (try --help)" ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
need cf
need jq
$PROBE && need curl || true

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/spring-detect.XXXXXX")"
cleanup() { rm -rf "$TMPROOT"; }
trap cleanup EXIT INT TERM

ALL_ROWS="$TMPROOT/all_rows.jsonl"; : > "$ALL_ROWS"
SKIPPED="$TMPROOT/skipped_parts";   : > "$SKIPPED"

# ---------------------------------------------------------------------------
# CC API: paginated GET -> JSON-lines of .resources[]
# ---------------------------------------------------------------------------
fetch_all_resources() {
  # $1 = CC path (e.g. /v3/apps?per_page=100), $2 = output file (truncated)
  local path="$1" out="$2" body
  : > "$out"
  while [ -n "$path" ] && [ "$path" != "null" ]; do
    body="$(cf curl "$path")" || die "cf curl failed for $path"
    if printf '%s' "$body" | jq -e 'type=="object" and has("errors") and (.errors|length>0)' >/dev/null 2>&1; then
      die "Cloud Controller error on $path: $(printf '%s' "$body" | jq -r '.errors[0].detail // "unknown"')"
    fi
    printf '%s' "$body" | jq -c '.resources[]?' >> "$out"
    path="$(printf '%s' "$body" | jq -r '.pagination.next.href // empty' | sed -E 's#^https?://[^/]+##')"
  done
}

# ---------------------------------------------------------------------------
# Probe one route for the Spring Boot CF actuator integration.
# Exported so xargs worker shells can call it.
# ---------------------------------------------------------------------------
probe_one() {
  local guid="$1" url="$2" code
  code="$(curl -s -k -o /dev/null -w '%{http_code}' --max-time "${PROBE_TIMEOUT:-5}" \
          "https://${url}/cloudfoundryapplication" 2>/dev/null || echo 000)"
  printf '%s\t%s\n' "$guid" "$code"
}
export -f probe_one
export PROBE_TIMEOUT

# Fetch one app's current droplet (link href ends in /droplets/current, not a
# droplet guid) and emit its detected buildpacks. Exported for xargs workers.
fetch_droplet() {
  local guid="$1" path="$2" body
  body="$(cf curl "$path" 2>/dev/null)" || return 0
  printf '%s' "$body" | jq -ce 'type=="object" and has("buildpacks")' >/dev/null 2>&1 || return 0
  printf '%s' "$body" | jq -c --arg g "$guid" \
    '{app_guid:$g,
      bp_names:[.buildpacks[]?.name],
      bp_lang:[.buildpacks[]?.buildpack_name],
      detect:[.buildpacks[]?.detect_output]}'
}
export -f fetch_droplet

# jq program: join orgs/spaces/apps/droplets and classify Spring candidates.
read -r -d '' CLASSIFY <<'JQ' || true
  ($orgs   | map({key:.guid,     value:.name}) | from_entries) as $O
| ($spaces | map({key:.guid,     value:.})     | from_entries) as $S
| ($drops  | map({key:.app_guid, value:.})     | from_entries) as $D
| ($exclude | ascii_downcase | split(",") | map(gsub("^ +| +$";"")) | map(select(length>0))) as $EX
| $apps[]
| . as $a
| ($S[$a.space_guid]) as $sp
| (if $sp == null then "<unknown>" else ($O[$sp.org_guid] // "<unknown>") end) as $org
| (if $sp == null then "<unknown>" else $sp.name end) as $space
| ($org | ascii_downcase) as $orglo
| ($D[$a.guid]) as $d
| select($d != null)
| ((($d.bp_names // []) + ($d.bp_lang // []) + ($d.detect // []) + ($a.user_bps // []))
     | map(select(. != null) | ascii_downcase)) as $bps
| select($bps | any(test("java") or test("spring")))
| select($include_system or (($EX | index($orglo)) == null))
| (($d.bp_names // []) | map(select(. != null)) | join(",")) as $lbl
| { foundation: $foundation,
    org: $org,
    space: $space,
    app: $a.name,
    buildpack: (if $lbl == "" then ($bps[0] // "java") else $lbl end),
    confidence: "LIKELY",
    app_guid: $a.guid }
JQ

# ---------------------------------------------------------------------------
# Query a single (already-authenticated) foundation; append rows to $ALL_ROWS.
# ---------------------------------------------------------------------------
collect_foundation() {
  local fname="$1"
  local wd; wd="$TMPROOT/work_$(printf '%s' "$fname" | tr -c 'A-Za-z0-9' '_')"
  rm -rf "$wd"; mkdir -p "$wd"

  log "[$fname] querying orgs, spaces, apps ..."
  fetch_all_resources "/v3/organizations?per_page=100" "$wd/orgs_raw.jsonl"
  jq -c '{guid:.guid, name:.name}' "$wd/orgs_raw.jsonl" > "$wd/orgs.jsonl"

  fetch_all_resources "/v3/spaces?per_page=100" "$wd/spaces_raw.jsonl"
  jq -c '{guid:.guid, name:.name, org_guid:.relationships.organization.data.guid}' \
     "$wd/spaces_raw.jsonl" > "$wd/spaces.jsonl"

  fetch_all_resources "/v3/apps?per_page=100" "$wd/apps_raw.jsonl"
  jq -c '{guid:.guid, name:.name, state:.state,
          space_guid:.relationships.space.data.guid,
          droplet_path:((.links.current_droplet.href // "") | sub("^https?://[^/]+";"")),
          user_bps:((.lifecycle.data.buildpacks) // [])}' \
     "$wd/apps_raw.jsonl" > "$wd/apps.jsonl"
  dbg "[$fname] orgs=$(wc -l < "$wd/orgs.jsonl" | tr -d ' ') spaces=$(wc -l < "$wd/spaces.jsonl" | tr -d ' ') apps=$(wc -l < "$wd/apps.jsonl" | tr -d ' ')"
  dbg "[$fname] sample current_droplet path: $(jq -r 'select(.droplet_path!="")|.droplet_path' "$wd/apps.jsonl" | head -1)"

  # Buildpack truth lives on each app's *current droplet*. The current_droplet
  # link href ends in /droplets/current (not a droplet guid), so fetch it
  # directly per app, in parallel, and read the detected buildpacks.
  jq -r 'select(.droplet_path != "") | "\(.guid) \(.droplet_path)"' "$wd/apps.jsonl" > "$wd/app_droplet.txt"
  : > "$wd/droplets.jsonl"
  if [ -s "$wd/app_droplet.txt" ]; then
    log "[$fname] fetching buildpacks for $(wc -l < "$wd/app_droplet.txt" | tr -d ' ') app droplet(s) ..."
    < "$wd/app_droplet.txt" xargs -P "$CONCURRENCY" -n 2 \
      bash -c 'fetch_droplet "$1" "$2"' _ >> "$wd/droplets.jsonl" || true
  fi
  dbg "[$fname] droplets resolved: $(wc -l < "$wd/droplets.jsonl" | tr -d ' ')"
  dbg "[$fname] detected buildpacks: $(jq -r '(.bp_names[]?, .bp_lang[]?) // empty' "$wd/droplets.jsonl" | sort | uniq -c | sort -rn | awk '{printf "%s(%s) ",$2,$1}')"

  # Join + classify.
  jq -n -c \
     --arg foundation "$fname" \
     --arg exclude "$EXCLUDE_ORGS" \
     --argjson include_system "$INCLUDE_SYSTEM" \
     --slurpfile orgs   "$wd/orgs.jsonl" \
     --slurpfile spaces "$wd/spaces.jsonl" \
     --slurpfile drops  "$wd/droplets.jsonl" \
     --slurpfile apps   "$wd/apps.jsonl" \
     "$CLASSIFY" > "$wd/candidates.jsonl"

  local n total_apps have_dp unstaged
  n="$(wc -l < "$wd/candidates.jsonl" | tr -d ' ')"
  total_apps="$(wc -l < "$wd/apps.jsonl" | tr -d ' ')"
  have_dp="$(wc -l < "$wd/droplets.jsonl" | tr -d ' ')"
  unstaged=$((total_apps - have_dp))
  [ "$unstaged" -ge 0 ] || unstaged=0
  printf '%s\n' "$unstaged" >> "$SKIPPED"
  log "[$fname] $n candidate Spring app(s)."

  if $PROBE && [ "$n" -gt 0 ]; then
    log "[$fname] probing /cloudfoundryapplication on candidates ..."
    jq -r '.app_guid' "$wd/candidates.jsonl" | sort -u > "$wd/cand_guids.txt"
    : > "$wd/routes.jsonl"
    < "$wd/cand_guids.txt" xargs -n 50 | while read -r grp; do
      [ -n "$grp" ] || continue
      ids="$(printf '%s' "$grp" | tr ' ' ',')"
      fetch_all_resources "/v3/routes?app_guids=${ids}&per_page=100" "$wd/routes_part.jsonl"
      jq -c '{url:.url, apps:[.destinations[]?.app.guid]}' "$wd/routes_part.jsonl" >> "$wd/routes.jsonl"
    done
    # First route URL per candidate app guid.
    jq -r '.url as $u | .apps[] | "\(.)\t\($u)"' "$wd/routes.jsonl" \
      | awk -F'\t' 'NF==2 && !seen[$1]++' > "$wd/guid_url.tsv"
    : > "$wd/probe_targets.txt"
    while IFS="$(printf '\t')" read -r g u; do
      [ -n "$g" ] && [ -n "$u" ] || continue
      if grep -qxF "$g" "$wd/cand_guids.txt"; then printf '%s %s\n' "$g" "$u"; fi
    done < "$wd/guid_url.tsv" >> "$wd/probe_targets.txt"

    : > "$wd/probe_results.tsv"
    if [ -s "$wd/probe_targets.txt" ]; then
      < "$wd/probe_targets.txt" xargs -P "$CONCURRENCY" -n 2 \
        bash -c 'probe_one "$1" "$2"' _ >> "$wd/probe_results.tsv" || true
    fi

    jq -c --slurpfile pr <(jq -R -c 'select(length>0)|split("\t")|{guid:.[0],code:.[1]}' "$wd/probe_results.tsv") '
        ($pr | map({key:.guid, value:.code}) | from_entries) as $P
        | .confidence = (if ((($P[.app_guid]) // "") | test("^(200|401|403)$")) then "CONFIRMED" else .confidence end)
      ' "$wd/candidates.jsonl" > "$wd/candidates2.jsonl"
    mv "$wd/candidates2.jsonl" "$wd/candidates.jsonl"

    local confd
    confd="$(jq -r 'select(.confidence=="CONFIRMED")|.app' "$wd/candidates.jsonl" | wc -l | tr -d ' ')"
    log "[$fname] $confd confirmed via actuator."
  fi

  jq -c '{foundation,org,space,app,buildpack,confidence}' "$wd/candidates.jsonl" >> "$ALL_ROWS"
}

# ---------------------------------------------------------------------------
# HTML report (self-contained: inline CSS + vanilla JS, no external refs)
# ---------------------------------------------------------------------------
html_head() {
cat <<'SPRING_HTML_HEAD'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Spring Applications Inventory</title>
<style>
:root{
  --green:#6db33f; --green-d:#4e8a2b; --ink:#1f2933; --muted:#67727e;
  --bg:#f4f6f8; --card:#fff; --line:#e3e8ee;
  --shadow:0 1px 3px rgba(16,24,40,.08),0 1px 2px rgba(16,24,40,.06);
}
@media (prefers-color-scheme:dark){
  :root{ --ink:#e6edf3; --muted:#9aa7b2; --bg:#0f1419; --card:#161c23; --line:#263039;
         --shadow:0 1px 3px rgba(0,0,0,.4); }
}
*{box-sizing:border-box}
body{margin:0;color:var(--ink);background:var(--bg);
  font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;}
.hero{background:linear-gradient(135deg,#6db33f 0%,#4e8a2b 60%,#2f6b1f 100%);
  color:#fff;padding:30px 24px;box-shadow:var(--shadow);}
.hero-inner{max-width:1240px;margin:0 auto;display:flex;align-items:center;gap:16px;}
.hero .leaf{font-size:44px;filter:drop-shadow(0 2px 4px rgba(0,0,0,.25));}
.hero h1{margin:0;font-size:25px;font-weight:700;letter-spacing:.2px;}
.hero .sub{margin:5px 0 0;opacity:.93;font-size:13px;}
main{max-width:1240px;margin:0 auto;padding:24px;}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:14px;margin-bottom:22px;}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:16px 18px;box-shadow:var(--shadow);}
.card-val{font-size:30px;font-weight:700;line-height:1;color:var(--green-d);}
@media (prefers-color-scheme:dark){.card-val{color:var(--green);}}
.card-lbl{margin-top:6px;font-size:12px;text-transform:uppercase;letter-spacing:.06em;color:var(--muted);}
.toolbar{display:flex;flex-wrap:wrap;gap:10px;align-items:center;margin-bottom:14px;}
.toolbar input,.toolbar select{padding:9px 12px;border:1px solid var(--line);border-radius:9px;
  background:var(--card);color:var(--ink);font-size:14px;}
.toolbar input{flex:1;min-width:220px;}
.toolbar input:focus,.toolbar select:focus{outline:2px solid var(--green);outline-offset:0;border-color:var(--green);}
#dl-csv{cursor:pointer;border:1px solid var(--green);background:var(--green);color:#fff;
  font-weight:600;padding:9px 14px;border-radius:9px;}
#dl-csv:hover{background:var(--green-d);}
.count{color:var(--muted);font-size:13px;margin-left:auto;}
.table-wrap{background:var(--card);border:1px solid var(--line);border-radius:12px;
  overflow:auto;box-shadow:var(--shadow);max-height:72vh;}
table{border-collapse:collapse;width:100%;font-size:14px;}
thead th{position:sticky;top:0;background:var(--card);text-align:left;padding:12px 14px;
  border-bottom:2px solid var(--line);cursor:pointer;user-select:none;white-space:nowrap;
  color:var(--muted);font-size:12px;text-transform:uppercase;letter-spacing:.05em;}
thead th:hover{color:var(--green-d);}
thead th.asc::after{content:" \25B2";font-size:10px;}
thead th.desc::after{content:" \25BC";font-size:10px;}
tbody td{padding:11px 14px;border-bottom:1px solid var(--line);}
tbody tr:nth-child(even){background:rgba(109,179,63,.045);}
tbody tr:hover{background:rgba(109,179,63,.11);}
.app-cell{font-weight:600;}
.badge{display:inline-block;padding:3px 10px;border-radius:999px;font-size:12px;font-weight:600;white-space:nowrap;}
.b-conf{background:var(--green);color:#fff;}
.b-likely{background:transparent;color:#b7791f;border:1px solid #e0b341;}
@media (prefers-color-scheme:dark){.b-likely{color:#e0b341;}}
.empty{padding:40px;text-align:center;color:var(--muted);}
footer{margin-top:18px;color:var(--muted);font-size:12px;}
footer code{background:var(--line);padding:1px 5px;border-radius:4px;}
</style>
</head>
<body>
<header class="hero"><div class="hero-inner">
  <div class="leaf">&#127793;</div>
  <div>
    <h1>Spring Applications Inventory</h1>
    <p class="sub">Tanzu Cloud Foundry &middot; generated <span id="generated"></span></p>
  </div>
</div></header>
<main>
  <section class="cards" id="cards"></section>
  <section class="toolbar">
    <input id="search" type="search" placeholder="Search apps, orgs, spaces, buildpacks...">
    <select id="f-foundation"></select>
    <select id="f-org"></select>
    <select id="f-conf">
      <option value="">All confidence</option>
      <option value="CONFIRMED">Confirmed</option>
      <option value="LIKELY">Likely</option>
    </select>
    <button id="dl-csv" type="button">Download CSV</button>
    <span class="count" id="count"></span>
  </section>
  <section class="table-wrap">
    <table id="tbl">
      <thead><tr>
        <th data-k="foundation">Foundation</th>
        <th data-k="org">Org</th>
        <th data-k="space">Space</th>
        <th data-k="app">App</th>
        <th data-k="buildpack">Buildpack</th>
        <th data-k="confidence">Confidence</th>
      </tr></thead>
      <tbody id="rows"></tbody>
    </table>
  </section>
  <footer>Detected via Cloud Controller v3 buildpack inspection.
    &ldquo;Confirmed&rdquo; means the app responded at <code>/cloudfoundryapplication</code>.</footer>
</main>
<script>
SPRING_HTML_HEAD
}

html_tail() {
cat <<'SPRING_HTML_TAIL'
(function(){
  document.getElementById('generated').textContent = GENERATED;

  var total = DATA.length;
  var confirmed = DATA.filter(function(r){return r.confidence==='CONFIRMED';}).length;
  var foundations = (new Set(DATA.map(function(r){return r.foundation;}))).size;
  var orgs = (new Set(DATA.map(function(r){return r.foundation+'/'+r.org;}))).size;
  var spaces = (new Set(DATA.map(function(r){return r.foundation+'/'+r.org+'/'+r.space;}))).size;
  var showF = foundations > 1;

  var cards = [['Spring apps',total],['Confirmed',confirmed],['Likely',total-confirmed],
               ['Foundations',foundations],['Orgs',orgs],['Spaces',spaces]];
  var cardWrap = document.getElementById('cards');
  cards.forEach(function(c){
    var d=document.createElement('div'); d.className='card';
    var v=document.createElement('div'); v.className='card-val'; v.textContent=c[1];
    var l=document.createElement('div'); l.className='card-lbl'; l.textContent=c[0];
    d.appendChild(v); d.appendChild(l); cardWrap.appendChild(d);
  });

  function fillSelect(id, vals, allLabel){
    var sel=document.getElementById(id);
    var o=document.createElement('option'); o.value=''; o.textContent=allLabel; sel.appendChild(o);
    Array.from(new Set(vals)).sort().forEach(function(v){
      var op=document.createElement('option'); op.value=v; op.textContent=v; sel.appendChild(op);
    });
  }
  fillSelect('f-foundation', DATA.map(function(r){return r.foundation;}), 'All foundations');
  fillSelect('f-org', DATA.map(function(r){return r.org;}), 'All orgs');
  if(!showF){
    document.getElementById('f-foundation').style.display='none';
    var th=document.querySelector('th[data-k=foundation]'); if(th) th.style.display='none';
  }

  var sortKey='app', sortDir=1, view=DATA.slice();

  function sortView(){
    view.sort(function(a,b){
      var x=(a[sortKey]||'').toString().toLowerCase(), y=(b[sortKey]||'').toString().toLowerCase();
      return x<y?-sortDir : x>y?sortDir : 0;
    });
  }
  function badge(conf){
    var s=document.createElement('span');
    s.className='badge '+(conf==='CONFIRMED'?'b-conf':'b-likely');
    s.textContent=conf; return s;
  }
  function render(){
    var tb=document.getElementById('rows'); tb.textContent='';
    view.forEach(function(r){
      var tr=document.createElement('tr');
      [['foundation',r.foundation],['org',r.org],['space',r.space],['app',r.app],['buildpack',r.buildpack]]
        .forEach(function(cell){
          if(cell[0]==='foundation' && !showF) return;
          var td=document.createElement('td'); td.textContent=cell[1];
          if(cell[0]==='app') td.className='app-cell';
          tr.appendChild(td);
        });
      var tdc=document.createElement('td'); tdc.appendChild(badge(r.confidence)); tr.appendChild(tdc);
      tb.appendChild(tr);
    });
    document.getElementById('count').textContent = view.length+' of '+total+' shown';
  }
  function applyFilters(){
    var q=document.getElementById('search').value.trim().toLowerCase();
    var ff=document.getElementById('f-foundation').value;
    var fo=document.getElementById('f-org').value;
    var fc=document.getElementById('f-conf').value;
    view=DATA.filter(function(r){
      if(ff && r.foundation!==ff) return false;
      if(fo && r.org!==fo) return false;
      if(fc && r.confidence!==fc) return false;
      if(q){
        var hay=(r.foundation+' '+r.org+' '+r.space+' '+r.app+' '+r.buildpack).toLowerCase();
        if(hay.indexOf(q)===-1) return false;
      }
      return true;
    });
    sortView(); render();
  }
  document.getElementById('search').addEventListener('input', applyFilters);
  ['f-foundation','f-org','f-conf'].forEach(function(id){
    document.getElementById(id).addEventListener('change', applyFilters);
  });
  document.querySelectorAll('th[data-k]').forEach(function(th){
    th.addEventListener('click', function(){
      var k=th.getAttribute('data-k');
      if(sortKey===k) sortDir=-sortDir; else { sortKey=k; sortDir=1; }
      document.querySelectorAll('th[data-k]').forEach(function(t){t.classList.remove('asc','desc');});
      th.classList.add(sortDir===1?'asc':'desc');
      sortView(); render();
    });
  });
  document.getElementById('dl-csv').addEventListener('click', function(){
    var header=['foundation','org','space','app','buildpack','confidence'];
    function esc(v){ v=(v==null?'':String(v)); return /[",\n]/.test(v)?'"'+v.replace(/"/g,'""')+'"':v; }
    var lines=[header.join(',')].concat(view.map(function(r){
      return header.map(function(h){return esc(r[h]);}).join(',');
    }));
    var blob=new Blob([lines.join('\n')],{type:'text/csv'});
    var a=document.createElement('a'); a.href=URL.createObjectURL(blob);
    a.download='spring-apps-filtered.csv'; document.body.appendChild(a); a.click(); a.remove();
  });

  applyFilters();
})();
</script>
</body>
</html>
SPRING_HTML_TAIL
}

write_html() {
  local data_file="$1" out="$2" gen_human gen_json
  gen_human="$(date '+%Y-%m-%d %H:%M:%S %Z')"
  gen_json="$(jq -n --arg t "$gen_human" '$t')"
  {
    html_head
    printf 'const DATA = '
    # Escape <, >, & so the JSON can never break out of the <script> element.
    sed 's/</\\u003c/g; s/>/\\u003e/g; s/&/\\u0026/g' "$data_file"
    printf ';\nconst GENERATED = %s;\n' "$gen_json"
    html_tail
  } > "$out"
}

render_table() {
  if command -v column >/dev/null 2>&1; then column -t -s "$(printf '\t')"; else cat; fi
}

# ---------------------------------------------------------------------------
# Authenticate + run, per connection mode
# ---------------------------------------------------------------------------
run_session() {
  # Use the current cf session.
  local probe; probe="$(cf curl '/v3/apps?per_page=1' 2>/dev/null || true)"
  printf '%s' "$probe" | jq -e 'has("pagination")' >/dev/null 2>&1 \
    || die "not logged in or Cloud Controller unreachable. Run 'cf login', or use --api/--config."
  local api_url fname
  api_url="$(cf api 2>/dev/null | awk 'tolower($0) ~ /api endpoint/ {print $NF}' || true)"
  fname="$(printf '%s' "$api_url" | sed -E 's#^https?://##; s#/.*##')"
  [ -n "$fname" ] || fname="current-foundation"
  collect_foundation "$fname" || die "failed to query current foundation ($fname)."
}

run_api() {
  [ -n "$CF_USER" ] || die "--api requires -u/--user"
  local pass; pass="${CF_PASSWORD-}"
  if [ -z "$pass" ]; then
    printf 'Password for %s @ %s: ' "$CF_USER" "$API" >&2
    read -r -s pass; printf '\n' >&2
  fi
  local fname; fname="$(printf '%s' "$API" | sed -E 's#^https?://##; s#/.*##')"
  (
    export CF_HOME="$TMPROOT/cfhome_api"; mkdir -p "$CF_HOME"
    if $SKIP_SSL; then cf api "$API" --skip-ssl-validation >/dev/null
    else cf api "$API" >/dev/null; fi
    CF_USERNAME="$CF_USER" CF_PASSWORD="$pass" cf auth >/dev/null
    collect_foundation "$fname"
  ) || die "failed to authenticate/query $API"
}

run_config() {
  [ -f "$CONFIG" ] || die "config file not found: $CONFIG"
  jq -e 'type=="array"' "$CONFIG" >/dev/null 2>&1 || die "config must be a JSON array of foundations."
  local count i name api uname skipssl san varname pass
  count="$(jq 'length' "$CONFIG")"
  [ "$count" -gt 0 ] || die "config has no foundations."
  i=0
  while [ "$i" -lt "$count" ]; do
    name="$(jq -r ".[$i].name // empty" "$CONFIG")"
    api="$(jq -r ".[$i].api // empty" "$CONFIG")"
    uname="$(jq -r ".[$i].username // empty" "$CONFIG")"
    skipssl="$(jq -r ".[$i].skip_ssl // false" "$CONFIG")"
    i=$((i+1))
    if [ -z "$name" ] || [ -z "$api" ]; then warn "config entry missing name/api -- skipping"; continue; fi
    if [ -z "$uname" ]; then warn "[$name] no username in config -- skipping"; continue; fi
    san="$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9' '_')"
    varname="CF_PASSWORD_${san}"
    pass="$(get_var "$varname")"
    [ -n "$pass" ] || pass="${CF_PASSWORD-}"
    if [ -z "$pass" ]; then warn "[$name] no password (set $varname or CF_PASSWORD) -- skipping"; continue; fi
    (
      export CF_HOME="$TMPROOT/cfhome_$san"; mkdir -p "$CF_HOME"
      if [ "$skipssl" = "true" ]; then cf api "$api" --skip-ssl-validation >/dev/null
      else cf api "$api" >/dev/null; fi
      CF_USERNAME="$uname" CF_PASSWORD="$pass" cf auth >/dev/null
      collect_foundation "$name"
    ) || warn "[$name] authentication or query failed -- skipping this foundation."
  done
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
if   [ -n "$CONFIG" ]; then run_config
elif [ -n "$API" ];    then run_api
else                        run_session
fi

# ---------------------------------------------------------------------------
# Render outputs
# ---------------------------------------------------------------------------
if [ ! -s "$ALL_ROWS" ]; then
  echo "No Spring applications found (after excluding system orgs: $EXCLUDE_ORGS)."
  exit 0
fi

SORTED="$TMPROOT/sorted.json"
jq -s 'sort_by(.foundation, .org, .space, .app)' "$ALL_ROWS" > "$SORTED"

nfound="$(jq 'length' "$SORTED")"
nconf="$(jq '[.[]|select(.confidence=="CONFIRMED")]|length' "$SORTED")"
nlikely=$((nfound - nconf))
nfd="$(jq '[.[].foundation]|unique|length' "$SORTED")"
skipped="$(awk '{s+=$1} END{print s+0}' "$SKIPPED" 2>/dev/null || echo 0)"
multi=false; if [ "$nfd" -gt 1 ]; then multi=true; fi

if $WANT_TABLE; then
  echo
  if $multi; then
    { printf 'FOUNDATION\tORG\tSPACE\tAPP\tBUILDPACK\tCONF\n'
      jq -r '.[]|[.foundation,.org,.space,.app,.buildpack,.confidence]|@tsv' "$SORTED"
    } | render_table
  else
    { printf 'ORG\tSPACE\tAPP\tBUILDPACK\tCONF\n'
      jq -r '.[]|[.org,.space,.app,.buildpack,.confidence]|@tsv' "$SORTED"
    } | render_table
  fi
fi

if $WANT_CSV; then
  { printf 'foundation,org,space,app,buildpack,confidence\n'
    jq -r '.[]|[.foundation,.org,.space,.app,.buildpack,.confidence]|@csv' "$SORTED"
  } > "$CSV_FILE"
fi

if $WANT_HTML; then
  write_html "$SORTED" "$HTML_FILE"
fi

echo
echo "Summary: $nfound Spring app(s) -- $nconf confirmed, $nlikely likely, across $nfd foundation(s)."
if [ "$skipped" -gt 0 ]; then
  echo "Note: $skipped app(s) had no current droplet (never staged) and were not classified."
fi
$WANT_CSV  && echo "CSV:  $CSV_FILE"  || true
$WANT_HTML && echo "HTML: $HTML_FILE" || true
