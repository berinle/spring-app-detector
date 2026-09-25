#!/usr/bin/env bash
#
# detect-spring-apps.sh
# ---------------------
# Inventory Spring applications running on one or many Tanzu Cloud Foundry
# (Tanzu Application Service / PCF) foundations and report them as a terminal
# table, a CSV file, and a self-contained interactive HTML report.
#
# Detection is evidence-based, strongest signal first:
#   SPRING_BOOT  the droplet's start command runs a Spring Boot launcher
#                (org.springframework.boot.loader...), the Java buildpack added
#                java-cfenv (Boot 3+), or --probe got Spring Boot's own
#                /cloudfoundryapplication security response.
#   SPRING       Spring evidence without proof of Boot: Spring auto-
#                reconfiguration on the classpath, a Spring Cloud Services
#                binding, or SPRING_* / JBP_CONFIG_SPRING* env vars.
#                With --inspect-droplets, apps still lacking evidence have
#                their droplet listed for Spring jars (e.g. a Spring MVC WAR).
#   JAVA         staged by the Java buildpack, but no Spring evidence found.
# Platform/system apps are excluded by org name. Reading start commands and
# env vars needs admin, admin_read_only or SpaceDeveloper; with less, apps
# fall back to JAVA and a warning is printed.
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
PROBE_TIMEOUT=10
INSPECT=false

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
  --probe               Also probe each running app's public HTTP routes at
                        /cloudfoundryapplication. Spring Boot's own security
                        response there upgrades the app to SPRING_BOOT. Needs
                        network access to the app routes.
  --inspect-droplets    For Java apps with no other Spring evidence, download
                        the droplet and look inside it for Spring jars
                        (spring-core, spring-boot, buildpack Spring support).
                        Catches Spring WARs on Tomcat. Each droplet is
                        typically 50-150 MB.
  --exclude-orgs LIST   Comma-separated org names to treat as platform/system
                        and exclude. Default: $EXCLUDE_ORGS
  --include-system      Do not exclude any orgs.
  --concurrency N       Parallel API/probe workers (default $CONCURRENCY).
  --probe-timeout S     Per-probe timeout in seconds (default $PROBE_TIMEOUT).

OUTPUT (table + CSV + HTML are all produced by default)
  --csv FILE            CSV path (default $CSV_FILE).
  --no-csv              Do not write CSV.
  --html FILE           HTML path (default $HTML_FILE).
  --no-html             Do not write HTML.
  --no-table            Do not print the terminal table.
  --debug               Print per-foundation diagnostics (counts, droplet
                        fetch results, detected buildpacks, classification
                        and probe response-code tallies) to stderr.
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
    --inspect-droplets) INSPECT=true ;;
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
export TMPROOT

ALL_ROWS="$TMPROOT/all_rows.jsonl"; : > "$ALL_ROWS"
STATS="$TMPROOT/stats.jsonl";       : > "$STATS"

# ---------------------------------------------------------------------------
# CC API: paginated GET -> JSON-lines of .resources[]
# ---------------------------------------------------------------------------
fetch_all_resources() {
  # $1 = CC path (e.g. /v3/apps?per_page=100), $2 = output file (truncated),
  # $3 = "soft" to warn and return 1 on failure instead of aborting.
  local path="$1" out="$2" soft="${3:-}" body err
  : > "$out"
  while [ -n "$path" ] && [ "$path" != "null" ]; do
    if ! body="$(cf curl "$path")"; then
      err="cf curl failed for $path"
    elif printf '%s' "$body" | jq -e 'type=="object" and has("errors") and (.errors|length>0)' >/dev/null 2>&1; then
      err="Cloud Controller error on $path: $(printf '%s' "$body" | jq -r '.errors[0].detail // "unknown"')"
    else
      err=""
    fi
    if [ -n "$err" ]; then
      [ "$soft" = "soft" ] || die "$err"
      warn "$err"; return 1
    fi
    printf '%s' "$body" | jq -c '.resources[]?' >> "$out"
    path="$(printf '%s' "$body" | jq -r '.pagination.next.href // empty' | sed -E 's#^https?://[^/]+##')"
  done
}

# ---------------------------------------------------------------------------
# Probe one app for Spring Boot's Cloud Foundry actuator endpoint.
# $2 is a comma-separated list of route URLs (host.domain[/path]), best first.
# A bare status code proves nothing (auth gateways and route services answer
# 401/403 on every path, SPA catch-alls answer 200), so an app is confirmed
# only when the response body is Spring Boot's own: the actuator's
# "security_error" JSON, or Boot's error JSON naming the probed path.
# Emits: guid <TAB> http_code <TAB> 1|0 (confirmed). Exported for xargs.
# ---------------------------------------------------------------------------
probe_one() {
  local guid="$1" urls="$2" url scheme path code seen="" tmp
  tmp="$(mktemp "$TMPROOT/probe.XXXXXX")" || return 0
  for url in $(printf '%s' "$urls" | tr ',' ' '); do
    for scheme in https http; do
      for path in /cloudfoundryapplication/health /cloudfoundryapplication; do
        : > "$tmp"
        code="$(curl -s -k -o "$tmp" -w '%{http_code}' --max-time "${PROBE_TIMEOUT:-10}" \
                --max-filesize 65536 "${scheme}://${url}${path}" 2>/dev/null)" || true
        [ -n "$code" ] || code=000
        [ "$code" = "000" ] || [ -n "$seen" ] || seen="$code"
        case "$code" in
          401|403|503)
            if head -c 8192 "$tmp" | grep -qE 'security_error|Authorization header is missing|Application id is not available|Cloud controller URL is not available|"path" *: *"[^"]*/cloudfoundryapplication'; then
              printf '%s\t%s\t1\n' "$guid" "$code"; rm -f "$tmp"; return 0
            fi ;;
        esac
        # Host unreachable over this scheme: skip its remaining paths.
        [ "$code" != "000" ] || break
      done
      # https answered, so don't retry the same route over plain http.
      [ "$code" = "000" ] || break
    done
  done
  printf '%s\t%s\t0\n' "$guid" "${seen:-000}"; rm -f "$tmp"
}
export -f probe_one
export PROBE_TIMEOUT

# Fetch one app's current droplet (link href ends in /droplets/current, not a
# droplet guid) and emit its buildpacks and detected start command, or why it
# could not be read. Exported for xargs workers.
fetch_droplet() {
  local guid="$1" path="$2" body
  if ! body="$(cf curl "$path" 2>/dev/null)"; then
    jq -nc --arg g "$guid" '{app_guid:$g, status:"fetch_failed", err:"cf curl failed"}'
    return 0
  fi
  printf '%s' "$body" | jq -c --arg g "$guid" '
    if type=="object" and ((.errors // []) | length) > 0 then
      {app_guid:$g,
       status:(if .errors[0].code == 10010 then "no_droplet" else "fetch_failed" end),
       err:(.errors[0].detail // "unknown")}
    elif type=="object" and has("guid") then
      {app_guid:$g, status:"ok", droplet_guid:.guid,
       bp_names:[.buildpacks[]?.name],
       bp_lang:[.buildpacks[]?.buildpack_name],
       detect:[.buildpacks[]?.detect_output],
       web_cmd:(.process_types.web // "")}
    else {app_guid:$g, status:"fetch_failed", err:"unexpected response"} end' 2>/dev/null \
  || jq -nc --arg g "$guid" '{app_guid:$g, status:"fetch_failed", err:"invalid JSON"}'
}
export -f fetch_droplet

# Emit the NAMES (never values) of an app's Spring-related env vars.
# Exported for xargs workers.
fetch_env() {
  local guid="$1" body
  body="$(cf curl "/v3/apps/$guid/environment_variables" 2>/dev/null)" || return 0
  printf '%s' "$body" | jq -c --arg g "$guid" '
    select(type=="object" and (.var|type)=="object")
    | {app_guid:$g,
       keys:[.var | to_entries[]
             | select((.key | test("^(SPRING_|JBP_CONFIG_SPRING)"))
                      or ((.key | test("^(JAVA_OPTS|JBP_CONFIG_JAVA_OPTS)$"))
                          and (.value | tostring | test("-Dspring\\."))))
             | .key]}' 2>/dev/null || true
}
export -f fetch_env

# Stream one droplet (a tgz) through `tar t` and report which Spring markers
# its file list contains. Needs CF_API_URL / CF_TOKEN in the environment.
# Emits: guid <TAB> ok|failed <TAB> comma-separated markers. Exported for xargs.
inspect_droplet() {
  set -o pipefail
  local guid="$1" dguid="$2" list status=ok k=""
  list="$(mktemp "$TMPROOT/inspect.XXXXXX")" || return 0
  $CF_SKIP_SSL && k="-k"
  curl -sSfL $k --max-time 600 -H "Authorization: $CF_TOKEN" \
       "$CF_API_URL/v3/droplets/$dguid/download" 2>/dev/null \
    | tar tzf - > "$list" 2>/dev/null || status=failed
  # Jar names come as spring-core-6.1.jar (Maven) or
  # org.springframework.spring-core-5.3.jar (sbt/Gradle dist), so match on
  # "start of name or dot" before the artifact id.
  local j='(^|/|\.)'
  printf '%s\t%s\t%s\n' "$guid" "$status" "$(
    { grep -qE "${j}spring-boot-[0-9][^/]*\.jar$|org/springframework/boot/loader/|/\.java-buildpack/container_customizer/" "$list" && echo spring-boot-jar
      grep -qE '/\.java-buildpack/java_cf_env/' "$list" && echo java-cfenv
      grep -qE "${j}spring-(webmvc|webflux)-[0-9][^/]*\.jar$" "$list" && echo spring-web-jar
      grep -qE "${j}spring-core-[0-9][^/]*\.jar$" "$list" && echo spring-core-jar
      grep -qE '/\.java-buildpack/spring_auto_reconfiguration/' "$list" && echo spring-auto-reconfig
      grep -qE "${j}(play_2\.1[0-9]|play-java_2\.1[0-9]|play-server_2\.1[0-9])-[0-9]" "$list" && echo framework:play
      grep -qE "quarkus-run\.jar$|${j}quarkus-core-[0-9]" "$list" && echo framework:quarkus
      grep -qE "${j}micronaut-(inject|runtime|http-server)-[0-9]" "$list" && echo framework:micronaut
      grep -qE "${j}dropwizard-core-[0-9]" "$list" && echo framework:dropwizard
      grep -qE "${j}helidon-webserver-[0-9]" "$list" && echo framework:helidon
    } | paste -sd, -)"
  rm -f "$list"
}
export -f inspect_droplet

# jq program: join orgs/spaces/droplets onto apps (one line per app).
read -r -d '' JOIN <<'JQ' || true
  ($orgs   | map({key:.guid,     value:.name}) | from_entries) as $O
| ($spaces | map({key:.guid,     value:.})     | from_entries) as $S
| ($drops  | map({key:.app_guid, value:.})     | from_entries) as $D
| ($exclude | ascii_downcase | split(",") | map(gsub("^ +| +$";"")) | map(select(length>0))) as $EX
| $apps[]
| . as $a
| ($S[$a.space_guid]) as $sp
| (if $sp == null then "<unknown>" else ($O[$sp.org_guid] // "<unknown>") end) as $org
| $a + { org: $org,
         space: (if $sp == null then "<unknown>" else $sp.name end),
         excluded: ((($include_system | not)) and (($EX | index($org | ascii_downcase)) != null)),
         drop: ($D[$a.guid] // null) }
JQ

# jq program: classify joined apps as SPRING_BOOT / SPRING / JAVA.
# Only the buildpack that actually staged the droplet counts (the final one;
# earlier ones are supply buildpacks), never the buildpack the app requests.
read -r -d '' CLASSIFY <<'JQ' || true
  ($scs | map({key:.app_guid, value:.names}) | from_entries) as $B
| $apps[]
| select((.excluded | not) and .drop != null and .drop.status == "ok")
| . as $a
| ($a.drop) as $d
| (($d.bp_names // []) | map(select(. != null))) as $names
| ((($names[-1] // "") + " " + ((($d.bp_lang // []) | map(select(. != null)))[-1] // ""))
    | ascii_downcase) as $final
| ($final | test("(^|[^a-z])java([^a-z]|$)")) as $javabp
| ($d.web_cmd // "") as $cmd
| ($cmd | test("org\\.springframework\\.boot\\.loader\\.")) as $bootcmd
| select($javabp or $bootcmd)
| (($d.detect // []) | map(select(. != null)) | join(" ")) as $det
| ($cmd + " " + $det) as $sig
| ([ (if $bootcmd then "boot-launcher" else empty end),
     (if ($sig | test("java_cf_env|java-cf-env")) then "java-cfenv" else empty end),
     (if ($sig | test("spring_auto_reconfiguration|spring-auto-reconfiguration")) then "spring-auto-reconfig" else empty end),
     (($B[$a.guid] // [])[] | "scs:" + .),
     (if ($cmd | test("play\\.core\\.server\\.")) then "framework:play" else empty end),
     (if ($cmd | test("quarkus-run\\.jar")) then "framework:quarkus" else empty end)
   ]) as $ev
| ($ev | map(select(startswith("framework:"))) | length > 0) as $other
| { foundation: $foundation,
    org: $a.org,
    space: $a.space,
    app: $a.name,
    state: ($a.state // ""),
    buildpack: (if ($names | length) > 0 then ($names | join(",")) else ($final | gsub("^ +| +$";"")) end),
    classification: (if ($ev | index("boot-launcher")) or ($ev | index("java-cfenv")) then "SPRING_BOOT"
                     elif ($ev | any(startswith("scs:"))) then "SPRING"
                     # Auto-reconfiguration only says spring-core is on the
                     # classpath; another framework may have brought it in.
                     elif ($ev | index("spring-auto-reconfig")) and ($other | not) then "SPRING"
                     else "JAVA" end),
    evidence: $ev,
    probe: "",
    cmd_hidden: ($cmd | test("PRIVATE DATA HIDDEN")),
    app_guid: $a.guid }
JQ

# ---------------------------------------------------------------------------
# Query a single (already-authenticated) foundation; append rows to $ALL_ROWS
# and one stats line to $STATS.
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
          lifecycle:(.lifecycle.type // "buildpack"),
          space_guid:.relationships.space.data.guid,
          droplet_path:((.links.current_droplet.href // "") | sub("^https?://[^/]+";""))}' \
     "$wd/apps_raw.jsonl" > "$wd/apps.jsonl"
  dbg "[$fname] orgs=$(wc -l < "$wd/orgs.jsonl" | tr -d ' ') spaces=$(wc -l < "$wd/spaces.jsonl" | tr -d ' ') apps=$(wc -l < "$wd/apps.jsonl" | tr -d ' ')"

  # Buildpack truth lives on each app's *current droplet*. The current_droplet
  # link href ends in /droplets/current (not a droplet guid), so fetch it
  # directly per app, in parallel. Docker apps have no buildpack to read.
  jq -r 'select(.droplet_path != "" and .lifecycle != "docker") | "\(.guid) \(.droplet_path)"' \
     "$wd/apps.jsonl" > "$wd/app_droplet.txt"
  : > "$wd/droplets.jsonl"
  if [ -s "$wd/app_droplet.txt" ]; then
    log "[$fname] fetching droplets for $(wc -l < "$wd/app_droplet.txt" | tr -d ' ') app(s) ..."
    < "$wd/app_droplet.txt" xargs -P "$CONCURRENCY" -n 2 \
      bash -c 'fetch_droplet "$1" "$2"' _ >> "$wd/droplets.jsonl" || true
  fi
  dbg "[$fname] droplet fetch: $(jq -r '.status' "$wd/droplets.jsonl" | sort | uniq -c | awk '{printf "%s=%s ",$2,$1}')"
  dbg "[$fname] detected buildpacks: $(jq -r '(.bp_names[]?, .bp_lang[]?) // empty' "$wd/droplets.jsonl" | sort | uniq -c | sort -rn | awk '{printf "%s(%s) ",$2,$1}')"
  if $DEBUG; then
    jq -r --arg f "$fname" 'select(.status=="fetch_failed") | "debug: [\($f)] droplet fetch failed for \(.app_guid): \(.err)"' \
       "$wd/droplets.jsonl" | head -5 >&2 || true
  fi

  jq -n -c \
     --arg exclude "$EXCLUDE_ORGS" \
     --argjson include_system "$INCLUDE_SYSTEM" \
     --slurpfile orgs   "$wd/orgs.jsonl" \
     --slurpfile spaces "$wd/spaces.jsonl" \
     --slurpfile drops  "$wd/droplets.jsonl" \
     --slurpfile apps   "$wd/apps.jsonl" \
     "$JOIN" > "$wd/joined.jsonl"

  # Spring Cloud Services bindings (config server, service registry, circuit
  # breaker) are Spring evidence. Optional: failures only lose this signal.
  : > "$wd/scs.jsonl"
  if fetch_all_resources "/v3/service_offerings?per_page=5000" "$wd/offerings_raw.jsonl" soft \
     && fetch_all_resources "/v3/service_plans?per_page=5000" "$wd/plans_raw.jsonl" soft \
     && fetch_all_resources "/v3/service_instances?type=managed&per_page=5000" "$wd/instances_raw.jsonl" soft \
     && fetch_all_resources "/v3/service_credential_bindings?type=app&per_page=5000" "$wd/bindings_raw.jsonl" soft; then
    jq -n -c \
       --slurpfile offerings "$wd/offerings_raw.jsonl" \
       --slurpfile plans     "$wd/plans_raw.jsonl" \
       --slurpfile instances "$wd/instances_raw.jsonl" \
       --slurpfile bindings  "$wd/bindings_raw.jsonl" '
        ($offerings | map({key:.guid, value:.name}) | from_entries) as $OF
      | ($plans | map({key:.guid, value:$OF[.relationships.service_offering.data.guid // ""]}) | from_entries) as $PL
      | ($instances | map({key:.guid, value:$PL[.relationships.service_plan.data.guid // ""]}) | from_entries) as $IN
      | [ $bindings[]
          | {app_guid:(.relationships.app.data.guid // ""), name:($IN[.relationships.service_instance.data.guid // ""] // "")}
          | select(.app_guid != "" and (.name | test("config-server|service-registry|circuit-breaker|spring-cloud"))) ]
      | group_by(.app_guid)[]
      | {app_guid:.[0].app_guid, names:(map(.name) | unique)}' > "$wd/scs.jsonl"
  else
    warn "[$fname] could not read service bindings; Spring Cloud Services evidence skipped."
  fi

  jq -n -c \
     --arg foundation "$fname" \
     --slurpfile apps "$wd/joined.jsonl" \
     --slurpfile scs  "$wd/scs.jsonl" \
     "$CLASSIFY" > "$wd/candidates.jsonl"

  # JAVA apps with no evidence yet: look for Spring env var names.
  jq -r 'select(.classification=="JAVA") | .app_guid' "$wd/candidates.jsonl" > "$wd/env_guids.txt"
  : > "$wd/envs.jsonl"
  if [ -s "$wd/env_guids.txt" ]; then
    log "[$fname] checking env vars of $(wc -l < "$wd/env_guids.txt" | tr -d ' ') Java app(s) without Spring evidence ..."
    < "$wd/env_guids.txt" xargs -P "$CONCURRENCY" -n 1 \
      bash -c 'fetch_env "$1"' _ >> "$wd/envs.jsonl" || true
    jq -c --slurpfile env "$wd/envs.jsonl" '
        ($env | map({key:.app_guid, value:.keys}) | from_entries) as $E
        | (($E[.app_guid] // []) | map("env:" + .)) as $k
        | if ($k | length) > 0 then .evidence += $k | .classification = "SPRING" else . end
      ' "$wd/candidates.jsonl" > "$wd/candidates2.jsonl"
    mv "$wd/candidates2.jsonl" "$wd/candidates.jsonl"
  fi

  if $INSPECT; then
    inspect_foundation "$fname" "$wd"
  fi

  local n hidden
  n="$(wc -l < "$wd/candidates.jsonl" | tr -d ' ')"
  hidden="$(jq -r 'select(.cmd_hidden) | .app_guid' "$wd/candidates.jsonl" | wc -l | tr -d ' ')"
  log "[$fname] $n Java/Spring app(s)."
  if [ "$hidden" -gt 0 ]; then
    warn "[$fname] start command hidden for $hidden app(s): this user can't read droplet details, so Spring Boot can't be recognised from the launcher. Run as admin, admin_read_only or SpaceDeveloper."
  fi

  if $PROBE && [ "$n" -gt 0 ]; then
    probe_foundation "$fname" "$wd"
  fi
  dbg "[$fname] classification: $(jq -r '.classification' "$wd/candidates.jsonl" | sort | uniq -c | awk '{printf "%s=%s ",$2,$1}')"

  jq -c '{foundation,org,space,app,state,buildpack,classification,
          evidence:(.evidence | join("; ")),probe}' "$wd/candidates.jsonl" >> "$ALL_ROWS"
  jq -s -c --arg f "$fname" --argjson h "$hidden" '[.[] | select(.excluded | not)] | {
      foundation: $f,
      docker:       (map(select(.lifecycle == "docker")) | length),
      no_droplet:   (map(select(.lifecycle != "docker" and (.drop == null or .drop.status == "no_droplet"))) | length),
      fetch_failed: (map(select(.drop.status == "fetch_failed")) | length),
      cmd_hidden:   $h }' "$wd/joined.jsonl" >> "$STATS"
}

# ---------------------------------------------------------------------------
# --inspect-droplets: list the files inside the droplets of JAVA apps that
# still have no Spring evidence. The buildpack puts Spring support for Tomcat
# apps in Tomcat's lib folder rather than the start command, and a WAR's own
# jars (WEB-INF/lib/spring-core-*.jar) are only visible here.
# ---------------------------------------------------------------------------
inspect_foundation() {
  local fname="$1" wd="$2"
  jq -r --slurpfile apps "$wd/joined.jsonl" '
      ($apps | map({key:.guid, value:(.drop.droplet_guid // "")}) | from_entries) as $DG
      | select(.classification=="JAVA") | "\(.app_guid) \($DG[.app_guid] // "")"' \
     "$wd/candidates.jsonl" | awk 'NF==2' > "$wd/inspect_targets.txt"
  : > "$wd/inspect.tsv"
  [ -s "$wd/inspect_targets.txt" ] || return 0

  # Droplet downloads need the raw API URL and a bearer token (cf curl can't
  # stream binaries). The redirect to the blobstore is signed, and curl does
  # not forward the token to a different host.
  local cfg="${CF_HOME:-$HOME}/.cf/config.json"
  CF_API_URL="$(jq -r '.Target // empty' "$cfg" 2>/dev/null || true)"
  CF_SKIP_SSL="$(jq -r '.SSLDisabled // false' "$cfg" 2>/dev/null || echo false)"
  CF_TOKEN="$(cf oauth-token 2>/dev/null || true)"
  if [ -z "$CF_API_URL" ] || [ -z "$CF_TOKEN" ]; then
    warn "[$fname] could not get the API URL or an OAuth token; droplet inspection skipped."
    return 0
  fi
  export CF_API_URL CF_SKIP_SSL CF_TOKEN

  log "[$fname] inspecting droplets of $(wc -l < "$wd/inspect_targets.txt" | tr -d ' ') Java app(s) without Spring evidence ..."
  < "$wd/inspect_targets.txt" xargs -P "$CONCURRENCY" -n 2 \
    bash -c 'inspect_droplet "$1" "$2"' _ >> "$wd/inspect.tsv" || true
  unset CF_TOKEN

  local failed
  failed="$(awk -F'\t' '$2!="ok"' "$wd/inspect.tsv" | wc -l | tr -d ' ')"
  [ "$failed" -eq 0 ] || warn "[$fname] $failed droplet download(s) failed; those apps stay JAVA."

  jq -c --slurpfile ins <(jq -R -c 'select(length>0) | split("\t")
                            | {guid:.[0], m:((.[2] // "") | split(",") | map(select(length>0)))}' "$wd/inspect.tsv") '
      ($ins | map({key:.guid, value:.m}) | from_entries) as $M
      | ($M[.app_guid] // []) as $m
      | def hit($x): $m | index($x) != null;
        if ($m | length) == 0 then .
        else .evidence = (.evidence + ($m | map(if startswith("framework:") then . else "droplet:" + . end)) | unique)
           # Spring jars alone are weak: Play, for one, ships spring-core for
           # form binding. With another framework present, they only count
           # as Spring when Spring MVC/WebFlux or Boot is there too.
           | .classification = (if hit("spring-boot-jar") or hit("java-cfenv") then "SPRING_BOOT"
                                elif hit("spring-web-jar") then "SPRING"
                                elif (hit("spring-core-jar") or hit("spring-auto-reconfig"))
                                     and (.evidence | any(startswith("framework:")) | not)
                                  then "SPRING"
                                else .classification end)
        end
    ' "$wd/candidates.jsonl" > "$wd/candidates2.jsonl"
  mv "$wd/candidates2.jsonl" "$wd/candidates.jsonl"
}

# ---------------------------------------------------------------------------
# --probe: hit each running candidate's public HTTP routes and upgrade apps
# whose response is Spring Boot's own CF actuator answer.
# ---------------------------------------------------------------------------
probe_foundation() {
  local fname="$1" wd="$2" grp ids
  jq -r 'select(.state=="STARTED" and .classification!="SPRING_BOOT") | .app_guid' \
     "$wd/candidates.jsonl" | sort -u > "$wd/cand_guids.txt"
  : > "$wd/probe_results.tsv"
  if [ -s "$wd/cand_guids.txt" ]; then
    log "[$fname] probing /cloudfoundryapplication on $(wc -l < "$wd/cand_guids.txt" | tr -d ' ') running app(s) ..."
    : > "$wd/domains.jsonl"
    fetch_all_resources "/v3/domains?per_page=100" "$wd/domains_raw.jsonl" soft \
      && jq -c '{guid:.guid, internal:(.internal // false)}' "$wd/domains_raw.jsonl" > "$wd/domains.jsonl" || true
    : > "$wd/routes.jsonl"
    xargs -n 50 < "$wd/cand_guids.txt" > "$wd/guid_groups.txt"
    while read -r grp; do
      [ -n "$grp" ] || continue
      ids="$(printf '%s' "$grp" | tr ' ' ',')"
      fetch_all_resources "/v3/routes?app_guids=${ids}&per_page=100" "$wd/routes_part.jsonl" soft || continue
      jq -c '{url:.url, protocol:(.protocol // "http"), host:(.host // ""), path:(.path // ""),
              domain:(.relationships.domain.data.guid // ""),
              apps:[.destinations[]?.app.guid]}' "$wd/routes_part.jsonl" >> "$wd/routes.jsonl"
    done < "$wd/guid_groups.txt"

    # Up to 3 public HTTP routes per app, root routes before path routes.
    # Internal (apps.internal), TCP and wildcard routes can't be probed.
    jq -n -r \
       --slurpfile routes  "$wd/routes.jsonl" \
       --slurpfile domains "$wd/domains.jsonl" \
       --rawfile   cands   "$wd/cand_guids.txt" '
        ($domains | map({key:.guid, value:.internal}) | from_entries) as $I
      | ($cands | split("\n") | map(select(length>0)) | map({key:., value:true}) | from_entries) as $C
      | [ $routes[]
          | select(.protocol == "http" and ($I[.domain] != true) and .host != "*" and (.url | startswith("*.") | not))
          | . as $r | .apps[] | select($C[.] == true) | {g:., url:$r.url, p:($r.path != "")} ]
      | group_by(.g)[]
      | "\(.[0].g) \(sort_by(.p) | map(.url) | reduce .[] as $u ([]; if any(.[]; . == $u) then . else . + [$u] end) | .[0:3] | join(","))"
      ' > "$wd/probe_targets.txt"

    if [ -s "$wd/probe_targets.txt" ]; then
      < "$wd/probe_targets.txt" xargs -P "$CONCURRENCY" -n 2 \
        bash -c 'probe_one "$1" "$2"' _ >> "$wd/probe_results.tsv" || true
    fi
  fi

  jq -c --slurpfile pr <(jq -R -c 'select(length>0) | split("\t") | {guid:.[0], code:.[1], ok:(.[2]=="1")}' "$wd/probe_results.tsv") '
      ($pr | map({key:.guid, value:.}) | from_entries) as $P
      | ($P[.app_guid]) as $r
      | if .classification == "SPRING_BOOT" then .probe = "skipped"
        elif .state != "STARTED" then .probe = "stopped"
        elif $r == null then .probe = "no-route"
        elif $r.ok then .probe = $r.code | .classification = "SPRING_BOOT" | .evidence += ["actuator-probe"]
        else .probe = $r.code end
    ' "$wd/candidates.jsonl" > "$wd/candidates2.jsonl"
  mv "$wd/candidates2.jsonl" "$wd/candidates.jsonl"

  local total unreachable confd
  total="$(wc -l < "$wd/probe_results.tsv" | tr -d ' ')"
  unreachable="$(awk -F'\t' '$2=="000"' "$wd/probe_results.tsv" | wc -l | tr -d ' ')"
  confd="$(awk -F'\t' '$3=="1"' "$wd/probe_results.tsv" | wc -l | tr -d ' ')"
  log "[$fname] $confd of $total probed app(s) confirmed Spring Boot via actuator."
  dbg "[$fname] probe response codes: $(cut -f2 "$wd/probe_results.tsv" | sort | uniq -c | sort -rn | awk '{printf "%s(%s) ",$2,$1}')"
  if [ "$total" -gt 0 ] && [ $((unreachable * 2)) -gt "$total" ]; then
    warn "[$fname] $unreachable of $total probed app(s) were unreachable (no HTTP response). Check that this host can reach the app domains (proxy, firewall, DNS)."
  fi
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
.b-boot{background:var(--green);color:#fff;}
.b-spring{background:transparent;color:var(--green-d);border:1px solid var(--green);}
.b-java{background:transparent;color:#b7791f;border:1px solid #e0b341;}
@media (prefers-color-scheme:dark){.b-spring{color:var(--green);}.b-java{color:#e0b341;}}
.ev-cell,.muted-cell{color:var(--muted);font-size:13px;}
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
      <option value="">All classifications</option>
      <option value="SPRING_BOOT">Spring Boot</option>
      <option value="SPRING">Spring</option>
      <option value="JAVA">Java (no Spring evidence)</option>
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
        <th data-k="state">State</th>
        <th data-k="buildpack">Buildpack</th>
        <th data-k="classification">Classification</th>
        <th data-k="evidence">Evidence</th>
        <th data-k="probe">Probe</th>
      </tr></thead>
      <tbody id="rows"></tbody>
    </table>
  </section>
  <footer>Detected via Cloud Controller v3 droplet inspection.
    <b>Spring Boot</b>: the start command runs a Spring Boot launcher, the buildpack added java-cfenv, or the app answered
    <code>/cloudfoundryapplication</code> with Spring Boot&rsquo;s own response.
    <b>Spring</b>: Spring auto-reconfiguration, a Spring Cloud Services binding, or Spring env vars.
    <b>Java</b>: Java buildpack, no Spring evidence found.</footer>
</main>
<script>
SPRING_HTML_HEAD
}

html_tail() {
cat <<'SPRING_HTML_TAIL'
(function(){
  document.getElementById('generated').textContent = GENERATED;

  var total = DATA.length;
  function countOf(c){ return DATA.filter(function(r){return r.classification===c;}).length; }
  var boot = countOf('SPRING_BOOT'), spring = countOf('SPRING'), java = countOf('JAVA');
  var foundations = (new Set(DATA.map(function(r){return r.foundation;}))).size;
  var orgs = (new Set(DATA.map(function(r){return r.foundation+'/'+r.org;}))).size;
  var spaces = (new Set(DATA.map(function(r){return r.foundation+'/'+r.org+'/'+r.space;}))).size;
  var showF = foundations > 1;

  var cards = [['Spring apps',boot+spring],['Spring Boot',boot],['Spring',spring],
               ['Java, no Spring evidence',java],['Foundations',foundations],['Orgs',orgs],['Spaces',spaces]];
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
  var showP = DATA.some(function(r){return !!r.probe;});
  if(!showP){ var thp=document.querySelector('th[data-k=probe]'); if(thp) thp.style.display='none'; }

  var sortKey='app', sortDir=1, view=DATA.slice();

  function sortView(){
    view.sort(function(a,b){
      var x=(a[sortKey]||'').toString().toLowerCase(), y=(b[sortKey]||'').toString().toLowerCase();
      return x<y?-sortDir : x>y?sortDir : 0;
    });
  }
  var LABELS={SPRING_BOOT:['Spring Boot','b-boot'],SPRING:['Spring','b-spring'],JAVA:['Java','b-java']};
  function badge(c){
    var s=document.createElement('span'), l=LABELS[c]||[c,'b-java'];
    s.className='badge '+l[1]; s.textContent=l[0]; return s;
  }
  function cell(tr, text, cls){
    var td=document.createElement('td'); td.textContent=text; if(cls) td.className=cls;
    tr.appendChild(td);
  }
  function render(){
    var tb=document.getElementById('rows'); tb.textContent='';
    view.forEach(function(r){
      var tr=document.createElement('tr');
      if(showF) cell(tr, r.foundation);
      cell(tr, r.org); cell(tr, r.space); cell(tr, r.app, 'app-cell');
      cell(tr, r.state, 'muted-cell'); cell(tr, r.buildpack);
      var tdc=document.createElement('td'); tdc.appendChild(badge(r.classification)); tr.appendChild(tdc);
      cell(tr, r.evidence || '—', 'ev-cell');
      if(showP) cell(tr, r.probe || '—', 'muted-cell');
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
      if(fc && r.classification!==fc) return false;
      if(q){
        var hay=(r.foundation+' '+r.org+' '+r.space+' '+r.app+' '+r.buildpack+' '+r.evidence).toLowerCase();
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
    var header=['foundation','org','space','app','state','buildpack','classification','evidence','probe'];
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
stat_sum() { jq -s --arg k "$1" 'map(.[$k] // 0) | add // 0' "$STATS"; }
print_notes() {
  local nodrop failed docker hidden
  nodrop="$(stat_sum no_droplet)"; failed="$(stat_sum fetch_failed)"
  docker="$(stat_sum docker)";     hidden="$(stat_sum cmd_hidden)"
  if [ "$nodrop" -gt 0 ]; then
    echo "Note: $nodrop app(s) have no current droplet (never staged) and were not classified."
  fi
  if [ "$failed" -gt 0 ]; then
    echo "Note: $failed app(s) could not be classified because their droplet could not be read (re-run with --debug for details)."
  fi
  if [ "$docker" -gt 0 ]; then
    echo "Note: $docker Docker-image app(s) were not classified (no buildpack to inspect)."
  fi
  if [ "$hidden" -gt 0 ]; then
    echo "Note: $hidden app(s) hid their start command from this user, so Spring Boot could not be recognised from it. Use an admin, admin_read_only or SpaceDeveloper account."
  fi
  return 0
}

if [ ! -s "$ALL_ROWS" ]; then
  echo "No Java or Spring applications found (after excluding system orgs: $EXCLUDE_ORGS)."
  print_notes
  exit 0
fi

SORTED="$TMPROOT/sorted.json"
jq -s 'sort_by(.foundation, .org, .space, .app)' "$ALL_ROWS" > "$SORTED"

nfound="$(jq 'length' "$SORTED")"
nboot="$(jq '[.[]|select(.classification=="SPRING_BOOT")]|length' "$SORTED")"
nspring="$(jq '[.[]|select(.classification=="SPRING")]|length' "$SORTED")"
njava=$((nfound - nboot - nspring))
nfd="$(jq '[.[].foundation]|unique|length' "$SORTED")"
multi=false; if [ "$nfd" -gt 1 ]; then multi=true; fi

if $WANT_TABLE; then
  echo
  # Empty cells would collapse under `column -t`, so show them as "-".
  cols='org,space,app,state,buildpack,classification,evidence'
  $multi && cols="foundation,$cols"
  $PROBE && cols="$cols,probe"
  { printf '%s\n' "$cols" | tr '[:lower:]' '[:upper:]' | tr ',' '\t'
    jq -r --arg cols "$cols" '($cols | split(",")) as $c
      | .[] | . as $r | [$c[] | ($r[.] // "") | if . == "" then "-" else . end] | @tsv' "$SORTED"
  } | render_table
fi

if $WANT_CSV; then
  { printf 'foundation,org,space,app,state,buildpack,classification,evidence,probe\n'
    jq -r '.[]|[.foundation,.org,.space,.app,.state,.buildpack,.classification,.evidence,.probe]|@csv' "$SORTED"
  } > "$CSV_FILE"
fi

if $WANT_HTML; then
  write_html "$SORTED" "$HTML_FILE"
fi

echo
echo "Summary: $nfound Java app(s) across $nfd foundation(s) -- $nboot Spring Boot, $nspring Spring, $njava with no Spring evidence."
print_notes
if [ "$njava" -gt 0 ] && ! $INSPECT; then
  echo "Tip: re-run with --inspect-droplets to look inside the $njava JAVA app(s)' droplets for Spring jars (catches Spring WARs on Tomcat)."
fi
$WANT_CSV  && echo "CSV:  $CSV_FILE"  || true
$WANT_HTML && echo "HTML: $HTML_FILE" || true
