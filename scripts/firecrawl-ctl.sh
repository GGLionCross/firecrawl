#!/usr/bin/env bash
# firecrawl-ctl.sh — run the self-hosted Firecrawl stack on demand.
#
#   ensure              start the stack if any service is down, wait for the API
#                       health endpoint (poll, ENSURE_TIMEOUT s), exit 0 fast if up
#   idle-stop [MIN]     `docker compose stop` (never down) only when the api logs
#                       show no scrape/crawl/search/map request in the last MIN
#                       minutes (default 20), no ensure ran in that window, and no
#                       job is queued/active/ongoing; otherwise print why and exit 0
#   status              up/down, last request age, active jobs, memory
#   hook                Hermes pre_tool_call shell hook: reads the hook JSON on
#                       stdin and runs ensure when the tool call is going to hit
#                       Firecrawl (web_search/web_extract, or :10002 in the input)
#
# Contract: the resource-guard watchdog calls `<this path> idle-stop` every few
# minutes. status / idle-stop / hook always exit 0; ensure exits 1 only when the
# stack could not be brought up.
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="$DIR/docker-compose.yaml"
API_URL="${FIRECRAWL_API_URL_LOCAL:-http://127.0.0.1:10002}"
ENSURE_TIMEOUT="${ENSURE_TIMEOUT:-60}"
STATE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/firecrawl-ctl"
LOCK="$STATE_DIR/lock"
ENSURE_STAMP="$STATE_DIR/last-ensure"
# Log lines that mean real work: every scrape/crawl/search/map/extract is a POST;
# GETs are status polls (and our own /crawl/ongoing probe), so they don't count.
ACTIVITY_RE='\[:POST\]|Worker taking job|Scraping URL'

mkdir -p "$STATE_DIR" 2>/dev/null || true

log() { printf '[firecrawl-ctl] %s\n' "$*"; }
dc() { docker compose -f "$COMPOSE_FILE" "$@"; }
now() { date +%s; }

have_docker() { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }

healthy() { curl -fsS --max-time 2 "$API_URL/" >/dev/null 2>&1; }

# Services declared vs running.
all_services()     { dc config --services 2>/dev/null | sort; }
running_services() { dc ps --status running --services 2>/dev/null | sort; }
down_services()    { comm -23 <(all_services) <(running_services); }

api_cid() { dc ps -q api 2>/dev/null | head -n1; }

# Epoch of the last activity line in the api logs within the window (empty if none).
last_activity_epoch() {
  local since="$1" cid line ts
  cid="$(api_cid)"; [ -n "$cid" ] || return 0
  line="$(docker logs --timestamps --since "$since" "$cid" 2>&1 | grep -E "$ACTIVITY_RE" | tail -n1)"
  [ -n "$line" ] || return 0
  ts="${line%% *}"
  date -d "$ts" +%s 2>/dev/null || true
}

last_ensure_epoch() { [ -f "$ENSURE_STAMP" ] && cat "$ENSURE_STAMP" 2>/dev/null || true; }

age() { # seconds -> human
  local s="$1"
  if [ "$s" -lt 120 ]; then echo "${s}s"; elif [ "$s" -lt 7200 ]; then echo "$((s/60))m"; else echo "$((s/3600))h$(( (s%3600)/60 ))m"; fi
}

# Active job count: nuq queued/active scrapes + backlog + ongoing crawls.
# Prints a number, or "?" if it could not be determined.
active_jobs() {
  local q crawls
  q="$(dc exec -T nuq-postgres psql -U "${POSTGRES_USER:-postgres}" -p 10432 -tAc \
      "select (select count(*) from nuq.queue_scrape where status in ('queued','active'))
            + (select count(*) from nuq.queue_scrape_backlog)" 2>/dev/null | tr -d '[:space:]')"
  crawls="$(curl -fsS --max-time 5 "$API_URL/v1/crawl/ongoing" 2>/dev/null \
      | grep -o '"id"' | wc -l | tr -d '[:space:]')"
  if [[ "$q" =~ ^[0-9]+$ ]] && healthy; then
    echo $(( q + ${crawls:-0} ))
  else
    echo "?"
  fi
}

cmd_ensure() {
  if ! have_docker; then log "error: docker is not available"; return 1; fi
  if [ -z "$(down_services)" ] && healthy; then
    now > "$ENSURE_STAMP" 2>/dev/null || true
    return 0
  fi
  # Serialise concurrent ensures (parallel tool calls) and keep idle-stop out.
  exec 9>"$LOCK"
  flock -w $((ENSURE_TIMEOUT + 180)) 9 || { log "error: could not take lock $LOCK"; return 1; }
  now > "$ENSURE_STAMP" 2>/dev/null || true
  local down; down="$(down_services | tr '\n' ' ')"
  if [ -n "$down" ]; then
    log "starting stack (down: ${down% })"
    if ! dc up -d >/dev/null 2>&1; then
      log "error: docker compose up -d failed"; dc ps -a 2>&1 | sed 's/^/  /'; return 1
    fi
  fi
  local start; start="$(now)"
  log "waiting for $API_URL (timeout ${ENSURE_TIMEOUT}s)"
  until healthy; do
    if [ $(( $(now) - start )) -ge "$ENSURE_TIMEOUT" ]; then
      log "error: API not healthy after ${ENSURE_TIMEOUT}s"; return 1
    fi
    sleep 1
  done
  log "API healthy after $(( $(now) - start ))s"
  now > "$ENSURE_STAMP" 2>/dev/null || true
  return 0
}

cmd_idle_stop() {
  local min="${1:-20}"
  [[ "$min" =~ ^[0-9]+$ ]] || { log "keep: invalid MINUTES '$min'"; return 0; }
  [ "$min" -ge 1 ] || min=1
  have_docker || { log "keep: docker not available, nothing to do"; return 0; }
  if [ -z "$(running_services)" ]; then log "keep: stack already stopped"; return 0; fi

  exec 9>"$LOCK"
  flock -n 9 || { log "keep: an ensure is in progress"; return 0; }

  local t cutoff last ens jobs
  t="$(now)"; cutoff=$(( t - min * 60 ))
  last="$(last_activity_epoch "${min}m")"
  if [ -n "$last" ]; then
    log "keep: last request $(age $(( t - last ))) ago (< ${min}m)"; return 0
  fi
  ens="$(last_ensure_epoch)"
  if [[ "$ens" =~ ^[0-9]+$ ]] && [ "$ens" -ge "$cutoff" ]; then
    log "keep: ensure ran $(age $(( t - ens ))) ago (< ${min}m), a scrape is likely imminent"; return 0
  fi
  jobs="$(active_jobs)"
  if [ "$jobs" = "?" ]; then
    log "keep: could not read the job queue (stack partly down or unhealthy)"; return 0
  fi
  if [ "$jobs" -gt 0 ]; then
    log "keep: $jobs job(s) queued/active/crawling"; return 0
  fi
  log "stop: no requests in ${min}m, 0 active jobs — docker compose stop"
  if dc stop >/dev/null 2>&1; then log "stopped"; else log "warn: docker compose stop reported an error"; fi
  return 0
}

cmd_status() {
  have_docker || { echo "state: unknown (docker not available)"; return 0; }
  local running total down t last ens
  total="$(all_services | grep -c . || true)"
  running="$(running_services | grep -c . || true)"
  down="$(down_services | tr '\n' ' ')"
  if [ "$running" -eq 0 ]; then
    echo "state: down (0/$total services running)"
  elif healthy && [ -z "$down" ]; then
    echo "state: up ($running/$total services running, API healthy)"
  else
    echo "state: partial ($running/$total running${down:+, down: ${down% }}; API $(healthy && echo healthy || echo not answering))"
  fi
  t="$(now)"
  if [ "$running" -gt 0 ]; then
    last="$(last_activity_epoch 24h)"
    if [ -n "$last" ]; then echo "last request: $(age $(( t - last ))) ago"; else echo "last request: none in api logs (24h / since start)"; fi
    echo "active jobs: $(active_jobs)"
  else
    echo "last request: n/a (stack stopped)"
    echo "active jobs: 0 (stack stopped)"
  fi
  ens="$(last_ensure_epoch)"
  [[ "$ens" =~ ^[0-9]+$ ]] && echo "last ensure: $(age $(( t - ens ))) ago"
  if [ "$running" -gt 0 ]; then
    echo "memory:"
    # shellcheck disable=SC2046
    docker stats --no-stream --format '  {{.Name}}\t{{.MemUsage}}' $(dc ps -q 2>/dev/null) 2>/dev/null || true
  else
    echo "memory: 0 (stack stopped)"
  fi
  return 0
}

# Hermes shell hook. stdout must stay empty or JSON, so all chatter goes to stderr.
cmd_hook() {
  local payload
  payload="$(cat 2>/dev/null || true)"
  if printf '%s' "$payload" | grep -Eq '"tool_name": *"web_(search|extract|crawl)"|web_search\(|web_extract\(|(127\.0\.0\.1|localhost):10002'; then
    cmd_ensure >&2 || true
  fi
  return 0
}

case "${1:-}" in
  ensure)    cmd_ensure; exit $? ;;
  idle-stop) shift; cmd_idle_stop "${1:-20}" || true; exit 0 ;;
  status)    cmd_status || true; exit 0 ;;
  hook)      cmd_hook || true; exit 0 ;;
  *) echo "usage: $(basename "$0") {ensure|idle-stop [MINUTES]|status|hook}" >&2; exit 2 ;;
esac
