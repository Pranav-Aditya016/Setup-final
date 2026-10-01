# Setup-final

For office-only use, you don't need a cloud service at all. The setup you already have is the right solution. It needed three finishing touches, and OFFICE-HOSTING.md is the final guide for Copilot. Everything in it is free.
How it works each day:
Morning: a BIOS timer powers the PC on, Windows signs in by itself, and Docker starts the app and Qwen 3. The screen then locks. It's ready in about 2–3 minutes.
During the day: staff open http://rldintelligence on office Wi-Fi. A health check runs every 5 minutes and restarts anything that crashes.
7 PM: an automatic backup of the database and uploaded resumes.
Night: the PC is off and the portal is offline, which is expected.
What changed:
A short link without a port number. The app now uses port 80, and the PC gets renamed to rldintelligence. Windows laptops use http://rldintelligence, iPhones use http://rldintelligence.local, and Android uses the PC's fixed IP. If the router lets you add a local name, Android can use the name too.
No Cloudflare, no Tailscale, no login. Copilot removes the Cloudflare code it added earlier, and Ollama no longer clashes with your Windows Ollama app.
The "can't open on phone" problem is handled in setup. setup.ps1 now opens the firewall and switches the network from Public to Private automatically.
A "starting up" banner. Anyone who opens the link during the first minutes after boot sees a friendly message instead of errors.
What to do:
Copy the updated files into deploy/ and delete the old REMOTE-ACCESS.md from the repo.
Tell Copilot: "Follow deploy/OFFICE-HOSTING.md Part A." Make sure its terminal is PowerShell this time, not the Python prompt that broke last time.
Do Part B yourself:
Rename the PC.
Get a fixed IP from the router.
Set up Autologon.
Set the BIOS wake timer, and turn off Windows "fast startup" so the timer works.
Do the shutdown test: set the BIOS timer 5 minutes ahead, shut down, and watch it come back by itself.
Two things to check first: if the PC is on the company network domain, ask IT before renaming it. And phones must be on the main office Wi-Fi, not the guest network.
