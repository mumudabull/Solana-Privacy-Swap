#!/usr/bin/env bash
# Idempotent bootstrap for the DARK Rewards workspace (dark-rewards).
# Node 24.13 and pnpm 10.26 match the repository's documented toolchain.
# PostgreSQL is installed here; the cluster is started from start.sh.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
export PATH="/usr/local/bin:${PATH}"

NODE_VERSION=24.13.0
NODE_SHA256=e798599612f4bb71333a3397ab0d095fd62214e115aea45aa858a145fc72d67e

discover_app() {
  local script_dir repo_root parent candidate
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  repo_root="$(cd "${script_dir}/.." && pwd)"
  parent="$(cd "${repo_root}/.." && pwd)"
  local candidates=(
    "${parent}/dark-rewards"
    "${parent}/repos/dark-rewards"
    "/workspace/dark-rewards"
    "/agent/repos/dark-rewards"
    "${PWD}/dark-rewards"
    "${repo_root}"
  )
  for candidate in "${candidates[@]}"; do
    if [[ -f "${candidate}/pnpm-workspace.yaml" && -f "${candidate}/pnpm-lock.yaml" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  local roots=() root found
  for root in /workspace /agent "${parent}" "${PWD}"; do
    [[ -d "${root}" ]] && roots+=("${root}")
  done
  if ((${#roots[@]} > 0)); then
    found="$(find "${roots[@]}" -maxdepth 4 \( -path '*/node_modules' -o -path '*/.git' \) -prune -o -type f -name pnpm-workspace.yaml -print -quit 2>/dev/null || true)"
    if [[ -n "${found}" && -f "$(dirname "${found}")/pnpm-lock.yaml" ]]; then
      dirname "${found}"
      return 0
    fi
  fi
  echo "Could not find the dark-rewards workspace (pnpm-workspace.yaml)." >&2
  return 1
}

if ! /usr/local/bin/node -v 2>/dev/null | grep -qx "v${NODE_VERSION}"; then
  tmp="$(mktemp)"
  curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" -o "${tmp}"
  echo "${NODE_SHA256}  ${tmp}" | sha256sum -c -
  sudo tar -xJf "${tmp}" -C /usr/local --strip-components=1 --no-same-owner
  rm -f "${tmp}"
fi
hash -r

sudo env PATH="/usr/local/bin:${PATH}" COREPACK_ENABLE_DOWNLOAD_PROMPT=0 /usr/local/bin/corepack enable
# Activate pnpm for the runtime user. `corepack enable` only needs root to
# link the shims into /usr/local/bin; the selected version is per user.
corepack prepare pnpm@10.26.1 --activate

if ! command -v pg_isready >/dev/null 2>&1 || ! command -v make >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y postgresql postgresql-contrib build-essential python3
fi

# Login and interactive shells should prefer this toolchain over the image Node.
profile_snippet=/etc/profile.d/dark-rewards-dev.sh
sudo tee "${profile_snippet}" >/dev/null <<'EOF'
export PATH="/usr/local/bin:${PATH}"
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
if [ -z "${DATABASE_URL:-}" ]; then
  export DATABASE_URL="postgresql://${USER}@127.0.0.1/darkrewards?host=/var/run/postgresql"
fi
export NODE_ENV="${NODE_ENV:-development}"
EOF
sudo chmod 644 "${profile_snippet}"

bashrc="${HOME}/.bashrc"
marker="# dark-rewards-dev-toolchain"
if [[ -f "${bashrc}" ]] && ! grep -q "${marker}" "${bashrc}"; then
  cat >> "${bashrc}" <<'EOF'

# dark-rewards-dev-toolchain
export PATH="/usr/local/bin:${PATH}"
EOF
fi

APP="$(discover_app)"
echo "Installing dependencies in ${APP}"
cd "${APP}"
pnpm install --frozen-lockfile
# Project references emit declarations the dashboard typecheck expects.
pnpm run typecheck:libs
echo "Dependency install complete"
