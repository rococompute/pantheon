# A machine with Soma and Pantheon built from source, by scripts/setup-node.sh.
# It is also the CI image attestors run checks in (--ci-image): soma is on the
# PATH and its OCaml switch is ready, so a check needs no network.
#
#   mkdir /tmp/soma-src && git -C /path/to/soma archive HEAD | tar -x -C /tmp/soma-src
#   docker build -f deploy/Dockerfile --build-context soma=/tmp/soma-src -t pantheon .
#
# The soma build context is Soma's source: its committed files, not a checkout
# with _build and _opam in it.
# Multi-architecture manifest digest verified against registry-1.docker.io.
# Updating the base or Debian packages is an explicit reviewed source change.
FROM debian:bookworm@sha256:268fb24c39bca92d326dd83ea3abebe4a3f7751c804ffef23bb6d857dd343ff8 AS system-base
ARG DEBIAN_SNAPSHOT=20261101T000000Z
RUN rm -f /etc/apt/sources.list.d/* \
 && printf 'deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/%s bookworm main\n' "$DEBIAN_SNAPSHOT" > /etc/apt/sources.list \
 && printf 'deb [check-valid-until=no] http://snapshot.debian.org/archive/debian-security/%s bookworm-security main\n' "$DEBIAN_SNAPSHOT" >> /etc/apt/sources.list
RUN apt-get update -q && apt-get install -y -q --no-install-recommends git python3 ca-certificates build-essential opam jq curl m4 \
      pkg-config libgmp-dev rsync sudo && rm -rf /var/lib/apt/lists/*
FROM system-base
RUN useradd -m pantheon
COPY deploy/pantheon-ci.sh /usr/local/bin/pantheon-ci
USER pantheon
WORKDIR /home/pantheon
RUN git config --global --add safe.directory '*'
# Soma first, in a layer of its own: it depends only on Soma's source and
# setup-node.sh, so a Pantheon change reuses it rather than rebuilding Soma
COPY --from=soma --chown=pantheon . /tmp/soma-src
COPY --chown=pantheon scripts/setup-node.sh /tmp/setup-node.sh
RUN SOMA_REPO=/tmp/soma-src SOMA_ONLY=1 sh /tmp/setup-node.sh \
 && rm -rf /tmp/soma-src /tmp/setup-node.sh
# Pantheon, built with it: setup-node.sh finds Soma built and skips it
COPY --chown=pantheon . /home/pantheon/pantheon
RUN /home/pantheon/pantheon/scripts/setup-node.sh \
 && chmod -R a+rX /home/pantheon
# Soma on the PATH. Attestors' CI runs through pantheon-ci, as nobody with a
# read-only root: see deploy/pantheon-ci.sh.
ENV PATH=/home/pantheon/soma/_build/install/default/bin:$PATH
WORKDIR /home/pantheon/pantheon
