#!/usr/bin/env bash
# Diffs the vendored firezone source in kube/image/src against upstream.
# Exit 0 = clean; exit 1 lists ADDED / MODIFIED / MODE / DELETED / SYMLINK /
# UNEXPECTED / MISSING-UPSTREAM paths.
set -euo pipefail

UPSTREAM_REPO_URL="https://github.com/firezone/firezone"
UPSTREAM_COMMIT="dc71329fa007942ed32c69bd820f66b94cf5a5cc"

VENDORED_PATHS=(apps config priv rel mix.exs mix.lock LICENSE .credo.exs .formatter.exs .tool-versions .gitignore)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR/src"

# Files that may differ from upstream (dependency manifests and toolchain pin only).
allow_listed() {
  case "$1" in
    mix.exs | mix.lock | .tool-versions) return 0 ;;
    apps/fz_http/mix.exs | apps/fz_vpn/mix.exs | apps/fz_wall/mix.exs) return 0 ;;
    apps/fz_http/assets/package.json | apps/fz_http/assets/yarn.lock) return 0 ;;
    *) return 1 ;;
  esac
}

in_vendored_paths() {
  local path
  for path in "${VENDORED_PATHS[@]}"; do
    [[ "$path" == "$1" ]] && return 0
  done
  return 1
}

# The Dockerfile's builder/node base images must match .tool-versions
# (elixir/erlang via the hexpm builder tag, nodejs via the node stage tag).
# .tool-versions uses asdf names: "erlang 25.3.2.21", "elixir 1.16.3-otp-25"
# (the -otp-* suffix is an asdf build qualifier, not part of the release
# version), "nodejs 18.20.8".
check_toolchain_pin() {
  local dockerfile="$SCRIPT_DIR/Dockerfile"
  if [[ ! -f "$dockerfile" ]]; then
    echo "TOOLCHAIN-PIN Dockerfile missing: $dockerfile"
    failures=1
    return
  fi

  local want_erlang want_elixir want_nodejs
  want_erlang="$(sed -n 's/^erlang[[:space:]]//p' "$SRC_DIR/.tool-versions")"
  want_elixir="$(sed -n 's/^elixir[[:space:]]//p' "$SRC_DIR/.tool-versions" | sed 's/-otp-.*//')"
  want_nodejs="$(sed -n 's/^nodejs[[:space:]]//p' "$SRC_DIR/.tool-versions")"

  # Escape dots: version strings must match literally, not as regex dots.
  local re_erlang re_elixir re_nodejs
  re_erlang="${want_erlang//./\\.}"
  re_elixir="${want_elixir//./\\.}"
  re_nodejs="${want_nodejs//./\\.}"

  if ! grep -qE "^FROM hexpm/elixir:${re_elixir}-erlang-${re_erlang}-alpine-[0-9]+(\\.[0-9]+)*@sha256:[0-9a-f]{64}( |$)" "$dockerfile"; then
    echo "TOOLCHAIN-PIN Dockerfile builder is not hexpm/elixir:${want_elixir}-erlang:${want_erlang} (per .tool-versions)"
    failures=1
  fi
  if ! grep -qE "^FROM node:${re_nodejs}-alpine@sha256:[0-9a-f]{64}( |$)" "$dockerfile"; then
    echo "TOOLCHAIN-PIN Dockerfile node stage is not node:${want_nodejs}-alpine (per .tool-versions)"
    failures=1
  fi

  # Runner and builder must stay on the same alpine minor: the BEAM and NIFs
  # are compiled against the builder's musl. X.Y of `FROM alpine:X.Y@sha256:`
  # must equal X.Y of the builder's `-alpine-X.Y.Z` tag.
  local builder_alpine runner_alpine
  builder_alpine="$(sed -n 's/^FROM hexpm\/elixir:.*-alpine-\([0-9][0-9]*\.[0-9][0-9]*\)[0-9.]*@sha256:.*/\1/p' "$dockerfile" | head -1)"
  runner_alpine="$(sed -n 's/^FROM alpine:\([0-9][0-9]*\.[0-9][0-9]*\)@sha256:.*/\1/p' "$dockerfile" | head -1)"
  if [[ -z "$builder_alpine" || -z "$runner_alpine" ]]; then
    echo "TOOLCHAIN-PIN cannot parse builder/runner alpine versions from Dockerfile"
    failures=1
  elif [[ "$builder_alpine" != "$runner_alpine" ]]; then
    echo "TOOLCHAIN-PIN runner alpine:${runner_alpine} minor does not match builder alpine ${builder_alpine}"
    failures=1
  fi
}

if [[ -n "${UPSTREAM_DIR:-}" ]]; then
  upstream="$UPSTREAM_DIR"
else
  upstream="$(mktemp -d)"
  trap 'rm -rf "$upstream"' EXIT
  git -C "$upstream" init -q
  git -C "$upstream" remote add origin "$UPSTREAM_REPO_URL"
  git -C "$upstream" fetch -q --depth 1 origin "$UPSTREAM_COMMIT"
  git -C "$upstream" checkout -q FETCH_HEAD
fi

failures=0
count=0

# Every vendored path must exist in the upstream tree, else the upstream-side
# find below would silently produce a short DELETED list.
for path in "${VENDORED_PATHS[@]}"; do
  if [[ ! -e "$upstream/$path" ]]; then
    echo "MISSING-UPSTREAM $path"
    failures=1
  fi
done
if ((failures)); then
  echo "source-guard: upstream tree is missing vendored paths" >&2
  exit 1
fi

if [[ "$(git -C "$upstream" rev-parse HEAD)" != "$UPSTREAM_COMMIT" ]]; then
  echo "source-guard: upstream dir is not at $UPSTREAM_COMMIT" >&2
  exit 1
fi

# Top level of the vendored tree: only the vendored paths plus UPSTREAM.md.
for entry in "$SRC_DIR"/* "$SRC_DIR"/.[!.]* "$SRC_DIR"/..?*; do
  [[ -e "$entry" || -L "$entry" ]] || continue
  rel="${entry#"$SRC_DIR"/}"
  if [[ "$rel" != "UPSTREAM.md" ]] && ! in_vendored_paths "$rel"; then
    echo "UNEXPECTED $rel"
    failures=1
  fi
done

# Upstream ships no symlinks in the vendored paths (verified at vendoring
# time); symlinks would bypass find -type f, so any symlink is a violation.
while IFS= read -r -d '' file; do
  echo "SYMLINK ${file#"$SRC_DIR"/}"
  failures=1
done < <(find "$SRC_DIR" -type l -print0)

# Vendored files: ADDED (not upstream), MODIFIED (bytes differ),
# MODE (executable bit differs).
while IFS= read -r -d '' file; do
  rel="${file#"$SRC_DIR"/}"
  count=$((count + 1))
  [[ "$rel" == "UPSTREAM.md" ]] && continue
  allow_listed "$rel" && continue
  if [[ ! -f "$upstream/$rel" ]]; then
    echo "ADDED $rel"
    failures=1
    continue
  fi
  if ! cmp -s "$upstream/$rel" "$file"; then
    echo "MODIFIED $rel"
    failures=1
  fi
  if [[ -x "$file" ]]; then src_exec=1; else src_exec=0; fi
  if [[ -x "$upstream/$rel" ]]; then up_exec=1; else up_exec=0; fi
  if ((src_exec != up_exec)); then
    echo "MODE $rel"
    failures=1
  fi
done < <(find "$SRC_DIR" -type f -print0)

# Upstream files under the vendored paths: DELETED if missing on our side
# (allow-listed files missing count as DELETED too). The -L test matters:
# -f alone would follow a symlink and hide the missing real file.
while IFS= read -r -d '' file; do
  rel="${file#"$upstream"/}"
  count=$((count + 1))
  if [[ ! -f "$SRC_DIR/$rel" || -L "$SRC_DIR/$rel" ]]; then
    echo "DELETED $rel"
    failures=1
  fi
done < <(cd "$upstream" && find "${VENDORED_PATHS[@]}" -type f -print0)

check_toolchain_pin

if ((failures)); then
  echo "source-guard: differences found (see above)" >&2
  exit 1
fi
echo "source-guard: clean ($count files checked)"
