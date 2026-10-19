# test_plumber2_website_container

A test of a workflow to build an R website (plumber2 backend) within a container for deployment. It is the R counterpart of the Flask prototype in `test_flask_website_container`.

The app is a deliberately tiny survey (a form, a thanks page, a results page, and a health check). The point of this repo is the packaging around it: a production image, a Compose setup that runs **several R processes** so several people can use the site at once, and a rehearsed path from laptop to registry to VM. The workflow has three rungs:

| Rung | What you practice | Compose file(s) | URL |
|---|---|---|---|
| 1 | Fast inner loop: one R process in a dev container, source bind-mounted from the host | `docker-compose.dev.yml` | http://localhost:5000 |
| 2 | Production-like stack built locally: several R replicas (non-root) behind nginx | `docker-compose.yml` + `docker-compose.local.yml` | http://localhost:8080 |
| 3 | Registry rehearsal: push to GitHub Container Registry (GHCR), then pull and run that exact image | `docker-compose.yml` only | http://localhost:8080 |

The image and `docker-compose.yml` used in Rung 3 are exactly what a Linux VM will run later. Only `.env` (and the published port in it) changes.

## Contents

1. [Prerequisites](#1-prerequisites)
2. [Rung 1: development stack](#2-rung-1-development-stack)
3. [Rung 2: production-style stack built locally](#3-rung-2-production-style-stack-built-locally)
4. [What to look for in Rung 2](#4-what-to-look-for-in-rung-2)
5. [How the app handles several users at once](#5-how-the-app-handles-several-users-at-once)
6. [Creating GitHub tokens for GHCR](#6-creating-github-tokens-for-ghcr)
7. [Rung 3, manual path: push, then pull and run](#7-rung-3-manual-path-push-then-pull-and-run)
8. [Rung 3, CI path: GitHub Actions tests, builds, and pushes](#8-rung-3-ci-path-github-actions-tests-builds-and-pushes)
9. [Rollback](#9-rollback)
10. [Moving to a VM](#10-moving-to-a-vm)
11. [Architecture note: WSL laptop to RHEL VM](#11-architecture-note-wsl-laptop-to-rhel-vm)
12. [Where this demo differs from a real project](#12-where-this-demo-differs-from-a-real-project)
13. [Troubleshooting](#13-troubleshooting)
14. [Reference](#14-reference)

---

## 1. Prerequisites

- **Docker Engine 25 or newer** with the **Compose plugin**, version 2.20 or newer. Check with:

  ```bash
  docker version --format '{{.Server.Version}}'
  docker compose version
  ```

  The command is `docker compose` (with a space). The old standalone `docker-compose` (v1) is not supported.
- **git**, **curl** (for the checks below), and **any editor**.
- A **GitHub account** for Rung 3.

**You do not need R on the host.** Everything R-related (the app, the tests, generating a secret key, regenerating `renv.lock`) runs inside containers. Installing R on the host is optional and only helps your editor (see [Editor integration](#editor-integration)).

Run every command in this README from the repository root (the folder that contains `docker-compose.yml`).

> **On WSL:** if `docker pull` or `docker compose up` fails with `error getting credentials ... docker-credential-desktop.exe`, see [Troubleshooting](#13-troubleshooting).

---

## 2. Rung 1: development stack

Rung 1 has **its own Compose file** (`docker-compose.dev.yml`), **its own Compose project** (`survey-demo-r-dev`), and **its own database volume** (`dev_data`). It never touches the `survey_data` volume used in Rungs 2 and 3, and it does not read `.env`.

It runs the `dev` image target: the same R packages as production plus testthat and httr2, running as the same non-root user. Your `app/` and `tests/` folders are bind-mounted into the container. It runs **one R process only**. Several replicas are exercised in Rung 2, not here.

### Start

```bash
docker compose -f docker-compose.dev.yml up --build
```

The first build downloads the `rocker/r-ver` base image (about 370 MB, 1.4 GB unpacked) and installs about 90 R packages as prebuilt binaries, which takes a minute or two. Later starts take seconds.

Open http://localhost:5000, fill in the form, and look at http://localhost:5000/results.

Press `Ctrl+C` to stop. (Add `-d` to run in the background, then follow the output with `docker compose -f docker-compose.dev.yml logs -f app`.)

### The edit loop

plumber2 has no auto-reload like Flask's `--debug`, so this setup splits changes into three kinds:

| You changed | What to do | How long |
|---|---|---|
| A template (`app/templates/*.html`) or the CSS (`app/static/style.css`) | Refresh the browser | Instant |
| R code (`app/run.R`, `app/api.R`, `app/R/*.R`) | `docker compose -f docker-compose.dev.yml restart app` | 1 to 2 seconds |
| Packages or the image (`renv.lock`, `dev-packages.txt`, `Dockerfile`) | `docker compose -f docker-compose.dev.yml up --build` | About a minute |

Try it with the stack running:

1. **Template:** in `app/templates/form.html`, change the text of the `<h1>`. Refresh the browser: the new text appears. In development the app reads each template from disk on every request (in production it reads them once at startup).
2. **CSS:** change a color in `app/static/style.css` and refresh. In development the stylesheet is sent with `Cache-Control: no-cache`, so the browser always fetches the new version.
3. **R code:** in `app/R/validation.R`, change the message `"Choose a language from the list."`. Submit the form without choosing a language: you still see the old message, because R loaded the code at startup. Now run:

   ```bash
   docker compose -f docker-compose.dev.yml restart app
   ```

   and submit again: the new message appears. The restart takes about a second, keeps the `dev_data` volume (your submissions stay), and needs no rebuild, because the source is bind-mounted.

For comparison, the same R code change in Rung 2 means rebuilding the production image and recreating every replica: about 7 seconds when only `app/` changed, because the R package layers come from the build cache. A package change takes about a minute in either rung.

> **A file watcher could be added later** if manual restarts become tedious. On this machine it would have to *poll* for changes (check file timestamps every second or so): the repository lives on the Windows drive (`/mnt/c/...`, reached through a symbolic link under `/home`), and file change events from that drive do not reliably reach containers.

### Run the tests

```bash
docker compose -f docker-compose.dev.yml run --rm app Rscript tests/run_tests.R
```

This works whether or not the dev stack is running. The tests start their own servers on random ports with temporary databases, and never touch the `dev_data` volume. Expect about 10 seconds and `[ FAIL 0 | WARN 0 | SKIP 0 | PASS 137 ]`.

### Shell, R console, and logs

```bash
docker compose -f docker-compose.dev.yml run --rm app bash   # a shell (try: id, ls, R --version)
docker compose -f docker-compose.dev.yml run --rm app R      # an R console with all packages
docker compose -f docker-compose.dev.yml logs -f app         # follow the running app's log
```

Type `exit` (shell) or `q()` (R, then `n` to not save the workspace) to leave.

### Reset the dev database

```bash
docker compose -f docker-compose.dev.yml down -v
```

`down` removes the container and network. `-v` also deletes the `dev_data` volume, so the next start begins with an empty database.

### Editor integration

- By default you edit files on the host with any editor. The R packages are installed only inside the container, so your editor may show unknown functions and limited autocomplete. The app still runs fine.
- **Optional:** install R on the host, open this folder in RStudio or Positron, and run `install.packages("renv")` and then `renv::restore()` in the R console, so the editor can resolve packages. When renv asks how to proceed, choose to activate the project. This creates `renv/` and `.Rprofile`, which git and Docker both ignore. The app still runs in the container.
- **Optional:** attach VS Code or Positron to the running dev container (in VS Code: Dev Containers extension, command "Attach to Running Container...", pick `survey-demo-r-dev-app-1`) for full editor integration inside the container.
- A VS Code Dev Container (a thin `devcontainer.json` reusing the `dev` target) could be added later. It is intentionally not part of this demo.

> **Security note:** the dev stack publishes port 5000 directly and uses a fixed, public `SECRET_KEY`. That is fine on a laptop. Never run the dev stack on a shared or public machine.

---

## 3. Rung 2: production-style stack built locally

Rung 2 builds the `prod` image target from your working copy and runs it the way a server would: `APP_REPLICAS` identical app containers (2 by default), each one R process running as a non-root user, behind an nginx container that spreads requests across them. Only nginx publishes a port.

### Step 1: create `.env`

```bash
cp .env.example .env
```

`.env` holds configuration and the secret key. It is listed in `.gitignore` and `.dockerignore`, so it is never committed and never copied into an image.

### Step 2: set `IMAGE` to your real names, in lowercase

Open `.env` in your editor and replace the placeholders in this line:

```
IMAGE=ghcr.io/YOUR_GITHUB_USERNAME/YOUR_REPO_NAME
```

Use your GitHub username and repository name **in lowercase**. For example, for `github.com/JaneDoe/Test_Plumber2_Website_Container` write:

```
IMAGE=ghcr.io/janedoe/test_plumber2_website_container
```

Docker requires lowercase image names. If you leave the uppercase placeholder in place, Compose stops with `invalid reference format: repository name ... must be lowercase`.

Keep `IMAGE_TAG=local` for now. The image you build will be named `${IMAGE}:local`.

### Step 3: set a real `SECRET_KEY`

Generate a random key inside the dev container (build it once with Rung 1 first) and write it into `.env` in one step:

```bash
KEY=$(docker compose -f docker-compose.dev.yml run --rm -T app Rscript -e 'cat(paste(openssl::rand_bytes(32), collapse = ""))')
sed -i "s/^SECRET_KEY=.*/SECRET_KEY=$KEY/" .env
unset KEY
grep -c '^SECRET_KEY=[0-9a-f]\{64\}$' .env    # prints 1 if it worked
```

To just see a key, run `docker compose -f docker-compose.dev.yml run --rm app Rscript -e 'cat(paste(openssl::rand_bytes(32), collapse = ""), "\n")'`.

The app refuses to start in production mode if `SECRET_KEY` is missing, shorter than 32 characters, or still `change-me`.

### Step 4: build and start

```bash
docker compose -f docker-compose.yml -f docker-compose.local.yml up --build -d
```

Compose builds the `prod` image, tags it `${IMAGE}:${IMAGE_TAG}`, starts the replicas, waits until every replica's health check passes, and then starts nginx. Open http://localhost:8080.

Leave out `-d` if you want to watch the logs in the foreground (stop with `Ctrl+C`).

**Why two files?** `docker-compose.yml` only says "run this image". `docker-compose.local.yml` adds "and build it from source first". In Rung 3 and on the VM you drop the second file, so nothing is built and the image comes from the registry.

**Why not `docker-compose.override.yml`?** Compose automatically loads a file with that exact name. If the build override had that name, every plain `docker compose up` (including the Rung 3 rehearsal) would silently rebuild from source instead of using the registry image, and you would not notice.

### Everyday commands

After the stack is up, the shorter commands below are enough. `docker compose` with no `-f` reads `docker-compose.yml`, and both files share the fixed project name `survey-demo-r`, so these commands find the same containers.

```bash
docker compose ps                       # status and health of every container
docker compose logs -f                  # follow logs from all replicas and nginx (Ctrl+C stops following)
docker compose logs -f app              # all app replicas, each line prefixed with app-1, app-2, ...
docker compose logs -f --index 2 app    # just one replica (here the second)
docker compose logs -f nginx            # nginx's own access log
curl -i http://localhost:8080/healthz   # health through nginx: 200 {"status":"ok","instance":"..."}
docker inspect --format '{{.State.Health.Status}}' survey-demo-r-app-1   # one replica's health check
docker compose down                     # stop and remove containers; the database volume stays
docker compose down -v                  # also delete the survey_data volume (resets the database)
```

Each app log line is one request: time, method, path, status, duration, and client IP, for example `2026-10-19T15:45:15Z GET / 200 31ms 172.19.0.1`. Errors go to the same log (stderr) and never to the browser.

**Change the number of replicas:** edit `APP_REPLICAS` in `.env` (for example `APP_REPLICAS=3`), then run `docker compose up -d`. Compose starts or removes app containers, and nginx picks up the new set within about 10 seconds. For a one-off experiment without editing `.env`: `docker compose up -d --scale app=3`.

After you change code, rebuild with the same command as Step 4.

> `docker compose down -v` deletes the same `survey_data` volume that Rung 3 uses, because Rungs 2 and 3 are the same Compose project.

---

## 4. What to look for in Rung 2

Work through these with the Rung 2 stack running.

1. **Only nginx publishes a port.** `docker compose ps` shows `8000/tcp` for each app replica (internal only) and `0.0.0.0:8080->80/tcp` for nginx.
2. **The app is not reachable directly.**

   ```bash
   curl -m 3 http://localhost:8000/healthz
   ```

   Expect `Connection refused` (curl exit code 7). The replicas are reachable only on the internal Compose network, where nginx calls them `app:8000`.
3. **Health works through nginx, and different replicas answer.**

   ```bash
   for i in $(seq 6); do curl -s http://localhost:8080/healthz; echo; done
   docker compose ps
   ```

   Expect `{"status":"ok","instance":"..."}` with at least two different `instance` values, and `(healthy)` next to every app container. Each `instance` is a container's hostname. To match them to container names:

   ```bash
   docker compose ps -q app | xargs docker inspect --format '{{.Name}} {{.Config.Hostname}}'
   ```

   The `/healthz` route runs `SELECT 1` against SQLite and returns `503` if the database cannot be opened. The image's health check calls it every 30 seconds.
4. **The containers run as a non-root user and cannot change their own code.**

   ```bash
   docker compose exec app id
   docker compose exec --index 2 app id
   docker compose exec app touch /app/app/run.R
   ```

   Expect `uid=10001(app) gid=10001(app)` for both replicas, and `Permission denied`.
5. **The production image has no dev tooling.**

   ```bash
   docker compose exec app Rscript -e 'ip <- rownames(installed.packages()); print(c(testthat = "testthat" %in% ip, httr2 = "httr2" %in% ip, renv = "renv" %in% ip, callr = "callr" %in% ip))'
   ```

   Expect `FALSE` for testthat, httr2, and renv. callr shows `TRUE`, and that is expected: plumber2 itself needs it (plumber2 needs roxygen2, which needs pkgload, then pkgbuild, then callr), so it is a runtime package pinned in `renv.lock`, not a dev tool.
6. **No secrets are baked into the image.** The secret key reaches the container at run time from `.env`:

   ```bash
   docker compose exec app ls -la /app
   docker image inspect "$(grep '^IMAGE=' .env | cut -d= -f2):local" --format '{{json .Config.Env}}'
   ```

   `/app` contains only `app/`, and the image's environment has no `SECRET_KEY`.
7. **Data survives `down` and `up`, but not `down -v`.**

   ```bash
   # submit the form once at http://localhost:8080, then:
   docker compose down
   docker compose up -d
   # http://localhost:8080/results still shows the submission
   docker compose down -v
   docker compose up -d
   # http://localhost:8080/results now shows 0 submissions
   ```

   `docker compose down` takes about a second, because `tini` (the image's entrypoint) passes the stop signal straight to R. Without it, Docker would wait 10 seconds and then kill each container.
8. **Concurrent load from the host all succeeds, and every replica shares it.**

   ```bash
   # 100 requests, 10 at a time: expect "100 200" (all returned HTTP 200)
   seq 100 | xargs -P 10 -I{} curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8080/healthz | sort | uniq -c

   # The same, counting which replica answered: expect roughly half each
   seq 100 | xargs -P 10 -I{} curl -s http://localhost:8080/healthz | grep -o '"instance":"[^"]*"' | sort | uniq -c

   # A heavier page: 200 form pages, 20 at a time
   seq 200 | xargs -P 20 -I{} curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8080/ | sort | uniq -c

   # Requests logged by each replica
   for i in 1 2; do echo "app-$i: $(docker compose logs --index $i app | grep -cE ' (GET|POST) ')"; done
   ```

   On the laptop this was built on, the 100 health checks took 0.3 seconds and the 200 form pages 0.7 seconds, with no errors.
9. **Production refuses a placeholder secret.** Set `SECRET_KEY=change-me` in `.env` and run `docker compose up -d`. Compose reports `dependency failed to start: container survey-demo-r-app-1 is unhealthy`, and `docker compose logs app` shows `Error: SECRET_KEY is missing, shorter than 32 characters, or still set to the example placeholder`. Put your real key back and run `docker compose up -d` again.
10. **Proxy awareness (`TRUST_PROXY`).** Every page has a footer, "Request as seen by R". Compare:

    | | Client IP | X-Forwarded-For header | TRUST_PROXY |
    |---|---|---|---|
    | Rung 1 (R reached directly) | Docker's gateway, for example `172.18.0.1` | not sent | no |
    | Rung 2 (behind nginx, `TRUST_PROXY=1`) | the address nginx saw, for example `172.19.0.1` | set by nginx | yes |
    | Rung 2 with `TRUST_PROXY=0` | **nginx's own container address**, for example `172.19.0.4` | set by nginx, but ignored | no |

    To see the third row, set `TRUST_PROXY=0` in `.env`, run `docker compose up -d`, reload the page, and compare with `docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' survey-demo-r-nginx-1`. The access log shows the same address. Set it back to `1` afterwards. Without proxy trust, every visitor looks like nginx. With it, the app trusts exactly one proxy hop (the function `request_origin()` in `app/R/security.R`, the R version of Flask's `ProxyFix`). `X-Forwarded-Proto` decides the cookie's `Secure` flag the same way. On WSL the "real client" is Docker's gateway because of network address translation. On a VM it is the visitor's actual IP.

    The footer also shows **"Served by instance"**: reload a few times and watch it change between replicas. The Host shows `localhost` without `:8080`, because nginx forwards `$host`, which has no port. Redirects in this app are relative, so that is harmless.

---

## 5. How the app handles several users at once

**Replicas versus users.** A replica is one R process. R does one thing at a time, so each replica handles one request at a time. That sounds limiting, but a *user* is not a *request*. Someone reading the form or typing into it uses no server resources at all. The server only works when a page loads or the form is submitted, and each of those takes a few milliseconds here (the duration is in every access log line). Two replicas can therefore serve many people "at once", as long as their clicks do not all land in the same few milliseconds.

**More requests than replicas.** nginx sends each request to the replica with the fewest requests in progress (`least_conn`). When every replica is busy, the request waits in a short queue at that replica until R finishes the one before it. With millisecond requests the wait is also milliseconds: in the concurrency test, 20 simultaneous submissions to 2 replicas all finished within about 0.2 seconds. The danger is a *slow* request: a handler that takes 5 seconds makes everyone queued behind it on that replica wait 5 seconds. A real app would move slow work (model fits, big reports) into an asynchronous handler or a background job. See the comment at the top of `app/api.R`.

**How SQLite copes with several writers.** SQLite allows one writer at a time for the whole database file. In WAL mode (set on every connection), readers never wait for the writer. A second writer waits its turn, up to 5 seconds (`busy_timeout`), instead of failing. Each insert here takes about a millisecond, so hundreds per second would still be fine. This only works because every replica runs on the same host and sees the same volume. See the comment at the top of `app/R/db.R`.

**No sticky sessions.** No per-user state lives in R's memory. The session (just the CSRF token) is in a signed cookie, and the data is in SQLite, so any replica can answer any request. Shiny is different: each user's session lives inside one R process, so a Shiny app needs sticky sessions (see the commented `ip_hash` in `nginx/default.conf`).

**Choosing `APP_REPLICAS` for a VM.**

- **CPU:** each replica uses at most one CPU core. A reasonable start is one replica per core, minus one core for nginx and the system, with a minimum of 2 (so one slow request never blocks everyone). For example 2 replicas on a 2-vCPU VM, 3 on a 4-vCPU VM.
- **Memory:** each replica here uses about 190 MB, nginx about 15 MB. An app that loads data or models at startup uses more per replica.
- **Measure, do not guess:** run `docker stats` on the VM while you generate realistic load (the `xargs` commands above). If every replica sits near 100% CPU and the durations in the access log climb, add replicas (if there are free cores). If memory runs short, remove some.

**Scaling beyond one host.** Running replicas on several VMs needs two changes: a server database that all hosts can reach (for example a managed PostgreSQL, or sending responses to REDCap) instead of a SQLite file, and a load balancer in front of the VMs (for example a cloud load balancer, or nginx on its own host). Sessions are already stateless, so no sticky sessions are needed, as long as every host uses the **same** `SECRET_KEY` (otherwise a cookie signed on one host is rejected by another).

---

## 6. Creating GitHub tokens for GHCR

GHCR (GitHub Container Registry, `ghcr.io`) stores images next to your GitHub account. **Packages are private by default:** only accounts with access can pull them, so anything that pulls (including the VM) must log in.

GHCR accepts **classic** personal access tokens. Create two, with different powers:

| Token | Scope | Used on | Purpose |
|---|---|---|---|
| Laptop push token | `write:packages` (this also grants `read:packages`) | your laptop | push images in Rung 3 |
| VM pull token | `read:packages` only | each VM | pull images, nothing else |

Keeping them separate means a compromised VM cannot push a new image.

To create each token:

1. On GitHub, open your profile picture menu, then **Settings**, then **Developer settings**, then **Personal access tokens**, then **Tokens (classic)**.
2. Click **Generate new token**, then **Generate new token (classic)**.
3. Give it a descriptive note (for example `ghcr push from laptop` or `ghcr pull on survey VM`) and an expiration date.
4. Tick only the scope from the table above.
5. Click **Generate token** and copy it immediately. GitHub shows it only once. Store it in a password manager.

Never put a token in this repo, in `.env`, or in an image. `docker login` asks for it interactively.

---

## 7. Rung 3, manual path: push, then pull and run

You push the image you built in Rung 2, then run it using `docker-compose.yml` alone. That is exactly what the VM will do.

### Step 1: commit first

The image is tagged with the short git SHA, so commit your changes before tagging. Then the tag points at code that actually exists in git.

```bash
git status      # should report a clean working tree
```

If you changed code since the last Rung 2 build, rebuild first with `docker compose -f docker-compose.yml -f docker-compose.local.yml up --build -d`.

### Step 2: log in to GHCR

```bash
docker login ghcr.io -u YOUR_GITHUB_USERNAME
```

At the `Password:` prompt, paste your **laptop push token** (`write:packages`), not your GitHub password.

### Step 3: tag the local image with the short git SHA and push it

```bash
IMAGE=$(grep '^IMAGE=' .env | cut -d= -f2)
GIT_SHA=$(git rev-parse --short=7 HEAD)
echo "Will push $IMAGE:$GIT_SHA"

docker tag "$IMAGE:local" "$IMAGE:$GIT_SHA"
docker push "$IMAGE:$GIT_SHA"
```

The first push uploads about 400 MB (mostly the `rocker/r-ver` base layers). Later pushes upload only the layers that changed, usually just `app/` (a few kilobytes) or the R library (if packages changed). The first push creates a private package. It appears on GitHub under your profile, in the **Packages** tab.

### Step 4: point `.env` at the registry image

Run steps 4 to 6 in the same terminal as step 3, because they use the `$IMAGE` and `$GIT_SHA` shell variables set there.

```bash
sed -i "s/^IMAGE_TAG=.*/IMAGE_TAG=$GIT_SHA/" .env
grep '^IMAGE' .env
```

### Step 5: delete the local copies, so the next step must pull

```bash
docker compose down
docker image rm "$IMAGE:$GIT_SHA" "$IMAGE:local"
```

### Step 6: pull and run with `docker-compose.yml` only

```bash
docker compose -f docker-compose.yml pull
docker compose -f docker-compose.yml up -d
docker compose -f docker-compose.yml ps
curl http://localhost:8080/healthz
```

Open http://localhost:8080. Some layers may report `Already exists` during the pull, because they are shared with `rocker/r-ver:4.6.1`, which you already have. That is normal.

Your Rung 2 submissions are still there, because Rungs 2 and 3 share the `survey-demo-r` project and its `survey_data` volume.

**This is the same command sequence the VM uses:** `docker login`, then `docker compose pull`, then `docker compose up -d`. The only differences on the VM are the values in its `.env` (its own `SECRET_KEY`, `HTTP_PORT=80`, and an `APP_REPLICAS` that suits it).

---

## 8. Rung 3, CI path: GitHub Actions tests, builds, and pushes

`.github/workflows/build-and-push.yml` automates Rung 3's build and push. **It does nothing until you commit and push it to GitHub yourself:**

```bash
git add .
git commit -m "Add R container workflow demo"
git push origin main
```

What the workflow does on each push to `main` (or when started by hand):

1. **test job:** builds the `dev` image target, exactly as Rung 1 does, then runs `Rscript tests/run_tests.R` inside it with `app/` and `tests/` mounted from the checkout. If a test fails, nothing is built or pushed. The GitHub Actions build cache keeps the R library layers between runs, so they are rebuilt only when `renv.lock`, `dev-packages.txt`, or the `Dockerfile` change.
2. **build-and-push job:**
   - logs in to `ghcr.io` with the workflow's built-in `GITHUB_TOKEN` (no personal token needed in CI; the workflow requests `packages: write`);
   - builds the `prod` target for `linux/amd64`, reusing the cached R library layers;
   - names the image `ghcr.io/<owner>/<repo>`, lowercased;
   - tags it with the 7-character short SHA (for example `3f2c1ab`) and `latest`;
   - fills in the OCI labels (`source`, `revision`, `created`). The `source` label links the package to the repository on GitHub.

The first run takes a few minutes (it downloads the base image and installs every package). Later runs that change only `app/` are much faster.

**Watch it run:** on GitHub, open the repository's **Actions** tab and select the `build-and-push` run. To start it by hand, choose **build-and-push** in the left sidebar, then **Run workflow**.

**Find the resulting tag:** the tag is the short SHA of the commit that triggered the run.

```bash
git rev-parse --short=7 HEAD     # on the commit you pushed
```

You can also find it on GitHub: on the repository page, find **Packages** in the right sidebar, open the package, and look at the list of recent tagged versions. The run's "Compute tags and labels" step also lists it.

Then deploy it on the laptop exactly as in [Rung 3, steps 4 to 6](#step-4-point-env-at-the-registry-image): set `IMAGE_TAG` to that SHA, then `pull` and `up -d`.

Notes:

- Use SHA tags in `.env`, not `latest`. A SHA says exactly which code is running, and it makes rollback a one-line change.
- If you pushed manually first, the package already exists and the workflow may fail with `403 Forbidden` or `permission_denied: write_package`. Fix: open the package on GitHub, then **Package settings**, then **Manage Actions access**, then add this repository with the **Write** role.
- To also build for ARM machines, follow the commented `linux/arm64` lines in the workflow. Expect that build to be slow, because GitHub's runners are x86 and emulate ARM.

---

## 9. Rollback

Every deployed version is a tag in GHCR, so rolling back means pointing `.env` at an older tag.

```bash
grep '^IMAGE_TAG' .env             # note the tag that is running now

# Find older tags: the package page on GitHub, or the images you have locally:
docker image ls "$(grep '^IMAGE=' .env | cut -d= -f2)"

# Pick the previous good tag and redeploy it (replace PREVIOUS_SHA):
sed -i "s/^IMAGE_TAG=.*/IMAGE_TAG=PREVIOUS_SHA/" .env
docker compose -f docker-compose.yml pull
docker compose -f docker-compose.yml up -d
docker compose -f docker-compose.yml ps
```

Compose recreates every app replica with the older image. nginx is restarted with them, and in any case re-resolves the replicas' addresses within 10 seconds. The `survey_data` volume is untouched.

Caveat: this demo has no database migrations. If a newer version had changed the table structure, the older code might not understand the data. Real projects keep migrations backwards compatible or roll the schema back as well.

---

## 10. Moving to a VM

The image does not change between laptop and VM. Only the host and the `.env` file do.

Checklist:

1. **Install Docker Engine and the Compose plugin** on the VM. For RHEL, see the commands in [section 11](#11-architecture-note-wsl-laptop-to-rhel-vm). Then check:

   ```bash
   docker compose version
   ```

2. **Log in to GHCR with the read-only token** (`read:packages`):

   ```bash
   docker login ghcr.io -u YOUR_GITHUB_USERNAME
   ```

3. **Copy the two deployment files** from your laptop. Nothing else is needed on the VM: no source code, no Dockerfile, no R.

   ```bash
   ssh YOUR_VM_USER@YOUR_VM_ADDRESS 'mkdir -p ~/survey-demo-r/nginx'
   scp docker-compose.yml YOUR_VM_USER@YOUR_VM_ADDRESS:~/survey-demo-r/
   scp nginx/default.conf YOUR_VM_USER@YOUR_VM_ADDRESS:~/survey-demo-r/nginx/
   ```

4. **Create a VM-specific `.env`** on the VM. Do not copy the laptop's `.env`: generate a **new** secret key for every environment.

   ```bash
   cd ~/survey-demo-r
   cat > .env <<'EOF'
   SECRET_KEY=change-me
   APP_ENV=production
   DATABASE_PATH=/data/survey.db
   TRUST_PROXY=1
   IMAGE=ghcr.io/YOUR_GITHUB_USERNAME/YOUR_REPO_NAME
   IMAGE_TAG=THE_SHORT_SHA_TO_DEPLOY
   HTTP_PORT=80
   APP_REPLICAS=2
   EOF
   chmod 600 .env
   ```

   Then edit `.env` on the VM:
   - Replace `IMAGE` with your real names in lowercase, exactly as on the laptop.
   - Set `IMAGE_TAG` to the short SHA you want to deploy.
   - Set `APP_REPLICAS` for the VM's size (see [section 5](#5-how-the-app-handles-several-users-at-once); check the core count with `nproc` and memory with `free -h`).
   - Set a new secret key, generated on the VM (RHEL includes `openssl`):

     ```bash
     sed -i "s/^SECRET_KEY=.*/SECRET_KEY=$(openssl rand -hex 32)/" .env
     ```

   If you forget the key, the app refuses to start, rather than running with a guessable one.

5. **Pull and start:**

   ```bash
   docker compose pull && docker compose up -d
   docker compose ps
   curl http://localhost/healthz
   ```

   On the VM, `docker-compose.yml` is the only Compose file, so `-f` is not needed.

6. **Open the firewall for HTTP** (see section 11), then browse to `http://YOUR_VM_ADDRESS/` from your laptop.

`restart: unless-stopped` plus `sudo systemctl enable docker` means the stack comes back by itself after a reboot.

What differs per environment, and what does not:

| Differs per environment | Same everywhere |
|---|---|
| `.env`: `SECRET_KEY`, `IMAGE_TAG`, `HTTP_PORT` (8080 on the laptop, 80 on the VM), `APP_REPLICAS` | The image (same tag, same bytes) |
| Firewall: host firewall and the cloud or campus network rules | `docker-compose.yml` |
| DNS: a hostname pointing at the VM's address | `nginx/default.conf` (until you add TLS) |
| TLS: certificates and an HTTPS server block in nginx (see the comment in `nginx/default.conf`) | Variable names |
| Secrets: a file on disk here; a secrets manager in a real deployment | The data layout (`/data/survey.db` in a named volume) |

---

## 11. Architecture note: WSL laptop to RHEL VM

You develop on Windows with WSL (native Docker Engine inside WSL Ubuntu, repository on `/mnt/c`) and deploy to a VM running RHEL. Nothing in the image or `docker-compose.yml` has to change, but these points matter.

**An Ubuntu image on a RHEL host.** The image is based on `rocker/r-ver:4.6.1`, which is Ubuntu 24.04. A container brings its own operating system files and shares only the host's Linux kernel, so the same Ubuntu-based image runs unchanged on RHEL, Ubuntu, or WSL. You never install R or any R package on the VM.

**CPU architecture.** Most laptops and most RHEL VMs are `x86_64`, which matches the `linux/amd64` images built here. Check on the VM with `uname -m`. If it prints `aarch64` (an ARM VM, for example AWS Graviton), build for `linux/arm64` as well (see the commented lines in the CI workflow). Otherwise the container fails with `exec format error`.

**Docker CE versus Podman on RHEL.** RHEL ships Podman, not Docker. This demo uses Docker Engine (Docker CE) from Docker's own RHEL repository, so the commands are the same as on the laptop. On RHEL 8 or 9 (check [docs.docker.com/engine/install/rhel](https://docs.docker.com/engine/install/rhel/) for your version):

```bash
# Docker's packages conflict with RHEL's podman and runc. Only remove them if nothing else on the VM needs them.
sudo dnf remove -y podman runc
sudo dnf -y install dnf-plugins-core
sudo dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"    # then log out and back in to use docker without sudo
```

Some institutional VMs do not allow third-party repositories, or require Podman. Ask your VM administrator first. Podman can run most of this setup (`podman compose`), and the image handles stop signals itself (it includes `tini`), but Podman is not what this demo was tested with: rootless Podman cannot publish port 80 without extra configuration, and Compose features such as `deploy.replicas` and `depends_on` with `restart: true` may behave differently.

**SELinux.** RHEL runs SELinux in enforcing mode, which can block containers from reading files on the host. The nginx config mount in `docker-compose.yml` ends in `:ro,z`. The `z` tells Docker to give the file a label that containers may read. WSL and Ubuntu do not use SELinux and ignore the flag, so the same file works on both. The database lives in a named volume, which needs no labelling. If nginx ever logs `Permission denied` for `default.conf`, SELinux is the first suspect.

**firewalld.** RHEL's host firewall blocks port 80 by default:

```bash
sudo firewall-cmd --permanent --add-service=http
sudo firewall-cmd --reload
```

Cloud VMs also have a network-level firewall (a security group or similar) that must allow port 80. Be aware that Docker manages its own firewall rules for published ports, and those rules can bypass firewalld. Treat any port published in `docker-compose.yml` as public, which is why only nginx publishes one.

**Why a future dev file watcher would need to poll.** The repository lives on the Windows drive (`/mnt/c/...`, reached through a symbolic link under `/home`). Linux tools learn about file changes through inotify events, and changes made to that drive (especially by Windows editors) do not reliably produce inotify events inside WSL or containers. A watcher would have to poll instead (check timestamps every second). Moving the repository into the WSL home directory (for example `~/projects/`) would make events work and file access faster. You can still edit it from Windows (VS Code's WSL extension, or `\\wsl$\` in Explorer).

**Where packages are pinned.** R packages come from a dated Posit Package Manager (PPM) snapshot: the `PPM_SNAPSHOT` build argument in the `Dockerfile` (currently `2026-10-15`) points R at `https://packagemanager.posit.co/cran/__linux__/noble/2026-10-15`, which is CRAN exactly as it was that day, as prebuilt binaries for Ubuntu 24.04. `renv.lock` pins the exact version of every runtime package (generated from the same date), and `dev-packages.txt` pins the dev-only ones. Rebuilding next year gives the same packages. See [Updating R packages](#updating-r-packages).

**A Red Hat base image is possible, but not needed.** If institutional policy requires Red Hat Universal Base Images (UBI), the `Dockerfile` could start from a UBI image with R installed from Posit's RHEL builds of R, and `PPM_SNAPSHOT` would point at PPM's RHEL binaries (for example `__linux__/rhel9/`). The system library package names in the `Dockerfile` would change (`dnf` instead of `apt-get`). Nothing else would. It is not needed to run on RHEL.

**Line endings.** Keep files with Unix (LF) line endings. Cloning and committing from inside WSL, with `git config --global core.autocrlf input`, does this.

**Reaching the app from Windows.** WSL forwards `localhost` ports to Windows, so a Windows browser can open http://localhost:5000 and http://localhost:8080.

**User IDs.** The app runs as UID 10001 on every host. Data is kept in a named volume, not a host folder, so there is no host user to match on either WSL or RHEL.

**Image size.** The production image is about 1.5 GB on disk (about 400 MB to download). Almost all of it is the `rocker/r-ver` base image, which includes a full R installation. The app's own layers are about 100 MB (the R packages) plus a few kilobytes of code, so redeploying a code change downloads very little.

---

## 12. Where this demo differs from a real project

- **Database:** SQLite in a Docker volume on one host. A real project would use a managed database (for example PostgreSQL run by a cloud provider or central IT), or send responses to an API such as REDCap, to get backups, access control, audit trails, and the ability to run on more than one host.
- **No TLS:** plain HTTP only. A real deployment terminates HTTPS in nginx (or a load balancer) with real certificates. See the comment in `nginx/default.conf`. The app already sets the cookie's `Secure` flag when nginx reports HTTPS.
- **No authentication:** anyone who can reach the site can see `/results`.
- **No migrations:** the table is created once with `CREATE TABLE IF NOT EXISTS`. Changing its structure later needs a migration tool or hand-written migration scripts.
- **No secrets manager:** the secret key sits in a plain `.env` file on each host. Real deployments use a secrets manager or the platform's secret store, and rotate keys.
- **The `instance` field in `/healthz`:** a teaching aid that shows which replica answered. A real project might remove it, because it reveals internal container names.
- **No backups or monitoring:** nothing backs up the `survey_data` volume, and logs go only to `docker compose logs`.
- **Single host:** one VM. Several replicas share its CPU cores, but there is no failover to another machine and no zero-downtime deploy (`up -d` with a new tag restarts every replica).
- **Abrupt shutdown:** on `docker compose down` R exits immediately, so a request that is in progress at that moment fails. A real service would stop taking new requests and finish the current ones first.
- **Minimal sessions and CSRF:** a small hand-written signed cookie (in `app/R/security.R`) is enough for one form. A bigger app would use a maintained library and give sessions an expiry.

---

## 13. Troubleshooting

**`error getting credentials - err: exec: "docker-credential-desktop.exe": executable file not found in $PATH`**
Your `~/.docker/config.json` still points at Docker Desktop's credential helper, but Docker Desktop is not installed or not reachable from WSL. Back up the file and remove the `"credsStore"` line:

```bash
cat ~/.docker/config.json
cp ~/.docker/config.json ~/.docker/config.json.bak
```

If the file contains nothing but `{"credsStore": "desktop.exe"}`, reset it with `echo '{}' > ~/.docker/config.json`. Otherwise delete just the `"credsStore"` line in an editor, keeping the JSON valid. Without a credential helper, `docker login` stores your token in that file, base64-encoded but not encrypted. Run `docker logout ghcr.io` when you no longer need it.

**`repository name (...) must be lowercase`**
`IMAGE` in `.env` still contains the uppercase placeholder or uppercase letters. See [Rung 2, step 2](#step-2-set-image-to-your-real-names-in-lowercase).

**`required variable IMAGE is missing a value`**
There is no `.env` file next to `docker-compose.yml`. Run `cp .env.example .env` and edit it.

**`dependency failed to start: container survey-demo-r-app-1 is unhealthy`**
The app did not start. Run `docker compose logs app`. The most common cause is `SECRET_KEY` missing, too short, or still `change-me`.

**`Bind for 0.0.0.0:8080 failed: port is already allocated`** (or 5000)
Something else is using the port, perhaps the Flask prototype's stack. Stop it, or change `HTTP_PORT` in `.env` (Rungs 2 and 3). For Rung 1, edit the `ports:` line in `docker-compose.dev.yml`. (The two demos use different Compose project names, `survey-demo` and `survey-demo-r`, so they never touch each other's containers or data. Only the ports can clash.)

**nginx returns `502 Bad Gateway`**
nginx is up but cannot reach any replica. Check `docker compose ps` and `docker compose logs app`.

**`denied` or `unauthorized` on `docker push` or `docker pull`**
Log in again with `docker login ghcr.io -u YOUR_GITHUB_USERNAME`. Check the token's scope (`write:packages` to push, `read:packages` to pull), and that `IMAGE` matches your username and repository exactly, in lowercase.

**An R code change does not show up in Rung 1**
R loads the code once at startup. Run `docker compose -f docker-compose.dev.yml restart app`. Changes to `renv.lock`, `dev-packages.txt`, or the `Dockerfile` need a rebuild: `docker compose -f docker-compose.dev.yml up --build`.

**`Permission denied` when you edit files under `app/` or `tests/`**
If one of those folders did not exist when you first ran the dev stack, Docker created it for the bind mount, owned by root. Remove the empty folder from a container and recreate it as yourself, for example: `docker run --rm -v "$PWD":/w rocker/r-ver:4.6.1 rmdir /w/tests && mkdir tests`.

**A stopped app container shows exit code 143**
That is normal: 143 means "stopped by SIGTERM", which is what `docker compose down`, `stop`, and `restart` send.

---

## 14. Reference

### Configuration (`.env`)

| Variable | Example | Read by | Meaning |
|---|---|---|---|
| `SECRET_KEY` | 64 random hex characters | app | Signs the session cookie that carries the CSRF token. Required in production: missing, shorter than 32 characters, or `change-me` is rejected. |
| `APP_ENV` | `production` | app | `production` or `development`. Development re-reads templates on every request, sends `Cache-Control: no-cache` for the CSS, and skips the strict `SECRET_KEY` check. |
| `DATABASE_PATH` | `/data/survey.db` | app | SQLite file location. `/data` is the named volume. |
| `TRUST_PROXY` | `1` | app | `1` trusts one hop of `X-Forwarded-For` and `X-Forwarded-Proto` (behind nginx). Use `0` when R is reached directly. |
| `IMAGE` | `ghcr.io/janedoe/test_plumber2_website_container` | Compose | Image name, lowercase. |
| `IMAGE_TAG` | `local` or a short SHA | Compose | `local` for images built in Rung 2, a git SHA for registry images. |
| `HTTP_PORT` | `8080` | Compose | Host port nginx publishes. `8080` on the laptop, `80` on a VM. |
| `APP_REPLICAS` | `2` | Compose | Number of app containers (R processes). The equivalent of gunicorn's `--workers`. |

The app also reads `PORT` (default `8000`, the port R listens on inside the container). There is no need to set it. Rung 1 does not read `.env`; its settings are in `docker-compose.dev.yml`.

### Names Compose creates

| | Rung 1 | Rungs 2 and 3 |
|---|---|---|
| Project | `survey-demo-r-dev` | `survey-demo-r` |
| Containers | `survey-demo-r-dev-app-1` | `survey-demo-r-app-1`, `survey-demo-r-app-2` (one per replica), `survey-demo-r-nginx-1` |
| Database volume | `survey-demo-r-dev_dev_data` | `survey-demo-r_survey_data` |

The project names are fixed with `name:` at the top of each Compose file. Without them, both stacks would be named after the folder and their `app` containers would collide. On the VM, the volume name also stays the same whatever folder you deploy into.

### Files

| Path | Purpose |
|---|---|
| `Dockerfile` | Multi-stage build: `base` (R, PPM snapshot, system libraries, tini, user), `builder` (restores `renv.lock`), `dev` (adds dev packages), `prod` (final stage, the default). |
| `docker-compose.yml` | Production-style stack: `app` replicas (image from `.env`) and `nginx`. Used in Rungs 2 and 3 and on the VM. |
| `docker-compose.local.yml` | Rung 2 override that builds the `prod` target from source. |
| `docker-compose.dev.yml` | Rung 1 standalone dev stack. |
| `nginx/default.conf` | Load balancer across the replicas (`least_conn`, re-resolved through Docker's DNS), with commented Shiny, WebSocket, and TLS notes. |
| `app/run.R` | Entry point: reads configuration, creates the table, sets up logging, starts plumber2. The equivalent of `wsgi.py`. |
| `app/api.R` | The routes (plumber2 annotations). |
| `app/R/config.R` | Environment variables and the `SECRET_KEY` check. |
| `app/R/db.R`, `app/schema.sql` | SQLite connection per request, WAL mode, busy timeout, queries, idempotent schema. |
| `app/R/validation.R` | The form questions and pure validation functions. |
| `app/R/security.R` | Signed session cookie, CSRF token, and `request_origin()` (proxy awareness). |
| `app/R/render.R` | whisker templates (cached in production, re-read in development) and template data. |
| `app/templates/`, `app/static/` | Mustache templates and one CSS file. |
| `tests/run_tests.R`, `tests/testthat/` | testthat suite: unit tests, tests against a real server, and a two-replica concurrency test. |
| `.github/workflows/build-and-push.yml` | CI: test in the dev image, then build and push to GHCR. |
| `renv.lock`, `dev-packages.txt` | Exact-pinned runtime and dev R packages. |
| `.env.example` | Template for `.env`. The real `.env` is never committed. |

### Routes

| Route | Purpose |
|---|---|
| `GET /` | Survey form |
| `POST /` | Validate and save, then redirect to `/thanks` (POST/redirect/GET, status 303). Invalid input or a bad CSRF token gives status 400 and the form again. |
| `GET /thanks` | Confirmation page |
| `GET /results` | Totals, counts per answer, and the 10 most recent submissions |
| `GET /static/style.css` | The stylesheet, read from disk on every request |
| `GET /healthz` | `200 {"status":"ok","instance":"<container hostname>"}` if the database answers `SELECT 1`, otherwise `503` |

### Pinned versions

R 4.6.1 (`rocker/r-ver:4.6.1`, Ubuntu 24.04), packages from the PPM snapshot of 2026-10-15: plumber2 0.2.0, whisker 0.4.1, DBI 1.3.0, RSQLite 3.53.3 (SQLite 3.53.3), openssl 2.4.2, jsonlite 2.0.0, and their dependencies (88 packages in `renv.lock`). Dev only: testthat 3.3.2, httr2 1.3.0. Build tooling: renv 1.3.1 (builder stage only). nginx 1.30 (`nginx:1.30-alpine`, the current stable series).

### Updating R packages

All three pins move together: the `PPM_SNAPSHOT` date in the `Dockerfile`, `renv.lock`, and `dev-packages.txt`.

1. Pick a new snapshot date (any past date works) and set it as the default of `ARG PPM_SNAPSHOT` in the `Dockerfile`.
2. Regenerate `renv.lock` from that date, inside a throwaway container (it runs as your own user, so the new file is not owned by root):

   ```bash
   docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -e PPM_SNAPSHOT=2026-10-15 \
     -v "$PWD":/work -w /work rocker/r-ver:4.6.1 Rscript -e '
       options(repos = c(CRAN = paste0("https://packagemanager.posit.co/cran/__linux__/noble/", Sys.getenv("PPM_SNAPSHOT"))))
       lib <- file.path(tempdir(), "lib"); dir.create(lib); .libPaths(c(lib, .libPaths()))
       install.packages("renv", quiet = TRUE)
       packages <- c("plumber2", "whisker", "DBI", "RSQLite", "openssl", "jsonlite")
       install.packages(packages, quiet = TRUE)
       renv::snapshot(project = tempdir(), library = lib, lockfile = "renv.lock", packages = packages, prompt = FALSE)'
   ```

   Replace `2026-10-15` with the new date. To add a runtime package, add it to `packages`.
3. Look up the dev package versions for that date and put them in `dev-packages.txt`:

   ```bash
   docker run --rm -e PPM_SNAPSHOT=2026-10-15 rocker/r-ver:4.6.1 Rscript -e 'ap <- available.packages(repos = paste0("https://packagemanager.posit.co/cran/__linux__/noble/", Sys.getenv("PPM_SNAPSHOT"))); cat(paste0(c("testthat", "httr2"), "@", ap[c("testthat", "httr2"), "Version"]), sep = "\n")'
   ```

   If `ARG RENV_VERSION` in the `Dockerfile` no longer matches the renv version at the new date, the build stops with a clear error. Update it to the version the error shows.
4. Rebuild and test: `docker compose -f docker-compose.dev.yml up --build -d`, then `docker compose -f docker-compose.dev.yml run --rm app Rscript tests/run_tests.R`.

To move to a newer R, change `rocker/r-ver:4.6.1` in the `Dockerfile` (and in the commands above) to the new exact tag, then follow the same steps.
