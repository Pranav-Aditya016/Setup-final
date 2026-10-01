# RLD Intelligence — Office Hosting (final, free)

**Scope:** used inside the office only, by a small team, during office hours. The PC is switched off at night and comes back in the morning. **Cost: ₹0** — Docker Desktop, Ollama, Qwen 3 and Windows features only. No cloud, no tunnel, no domain, no login (the office network is the boundary).

**Link for employees:** `http://rldintelligence` (Windows laptops) · `http://rldintelligence.local` (iPhone/Mac) · `http://<fixed-IP>` (works on every device, including Android).

```
Morning: PC powers on (BIOS timer) → Windows auto-signs-in → Docker starts
         → app + Qwen 3 come up (~2-3 min) → screen locks
Day:     office Wi-Fi / LAN → http://rldintelligence → app → Qwen 3 on GPU
         watchdog checks health every 5 min, restarts if needed
19:00:   nightly backup of database + uploaded resumes
Night:   PC off → portal offline (expected) → repeats next morning
```

---

## Part A — Copilot tasks

Same hard rules as `DEPLOYMENT.md`: no changes to ranking, prompts, score blending or API shapes; never run `ingest.py --rebuild`; never commit `deploy/.env`, databases or resumes.

### A1. Remove all remote-access work
- Delete `backend/security/cf_access.py` and its registration in `backend/main.py`. Remove `PyJWT` from `requirements.txt` if nothing else imports `jwt`.
- In `frontend/src/lib/api.js`, remove the Cloudflare/expired-session redirect and reload logic. Plain error handling only.
- Do **not** add any login/auth. Delete `deploy/REMOTE-ACCESS.md` if present.
- Keep: "RLD Intelligence" title, manifest, icons, `.gitattributes`, all of `DEPLOYMENT.md` Phase 1.

✅ `git grep -i -E "cloudflare|cf_access|cf-ray|tailscale"` finds nothing outside docs.

### A2. Apply the updated deploy files
Replace with this folder's versions: `docker-compose.yml`, `.env.example`, `setup.ps1`, `watchdog.ps1`, `DEPLOYMENT.md`. Changes:
- Ollama publishes **no** host port (no conflict with the Windows Ollama app after reboots).
- App is served on **port 80** (`APP_PORT` in `.env`) so the link needs no `:8080`.
- `setup.ps1` opens the firewall for that port (office subnet only) and switches the network from Public to Private if needed.
- No `cloudflared` service.

In the real `deploy/.env`: remove any `CLOUDFLARE_*`, `CF_ACCESS_*`, `APP_BIND` lines; add `APP_PORT=80` and `APP_ENV=production`.

### A3. Check port 80 is free
```powershell
netstat -ano | findstr ":80 " | findstr LISTENING
```
If something is listening (often `PID 4` = Windows HTTP service / IIS), set `APP_PORT=8080` in `deploy/.env` instead and tell the human the links become `http://rldintelligence:8080`. Don't disable Windows services.

### A4. Hide API docs in production
In `main.py`: when `APP_ENV == "production"`, create FastAPI with `docs_url=None, redoc_url=None, openapi_url=None`. Local dev unchanged.

### A5. Friendly "starting up" message
For the first ~2-3 minutes after boot, the app may be up while Ollama or the search index isn't ready. In the frontend, if `/api/health` is not OK, show a banner: "RLD Intelligence is starting up — ready in a couple of minutes" and retry every 15 s, instead of raw errors.

### A6. Rebuild, register tasks, verify
Run in a **PowerShell** terminal (not a Python prompt), as Administrator, from `deploy\`:
```powershell
docker compose down
docker compose build app
Set-ExecutionPolicy -Scope Process Bypass
.\setup.ps1
```
`setup.ps1` is safe to re-run: it rebuilds, re-checks models, firewall, and (re)creates the three scheduled tasks: `RLD-Talent-Start`, `RLD-Talent-Watchdog`, `RLD-Talent-Backup`.

✅ `Get-ScheduledTask RLD-Talent-*` lists 3 tasks · `docker compose ps` shows `ollama` and `app` (healthy) · `docker compose ps` shows **no** host port for ollama · `http://localhost/api/health` → ok, 3976 candidates.

---

## Part B — Human steps (one time)

1. **Name the PC** (needs a restart; if the PC is on a company domain, ask IT first):
   ```powershell
   Rename-Computer -NewName "rldintelligence" -Restart
   ```
   (Windows names max 15 characters, so no hyphen.)

2. **Fixed IP:** router admin page → DHCP reservation for this PC's MAC address. If the router has a "local DNS / hostname" option, add `rldintelligence` → that IP; then `http://rldintelligence` works on Android too. Otherwise Android users use `http://<fixed-IP>`.

3. **Auto sign-in:** install Microsoft **Sysinternals Autologon** (free) and enter the PC account's password. `start-stack.ps1` locks the screen after starting everything.

4. **Auto power-on every morning** — pick one:
   - **BIOS timer:** BIOS → Power / APM → "Resume by RTC Alarm" (name varies: "RTC Wake", "Power On By RTC") → every weekday 08:30.
   - **Power-loss restore:** BIOS → "Restore on AC Power Loss = Power On", and staff switch the PC off at the plug/strip at night instead of Shut Down.
   - In Windows: Control Panel → Power Options → "Choose what the power buttons do" → untick **Turn on fast startup** (fast startup can stop BIOS timers from working).

5. **Docker Desktop settings:** General → tick "Start Docker Desktop when you sign in", untick "Open Docker Dashboard at startup".

6. **Bookmark for staff:** open the link on each phone → browser menu → **Add to Home Screen** → it appears as **RLD Intelligence**. Phones must be on the **office Wi-Fi** (not guest Wi-Fi, not mobile data).

---

## Part C — Test before handing over

- [ ] Office laptop: `http://rldintelligence` opens the app.
- [ ] iPhone on office Wi-Fi: `http://rldintelligence.local` (or the IP) works.
- [ ] Android on office Wi-Fi: `http://<fixed-IP>` works.
- [ ] Two people run evaluations at the same time — no errors.
- [ ] **Shutdown test:** shut down in the evening (or test now with the BIOS timer set 5 minutes ahead) → PC powers on by itself → within ~3 minutes the link works and the screen is locked, nobody touched the keyboard.
- [ ] `deploy\logs\startup.log` shows "Stack up"; after 19:00 a zip appears in the backup folder.

**If other devices can't open the link:** on the PC run `Get-NetConnectionProfile` (must be Private), `Get-NetFirewallRule -DisplayName "RLD Talent Portal"` (must exist), `netstat -ano | findstr ":80 "` (must show `0.0.0.0:80`). From another laptop: `Test-NetConnection <PC-IP> -Port 80`. If the laptop works but phones don't, the office Wi-Fi isolates wireless devices or is on a separate network from the PC — ask whoever manages the router.

---

## Later (only if needed)

- **Access from outside the office:** Tailscale (free, private, each user installs the app) — no code changes needed.
- **Available 24/7:** just don't switch the PC off; everything already restarts itself after reboots and Windows updates.
