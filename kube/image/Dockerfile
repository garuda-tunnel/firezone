FROM firezone/firezone:0.7.30

RUN set -eux; \
    printf '%s\n' \
      'https://dl-cdn.alpinelinux.org/alpine/edge/main' \
      'https://dl-cdn.alpinelinux.org/alpine/edge/community' \
      > /etc/apk/repositories; \
    apk update; \
    apk del nftables || true; \
    apk add --no-cache --update-cache --upgrade nftables
