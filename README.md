# Project Zomboid Server Manager (laptop edition)

Run a Project Zomboid dedicated server from your everyday laptop, only when you want to.

## Quick start

```bash
cd ~/Projects/PZ-Server-Script
./pz-server.sh            # opens the main menu
```

1. **7) Install / update server**: installs SteamCMD (if needed) and the server into `~/pzserver`.
2. **8) Network / WAN setup → 1**: shows whether friends can reach you directly or you're behind CGNAT.
3. **1) Start server**: choose a lid mode. On the first start you'll set the admin password.
4. **2) Live dashboard**: status, connected player list with individual latency (ping), system RAM/CPU, battery and recent events.
5. **10) Troubleshoot / reset server data**: scan logs for crash reasons & safely reset corrupted map/db files.

| Command | What it does |
|---|---|
| `./pz-server.sh start safe` | Start; closing the lid saves, stops, then sleeps |
| `./pz-server.sh start keep` | Start; server stays online with the lid closed |
| `./pz-server.sh stop 30` | 30s in-game warning → save → quit |
| `./pz-server.sh save` | Save world now |
| `./pz-status.sh` | Live terminal dashboard |
| `./pz-server.sh mods` | Open Steam Workshop Mod Manager |
| `./pz-server.sh restore-save` | Revert world save from a previous backup |
| `./pz-server.sh reset-data` | Open Troubleshooting & Reset menu |

## Smart Diagnostics & Safe Reset / Delete

If server startup, player connection, or map creation fails:
- The script automatically scans logs for common errors (Steam auth vs `-nosteam` mismatches, corrupted world files, port conflicts, Java out-of-memory, or Steam mod issues).
- **Player-Only Auto-Save**: Automatically saves the world every 10 minutes (configurable in Settings) **only when at least 1 player is connected**.
- If map creation or save files are corrupted, option **10) Troubleshoot / reset server data** allows you to wipe corrupted map/database files to start fresh.
- **Accidental Deletion Protection**:
  1. Automatically offers to create a `.tar.gz` backup zip in `~/Zomboid/Backups/` before deleting.
  2. Requires typing the exact keyword **`DELETE`** to confirm resetting the map and database.

## Lid modes

- **Safe Stop** (default): when the lid closes, players get a 10s warning, the world is saved, the server quits, and then the laptop sleeps.
- **Keep Running**: sleep and the lid action are blocked while the server runs. Your normal settings come back automatically when the server stops, even after a crash. To restore them by hand: `./pz-server.sh restore-lid`.

In both modes the server saves and stops automatically when you're on battery and reach 15% (configurable).

## RAM

The default is **6 GB**, a good fit for a 16 GB laptop that's also your work machine. Change it in Settings: 4 GB (vanilla, 1–4 players), 6 GB, 8 GB (heavy mods), or a custom value (max 10 GB).

## Steam & Non-Steam (Cracked) Compatibility

- **Steam Mode (Default)**: Validates players via Steam authentication.
- **Non-Steam / Cracked Support (`-nosteam`)**:
  - Open **Option 9) Settings** -> **Option 11) Steam auth mode** and select **Disabled (-nosteam)**.
  - Allows cracked / non-Steam clients to connect directly via IP and Port (`playit.gg` domain or local IP).
  - Restart the server for the mode change to take effect.

## Letting friends join over the internet

1. Run **Network → 1** for the report and CGNAT check.
2. **No CGNAT**: **Network → 2** (firewall), then **3** (UPnP). If UPnP fails, forward **UDP 16261–16262** on your router (**Network → 5** has instructions). Friends join with `PUBLIC_IP:16261`.
3. **CGNAT** (common on PLDT/Globe/Converge): use **Network → 4** (playit.gg). Create a UDP tunnel to local port 16261, then share the address it gives you.
4. When you play on this same laptop, connect to `127.0.0.1`.

## Files

- `pz-server.conf`: settings (contains the admin password, so permissions are set to 600)
- `~/.local/state/pz-server/`: logs (`server-screen.log`, `watcher.log`) and runtime state
- `~/Zomboid/`: game saves, `Server/servertest.ini`, `server-console.txt`, `Backups/`
