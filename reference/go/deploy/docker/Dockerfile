# A node host for local multi-machine testing. git comes from Alpine's package and
# entry.sh pins whatever version that is, so all four containers match each other.
FROM alpine:3.20
RUN apk add --no-cache git
COPY pantheon /usr/local/bin/pantheon
COPY entry.sh /usr/local/bin/entry.sh
ENTRYPOINT ["/bin/sh", "/usr/local/bin/entry.sh"]
