# RLD Talent Intelligence v2 — Production Deployment Guide

Target: self-host the app on one office Windows PC (RTX 4060 Ti 16 GB, Ryzen 9, 32 GB RAM) with Docker, reachable by employees on the office LAN, starting automatically every morning.

---

## 0. Instructions for GitHub Copilot (read first)

You are implementing this deployment inside the `rld-talent-intelligence-v2` repo. Work phase by phase, in order. After each task, check its acceptance criteria before moving on.

**Hard rules — do not break these:**

1. **Do not change product behaviour.** Do not modify ranking logic (`matching/ranker.py`), score blending (35% model / 65% deterministic), rubric maxima, banding thresholds, prompts (`llm/prompts.py`), or API request/response shapes. This work is configuration, paths, connection settings and packaging only.
2. **Never run `data/ingest.py --rebuild`.** It deletes and recreates the database and needs source workbooks that are not in this repo.
3. **Never commit personal data**: `*.db`, `*.db-wal`, `*.db-shm`, resume PDFs/DOCX, `deploy/.env`, backups.
4. **Do not rewrite git history** (filter-repo, force-push). Phase 5 explains this is a human decision.
5. Keep local development working: running `uvicorn main:app` from `backend/` with no env vars set must behave exactly as today (defaults = current paths and `http://127.0.0.1:11434`).
6. When something in this guide doesn't match the code (a file name, a path, an env var the code already uses), follow the code and adapt the guide's intent; leave a short note in the PR description.

---

## 1. Context

**Backend:** FastAPI in `backend/main.py`. Registers routers (`routes/jd.py`, `pool.py`, `upload.py`, `match.py`, `candidates.py`, `interview.py`, `reports.py`, comms), initialises SQLite pipeline storage, builds the candidate search index at startup, exposes `GET /api/health`, and serves the built frontend from `frontend/dist` when present.

**Data:** single SQLite DB `backend/data/talent_pool.db` with FTS5. Holds candidates (summaries, work history, education, skills, projects, certifications), the hiring pipeline, and cached match evaluations. Schema/migrations: `data/db.py`. Queries/search: `data/repository.py`. Uploads normalised by `data/pool_writer.py`. Pipeline persistence: `storage/sqlite_store.py` (a Sheets adapter exists but is not wired). Currently ~3,976 candidates.

**AI:** local Ollama via `llm/client.py`. Text model `qwen3:8b`; OCR fallback `glm-ocr` for image-based resumes (`resume/document_prep.py`, `resume/ocr.py`). `POST /api/match/evaluate` streams NDJSON.

**Current limitations that matter for deployment:** built as a single-user local tool — CORS allows all origins, no auth, hard-coded local paths, DB and two resume PDFs tracked in git.

---

## 2. Target architecture

```
Employee browsers (office LAN)
        │  http://rldintelligence
        ▼
┌──────────────── Office PC: Windows 11 + Docker Desktop (WSL2) ───────────────┐
│                                                                              │
│  app container (rld-talent-app)          ollama container                    │
│  ├─ FastAPI :8000  (host port 8080)  ──► ├─ :11434 (localhost-only on host) │
│  ├─ serves /app/frontend/dist            ├─ qwen3:8b + glm-ocr on the GPU    │
│  └─ /data volume: talent_pool.db + files └─ ollama-models volume             │
│                                                                              │
│  Boot chain: BIOS power-on → Windows Autologon → Task "RLD-Talent-Start"     │
│              → Docker Desktop → compose up → screen locks                    │
│  Watchdog task every 5 min (hits /api/health) · Backup task daily 7 PM       │
└──────────────────────────────────────────────────────────────────────────────┘
```

Why this shape:

- **One app container, no nginx.** FastAPI already serves `frontend/dist` and all routes live under `/api`, so the browser talks to one origin and NDJSON streaming works without proxy tuning.
- **Named Docker volume for data, not a Windows bind mount.** SQLite locking over the Windows↔WSL2 file share is slow and unreliable; a named volume lives inside WSL2's ext4 disk.
- **`--workers 1`.** SQLite allows one writer at a time. The app is async and LLM-bound, so one worker serves the whole office.
- **Netlify/Vercel are not used.** They can't run a GPU model, and putting a no-login portal with candidate personal data on the public internet is not acceptable.

---

## 3. Target repo layout (new/changed files only)

```
rld-talent-intelligence-v2/
├─ .dockerignore                 NEW
├─ .gitattributes                NEW
├─ .gitignore                    CHANGED
├─ backend/
│  ├─ config.py                  NEW  (single source of settings)
│  ├─ main.py                    CHANGED (CORS, frontend path, SPA fallback)
│  ├─ data/db.py                 CHANGED (DB path + SQLite pragmas)
│  ├─ storage/sqlite_store.py    CHANGED (DB path)
│  ├─ llm/client.py              CHANGED (Ollama host, model names, timeouts)
│  └─ resume/*.py, data/pool_writer.py, routes/upload.py, routes/pool.py
│                                CHANGED where they read/write files
├─ frontend/                     CHANGED only if API base URL is absolute
└─ deploy/                       NEW (all files below)
   ├─ docker-compose.yml   Dockerfile   entrypoint.sh   backup_inside.py
   ├─ .env.example
   └─ setup.ps1  start-stack.ps1  watchdog.ps1  backup.ps1  restore.ps1  update.ps1
```

---

## 4. Phase 1 — Code changes (make the app deployable)

### Task 1.1 — Central config: `backend/config.py`

Create one settings module. Every path, URL and model name in the backend must come from here.

```python
# backend/config.py
import os
from pathlib import Path

BACKEND_DIR = Path(__file__).resolve().parent
REPO_DIR = BACKEND_DIR.parent

# Data: defaults keep today's local layout; Docker sets DATA_DIR=/data
DATA_DIR = Path(os.getenv("DATA_DIR", BACKEND_DIR / "data"))
DB_FILENAME = os.getenv("DB_FILENAME", "talent_pool.db")
DB_PATH = DATA_DIR / DB_FILENAME

# Frontend build served by FastAPI
FRONTEND_DIST = Path(os.getenv("FRONTEND_DIST", REPO_DIR / "frontend" / "dist"))

# Ollama
OLLAMA_HOST = os.getenv("OLLAMA_HOST", "http://127.0.0.1:11434").rstrip("/")
TEXT_MODEL = os.getenv("TEXT_MODEL", "qwen3:8b")
OCR_MODEL = os.getenv("OCR_MODEL", "glm-ocr")
OLLAMA_TIMEOUT_S = float(os.getenv("OLLAMA_TIMEOUT_S", "300"))

# CORS: comma-separated. Empty => no CORS middleware (same-origin only).
# Local dev default keeps today's permissive behaviour.
CORS_ORIGINS = [o.strip() for o in os.getenv("CORS_ORIGINS", "*").split(",") if o.strip()]

DATA_DIR.mkdir(parents=True, exist_ok=True)
```

Then find every hard-coded path/URL/model and replace it:

```bash
grep -rnE "talent_pool\.db|11434|localhost|127\.0\.0\.1|qwen3|glm-ocr|frontend/dist|Path\(__file__\)" backend --include=*.py
```

Expected touch points: `data/db.py`, `data/repository.py`, `storage/sqlite_store.py`, `data/pool_writer.py`, `matching/deep_eval.py`, `llm/client.py`, `resume/document_prep.py`, `resume/ocr.py`, `routes/upload.py`, `routes/pool.py`, `main.py`.

**Any file the app writes at runtime** (uploaded resumes, rendered page images, extracted text, temp files that must persist) must live under `config.DATA_DIR` (e.g. `DATA_DIR / "resumes"`). Code (`data/*.py`) stays where it is — only runtime files move. If uploads currently go to a folder inside `backend/data/`, keep the same sub-folder name under `DATA_DIR` so local dev is unchanged, and list that folder name in `SEED_DIRS` in `deploy/.env.example`.

Leave `data/ingest.py` default workbook paths alone (it's an offline tool), but if it writes the DB, make it use `config.DB_PATH`.

✅ Acceptance: grep above shows no remaining hard-coded DB path, Ollama URL or model name outside `config.py`. App still starts locally with no env vars.

### Task 1.2 — SQLite connection settings (multi-user safety)

Wherever SQLite connections are opened (`data/db.py`, `storage/sqlite_store.py`, any other `sqlite3.connect`), route them through one helper:

```python
# in data/db.py
import sqlite3
from config import DB_PATH

def connect() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH, timeout=10, check_same_thread=False)
    conn.row_factory = sqlite3.Row          # keep whatever row_factory the code uses today
    conn.execute("PRAGMA journal_mode=WAL;")      # readers don't block the writer
    conn.execute("PRAGMA busy_timeout=10000;")    # wait instead of 'database is locked'
    conn.execute("PRAGMA synchronous=NORMAL;")
    conn.execute("PRAGMA foreign_keys=ON;")       # only if the schema already expects it
    return conn
```

Rules:
- Keep write transactions short. Never hold a write transaction open while waiting on Ollama (e.g. in `match/evaluate` streaming: generate first, then open a short transaction to write the cache row).
- If a single long-lived global connection is shared across requests, either guard writes with a `threading.Lock` or switch to a connection per request/operation.
- Do not change the schema.

✅ Acceptance: two simultaneous `POST /api/match/evaluate` calls plus a `PATCH /api/candidates/{id}` complete without `database is locked`.

### Task 1.3 — `main.py`: CORS, frontend path, SPA fallback

- CORS: if `config.CORS_ORIGINS` is empty, don't add CORS middleware. Otherwise add it with that list (default `*` keeps local dev unchanged; Docker sets it empty).
- Serve the frontend from `config.FRONTEND_DIST`.
- SPA fallback: any non-`/api` GET that isn't a real static file returns `index.html`, so refreshing a deep link (e.g. `/pipeline`) doesn't 404. Unknown `/api/*` paths must still return JSON 404. Mount static assets and register the fallback **after** all API routers.

```python
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from config import FRONTEND_DIST

if FRONTEND_DIST.exists():
    app.mount("/assets", StaticFiles(directory=FRONTEND_DIST / "assets"), name="assets")

    @app.get("/{full_path:path}", include_in_schema=False)
    def spa(full_path: str):
        if full_path.startswith("api/"):
            from fastapi import HTTPException
            raise HTTPException(404)
        candidate = FRONTEND_DIST / full_path
        if full_path and candidate.is_file():
            return FileResponse(candidate)
        return FileResponse(FRONTEND_DIST / "index.html")
```

Adapt to how `main.py` mounts the frontend today; don't create a second mount.

- Health: keep `/api/health` as-is, but make sure it returns **HTTP 503** (not 200) when Ollama is unreachable or the index isn't built yet. The Docker healthcheck and the watchdog rely on the status code.

✅ Acceptance: `GET /` and `GET /some/deep/link` return the app; `GET /api/nope` returns 404 JSON; `/api/health` returns 503 while Ollama is stopped.

### Task 1.4 — Ollama client

In `llm/client.py` (and `resume/ocr.py` if it calls Ollama directly):
- Base URL from `config.OLLAMA_HOST`; models from `config.TEXT_MODEL` / `config.OCR_MODEL`.
- Timeout from `config.OLLAMA_TIMEOUT_S` (long generations + queueing when several users evaluate at once).
- On connection errors, raise a clear error the routes turn into a 503 with a readable message — not a 500 stack trace.
- Don't change prompts, `think` settings, temperatures or output parsing.

✅ Acceptance: with `OLLAMA_HOST=http://ollama:11434` in Docker, `/api/health` reports both models ready.

### Task 1.5 — Frontend API base URL

Search the frontend for absolute backend URLs:

```bash
grep -rnE "127\.0\.0\.1|localhost:8000|http://" frontend/src
```

All API calls must be **relative** (`/api/...`) in production builds. If dev relies on a different origin, use the Vite dev proxy (`server.proxy['/api'] = 'http://127.0.0.1:8000'` in `vite.config.*`) instead of an absolute URL. Confirm the build output folder is `frontend/dist`.

✅ Acceptance: `npm run build` succeeds; built JS contains no `127.0.0.1` / `localhost:8000`.

### Task 1.6 — Repo hygiene files

**`.gitattributes`** (prevents CRLF breaking the container entrypoint on Windows):

```
*.sh text eol=lf
```

**Append to `.gitignore`:**

```
# Runtime data / personal data
backend/data/*.db
backend/data/*.db-wal
backend/data/*.db-shm
deploy/.env
deploy/logs/
*.zip
```

Do **not** `git rm` the tracked DB/PDFs in this PR — see Phase 5.

**`.dockerignore`** (repo root — keeps personal data and junk out of the image):

```
.git
**/node_modules
**/__pycache__
**/.venv
**/venv
**/.pytest_cache
frontend/dist
backend/data/*.db
backend/data/*.db-wal
backend/data/*.db-shm
**/*.pdf
**/*.docx
deploy/.env
deploy/logs
```

If any PDF/DOCX is a genuine app asset (not a resume), add a `!path/to/file` exception.

✅ Acceptance: after building, `docker run --rm --entrypoint sh rld-talent-app -c "find / -name '*.db' -o -name '*.pdf' 2>/dev/null | grep -v proc"` finds no candidate data in the image.

---

## 5. Phase 2 — Container files

Create these exactly, then adjust only where marked.

**`deploy/docker-compose.yml`**

```yaml
# RLD Talent Intelligence v2 - production stack for the office PC.
# Lives at <repo>/deploy/docker-compose.yml. Run all commands from this folder.
name: rld-talent

services:
  ollama:
    image: ollama/ollama:latest            # pin to a tested version once everything works
    restart: always
    volumes:
      - ollama-models:/root/.ollama
    environment:
      OLLAMA_KEEP_ALIVE: "24h"             # keep models in VRAM, no cold starts
      OLLAMA_NUM_PARALLEL: "2"             # two concurrent generations
      OLLAMA_MAX_LOADED_MODELS: "2"        # qwen3:8b + glm-ocr resident together
      OLLAMA_CONTEXT_LENGTH: "${CONTEXT_LENGTH:-8192}"
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
    healthcheck:
      test: ["CMD", "ollama", "list"]
      interval: 30s
      timeout: 10s
      retries: 10
      start_period: 30s

  app:
    build:
      context: ..                          # repo root
      dockerfile: deploy/Dockerfile
    image: rld-talent-app:latest
    restart: always
    env_file: .env
    environment:
      DATA_DIR: /data
      DB_FILENAME: talent_pool.db
      FRONTEND_DIST: /app/frontend/dist
      OLLAMA_HOST: http://ollama:11434
    volumes:
      - app-data:/data                     # SQLite DB + uploaded resumes; survives rebuilds
      - ../backend/data:/seed:ro           # first-run seed source only (read-only)
    ports:
      # Office LAN: http://rldintelligence (port 80). Set APP_PORT=8080 in .env if port 80 is taken.
      - "${APP_PORT:-80}:8000"
    depends_on:
      ollama:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "python", "-c", "import urllib.request;urllib.request.urlopen('http://localhost:8000/api/health',timeout=5)"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 180s                   # search index for ~4k candidates builds at startup

volumes:
  ollama-models:
  app-data:
```

**`deploy/Dockerfile`**

```dockerfile
# syntax=docker/dockerfile:1
# Build context = repo root. One image: React build + FastAPI (FastAPI serves frontend/dist).

# ---------- Stage 1: frontend ----------
FROM node:20-alpine AS frontend
WORKDIR /src/frontend
COPY frontend/package*.json ./
RUN npm ci
COPY frontend/ ./
RUN npm run build

# ---------- Stage 2: backend runtime ----------
FROM python:3.11-slim AS runtime
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1

# Uncomment ONLY if requirements.txt uses pdf2image (needs poppler). PyMuPDF/pypdf need nothing.
# RUN apt-get update && apt-get install -y --no-install-recommends poppler-utils && rm -rf /var/lib/apt/lists/*

WORKDIR /app/backend
COPY backend/requirements.txt .
RUN pip install -r requirements.txt
COPY backend/ ./
COPY --from=frontend /src/frontend/dist /app/frontend/dist
COPY deploy/entrypoint.sh /entrypoint.sh
COPY deploy/backup_inside.py /app/ops/backup_inside.py
RUN sed -i 's/\r$//' /entrypoint.sh && chmod +x /entrypoint.sh && mkdir -p /data

EXPOSE 8000
ENTRYPOINT ["/entrypoint.sh"]
# 1 worker on purpose: SQLite has a single writer; async FastAPI still serves many users.
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1", "--proxy-headers"]
```

Check `backend/requirements.txt`: if it uses `pdf2image`, uncomment the poppler line. If the local Python version isn't 3.11, match it.

**`deploy/entrypoint.sh`**

```sh
#!/bin/sh
# Seeds the data volume from the repo's DB on first run, then starts the app.
set -e
mkdir -p "$DATA_DIR"

if [ ! -f "$DATA_DIR/$DB_FILENAME" ] && [ -f "/seed/$DB_FILENAME" ]; then
  echo "[entrypoint] Seeding $DATA_DIR/$DB_FILENAME from /seed (SQLite backup API)"
  python - <<'PY'
import os, sqlite3
d, n = os.environ["DATA_DIR"], os.environ["DB_FILENAME"]
src = sqlite3.connect(f"file:/seed/{n}?immutable=1", uri=True)
dst = sqlite3.connect(f"{d}/{n}")
src.backup(dst)
dst.close(); src.close()
PY
fi

# Seed any resume/document folders the app stores under DATA_DIR (names set by SEED_DIRS in .env)
for dir in $SEED_DIRS; do
  if [ -d "/seed/$dir" ] && [ ! -d "$DATA_DIR/$dir" ]; then
    echo "[entrypoint] Seeding folder $dir"
    cp -r "/seed/$dir" "$DATA_DIR/$dir"
  fi
done

exec "$@"
```

The DB is copied into the volume **once** using SQLite's backup API (safe even if the source has WAL files). After that, the volume is the source of truth — editing `backend/data/talent_pool.db` on Windows no longer affects the running app.

**`deploy/backup_inside.py`**

```python
"""Runs inside the app container. Writes a consistent snapshot to $DATA_DIR/_backup/."""
import os, pathlib, sqlite3, tarfile

data = pathlib.Path(os.environ.get("DATA_DIR", "/data"))
db_name = os.environ.get("DB_FILENAME", "talent_pool.db")
out = data / "_backup"
out.mkdir(exist_ok=True)
for f in out.iterdir():
    f.unlink()

src = sqlite3.connect(data / db_name)
dst = sqlite3.connect(out / db_name)
src.backup(dst)            # online backup: safe while the app is writing
dst.close(); src.close()

with tarfile.open(out / "files.tar.gz", "w:gz") as tar:
    for p in data.iterdir():
        if p.name == "_backup" or p.name.startswith(db_name):
            continue
        tar.add(p, arcname=p.name)
print("backup ok")
```

**`deploy/.env.example`**

```ini
# Copied to deploy/.env by setup.ps1. Never commit deploy/.env.
TEXT_MODEL=qwen3:8b
OCR_MODEL=glm-ocr
CONTEXT_LENGTH=8192
# Empty = same-origin only (frontend is served by the backend, so no CORS is needed)
CORS_ORIGINS=
# Space-separated folder names under backend/data to copy into the volume on first run
# (e.g. the uploaded-resume folder). Leave empty if all documents live inside the DB.
SEED_DIRS=
# Nightly backup target. Point at a Google Drive / OneDrive synced folder for a free off-site copy.
BACKUP_DIR=C:\Users\Public\RLD-Backups

# ---- Office hosting ----
# Port employees use. 80 = http://rldintelligence (no port in the link). Use 8080 if 80 is taken.
APP_PORT=80
APP_ENV=production
```

✅ Phase 2 acceptance (run from `deploy/`):

```powershell
docker compose build
docker compose up -d
docker compose exec ollama ollama pull qwen3:8b
docker compose exec ollama ollama pull glm-ocr
docker compose restart app
curl http://localhost/api/health        # Ollama reachable, both models ready, ~3,976 candidates
```

Then run the existing verification scripts inside the container (they must target the volume DB, never the repo copy):

```powershell
docker compose exec app ls scripts
docker compose exec app python scripts/<each_verification_script>.py
```

If a script writes test records, run it against a copy, not production: `docker compose exec -e DB_FILENAME=verify.db app ...` after copying the DB to `/data/verify.db`.

---

## 6. Phase 3 — Windows operations scripts

**`deploy/setup.ps1`**

```powershell
# ONE-TIME SETUP. Admin PowerShell, from the deploy folder:
#   Set-ExecutionPolicy -Scope Process Bypass; .\setup.ps1
$ErrorActionPreference = "Stop"
$Deploy = $PSScriptRoot
$Repo   = Split-Path -Parent $Deploy
Set-Location $Deploy
function Env($k) { (Get-Content "$Deploy\.env" | Where-Object { $_ -match "^$k=" }) -replace "^$k=","" }

Write-Host "`n[1/9] NVIDIA driver..." -ForegroundColor Cyan
nvidia-smi | Out-Null; if ($LASTEXITCODE) { throw "nvidia-smi failed. Install the latest NVIDIA driver." }

Write-Host "[2/9] Docker..." -ForegroundColor Cyan
docker info *> $null; if ($LASTEXITCODE) { throw "Docker not running. Install Docker Desktop (WSL2 backend) and start it." }

Write-Host "[3/9] GPU inside Docker..." -ForegroundColor Cyan
docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi
if ($LASTEXITCODE) { throw "GPU not visible in Docker. Update Docker Desktop + NVIDIA driver, run 'wsl --update'." }

Write-Host "[4/9] Config..." -ForegroundColor Cyan
if (-not (Test-Path "$Deploy\.env")) { Copy-Item "$Deploy\.env.example" "$Deploy\.env" }
if (-not (Test-Path "$Repo\backend\data\talent_pool.db")) {
  Write-Warning "backend\data\talent_pool.db not found - the app will start with an EMPTY pool."
}
$wslcfg = "$env:USERPROFILE\.wslconfig"
if (-not (Test-Path $wslcfg)) {
  "[wsl2]`nmemory=20GB`nprocessors=12`n" | Set-Content $wslcfg
  Write-Host "  Wrote $wslcfg. Restart Docker Desktop once after setup for it to apply."
}

Write-Host "[5/9] Building image..." -ForegroundColor Cyan
docker compose build

Write-Host "[6/9] Starting Ollama + pulling models..." -ForegroundColor Cyan
docker compose up -d ollama
Start-Sleep -Seconds 15
docker compose exec ollama ollama pull (Env "TEXT_MODEL")
docker compose exec ollama ollama pull (Env "OCR_MODEL")

Write-Host "[7/9] Starting app (first run seeds the database)..." -ForegroundColor Cyan
docker compose up -d
$ok = $false
$port = Env "APP_PORT"; if (-not $port) { $port = "80" }
for ($i = 0; $i -lt 40; $i++) {
  try { $h = Invoke-RestMethod "http://localhost:$port/api/health" -TimeoutSec 5; $ok = $true; break } catch { Start-Sleep 5 }
}
if ($ok) { $h | ConvertTo-Json -Depth 5 } else { Write-Warning "Health check not passing yet. Check: docker compose logs app" }

Write-Host "[8/9] Firewall (office subnet only) + power..." -ForegroundColor Cyan
if (-not (Get-NetFirewallRule -DisplayName "RLD Talent Portal" -ErrorAction SilentlyContinue)) {
  New-NetFirewallRule -DisplayName "RLD Talent Portal" -Direction Inbound -Protocol TCP -LocalPort $port `
    -RemoteAddress LocalSubnet -Action Allow -Profile Domain,Private | Out-Null
}
Get-NetConnectionProfile | Where-Object NetworkCategory -eq Public | ForEach-Object {
  Set-NetConnectionProfile -InterfaceIndex $_.InterfaceIndex -NetworkCategory Private
  Write-Host "  Network '$($_.Name)' switched from Public to Private"
}
powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0

Write-Host "[9/9] Scheduled tasks (start, watchdog, backup)..." -ForegroundColor Cyan
$user = "$env:USERDOMAIN\$env:USERNAME"
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 1)
function Task($name, $script, $trigger) {
  $a = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Deploy\$script`""
  Register-ScheduledTask -TaskName $name -Action $a -Trigger $trigger -Settings $settings -User $user -RunLevel Highest -Force | Out-Null
}
$t1 = New-ScheduledTaskTrigger -AtLogOn -User $user; $t1.Delay = "PT30S"
Task "RLD-Talent-Start"    "start-stack.ps1" $t1
Task "RLD-Talent-Watchdog" "watchdog.ps1"    (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) -RepetitionInterval (New-TimeSpan -Minutes 5))
Task "RLD-Talent-Backup"   "backup.ps1"      (New-ScheduledTaskTrigger -Daily -At 7pm)

$ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notmatch '^(127|169\.254|172\.)' } | Select-Object -First 1).IPAddress
Write-Host "`nDone. Portal: http://$env:COMPUTERNAME (or http://$ip) on port $port" -ForegroundColor Green
Write-Host "Manual steps left: see OFFICE-HOSTING.md Part B (PC name, Autologon, BIOS power-on, fixed IP)."
```

**`deploy/start-stack.ps1`**

```powershell
# Runs at Windows sign-in. Starts Docker Desktop, waits for the engine, brings the stack up, locks the screen.
$Deploy = $PSScriptRoot
New-Item -ItemType Directory -Force "$Deploy\logs" | Out-Null
$Log = "$Deploy\logs\startup.log"
function Log($m) { "$(Get-Date -Format s)  $m" | Out-File $Log -Append -Encoding utf8 }

Log "---- boot ----"
if (-not (Get-Process "Docker Desktop" -ErrorAction SilentlyContinue)) {
  Start-Process "C:\Program Files\Docker\Docker\Docker Desktop.exe"; Log "Launched Docker Desktop"
}
$deadline = (Get-Date).AddMinutes(5); $ready = $false
while ((Get-Date) -lt $deadline) {
  docker info *> $null; if ($LASTEXITCODE -eq 0) { $ready = $true; break }; Start-Sleep 5
}
if (-not $ready) { Log "Docker engine not ready after 5 min"; exit 1 }

Set-Location $Deploy
docker compose up -d --remove-orphans 2>&1 | ForEach-Object { Log $_ }
Log "Stack up"
Start-Sleep -Seconds 10
rundll32.exe user32.dll,LockWorkStation   # containers keep running while locked
```

**`deploy/watchdog.ps1`**

```powershell
# Runs every 5 minutes. Restarts the stack if /api/health fails.
$Deploy = $PSScriptRoot
New-Item -ItemType Directory -Force "$Deploy\logs" | Out-Null
$Log = "$Deploy\logs\watchdog.log"
function Log($m) { "$(Get-Date -Format s)  $m" | Out-File $Log -Append -Encoding utf8 }
$port = (Get-Content "$Deploy\.env" | Where-Object { $_ -match '^APP_PORT=' }) -replace 'APP_PORT=',''
if (-not $port) { $port = "80" }
function Healthy { try { (Invoke-WebRequest "http://localhost:$port/api/health" -UseBasicParsing -TimeoutSec 15).StatusCode -eq 200 } catch { $false } }

docker info *> $null
if ($LASTEXITCODE -ne 0) { Log "Docker down - running start-stack"; & "$Deploy\start-stack.ps1"; exit }
if (Healthy) { exit 0 }

Set-Location $Deploy
Log "Health failed - compose up"
docker compose up -d 2>&1 | ForEach-Object { Log $_ }
Start-Sleep -Seconds 120
if (-not (Healthy)) { Log "Still failing - restarting app"; docker compose restart app 2>&1 | ForEach-Object { Log $_ } }
```

**`deploy/backup.ps1`**

```powershell
# Nightly backup (7 PM). Consistent SQLite snapshot + uploaded files, zipped, last 14 kept.
$Deploy = $PSScriptRoot
Set-Location $Deploy
New-Item -ItemType Directory -Force "$Deploy\logs" | Out-Null
$Log = "$Deploy\logs\backup.log"
function Log($m) { "$(Get-Date -Format s)  $m" | Out-File $Log -Append -Encoding utf8 }

$dest = (Get-Content .env | Where-Object { $_ -match '^BACKUP_DIR=' }) -replace 'BACKUP_DIR=',''
if (-not $dest) { $dest = "C:\Users\Public\RLD-Backups" }
New-Item -ItemType Directory -Force $dest | Out-Null

docker compose exec -T app python /app/ops/backup_inside.py
if ($LASTEXITCODE) { Log "Backup FAILED"; exit 1 }

$tmp = Join-Path $env:TEMP "rld-backup"
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
docker compose cp app:/data/_backup $tmp
$zip = Join-Path $dest ("talent-" + (Get-Date -Format "yyyy-MM-dd") + ".zip")
Compress-Archive -Path "$tmp\*" -DestinationPath $zip -Force
Remove-Item $tmp -Recurse -Force
Log "Saved $zip"

Get-ChildItem $dest -Filter "talent-*.zip" | Sort-Object LastWriteTime -Descending | Select-Object -Skip 14 | Remove-Item -Force
```

**`deploy/restore.ps1`**

```powershell
# Restore from a backup zip:  .\restore.ps1 -Zip "C:\...\talent-2026-10-01.zip"
param([Parameter(Mandatory)][string]$Zip)
$Deploy = $PSScriptRoot; Set-Location $Deploy
$tmp = Join-Path $env:TEMP "rld-restore"
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Expand-Archive $Zip -DestinationPath $tmp
docker compose stop app
docker compose run --rm --no-deps --entrypoint sh -v "${tmp}:/restore:ro" app -c `
  "rm -f /data/talent_pool.db /data/talent_pool.db-wal /data/talent_pool.db-shm && cp /restore/talent_pool.db /data/ && tar -xzf /restore/files.tar.gz -C /data"
docker compose start app
Remove-Item $tmp -Recurse -Force
Write-Host "Restored from $Zip"
```

**`deploy/update.ps1`**

```powershell
# Deploy new code: pull, rebuild, restart. Data volume is untouched.
$Deploy = $PSScriptRoot
Set-Location (Split-Path -Parent $Deploy); git pull
Set-Location $Deploy
docker compose build app
docker compose up -d
docker image prune -f
```

---

## 7. Phase 4 — Machine setup (human steps, not Copilot)

1. **NVIDIA driver**: latest Game Ready/Studio driver on Windows. Don't install a driver inside WSL.
2. **Docker Desktop**: WSL2 backend. Settings → General: enable "Start Docker Desktop when you sign in", disable "Open Docker Dashboard at startup". Settings → Resources → WSL integration: default distro on.
3. **Run `deploy\setup.ps1`** as Administrator.
4. **Auto-login**: install Sysinternals **Autologon** (stores the password encrypted in LSA, unlike `netplwiz`). Use a dedicated local account, e.g. `rld-ai`, without admin rights for day-to-day if IT allows; `start-stack.ps1` locks the screen right after boot.
5. **Power-on**: BIOS → "Restore on AC Power Loss = Power On" and/or "Resume by RTC Alarm" weekdays ~08:30. Simplest: label the PC "do not shut down" and leave it on.
6. **Fixed address**: DHCP reservation on the office router for the PC's MAC, or a local DNS name like `rld-ai.local`. Bookmark `http://rldintelligence` for employees.
7. **Windows Update**: set Active Hours to office hours so updates don't reboot mid-day. Reboots are fine — the boot chain brings everything back.
8. **Backups off-site**: install Google Drive or OneDrive desktop, set `BACKUP_DIR` in `deploy\.env` to a synced folder.

---

## 8. Verification checklist

- [ ] `/api/health` OK on `http://localhost` and from another office machine via `http://rldintelligence`.
- [ ] Pool stats show ~3,976 candidates.
- [ ] JD generate, shortlist, streaming evaluate (tokens appear progressively), upload inspect/commit (native PDF **and** a scanned image PDF → OCR), pipeline CRUD, interview questions, comms drafts, Excel report download.
- [ ] Two people run evaluations at the same time; no `database is locked`.
- [ ] Refresh on a deep link doesn't 404.
- [ ] `docker compose exec ollama ollama ps` shows both models at 100% GPU.
- [ ] **Reboot test**: restart Windows → without touching anything, portal is back within ~3 minutes and screen is locked.
- [ ] **Crash test**: `docker compose stop app` → within 5–7 minutes the watchdog brings it back (`deploy\logs\watchdog.log`).
- [ ] **Backup test**: run `.\backup.ps1`, then restore that zip on a test copy with `.\restore.ps1`.
- [ ] Port 11434 is **not** published on the host (`docker compose ps` shows no host port for ollama).

---

## 9. Operations runbook

| Task | Command (in `deploy\`) |
|---|---|
| Status | `docker compose ps` |
| App logs | `docker compose logs -f --tail 200 app` |
| Model / GPU state | `docker compose exec ollama ollama ps` |
| Deploy new code | `.\update.ps1` |
| Manual backup | `.\backup.ps1` |
| Restore | `.\restore.ps1 -Zip <path>` |
| Change text model | edit `TEXT_MODEL` in `.env` → `docker compose exec ollama ollama pull <model>` → `docker compose up -d app` |
| Stop everything | `docker compose down` (data volumes are kept; **never** add `-v`) |

**Model sizing (16 GB VRAM):** `qwen3:8b` + `glm-ocr` fit comfortably with room for 2 parallel 8k-context requests. `qwen3:14b` also fits if quality needs it (raise nothing else; test with two concurrent evaluations). Don't go beyond what fits fully in VRAM — spilling to system RAM makes evaluations several times slower.

**Troubleshooting**

| Symptom | Likely cause / fix |
|---|---|
| `exec /entrypoint.sh: no such file` | CRLF line endings → `.gitattributes` + rebuild (Dockerfile also strips `\r`). |
| Health says Ollama unreachable | `docker compose logs ollama`; GPU not passed through → rerun the CUDA test in `setup.ps1`, `wsl --update`, restart Docker Desktop. |
| Pool shows 0 candidates | Volume was created before the seed DB existed. Copy it in: `docker compose stop app`, then `docker compose run --rm --no-deps --entrypoint sh app -c "rm -f /data/talent_pool.db*"`, `docker compose up -d app` (entrypoint re-seeds). Only do this before real use — it wipes pipeline data in the volume. |
| `database is locked` | Something holds a write transaction during LLM calls — revisit Task 1.2. |
| Very slow evaluations | `ollama ps` shows CPU% → model too big or two big models loaded; check `TEXT_MODEL`. |
| Portal unreachable from other PCs | Firewall rule profile/subnet, network marked Public instead of Private, IP changed (DHCP reservation). |
| Nothing after reboot | Autologon not set, or check `deploy\logs\startup.log` and Task Scheduler history for `RLD-Talent-Start`. |

---

## 10. Phase 5 — Privacy and git hygiene (human decision)

The DB and two resume PDFs with personal data are tracked in git. After the deployment is running from the Docker volume:

1. Stop tracking them going forward: `git rm --cached backend/data/talent_pool.db <the two PDFs>` and commit (the `.gitignore` from Task 1.6 keeps them out). Keep a local copy for seeding/backup.
2. They still exist in git **history**. Removing them needs a history rewrite (`git filter-repo`) and a force-push, which affects every clone. Get RLD's approval first; until then keep the repo private with minimal collaborators.
3. Access control: the portal has no login and is reachable by anyone on the office LAN. The firewall rule limits it to the local subnet. If guest Wi-Fi shares that subnet, ask IT to separate it, or add a simple shared-password gate later.

---

## 11. Out of scope (known product gaps, unchanged by this work)

- No authentication or per-user audit trail.
- Pipeline stores current status only, no status history; funnel "reached" counts are inferred and exclude rejected candidates.
- Interview flow covers recruiter Round 1 question generation + HR comments only.
- Letters/messages are drafts; nothing is sent by email/WhatsApp.
- Google Sheets storage adapter exists but stays unwired.
