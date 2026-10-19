# AGENTS.md

Instructions for Claude Code (or any coding agent) building the **R container workflow demo**.

## 1. Purpose

Build a small web app with an R backend (plumber2) whose real job is to let the owner rehearse a container deployment workflow end to end. It is the R counterpart of an earlier Flask prototype (repository `test_flask_website_container`) and should match its scope and structure wherever R allows. The app itself is intentionally trivial: fill out a form, save it to a database, show a summary. The value is in the packaging, the Compose setup, and the documentation.

The one deliberate addition compared with the Flask prototype: the production stack must handle **several simultaneous users** by running more than one R process (section 8).

The owner will use the result to practice three stages:

- **Rung 1:** Fast inner loop. Run the app inside a development container started by Docker Compose, with the source bind-mounted from the host. Template and CSS edits show up on a browser refresh, and R code edits take effect after a quick container restart (a few seconds, no image rebuild).
- **Rung 2:** Production-like stack built locally. Production image (non-root, several R processes) behind an nginx container, using Docker Compose, viewed at `http://localhost:8080`.
- **Rung 3:** Registry rehearsal. Push an image to GitHub Container Registry (GHCR), then pull and run that exact image on the same laptop using the same Compose file a VM would use.

The same image and the same Compose file must later work unchanged on a Linux VM (local RHEL or cloud). Only the `.env` file and the host's published port should differ.

## 2. Hard rules

1. **Do not run any git commit, git push, git tag, or any command that writes to a remote.** Local file creation is fine. Do not create or modify anything under `.git/`.
2. **Do not push images to any registry.** Do not run `docker push` or `docker login`. Document those steps in the README for the owner to run.
3. **Do not run `docker login`, and never embed or request tokens.** Use placeholders such as `YOUR_GITHUB_USERNAME` and `YOUR_REPO_NAME`.
4. **No secrets in the repo or in images.** Provide `.env.example` only. Add `.env` to `.gitignore` and `.dockerignore`.
5. **If you need anything installed on the host machine, ask the owner.** You should not install. Provide instructions to the owner to run the installation. All R tooling runs inside containers. Do not assume R is installed on the host.
6. **Keep the app small.** If a choice is between simple and clever, choose simple. Do not add frameworks, ORMs, front-end build tooling, JavaScript, or authentication without asking.  If adding something would simplify or significantly reduce the amount of code needed, raise this to the owner for approval before proceeding.
7. Writing GitHub Actions workflow files locally is allowed (see section 10), but do not trigger or run them.
8. **Do not use em-dashes** in any documentation or comments you write. Use commas, colons, parentheses, or separate sentences.

If something in these instructions is ambiguous or seems wrong, stop and ask the owner rather than guessing. In particular, plumber2 is a young package (pre-1.0). If a feature these instructions assume (session cookies, static file serving, form body parsing, a particular annotation) works differently in the pinned version, read the package documentation for that version, choose the simplest approach that meets the requirement, and note the decision in your final report.

## 3. Stack

| Concern | Choice |
|---|---|
| Language | R (latest 4.x release that has a `rocker/r-ver` tag, pinned to an exact patch tag such as `rocker/r-ver:4.5.1`) |
| Web framework | plumber2 (pinned exact version) |
| Concurrency | Several identical app containers (Compose `deploy.replicas`) load balanced by nginx (section 8) |
| Database | SQLite via `DBI` + `RSQLite` (no ORM) |
| Templates | `whisker` (Mustache templates, HTML-escaped by default), plain HTML and a small CSS file, no JavaScript |
| Sessions and CSRF | Signed session cookie (HMAC-SHA256 via `openssl`), verified token on every POST |
| Reverse proxy | nginx (official image `nginx:1.30-alpine`, config mounted from the repo) |
| Orchestration | Docker Compose v2 |
| Tests | testthat, with `callr` and `httr2` for tests against a running server |
| Package pinning | `renv.lock` for runtime packages, installed from a dated Posit Package Manager (PPM) snapshot |
| Dev environment | Docker Compose dev file (`dev` image target, bind-mounted source, templates re-read on every request, manual restart for R code changes) |

### Package pinning

- Runtime packages are pinned to exact versions in `renv.lock` (the R equivalent of `requirements.txt`). Generate it inside a container, never on the host.
- Dev-only packages (testthat, httr2, callr, and anything similar) are listed with exact versions in `dev-packages.txt`, one `package@version` per line (the equivalent of `requirements-dev.txt`), and installed only in the `dev` target.
- All packages come from a **dated** PPM snapshot URL for the base image's Ubuntu release, for example `https://packagemanager.posit.co/cran/__linux__/noble/2026-10-01`. Put the date in one build arg (`PPM_SNAPSHOT`) with a sensible default. Do not rely on the snapshot that rocker sets by default: for the newest R version rocker tracks "latest", which is not reproducible.
- PPM serves prebuilt Linux binaries, so packages install in seconds and the image usually needs no compilers. Install only the system libraries the packages need at runtime (check with `pak::pkg_sysreqs()` or the PPM system requirements listing).
- The runtime image does not need renv itself. Restore into a plain library folder in the builder stage and copy that folder.

Pin base images to exact tags, not `latest`.

## 4. Repository layout

The repository already contains a short placeholder `README.md`. Replace it with the full README described in section 12. Create this structure:

```
.
├── AGENTS.md
├── README.md
├── .env.example
├── .gitignore
├── .dockerignore
├── Dockerfile
├── docker-compose.yml            # production-style stack, image-based
├── docker-compose.local.yml      # override: build locally instead of pulling
├── docker-compose.dev.yml        # Rung 1: standalone dev stack, source bind-mounted
├── renv.lock                     # runtime packages, exact versions
├── dev-packages.txt              # dev-only packages, exact versions
├── .github/
│   └── workflows/
│       └── build-and-push.yml    # written but never run by you
├── nginx/
│   └── default.conf
├── app/
│   ├── run.R                     # entry point: read config, build the API, start the server
│   ├── api.R                     # plumber2 route definitions
│   ├── schema.sql
│   ├── R/
│   │   ├── config.R              # read and check environment variables
│   │   ├── db.R                  # connections, pragmas, queries
│   │   ├── validation.R          # form validation, pure functions
│   │   ├── security.R            # session cookie and CSRF helpers
│   │   └── render.R              # whisker template helpers
│   ├── templates/
│   │   ├── base.html
│   │   ├── form.html
│   │   ├── thanks.html
│   │   └── results.html
│   └── static/
│       └── style.css
└── tests/
    ├── run_tests.R               # entry point: testthat::test_dir("tests/testthat")
    └── testthat/
        ├── helper-server.R       # start and stop a test server with callr
        ├── test-validation.R
        ├── test-security.R
        ├── test-app.R
        └── test-concurrency.R
```

`app/run.R` plays the role of `wsgi.py` in the Flask prototype, and `app/R/` plays the role of the Flask app package.

## 5. Application requirements

### Routes

- `GET /` shows the survey form.
- `POST /` validates and saves a submission, then redirects (POST/redirect/GET, status 303) to `/thanks`.
- `GET /thanks` shows a confirmation page.
- `GET /results` shows a simple summary: total submission count, a count per answer for the multiple-choice questions, and a table of the 10 most recent submissions (timestamp, name or "anonymous", and answers).
- `GET /healthz` returns `200` and JSON `{"status": "ok", "instance": "<container hostname>"}`. It must confirm the database is reachable (run `SELECT 1`) and return `503` if not. The `instance` field is a teaching aid: repeated calls through nginx should show different replicas answering. Add a comment noting that a real project might remove it.
- `GET /static/style.css` serves the stylesheet.
- In production, errors must not show stack traces to the browser. Log them to stderr.

### Templates and static files in development

So that Rung 1 needs no file watcher (section 9):

- In development (`APP_ENV=development`), `render.R` reads each template file from disk on every request. In production, it reads the templates once at startup and keeps them in memory. Keep this to one small, commented `if` in `render.R`.
- `style.css` is served from disk in both modes. In development, send `Cache-Control: no-cache` so the browser picks up edits on refresh.

### Form questions

Use these (generic and harmless), the same as the Flask prototype:

1. **Name** (optional text, max 80 characters)
2. **Primary language you use at work** (single select: Python, R, Julia, JavaScript, Other)
3. **Experience with containers** (radio, 1 to 5, where 1 is "never used" and 5 is "use daily")
4. **Which environments do you deploy to?** (checkboxes: Laptop, Local server, AWS, Azure, Other)
5. **Comments** (optional textarea, max 500 characters)

### Validation and security basics

- Validate server-side in pure functions in `validation.R` that take a named list and return either cleaned values or a list of error messages. Reject unknown select or checkbox values, out-of-range ratings, and oversize text. Re-render the form with error messages and keep the user's input.
- Handle repeated form keys correctly: several checked `environments` boxes arrive as repeated keys in the URL-encoded body. Write a test for this.
- Use parameterized SQL only (`DBI::dbExecute(con, sql, params = list(...))`). Never build SQL with `paste`, `sprintf`, or `glue`.
- HTML escaping (the equivalent of Jinja autoescaping): use whisker's double-brace `{{value}}`, which escapes HTML. Use triple braces `{{{ }}}` only to insert HTML that our own templates already rendered (for example the page body inside `base.html`). Never build HTML from user input with `paste` or `glue`.
- CSRF protection: generate a random token, keep it in the session cookie, include it as a hidden form field, and check on every POST that the two match (constant-time comparison).
- Sessions must be **stateless on the server**: everything a session needs lives in a cookie signed with HMAC-SHA256 using `SECRET_KEY` (via the `openssl` package). Use plumber2's built-in session cookie support if the pinned version provides a signed or encrypted one, otherwise write the small helper in `security.R`. This is what lets several replicas share the work (section 8): any replica can handle any request.
- Cookie flags: `HttpOnly`, `SameSite=Lax`, and `Secure` when the request arrived over HTTPS (see "Proxy awareness").
- `SECRET_KEY` comes from the environment. The app must refuse to start in production mode (`APP_ENV=production`) if `SECRET_KEY` is missing, shorter than 32 characters, or equal to the example placeholder.

### Proxy awareness

When `TRUST_PROXY=1`, the app trusts one proxy hop: it uses the `X-Forwarded-For` header for the client IP in logs and `X-Forwarded-Proto` to decide whether to set the `Secure` cookie flag. When `TRUST_PROXY=0` (Rung 1), it ignores those headers and uses the direct connection. Put this logic in one small, commented function. This mirrors the ProxyFix teaching point from the Flask prototype: the owner wants to see the difference between Rung 1 and Rung 2. (plumber2 has no ProxyFix equivalent, so this is done by hand.)

### Logging

Log one line per request to stdout (time, method, path, status, duration in ms, client IP as described above), like gunicorn's access log. Log errors to stderr. Do not log form contents, cookies, or the secret key.

## 6. Database requirements

- The SQLite file lives at the path in `DATABASE_PATH` (default `/data/survey.db` in containers).
- `app/schema.sql` creates the table if it does not exist. Run it at startup from `run.R`, idempotently. Several replicas start at the same time, so schema creation must be safe to run concurrently (`CREATE TABLE IF NOT EXISTS`, relying on `busy_timeout`).
- Table `submissions`: `id` (integer primary key), `created_at` (UTC ISO 8601 text), `name`, `language`, `container_experience` (integer), `environments` (JSON text array), `comments`.
- On every connection set `PRAGMA journal_mode=WAL;`, `PRAGMA busy_timeout=5000;`, and `PRAGMA foreign_keys=ON;`. This keeps several R processes from tripping over each other.
- Open a connection per request and close it when the request finishes (for example a helper that opens a connection and closes it with `on.exit`). Do not keep a global connection that outlives a request.
- Add a short comment in `db.R` explaining why SQLite is acceptable for this demo (single host, low write volume), that it works with several replicas only because they share one host and one filesystem (SQLite on a network file share such as AWS EFS or Azure Files is not safe), and what would change for a real project (a managed database such as PostgreSQL, or an API such as REDCap).

## 7. Configuration

All configuration comes from environment variables. Provide `.env.example` with:

```
# Required
SECRET_KEY=change-me

# App
APP_ENV=production
DATABASE_PATH=/data/survey.db
TRUST_PROXY=1

# Compose
IMAGE=ghcr.io/YOUR_GITHUB_USERNAME/YOUR_REPO_NAME
IMAGE_TAG=local
HTTP_PORT=8080
APP_REPLICAS=2
```

Notes:

- `IMAGE` and `IMAGE_TAG` let the same Compose file run a locally built image (`local`) or a registry image pinned to a git SHA.
- `HTTP_PORT` is the host port nginx publishes. Locally it is 8080. On a VM it would be 80.
- `APP_REPLICAS` is the number of app containers. It is read by Compose, not by the app. It plays the role of gunicorn's `--workers 2` in the Flask prototype.
- Use the same variable names in every environment.
- Document how to generate a secret key in the README, run inside the container, for example `docker compose -f docker-compose.dev.yml run --rm app Rscript -e 'cat(paste(openssl::rand_bytes(32), collapse = ""), "\n")'`.

## 8. Docker requirements

### Dockerfile

Use a multi-stage build, all stages based on the same pinned `rocker/r-ver` tag:

- **base stage:** set the PPM snapshot repository, install only the runtime system libraries the R packages need, create a non-root user with a fixed UID (10001), and create `/data` owned by that user so a named volume mounted there inherits the correct ownership. Set `LANG=C.UTF-8` and `TZ=UTC`.
- **builder stage:** install a pinned `renv` and run `renv::restore()` from `renv.lock` into a plain library folder such as `/opt/R/site-library`.
- **dev target:** copy the library from the builder, install the packages in `dev-packages.txt` (as root), then switch to the non-root user. The application source and tests are bind-mounted by `docker-compose.dev.yml`, not copied.
- **prod target:** copy the library from the builder, then `app/`. No dev packages, no tests. Run as the non-root user. Make `prod` the last stage in the Dockerfile so a plain `docker build` produces it. The `prod` image must not contain testthat, httr2, callr, or any other dev-only package.
- Make sure R finds the copied library in both targets (for example with `R_LIBS_SITE`), and that no project `.Rprofile` from renv activates renv inside the image.
- `EXPOSE 8000`. Start with `Rscript app/run.R`. The server binds to `0.0.0.0` on the port in `PORT` (default 8000).
- Add a `HEALTHCHECK` that calls `http://127.0.0.1:8000/healthz` using base R only (for example `readLines(url(...))` inside `tryCatch`, exiting non-zero on failure). Do not add curl just for this. R takes about a second to start, so use a timeout of at least 10 seconds, an interval of 30 seconds, and a start period long enough for the app to load.
- Add OCI labels (`org.opencontainers.image.source`, `.revision`, `.created`) populated by build args, defaulting to empty values.
- Handle `SIGTERM` cleanly so `docker compose down` does not wait for the 10 second kill timeout. If `Rscript` as PID 1 does not stop promptly, use the `init: true` Compose option or `tini`, and say which in a comment.

### Multiple simultaneous users

A single R process handles one request at a time. The Flask prototype got concurrency from gunicorn's two worker processes. Here it comes from several identical app containers:

- In `docker-compose.yml`, the `app` service runs `${APP_REPLICAS:-2}` containers using `deploy.replicas`. Do not set `container_name` (it prevents replicas). Each replica is one R process listening on port 8000 inside the Compose network.
- nginx balances across the replicas with an `upstream` block: a shared memory `zone`, `least_conn` (send each request to the replica with the fewest active requests, so a slow request on one replica does not hold up others), `server app:8000 resolve;`, and `resolver 127.0.0.11 valid=10s ipv6=off;` (Docker's internal DNS), so nginx picks up replicas as they start, stop, or are recreated. The `resolve` parameter is available in open source nginx 1.27.3 and newer. Add `keepalive` connections to the upstream. Comment each directive.
- No per-user state lives in R memory. Sessions live in the cookie and data lives in SQLite, so no sticky sessions are needed. Say so in a comment in `nginx/default.conf`, and contrast it with Shiny, which needs sticky sessions.
- All handlers in this demo should finish in well under 100 ms. Add a comment in `api.R` that a slow handler blocks every other user on that replica, and that slow work in a real project would go into an asynchronous handler or a background job.

### docker-compose.yml (production-style, image-based)

Use a fixed project name (`name:`) so container and volume names do not depend on the directory.

Services:

- `app`: `image: ${IMAGE}:${IMAGE_TAG}` (fail with a clear message if either is unset), `env_file: .env`, `deploy.replicas: ${APP_REPLICAS:-2}`, volume `survey_data:/data`, no published ports, `restart: unless-stopped`, healthcheck inherited from the image.
- `nginx`: `nginx:1.30-alpine`, mounts `./nginx/default.conf` read-only with `:ro,z` (the `z` is for SELinux on RHEL, and hosts without SELinux ignore it), publishes `${HTTP_PORT}:80`, `depends_on` the app being healthy (with `restart: true`), `restart: unless-stopped`.
- Named volume `survey_data`.
- Only nginx publishes a port. The app is reachable only on the internal Compose network.

### docker-compose.local.yml (override)

Adds a `build:` section to `app` (context `.`, `target: prod`) so that `docker compose -f docker-compose.yml -f docker-compose.local.yml up --build` builds from source. Do not name this file `docker-compose.override.yml`, because Compose would load that automatically and silently break the Rung 3 rehearsal. Document this in the README.

### nginx/default.conf

- `resolver` and an `upstream` block for the app replicas, as described above.
- Proxy `/` to the upstream.
- Set `Host`, `X-Real-IP`, `X-Forwarded-For`, and `X-Forwarded-Proto` headers.
- `server_name _;` so it works with `localhost` and any VM hostname.
- Reasonable timeouts and `client_max_body_size 1m`.
- Include a short commented block showing the extra headers, longer timeouts, and sticky sessions (`ip_hash`) that a WebSocket app such as Shiny would need, left commented out. This is for the owner's future reference.
- Plain HTTP only. Add a comment noting where TLS would be added on a real VM.

### .dockerignore

Exclude `.git`, `.env`, `renv/library`, `renv/staging`, any project `.Rprofile`, `.Rhistory`, `.RData`, `.Rproj.user`, `tests/`, and docs from the build context. Keep `renv.lock` and `dev-packages.txt` in the context. (In the dev stack, source and tests are bind-mounted rather than copied.)

## 9. Development stack (Rung 1)

There is no VS Code dev container in this project. Rung 1 uses Docker Compose, so the owner has one workflow from laptop to VM and can use any editor.

Create `docker-compose.dev.yml` as a **standalone** file (do not layer it on `docker-compose.yml`), with its own project name. It defines a single service, `app`:

- `build`: context `.`, `target: dev`.
- `command`: `Rscript app/run.R`, the same as production.
- `ports`: `5000:8000`. In dev the app is published directly on host port 5000 and nginx is not used. The app still listens on 8000 inside the container, the same as in production.
- `volumes`: bind-mount `./app` and `./tests` into the paths the Dockerfile uses, so host edits are visible inside the container. Add a named volume `dev_data` mounted at `/data`. This is deliberately separate from the `survey_data` volume used in Rungs 2 and 3, so the databases never mix.
- `environment` (set directly in the file, not read from `.env`): `APP_ENV=development`, `DATABASE_PATH=/data/survey.db`, `TRUST_PROXY=0`, and `SECRET_KEY=dev-only-not-a-secret-at-least-32-chars`. Add a comment that this key is for local development only and must never be reused.
- One process only. The README must say that multiple replicas are exercised in Rung 2, not Rung 1.

### Applying changes in Rung 1

plumber2 has no built-in auto reload comparable to Flask's `--debug`. Do not build a file watcher. Instead:

- **Templates and CSS:** edits show up on a browser refresh (section 5).
- **R code** (`app/run.R`, `app/api.R`, `app/R/*.R`): restart the container with `docker compose -f docker-compose.dev.yml restart app`. This takes a few seconds, keeps the `dev_data` volume, and needs no rebuild because the source is bind-mounted.
- **Packages or the Dockerfile** (`renv.lock`, `dev-packages.txt`, `Dockerfile`): rebuild with `docker compose -f docker-compose.dev.yml up --build`.

Make sure `SIGTERM` handling (section 8) works in the dev container too, so the restart is quick.

Add a short note in the README that a file watcher could be added later if manual restarts become tedious. On this machine it would have to poll for changes, because the repository is on a Windows drive mounted into WSL (`/mnt/c/...`, reached through a symbolic link under `/home`), and file change events from that drive do not reliably reach containers.

Usage the README must document:

- Start: `docker compose -f docker-compose.dev.yml up --build`, then browse to `http://localhost:5000`.
- Apply an R code change: `docker compose -f docker-compose.dev.yml restart app`.
- Follow the logs: `docker compose -f docker-compose.dev.yml logs -f app`.
- Tests: `docker compose -f docker-compose.dev.yml run --rm app Rscript tests/run_tests.R`.
- Shell inside the container: `docker compose -f docker-compose.dev.yml run --rm app bash`.
- An R console inside the container: `docker compose -f docker-compose.dev.yml run --rm app R`.
- Reset the dev database: `docker compose -f docker-compose.dev.yml down -v`.

Editor integration (document briefly in the README, do not build anything for it):

- By default the owner edits files on the host with any editor. The editor will not see packages installed inside the container, so autocomplete may be limited.
- Optional: install R on the host and run `renv::restore()` so RStudio or Positron can resolve packages. The app still runs in the container.
- Optional: attach VS Code or Positron to the running dev container for full editor integration.
- A VS Code Dev Container could be added later as a thin `devcontainer.json` that reuses the `dev` target. Do not create one now.

## 10. CI workflow (write only, do not run)

Create `.github/workflows/build-and-push.yml`:

- Triggers on push to `main` and on manual dispatch.
- Uses `actions/checkout`, `docker/setup-buildx-action`, `docker/login-action` (registry `ghcr.io`, username `${{ github.actor }}`, password `${{ secrets.GITHUB_TOKEN }}`), `docker/metadata-action`, and `docker/build-push-action`.
- Needs `permissions: contents: read, packages: write`.
- Runs the tests first by building the `dev` target and running `Rscript tests/run_tests.R` in it with the workspace mounted, the same way as locally. Use the GitHub Actions build cache (`cache-from` and `cache-to` with `type=gha`) so the R library layer is not rebuilt every time.
- Builds the `prod` target for `linux/amd64`. Include a commented line showing how to add `linux/arm64`, with a note that it is slow under emulation.
- Tags the image with the short git SHA and `latest`.
- Image name derived from `${{ github.repository }}`, lowercased.

Remind the owner in the README that this file does nothing until they commit and push it.

## 11. Tests

Write a testthat suite under `tests/testthat/`, run with `Rscript tests/run_tests.R`:

- **Unit tests** (no server): validation accepts a valid form and rejects a bad language value, an out-of-range rating, an unknown environment, and an oversize comment; several `environments` values are handled. Signed cookies round-trip, tampered cookies are rejected, and the CSRF comparison works.
- **Server tests** (`helper-server.R` starts `app/run.R` with `callr::r_bg()` on a free port with a temporary database, waits for `/healthz`, and stops it afterward):
  - `/healthz` returns 200.
  - A valid submission (GET the form, read the CSRF token and cookie, POST) is saved and redirects to `/thanks`.
  - Invalid submissions (bad language value, rating out of range, oversize comment, missing CSRF token) are rejected and nothing is saved.
  - `/results` renders, shows the saved submission, and shows HTML in user input escaped.
  - The app refuses to start in production mode with a missing or placeholder `SECRET_KEY` (the process exits non-zero with a clear message).
- **Concurrency test** (`test-concurrency.R`): start two server processes on different ports that share one temporary database file, send at least 40 valid submissions split across both using `httr2::req_perform_parallel()`, and check that every request succeeded, every submission was saved exactly once, and no "database is locked" error appeared. This stands in for two replicas sharing a volume.

Never run the tests on the bare host.

## 12. README requirements

The README is the main deliverable besides the code. Write it for someone who is comfortable with Docker but has never deployed a container to a cloud or VM. It must include step-by-step instructions, with copy-pasteable commands, for each of the following. Use `YOUR_GITHUB_USERNAME` and `YOUR_REPO_NAME` as placeholders.

1. **Prerequisites** (Docker with Compose v2, and any editor). R on the host is optional and not needed to run anything.
2. **Rung 1:** start the dev stack with `docker compose -f docker-compose.dev.yml up --build`, browse at `http://localhost:5000`, and show the edit loop: a template or CSS edit appears on a browser refresh, and an R code edit appears after `docker compose -f docker-compose.dev.yml restart app`. Explain when a rebuild is needed instead (package or Dockerfile changes), and compare the few seconds this takes with a full Rung 2 rebuild. Include how to run tests, open a shell or R console in the container, and reset the dev database volume. State that Rung 1 has its own Compose file and its own database volume, separate from Rungs 2 and 3, and runs only one process. Include the short note on editor integration from section 9.
3. **Rung 2:** create `.env` from `.env.example` (including generating `SECRET_KEY`), then build and run the production-style stack locally with `docker compose -f docker-compose.yml -f docker-compose.local.yml up --build`. View it at `http://localhost:8080`. Show how to check logs (all replicas and one replica), check health, change the number of replicas, stop the stack, and reset the database volume.
4. **A short "what to look for" list for Rung 2:** confirm the app is not reachable directly on port 8000; confirm `/healthz` through nginx and that repeated calls show different `instance` values; confirm the containers run as non-root; confirm data survives `docker compose down` and `up` but not `down -v`; run a simple concurrent load from the host (for example 100 requests to `/healthz` with `xargs -P 10 curl ...`) and confirm all succeed and both replicas served requests.
5. **How the app handles several users at once:** a short plain-language explanation of replicas versus users (a user typing into the form uses no server resources; only page loads and submissions do, and each takes milliseconds), what happens when more requests arrive at once than there are replicas (they wait briefly in a queue), how SQLite serializes writes, how to choose `APP_REPLICAS` for a VM's CPU count and memory (measure with `docker stats`), and what would change to scale beyond one host (a server database and a cloud load balancer; sessions are already stateless).
6. **Creating a GitHub personal access token** for GHCR (classic token with `write:packages` for pushing from the laptop, and a separate read-only `read:packages` token for pulling on a VM). Explain that GHCR packages are private by default.
7. **Rung 3, manual path:** log in to GHCR, tag the locally built image with a short git SHA, push it, then set `IMAGE` and `IMAGE_TAG` in `.env`, run `docker compose pull` and `docker compose up -d` using only `docker-compose.yml`, and confirm it works at localhost. Explain that this is the same command sequence the VM will use.
8. **Rung 3, CI path:** how the included GitHub Actions workflow would test, build, and push, and how to find the resulting tag.
9. **Rollback:** how to redeploy a previous tag.
10. **Moving to a VM:** a short checklist (install Docker Engine and the Compose plugin, create a read-only GHCR token and `docker login`, copy `docker-compose.yml`, `nginx/default.conf`, and a VM-specific `.env`, set `HTTP_PORT=80` and an `APP_REPLICAS` value suited to the VM, `docker compose pull && docker compose up -d`). Note what differs per environment (firewall, DNS, TLS, secrets) and that the image does not change.
11. **Architecture note:** the owner develops on Windows WSL (native Docker Engine inside WSL Ubuntu, repository on `/mnt/c`) and deploys to a VM running RHEL. Cover: the image is Ubuntu-based and runs unchanged on a RHEL host; Docker CE versus Podman on RHEL; SELinux and the `:z` mount flag; firewalld; why a future dev file watcher would need to poll on `/mnt/c`; where the PPM snapshot pins packages; that a Red Hat UBI base image is possible (Posit publishes R builds for RHEL) if institutional policy requires it, but is not needed.
12. **Where this demo differs from a real project:** SQLite versus a managed database or REDCap API, no TLS, no auth, no migrations, no secrets manager, and the `instance` field in `/healthz`.

## 13. Working method for the agent

1. Read this whole file first.
2. Plan the work briefly, then build the files roughly in the order of section 4. Generate `renv.lock` inside a container.
3. Build and run the stack to verify it, using only local Docker commands (`build`, `compose up`, `compose down`, `exec`, `logs`). Do not push or log in anywhere.
4. Run the tests in a container.
5. Check load balancing across replicas through nginx.
6. At the end, report: what was built, what was verified and how, any plumber2 behavior that differed from these instructions and what you did about it, anything you could not verify, and the exact commands the owner should run for each rung.

Environment notes from the Flask build on this machine:

- The repository is on `/mnt/c`. File tools sometimes report a spurious "file not found" error even though a write succeeded. Check the file before retrying.
- Docker pulls once failed with `docker-credential-desktop.exe: executable file not found`, because `~/.docker/config.json` referenced Docker Desktop, which is not installed. If that happens, do not edit the owner's config. Use a temporary `DOCKER_CONFIG` directory containing `{}` for your own commands, and tell the owner.

## 14. Acceptance checklist

The work is done when all of these are true:

- [ ] `docker compose -f docker-compose.dev.yml up --build` starts the dev stack at `http://localhost:5000`. A template edit on the host appears on a browser refresh, and an R code edit appears after `docker compose -f docker-compose.dev.yml restart app`, with no rebuild.
- [ ] `docker compose -f docker-compose.yml -f docker-compose.local.yml up --build` starts the production-style stack with two app replicas, and the form works at `http://localhost:8080`.
- [ ] A submission is saved and appears on `/results`.
- [ ] Data persists across `docker compose down` followed by `up`.
- [ ] Port 8000 is not reachable from the host. Only nginx is published.
- [ ] `/healthz` works through nginx, repeated calls reach more than one replica, and every replica's container healthcheck reports healthy.
- [ ] Concurrent requests from the host (at least 100, at least 10 in parallel) all succeed.
- [ ] The app containers run as a non-root user.
- [ ] Running `docker compose -f docker-compose.yml up -d` (no override) with `IMAGE` and `IMAGE_TAG` pointing at a local image tag works, proving the Rung 3 path.
- [ ] Tests, including the concurrency test, pass when run with `docker compose -f docker-compose.dev.yml run --rm app Rscript tests/run_tests.R`.
- [ ] The `prod` image does not contain testthat, httr2, callr, or other dev-only packages.
- [ ] `docker compose down` stops the app containers promptly (no 10 second kill timeout).
- [ ] No secrets, tokens, or `.env` file are present in the repo or the image.
- [ ] Nothing was committed, pushed, or logged in to anywhere.
- [ ] The README covers every item in section 12.
