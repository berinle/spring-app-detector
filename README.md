# Spring App Detector for Tanzu Cloud Foundry

`detect-spring-apps.sh` inventories the **Spring applications** running on one or many
Tanzu Cloud Foundry (Tanzu Application Service / PCF) foundations and reports them three ways:

- a clean **terminal table**,
- a **CSV** file (for spreadsheets / diffing across runs), and
- a self-contained, interactive **HTML report** (search / sort / filter, no external dependencies).

It talks to the **Cloud Controller v3 API** via `cf curl`, so it works against any
foundation you can `cf login` to — no Tanzu Hub or Apps Manager access required.

---

## How detection works

Every app staged by the **Java buildpack** is listed and classified by the strongest evidence
found. No evidence needs network access to the apps except `--probe`.

| Classification | Evidence (shown in the `Evidence` column) |
|----------------|--------------------------------------------|
| **SPRING_BOOT** | `boot-launcher`: the droplet's start command runs `org.springframework.boot.loader.…JarLauncher` / `WarLauncher` / `PropertiesLauncher` (every Spring Boot executable jar). `java-cfenv`: the Java buildpack added java-cfenv, which it only does for Spring Boot 3+. `actuator-probe` (`--probe`): the app answered `/cloudfoundryapplication` with Spring Boot's own security response. |
| **SPRING** | `spring-auto-reconfig`: the Java buildpack found `spring-core` in the app. `scs:<offering>`: bound to a Spring Cloud Services config server, service registry or circuit breaker. `env:<NAME>`: `SPRING_*` / `JBP_CONFIG_SPRING*` env vars, or `-Dspring.` in `JAVA_OPTS` (names only; values are never read into the report). |
| **SPRING / SPRING_BOOT** (`--inspect-droplets`) | `droplet:*`: for Java apps with no other evidence, the droplet's file list shows `spring-boot` / `spring-webmvc` / `spring-webflux` / `spring-core` jars or the buildpack's Spring support. This is what catches a plain Spring MVC WAR on Tomcat, whose start command is only `catalina.sh run`. |
| **JAVA** | Java buildpack, but none of the above. Plain Java, Tomcat WARs, Quarkus, Micronaut, vendor products, or Spring apps that leave no trace. |

Spring *libraries* alone are weak evidence: Play, for example, ships `spring-core` for form
binding. When another framework is detected (`framework:play`, `quarkus`, `micronaut`,
`dropwizard`, `helidon`), `spring-core` / auto-reconfiguration alone leaves the app as `JAVA`, and
the Evidence column shows both.

Only the buildpack that actually staged the app's **current droplet** counts, never the buildpack
the app merely requests. Docker-image apps, never-staged apps and apps whose droplet can't be read
are not classified; the summary counts each group separately.

Platform/system apps are excluded **by org name** (default: `system`, `p-spring-cloud-services`,
`p-dataflow`). Note that Spring Cloud Services components (config-server, eureka, …) *are*
Spring Boot but are platform infrastructure, so they live in `p-spring-cloud-services` and are
excluded by default. Most other TAS platform components are BOSH VMs, not CF apps, so they never
appear here. Override with `--exclude-orgs` or `--include-system`.

---

## Requirements

- [`cf` CLI](https://github.com/cloudfoundry/cli) v8+ (uses the v3 API)
- [`jq`](https://jqlang.github.io/jq/) 1.6+
- `column` (optional — falls back to plain output) and `curl` (only needed for `--probe`)

The script is written to run on **stock macOS bash 3.2** and Linux jump hosts.

---

## Usage

### 1. Against the foundation you're already logged into (zero config)

```bash
cf login -a https://api.sys.dc1.example.com
./detect-spring-apps.sh
```

### 2. Confirm with the actuator probe

```bash
./detect-spring-apps.sh --probe
```

> `--probe` requires the machine running the script to have **network access to the app routes**
> (`*.apps.<domain>`). It probes up to 3 public HTTP routes per **running** app (internal, TCP and
> wildcard routes are skipped), over https and then http. A bare status code never confirms an app,
> because auth gateways answer 401/403 and SPA catch-alls answer 200 on every path. Only Spring Boot's
> own response body does. The `Probe` column records the HTTP code seen (`000` = no response,
> `stopped`, `no-route`, or `skipped` when the app was already proven Spring Boot).
>
> The probe only finds Spring Boot apps with **Actuator**. On **Spring Boot 4** the Cloud Foundry
> endpoint also needs `spring-boot-starter-cloudfoundry`; without it those apps return 404.

### 3. Look inside droplets for the rest

```bash
./detect-spring-apps.sh --inspect-droplets
```

> For each Java app still without Spring evidence, downloads its droplet (typically 50–150 MB)
> and lists its files without saving them. Needs the same admin / SpaceDeveloper access as the start
> command. Only apps that would otherwise be `JAVA` are downloaded.

### 4. Sweep many foundations from a config file

```bash
cp foundations.example.json foundations.json   # edit endpoints + usernames
export CF_PASSWORD_PROD_DC1='...'
export CF_PASSWORD_PROD_DC2='...'
export CF_PASSWORD_NONPROD='...'
./detect-spring-apps.sh --config foundations.json --probe
```

Results from all foundations are merged into one table / CSV / HTML, tagged with the foundation name.

### 5. Ad-hoc single foundation

```bash
CF_PASSWORD='...' ./detect-spring-apps.sh --api https://api.sys.dc1.example.com -u svc-spring-audit
```

---

## Authentication & the config file

`foundations.json` is a JSON array. Each entry:

```json
{ "name": "prod-dc1", "api": "https://api.sys.dc1.example.com",
  "username": "svc-spring-audit", "skip_ssl": false }
```

Passwords are **never** stored in the file. For each foundation the script reads the env var
`CF_PASSWORD_<NAME>` — where `<NAME>` is the `name` upper-cased with every non-alphanumeric
character turned into `_` — and falls back to `CF_PASSWORD`. Examples:

| Foundation `name` | Password env var |
|-------------------|------------------|
| `prod-dc1`        | `CF_PASSWORD_PROD_DC1` |
| `nonprod`         | `CF_PASSWORD_NONPROD` |
| `eu.west`         | `CF_PASSWORD_EU_WEST` |

Each foundation is authenticated in an **isolated `CF_HOME`**, so the script never touches your
real `~/.cf/config.json` and a failure on one foundation doesn't abort the rest.

**Use a read-only account that can see droplet details.** The script only issues `GET`s. The
strongest signals (start command, env var names) are only shown to **admin**, **admin_read_only**
or **SpaceDeveloper** users. An org/space *auditor* can run the script, but Cloud Controller hides the
start command from them, so Spring Boot apps fall back to `JAVA` and the script prints a warning.

---

## Options

```
--config FILE        Sweep many foundations (JSON array; see above).
--api URL            Ad-hoc single foundation API endpoint.
-u, --user NAME      Username for --api (password via CF_PASSWORD or prompt).
--skip-ssl           Skip TLS validation for --api.

--probe              Also probe running apps' routes at /cloudfoundryapplication.
--inspect-droplets   Look inside the droplets of Java apps with no other
                     Spring evidence (catches Spring WARs on Tomcat).
--exclude-orgs LIST  Comma-separated org names to exclude
                     (default: system,p-spring-cloud-services,p-dataflow).
--include-system     Exclude nothing.
--concurrency N      Parallel API/probe workers (default 8).
--probe-timeout S    Per-request probe timeout, seconds (default 10).

--csv FILE / --no-csv      CSV output (default spring-apps-<timestamp>.csv).
--html FILE / --no-html    HTML output (default spring-apps-<timestamp>.html).
--no-table                 Suppress the terminal table.
--debug                    Print per-foundation diagnostics (org/space/app
                           counts, droplet fetch results and failures,
                           detected buildpacks, classification counts and
                           probe response-code tallies) to stderr.
-h, --help                 Help.
```

Buildpack truth is read from each app's **current droplet**, fetched directly from the app's
`current_droplet` link (`/v3/apps/:guid/droplets/current`). That's one API call per app, run in
parallel (`--concurrency`, default 8), plus one env-var call per Java app that has no other
Spring evidence. On very large foundations raise it, e.g. `--concurrency 16`.

By default the terminal table, CSV, and HTML are **all** produced.

---

## Output columns

`Foundation` (only shown when more than one), `Org`, `Space`, `App`, `State`, `Buildpack`,
`Classification`, `Evidence`, and `Probe` (with `--probe`).

The HTML report adds summary cards (Spring Boot / Spring / Java counts, foundation/org/space
counts), a live search box, foundation/org/classification filters, click-to-sort columns, and a
“Download CSV” button that exports the currently filtered view.

---

## Caveats

- **JAVA is not "not Spring".** It means no evidence was found. Spring Boot WARs deployed to
  Tomcat and apps with custom start commands don't show the Boot launcher; `--probe` or env
  vars may still catch them.
- **Unclassified apps.** Never-staged apps, Docker-image apps, and apps whose droplet couldn't be
  read are counted separately in the summary. Use `--debug` to see why a droplet fetch failed.
- **Probe reach.** `--probe` needs this host to reach the app domains. If most probes return
  `000`, the script warns: check proxy (`HTTPS_PROXY`/`NO_PROXY`), firewall and DNS.
- **Stopped apps** are listed (State `STOPPED`) but never probed. Leftover blue-green copies
  (`*-venerable`) show up this way.

## Troubleshooting

**Spring apps showing as `JAVA`?** Check for the "start command hidden" warning: the account
can't see droplet details, so use an admin, admin_read_only or SpaceDeveloper user.

**No results, or fewer than expected?** Re-run with `--debug`. `detected buildpacks: …` lists the
buildpack names the foundation actually reports, and `droplet fetch: ok=… no_droplet=…
fetch_failed=…` shows whether droplets could be read (the first few failures are printed with
the Cloud Controller's reason).

**Few `actuator-probe` confirmations?** `probe response codes: …` in `--debug` tells you why:
mostly `000` means no network path to the apps, `404` means no Actuator (or Spring Boot 4 without
`spring-boot-starter-cloudfoundry`), `302` means an SSO layer or route service is in front.
