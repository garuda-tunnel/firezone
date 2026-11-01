# Vendored upstream source

This directory is a vendored copy of third-party code. Do not edit it except the
allow-listed files below; `kube/image/source-guard.sh` (CI job `source-guard`)
fails on any other difference from upstream.

- Upstream repository: https://github.com/firezone/firezone
- Tag: `0.7.36`
- Commit: `dc71329fa007942ed32c69bd820f66b94cf5a5cc`
- Licence: Apache-2.0 (see `LICENSE`)

## Vendored paths

`apps/`, `config/`, `priv/`, `rel/`, `mix.exs`, `mix.lock`, `LICENSE`,
`.credo.exs`, `.formatter.exs`, `.tool-versions`, `.gitignore`.

Tracking note: `priv/wg0.client.conf` is force-added (`git add -f`) because the
vendored upstream `.gitignore` pattern `*.conf` hides it; upstream tracks the
file despite that pattern. Never remove it from the index.

## Excluded upstream paths

Everything else, notably: `website/`, `omnibus/`, `.github/`, `scripts/`,
`docker-compose*.yml`, `Dockerfile`, `Dockerfile.dev`, `Dockerfile.prod`,
`README.md`, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `SECURITY.md`,
`asyncapi.yml`, `Gemfile`, `Gemfile.lock`, `requirements.txt`, `tmp/`, `.ci/`,
and other top-level CI/lint/doc dotfiles.

## Allow-list: files that may differ from upstream

Only these may change (dependency version requirements and sources only, plus
the toolchain pin):

- `mix.exs`
- `mix.lock`
- `apps/fz_http/mix.exs`, `apps/fz_vpn/mix.exs`, `apps/fz_wall/mix.exs`
- `apps/fz_http/assets/package.json`
- `apps/fz_http/assets/yarn.lock`
- `.tool-versions`

Everything else under `kube/image/src/` must stay byte-identical to upstream.

## Versions

| Component | Upstream 0.7.36 | Ours | Note |
|-----------|-----------------|------|------|
| erlang    | 25.2.1          | 25.3.2.21 | ceiling: OTP 26 changes small-map iteration order, which flips `FzHttp.Config.ValidatorTest` error order (unfixable: ecto ≥ 3.10 conflicts with `FzHttp.Validator.changed?/2`) |
| elixir    | 1.14.3-otp-25   | 1.16.3-otp-25 | ceiling: 1.17 needs credo ≥ 1.7 (2 new findings on unchanged code, 1.6.x crashes), 1.18+ formatter rewrites `apps/fz_http/lib/fz_http/types/cidr.ex` |
| nodejs    | 18.16.0         | 18.20.8 | ceiling: `local_modules/admin-one-bulma-dashboard` pins node-sass ^7.0.1 (no prebuilt past node 18, source build breaks on newer V8) |
| alpine    | 3.16            | 3.22 | runner `alpine:3.22`, builder `hexpm/elixir:…-alpine-3.22.7` (same minor), both digest-pinned in kube/image/Dockerfile |

## Dependency changes (T8 raise)

Non-trivial bumps (patch-level bumps omitted): phoenix 1.7.2→1.7.24, plug 1.14.2→1.20.3,
plug_crypto 1.2.5→2.2.1, hpax 0.1.2→1.1.0, gettext 0.22.1→0.26.2, guardian 2.3.1→2.5.0,
gen_smtp 1.2.0→1.3.0, wireguardex 0.3.6→0.4.0, jose 1.11.5→1.11.10, finch 0.15.0→0.21.0,
swoosh 1.9.1→1.12.0, mint 1.5.1→1.11.0, hackney 1.18.1→1.25.0, posthog 0.1.0→0.4.4 (a
runtime dep of fz_http and the reason hackney ships in the image), dialyxir 1.2.0→1.4.8,
excoveralls 0.16.1→0.18.5, ueberauth 0.10.3→0.11.0, decimal 2.0.0→2.4.1, jason 1.4.0→1.4.5.
npm: esbuild ^0.14→^0.28.0, esbuild-sass-plugin ^2.2.6→^3.7.0, @fontsource ^4→^5.3.0,
highlight.js ^11.4→^11.12.0, qrcode ^1.3.3→^1.5.4, glob ^7.1.7→^7.2.3, @mdi/font ^6.5.95→^6.9.96; yarn
resolutions pin `sass ~1.99.0` (last dart-sass supporting Node 18) and `form-data 2.5.4`
(CVE-2025-7783 fix; parent range `~2.3.2` cannot reach it).

Caps added as version requirements (each verified by a red test/compile on the newer
version, see garuda-tunnel/firezone-internal#35): jose == 1.11.10
(1.11.11 fails to compile on OTP 25: `type dynamic() undefined` in jose_json_otp.erl;
fixed only by OTP >= 26), ecto/ecto_sql < 3.10.0, phoenix_ecto ~> 4.4.0, finch ~> 0.21.0,
swoosh < 1.13.0, wallaby < 0.30.6, credo ~> 1.6.0. phoenix_ecto ~> 4.4.0 is deliberately
conservative: 4.7.0 deadlocks the parallel sandbox (reproduced on db_connection 2.5 and
2.10); 4.5/4.6 untried. The six caps in the root mix.exs need no `override: true`:
`mix deps.get` resolves to the pinned versions without it.

### Format-sensitive deps (changelog evidence)

- cloak 1.1.2 → 1.1.4 (stays 1.x). Changelog v1.1.3/v1.1.4: "Fixed bugs: Clock with
  changeset issue", "{:badarg, {'aead.c', 90}, 'Unknown cipher or invalid key size'}",
  "ETS error when running Vault without mix" — bugfixes only, no ciphertext format
  change; AES.GCM ciphertexts written by 1.1.2 stay readable.
- cloak_ecto 1.2.0 → 1.3.0 (stays 1.x). Changelog 1.3.0: Migrator fixes (Ecto.Enum,
  plaintext arrays/maps), adds Decimal type, PBKDF2 iteration bump for the PBKDF2
  type, and closure-wrapped plaintext support (`encrypt` accepts a zero-arity
  closure returning the plaintext). Firezone uses Cloak.Ciphers.AES.GCM via
  FzHttp.Vault with plain strings; no stored-format change.
- argon2_elixir stays 2.4.1 (last 2.x release; 3.x/4.x are majors). Hash verification
  unchanged by definition; T9's fixture check pins it.
- guardian 2.3.1 → 2.5.0 (stays 2.x), guardian_db stays 2.1.0 (2.x). No token format
  changes in the 2.x line. Two behaviour changes to know about, neither touching
  Firezone: 2.4.1 — "Verify a token's signature in `Guardian.revoke/3` before
  invoking the token module's `revoke`" (revocation now rejects forged tokens;
  Firezone only revokes tokens it minted itself); 2.5.0 — "`Guardian.Token.Jwt` no
  longer falls back to the implementation module's `:secret_key` when an explicitly
  provided `:secret` is `nil`" (fails `{:error, :secret_not_found}` instead;
  Firezone never passes `:secret`, it configures `:secret_key` in runtime.exs, so
  the fallback path is the one actually used and unchanged).
- wireguardex 0.3.6 → 0.4.0: the Elixir API modules (wireguardex.ex, device.ex,
  peer_info.ex, peer_config.ex, device_config.ex) are byte-identical between v0.3.6 and
  v0.4.0; 0.4.0 adds precompiled NIFs for nif 2.15/2.16/2.17. No key-format or API
  change Firezone would notice.

### CI flags dropped

`--warnings-as-errors` was removed from the static-analysis compile step and from
unit-test's `mix test`. Every Elixir ≥ 1.15 emits `Logger.warn/1 is deprecated`
(5 sites in unchanged Firezone code: fz_http/config/errors.ex:94,
fz_http_web/live/hooks/live_auth.ex:20, fz_http_web/sockets/user_socket.ex:41-42,
fz_wall/shell.ex:22), so no Elixir above 1.14 is warning-clean and 1.14 would pin the
runtime to the baseline. `mix format --check-formatted` and `mix credo --strict` stay
enforced.

## Accepted vulnerability exceptions (operator decision 2026-10-31, #37)

Both are listed in `kube/image/.trivyignore` with inline `exp:2027-05-01`
(trivy parses `exp:` only on the same line as the ID, no space):

- **hackney EEF-CVE-2026-115693** (CRITICAL, mix.lock): pulled at runtime only
  by `posthog ~> 0.1`, which pins `hackney ~> 1.20`; the fix exists only in
  4.x. Reachable only when Firezone telemetry is enabled, and the chart
  defaults `telemetryEnabled: false`. **Condition: telemetry must stay
  disabled.** (Trivy's DB rates the hackney finding CVE-2026-47071 HIGH and
  shows no CRITICAL for mix.lock; the CRITICAL rating is `mix hex.audit`'s EEF
  advisory. All three spellings are in .trivyignore.)
- **tar CVE-2026-59873** (CRITICAL, yarn.lock): build-time only, via
  node-gyp/node-sass during `yarn install` in the assets stage, absent from
  the runtime image (verified by the trivy-image CI job: 0 findings).

## Known upstream test failures

None recorded yet.
