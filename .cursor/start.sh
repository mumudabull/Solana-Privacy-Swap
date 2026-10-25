#!/usr/bin/env bash
# Boot-time services: local PostgreSQL, read-only rewards preview, dashboard,
# brand dev server, and a same-origin proxy. Does not start payout workers.
set -euo pipefail

export PATH="/usr/local/bin:${PATH}"
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0

LOCAL_DATABASE_URL="postgresql://${USER}@127.0.0.1/darkrewards?host=/var/run/postgresql"
APP_PORT="${REWARDS_PROXY_PORT:-4173}"

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
  echo "Could not find the dark-rewards workspace (pnpm-workspace.yaml)." >&2
  return 1
}

if ! command -v pg_isready >/dev/null 2>&1; then
  echo "postgresql is not installed. Run the environment install script first." >&2
  exit 1
fi

if ! pg_isready -q; then
  sudo service postgresql start
fi
ready=0
for _ in $(seq 1 30); do
  if pg_isready -q; then
    ready=1
    break
  fi
  sleep 1
done
if [[ "${ready}" -ne 1 ]]; then
  echo "postgresql did not become ready" >&2
  exit 1
fi

if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${USER}'" | grep -qx 1; then
  sudo -u postgres createuser -s "${USER}"
fi
if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='darkrewards'" | grep -qx 1; then
  sudo -u postgres createdb -O "${USER}" darkrewards
fi

APP="$(discover_app)"
PROXY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dev-proxy.mjs"

# Only migrate the local development database. A caller-supplied URL is left untouched.
case "${DATABASE_URL:-}" in
  ""|"postgresql:///darkrewards"|"postgresql://${USER}@/darkrewards?host=/var/run/postgresql"|"${LOCAL_DATABASE_URL}")
    export DATABASE_URL="${LOCAL_DATABASE_URL}"
    echo "Initializing the local development ledger"
    (cd "${APP}" && NODE_ENV=development DATABASE_URL="${LOCAL_DATABASE_URL}" pnpm --filter @workspace/dark-rewards init-db)
    ;;
  *)
    echo "DATABASE_URL is already set; leaving that database unchanged"
    ;;
esac

env_file=/tmp/dark-rewards-dev.env
umask 077
{
  printf 'PATH=%q\n' "/usr/local/bin:${PATH}"
  printf 'NODE_ENV=%q\n' development
  printf 'DRY_RUN=%q\n' true
  printf 'DATABASE_URL=%q\n' "${DATABASE_URL}"
} > "${env_file}"
chmod 600 "${env_file}"

tmux_cmd() {
  if [[ -f /exec-daemon/tmux.portal.conf ]]; then
    tmux -f /exec-daemon/tmux.portal.conf "$@"
  else
    tmux "$@"
  fi
}

http_up() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$1" || true)"
  [[ "${code}" != "000" && -n "${code}" ]]
}

launch() {
  local name="$1"
  local probe="$2"
  local cmd="$3"
  local log="/tmp/${name}.log"
  if http_up "${probe}"; then
    echo "${name} already ready"
    return 0
  fi
  if tmux_cmd has-session -t "=${name}" 2>/dev/null; then
    tmux_cmd kill-session -t "=${name}"
  fi
  : > "${log}"
  tmux_cmd new-session -d -s "${name}" "bash -lc $(printf '%q' "${cmd}") >> $(printf '%q' "${log}") 2>&1"
}

launch rewards-api "http://127.0.0.1:8080/api/healthz" "set -a; . ${env_file}; set +a; cd $(printf '%q' "${APP}"); export PORT=8080; exec pnpm --filter @workspace/api-server dev:preview"
launch rewards-ui "http://127.0.0.1:3000/" "set -a; . ${env_file}; set +a; cd $(printf '%q' "${APP}"); export PORT=3000 BASE_PATH=/; exec pnpm --filter @workspace/dark-airdrop dev"
launch darkswap-brand "http://127.0.0.1:3001/darkswap-brand/" "set -a; . ${env_file}; set +a; cd $(printf '%q' "${APP}"); export PORT=3001 BASE_PATH=/darkswap-brand/; exec pnpm --filter @workspace/darkswap-brand dev"
launch rewards-proxy "http://127.0.0.1:${APP_PORT}/api/healthz" "set -a; . ${env_file}; set +a; export PROXY_PORT=${APP_PORT} UI_PORT=3000 API_PORT=8080 BRAND_PORT=3001; exec node $(printf '%q' "${PROXY}")"

echo "Waiting for the rewards proxy on port ${APP_PORT}"
for _ in $(seq 1 90); do
  if curl -sf --max-time 2 "http://127.0.0.1:${APP_PORT}/api/healthz" >/dev/null \
    && curl -sf --max-time 2 "http://127.0.0.1:${APP_PORT}/" >/dev/null; then
    echo "DARK Rewards preview is ready at http://127.0.0.1:${APP_PORT}/"
    exit 0
  fi
  sleep 2
done

echo "DARK Rewards preview did not become ready" >&2
for name in rewards-api rewards-ui darkswap-brand rewards-proxy; do
  echo "----- ${name} -----" >&2
  tail -n 40 "/tmp/${name}.log" >&2 || true
done
exit 1
