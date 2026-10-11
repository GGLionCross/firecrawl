# Firecrawl on demand

The stack holds ~3.5 GB while idle (the `api` container alone ~2.8 GiB), so it is not kept
resident. It starts when something is about to scrape and is stopped when idle.

`scripts/firecrawl-ctl.sh` is the only control surface:

| Command | What it does | Exit |
|---|---|---|
| `ensure` | If any compose service is not running: `docker compose up -d`, then poll `http://127.0.0.1:10002/` until it answers (`ENSURE_TIMEOUT`, default 60 s, counted after `up -d` returns). Already up and healthy: returns in well under a second. Concurrent calls are serialised with `flock`. | 0, or 1 if the stack could not be brought up |
| `idle-stop [MINUTES]` | `docker compose stop` (never `down`) only when the api logs show no scrape/crawl/search/map/extract request (any `POST`, or a worker taking a job) in the last MINUTES (default 20), no `ensure` ran in that window, and no job is queued/active (nuq Postgres `queue_scrape` + backlog) or crawling (`GET /v1/crawl/ongoing`). Otherwise prints one `keep: <reason>` line. | always 0 |
| `status` | up / down / partial, age of the last request, active jobs, `docker stats` memory per container. | always 0 |
| `hook` | Hermes `pre_tool_call` shell hook: reads the hook JSON on stdin and runs `ensure` when the call is `web_search` / `web_extract`, or the input mentions `127.0.0.1:10002` / `localhost:10002`. Prints nothing on stdout. | always 0 |

Who calls what:

- **Watchdog** — `~/.claude/scripts/resource-guard/guard.sh` calls
  `/home/gglioncross/firecrawl-selfhost/scripts/firecrawl-ctl.sh idle-stop` every few minutes.
  That path and the subcommand names are a contract; do not rename them.
- **Hermes (WSL)** — `~/.hermes/config.yaml` `hooks.pre_tool_call` runs `firecrawl-ctl.sh hook`
  for `web_search|web_extract|terminal|execute_code` (allowlisted in
  `~/.hermes/shell-hooks-allowlist.json`). Takes effect when the gateway (re)starts. Editing this
  script changes its mtime, which `hermes hooks doctor` reports as drift; re-approve if it asks.
- **Anything else** (curl, scripts, other agents) — run `firecrawl-ctl.sh ensure` first.

Why `stop` and not `down`: `stop` keeps the containers, so the next `ensure` is a start (~30 s to
healthy) rather than a recreate, and the `restart: unless-stopped` policy keeps them stopped across a
Docker restart. Redis/RabbitMQ/Postgres are unpersisted anyway, so a stop drops nothing a crawl in
progress would need — which is why `idle-stop` refuses while a job is active.

No `mem_limit` on `api`: its ~2.8 GiB is the idle footprint of the worker harness (API + several nuq
workers + extract worker), not a leak, and a cap would OOM-kill it mid-crawl under load. Not keeping it
resident is the fix; `playwright-service` keeps its existing 4 G cap.

State (last `ensure` time, lock) lives in `${XDG_CACHE_HOME:-~/.cache}/firecrawl-ctl/`.
