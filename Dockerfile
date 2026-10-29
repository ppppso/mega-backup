FROM debian:12-slim

ARG RESTIC_VERSION=0.19.1
# Set automatically by buildx / BuildKit (amd64, arm64).
ARG TARGETARCH

ENV DEBIAN_FRONTEND=noninteractive

# MEGAcmd from MEGA's official apt repo.
# The megacmd package installs its own apt source that points at
# /etc/apt/keyrings/meganz-archive-keyring.gpg, so the key must live at exactly that
# path, and our temporary .list is removed afterwards (otherwise apt fails with
# "Conflicting values set for option Signed-By").
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg bzip2 jq tzdata procps util-linux \
      python3 python3-flask python3-waitress python3-pexpect \
 && mkdir -p /etc/apt/keyrings \
 && curl -fsSL https://mega.nz/linux/repo/Debian_12/Release.key \
      | gpg --dearmor -o /etc/apt/keyrings/meganz-archive-keyring.gpg \
 && echo "deb [signed-by=/etc/apt/keyrings/meganz-archive-keyring.gpg] https://mega.nz/linux/repo/Debian_12/ ./" \
      > /etc/apt/sources.list.d/mega-tmp.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends megacmd \
 && rm -f /etc/apt/sources.list.d/mega-tmp.list \
 && apt-get purge -y gnupg && apt-get autoremove -y \
 && rm -rf /var/lib/apt/lists/*

# restic: Debian's package is too old, install a pinned, checksum-verified release.
RUN set -eu; \
    arch="${TARGETARCH:-$(dpkg --print-architecture)}"; \
    file="restic_${RESTIC_VERSION}_linux_${arch}.bz2"; \
    base="https://github.com/restic/restic/releases/download/v${RESTIC_VERSION}"; \
    cd /tmp; \
    curl -fsSLO "${base}/${file}"; \
    curl -fsSLO "${base}/SHA256SUMS"; \
    grep " ${file}\$" SHA256SUMS | sha256sum -c -; \
    bunzip2 -c "${file}" > /usr/bin/restic; \
    chmod 755 /usr/bin/restic; \
    rm -f "${file}" SHA256SUMS; \
    restic version

# MEGAcmd keeps its session in $HOME/.megaCmd.
ENV HOME=/config \
    PUID=1000 \
    PGID=1000 \
    RESTIC_REPOSITORY=/data/repo \
    RESTIC_PASSWORD_FILE=/config/restic-password \
    RESTIC_CACHE_DIR=/config/restic-cache \
    LISTEN_PORT=8080

COPY share/settings-schema.json /usr/local/share/mega-backup/
COPY web/ /app/web/
COPY scripts/ /usr/local/bin/

# /usr/local/bin comes before /usr/bin in PATH. For every MEGAcmd client command and
# for restic, add a wrapper there that drops to PUID:PGID when called as root, so
# `docker exec mega-backup mega-login ...` talks to the right server and never leaves
# root-owned files in /config or the repo.
RUN set -eu; \
    chmod 755 /usr/local/bin/*.sh /usr/local/bin/*.py; \
    for f in /usr/bin/mega-* /usr/bin/restic; do \
      name="$(basename "$f")"; \
      [ "$name" = mega-cmd-server ] && continue; \
      printf '#!/bin/sh\nexec /usr/local/bin/as-user.sh %s "$@"\n' "$f" > "/usr/local/bin/$name"; \
      chmod 755 "/usr/local/bin/$name"; \
    done; \
    ln -s /usr/local/bin/backup.sh /usr/local/bin/backup

EXPOSE 8080

HEALTHCHECK --interval=5m --timeout=30s --start-period=2m --retries=3 \
  CMD ["/usr/local/bin/healthcheck.sh"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
