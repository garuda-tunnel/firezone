# Build context is kube/image (the shared publish-component.yml passes only
# `context`: no build args, no dockerfile path), so the vendored source is at
# src/ here.
#
# Toolchain pins match kube/image/src/.tool-versions (elixir 1.16.3-otp-25 /
# erlang 25.3.2.21 / nodejs 18.20.8); kube/image/source-guard.sh
# (check_toolchain_pin) fails CI if these FROM tags drift from it.

# ── Builder: Elixir/OTP per .tool-versions ──────────────────────────────────
FROM hexpm/elixir:1.16.3-erlang-25.3.2.21-alpine-3.22.7@sha256:530c9ee8ffec517c6ed676811514ec1eac2eb2509d783c3bb11ac7bce9a0b569 AS builder

# Rust toolchain builds the wireguardex rustler NIF from source.
RUN apk add --no-cache build-base git python3 rust cargo

ENV MIX_ENV=prod
# Force wireguardex 0.4.0 to build its NIF from source instead of downloading
# the precompiled artifact from firezone's GitHub releases
# (deps/wireguardex/lib/wireguardex.ex: force_build: System.get_env("WIREGUARDNIF_BUILD") in ["1","true"]).
ENV WIREGUARDNIF_BUILD=1

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

# Same layer ordering as upstream Dockerfile.prod so config/manifest changes
# alone recompile deps.
COPY src/mix.exs src/mix.lock ./
COPY src/apps/fz_http/mix.exs ./apps/fz_http/mix.exs
COPY src/apps/fz_vpn/mix.exs ./apps/fz_vpn/mix.exs
COPY src/apps/fz_wall/mix.exs ./apps/fz_wall/mix.exs

RUN mix deps.get --only "$MIX_ENV"
RUN mkdir config

COPY src/config/config.exs src/config/prod.exs config/
RUN mix deps.compile

COPY src/priv priv
COPY src/apps apps

# ── Assets: exact nodejs 18.20.8 per .tool-versions ─────────────────────────
# The vendored local_modules/admin-one-bulma-dashboard pins node-sass ^7.0.1,
# which has prebuilt bindings only up to node 18 (see src/UPSTREAM.md), and
# alpine's apk ships a different node than .tool-versions. So assets are built
# in a dedicated node:18.20.8-alpine stage, not with the builder's apk node.
# package.json pulls phoenix/phoenix_html/phoenix_live_view via
# file:../../../deps/*, so those hex deps are copied in from the builder.
FROM node:18.20.8-alpine@sha256:929b04d7c782f04f615cf785488fed452b6569f87c73ff666ad553a7554f0006 AS assets

WORKDIR /app/apps/fz_http/assets

COPY --from=builder /app/apps/fz_http/assets ./
COPY --from=builder /app/deps/phoenix /app/deps/phoenix
COPY --from=builder /app/deps/phoenix_html /app/deps/phoenix_html
COPY --from=builder /app/deps/phoenix_live_view /app/deps/phoenix_live_view

# --ignore-scripts: the only script-bearing dep is node-sass (a leftover dep of
# the vendored admin-one dashboard — the build compiles scss with dart-sass via
# esbuild-sass-plugin, node-sass is never imported). node-sass has no musl
# prebuild and its node-gyp needs distutils (gone from python >= 3.12), so let
# its install script be skipped instead of compiled. esbuild ships its binary
# as an optionalDependency and needs no install script.
RUN yarn install --frozen-lockfile --ignore-scripts && yarn deploy

# ── Release assembly (same builder image, assets from the node stage) ───────
FROM builder AS release

# mix phx.digest triggers fz_http compilation; VERSION must be set here
# (mirrors upstream Dockerfile.prod, which passes the released version):
# the release and the UI footer report it.
ARG VERSION=0.7.36
ENV VERSION=$VERSION

COPY --from=assets /app/apps/fz_http/priv/static ./apps/fz_http/priv/static

RUN mix phx.digest
RUN mix compile

# Changes to config/runtime.exs don't require recompiling the code.
COPY src/config/runtime.exs config/

COPY src/rel rel
RUN mix release

# ── Runner: same alpine minor as the builder (3.22) ─────────────────────────
FROM alpine:3.22@sha256:dc92f017beea8e7f43263073d717f7bc011228c95d5312e440deb4d035bb4eec

# nftables: firezone rule engine + the mss-clamp sidecar reuses this image's nft.
# libstdc++/ncurses-libs: BEAM runtime. openssl: crypto + `openssl req` in
# bin/bootstrap (SAML cert). Same package set as upstream's runner: busybox ip
# handles bin/bootstrap's `ip link add ... type wireguard` (verified at
# runtime with --cap-add NET_ADMIN).
RUN apk add --no-cache nftables libstdc++ ncurses-libs openssl

WORKDIR /app

# Runtime invariants: release at /app, MIX_ENV=prod, CMD /app/bin/server —
# matches the env/user/workdir/cmd of firezone/firezone:0.7.36 (docker inspect:
# PATH stays the alpine default, no entrypoint, root user).
ENV MIX_ENV=prod

COPY --from=release /app/_build/prod/rel/firezone ./

CMD ["/app/bin/server"]
