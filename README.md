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

| Confidence | Meaning |
|------------|---------|
| **LIKELY** (default) | The app's **detected buildpack** (read from its current droplet) is the **Java buildpack**. This is the practical ~95% filter for Spring on TAS — fast, needs no network access to the apps, and covers apps with no route and stopped apps. |
| **CONFIRMED** (`--probe`) | In addition, the app's route responded at **`/cloudfoundryapplication`** with `200/401/403`. The Java buildpack maps Spring Boot Actuator to this protected path, so a response proves the app is Spring Boot from the inside out. |

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
> (`*.apps.<domain>`). Apps without a route, or Spring apps without the Actuator dependency, stay
> `LIKELY` (they are not missed — just not upgraded to `CONFIRMED`).

### 3. Sweep many foundations from a config file

```bash
cp foundations.example.json foundations.json   # edit endpoints + usernames
export CF_PASSWORD_PROD_DC1='...'
export CF_PASSWORD_PROD_DC2='...'
export CF_PASSWORD_NONPROD='...'
./detect-spring-apps.sh --config foundations.json --probe
```

Results from all foundations are merged into one table / CSV / HTML, tagged with the foundation name.

### 4. Ad-hoc single foundation

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

**Use a read-only account.** The script only issues `GET`s. A UAA user with `cloud_controller.read`
(e.g. an `admin_read_only` user, or an org/space *auditor*) is sufficient.

---

## Options

```
--config FILE        Sweep many foundations (JSON array; see above).
--api URL            Ad-hoc single foundation API endpoint.
-u, --user NAME      Username for --api (password via CF_PASSWORD or prompt).
--skip-ssl           Skip TLS validation for --api.

--probe              Confirm Spring Boot via /cloudfoundryapplication.
--exclude-orgs LIST  Comma-separated org names to exclude
                     (default: system,p-spring-cloud-services,p-dataflow).
--include-system     Exclude nothing.
--concurrency N      Parallel probe/route workers (default 8).
--probe-timeout S    Per-probe timeout, seconds (default 5).

--csv FILE / --no-csv      CSV output (default spring-apps-<timestamp>.csv).
--html FILE / --no-html    HTML output (default spring-apps-<timestamp>.html).
--no-table                 Suppress the terminal table.
--debug                    Print per-foundation diagnostics (org/space/app
                           counts, a sample current-droplet path, and the
                           detected buildpack names) to stderr.
-h, --help                 Help.
```

Buildpack truth is read from each app's **current droplet**, fetched directly from the app's
`current_droplet` link (`/v3/apps/:guid/droplets/current`). That's one API call per app, run in
parallel (`--concurrency`, default 8). On very large foundations raise it, e.g. `--concurrency 16`.

By default the terminal table, CSV, and HTML are **all** produced.

---

## Output columns

`Foundation` (only shown when more than one), `Org`, `Space`, `App`, `Buildpack`, `Confidence`.

The HTML report adds summary cards (totals, confirmed vs likely, foundation/org/space counts),
a live search box, foundation/org/confidence filters, click-to-sort columns, and a
“Download CSV” button that exports the currently filtered view.

---

## Caveats

- **LIKELY vs CONFIRMED.** Without `--probe`, "Spring" means "Java buildpack". A plain (non-Spring)
  Java app would show as LIKELY; use `--probe` to separate true Spring Boot apps.
- **Unstaged apps.** Apps that have never been staged have no current droplet, so their buildpack
  is unknown; they are skipped and counted in the summary.
- **WAR / non-Boot Spring.** Buildpack detection captures these (Java buildpack), but `--probe`
  only confirms apps exposing the Actuator at the route root.
- **Context-path routes.** `--probe` hits `https://<route>/cloudfoundryapplication`; apps served
  under a non-root context path may not confirm even though they are Spring.

## Troubleshooting

**"No Spring applications found" but you know there are Spring apps?** Re-run with `--debug`. The
key line is `detected buildpacks: …` — it lists the buildpack names the foundation actually
reports. If you see Java buildpacks there but still get no results, share that line. Also check
`droplets resolved: N` is close to your app count; if it's `0`, the script couldn't read the
apps' current droplets (permissions or an unstaged-only space).
