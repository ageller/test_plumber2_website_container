# syntax=docker/dockerfile:1

# Multi-stage build for the survey demo.
#
#   base    : R, the dated package snapshot, runtime system libraries, tini,
#             and the non-root user
#   builder : the runtime R packages from renv.lock, restored into a plain
#             library folder (/opt/R/site-library)
#   dev     : builder's library plus dev-packages.txt (testthat, httr2), used
#             by docker-compose.dev.yml (Rung 1) and by CI to run the tests
#   prod    : builder's library plus app/, used by docker-compose.yml
#             (Rungs 2 and 3, and the VM)
#
# "prod" is the last stage, so a plain "docker build ." produces it.

FROM rocker/r-ver:4.6.1 AS base

# Every R package comes from the Posit Package Manager (PPM) snapshot of this
# date: CRAN exactly as it was that day, as prebuilt binaries for Ubuntu 24.04
# (noble), so installs take seconds and need no compilers. rocker's default
# for the newest R tracks "latest", which changes daily, so it is replaced.
# renv.lock was generated from the same date. Change both together (see the
# README, "Updating R packages").
ARG PPM_SNAPSHOT=2026-10-15

# R_LIBS: R looks for packages in /opt/R/site-library first. (rocker's
# Renviron.site points R_LIBS at its own folders only when it is not set.)
ENV LANG=C.UTF-8 \
    TZ=UTC \
    R_LIBS=/opt/R/site-library \
    CRAN=https://packagemanager.posit.co/cran/__linux__/noble/${PPM_SNAPSHOT}

# This line comes after rocker's own repos line in Rprofile.site, so it wins.
RUN echo "options(repos = c(CRAN = '${CRAN}'))" >> /usr/local/lib/R/etc/Rprofile.site

# Shared libraries that the binary R packages load at run time and that the
# rocker image does not already have: libuv (fs), libsodium (sodium, used by
# reqres and fiery), and libwebpmux (ragg). Found with ldd on the installed
# packages. tini is a tiny init process, see ENTRYPOINT below.
RUN apt-get update \
 && apt-get install -y --no-install-recommends libuv1t64 libsodium23 libwebpmux3 tini \
 && rm -rf /var/lib/apt/lists/*

# Non-root user with a fixed UID and GID, identical on every host. It gets a
# home folder because some R packages look for a per-user cache folder there.
# /data is created here and owned by that user, so a new named volume mounted
# at /data inherits the correct ownership.
RUN groupadd --system --gid 10001 app \
 && useradd --system --uid 10001 --gid app --create-home --home-dir /home/app \
      --shell /usr/sbin/nologin app \
 && mkdir /data \
 && chown app:app /data

WORKDIR /app

# Rscript as PID 1 ignores SIGTERM (the kernel gives PID 1 no default signal
# handling), so "docker compose down" or "restart" would wait 10 seconds and
# then kill it. tini runs as PID 1 instead and passes SIGTERM on to R, which
# then exits at once. Baking tini into the image (rather than "init: true" in
# each Compose file) means every way of running the image gets this, including
# the CI test run and Podman.
ENTRYPOINT ["/usr/bin/tini", "--"]


FROM base AS builder

# renv is needed only to restore renv.lock. It is installed in its own folder,
# pinned to this version, and is not copied into the prod image.
ARG RENV_VERSION=1.3.1
RUN mkdir -p /opt/renv \
 && Rscript -e "install.packages('renv', lib = '/opt/renv')" \
 && Rscript -e " \
      found <- packageVersion('renv', lib.loc = '/opt/renv'); \
      if (found != '${RENV_VERSION}') stop('The PPM snapshot has renv ', found, \
        ', but RENV_VERSION is ${RENV_VERSION}. Update RENV_VERSION.', call. = FALSE)"

# The renv cache is turned off, so packages are installed as real files into
# the library folder (not as links into a cache that the next stage would not
# have). repos = the PPM snapshot above, so the binaries come from that date.
# libcurl: renv downloads with R's built-in libcurl (the image has no curl command).
ENV RENV_CONFIG_CACHE_ENABLED=FALSE \
    RENV_DOWNLOAD_METHOD=libcurl
COPY renv.lock /tmp/renv.lock
RUN mkdir -p /opt/R/site-library \
 && Rscript -e " \
      loadNamespace('renv', lib.loc = '/opt/renv'); \
      renv::restore(lockfile = '/tmp/renv.lock', library = '/opt/R/site-library', \
                    repos = getOption('repos'), prompt = FALSE)"


FROM base AS dev

# Runtime packages from the builder, then the dev-only packages on top (as
# root, into the same library). renv is copied only for this step.
COPY --from=builder /opt/R/site-library /opt/R/site-library
COPY --from=builder /opt/renv /opt/renv
COPY dev-packages.txt /tmp/dev-packages.txt
RUN cd /tmp \
 && RENV_CONFIG_CACHE_ENABLED=FALSE RENV_DOWNLOAD_METHOD=libcurl Rscript -e " \
      loadNamespace('renv', lib.loc = '/opt/renv'); \
      packages <- grep('^[^#[:space:]]', readLines('/tmp/dev-packages.txt'), value = TRUE); \
      renv::install(packages, library = '/opt/R/site-library', prompt = FALSE)"

# app/ and tests/ are bind-mounted here by docker-compose.dev.yml, not copied.
USER app
EXPOSE 8000
CMD ["Rscript", "app/run.R"]


FROM base AS prod

COPY --from=builder /opt/R/site-library /opt/R/site-library
# Code stays owned by root, so the app user can read it but not change it.
COPY app ./app

# OCI labels, filled in by CI (see .github/workflows/build-and-push.yml).
# Declared late so that changing them does not invalidate the layers above.
ARG SOURCE_URL=""
ARG GIT_SHA=""
ARG BUILD_DATE=""
LABEL org.opencontainers.image.source="${SOURCE_URL}" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.created="${BUILD_DATE}"

USER app
EXPOSE 8000

# Uses base R only (url() and readLines()), so curl is not needed in the image.
# readLines() fails on a 503 or a refused connection, and the check exits 1.
# R takes about a second to start, hence the 10 second timeout. start-interval
# makes the first checks run every 2 seconds, so nginx (which waits for the app
# to be healthy) is not kept waiting for a full 30 second interval.
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --start-interval=2s --retries=3 \
    CMD ["Rscript", "--vanilla", "-e", "options(timeout = 5); ok <- tryCatch({ readLines(url('http://127.0.0.1:8000/healthz'), warn = FALSE); TRUE }, error = function(e) FALSE); quit(status = if (ok) 0 else 1)"]

CMD ["Rscript", "app/run.R"]
