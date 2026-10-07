#!/usr/bin/env bash
# ============================================================================
#  Project Zomboid Dedicated Server Manager  (laptop / daily-driver edition)
# ----------------------------------------------------------------------------
#  - Start / stop (with world save + in-game countdown) / save / broadcast
#  - Lid-close modes:  safe = save & stop then sleep,  keep = keep running
#  - Live terminal dashboard: status, players, ping, CPU/RAM, battery, events
#  - Install / update via SteamCMD, WAN helpers (ufw, UPnP, CGNAT, playit.gg)
#
#  Usage:  ./pz-server.sh                 interactive menu
#          ./pz-server.sh start [safe|keep]
#          ./pz-server.sh stop [warn_seconds]
#          ./pz-server.sh save | dashboard | install | restore-lid | help
# ============================================================================

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
CONFIG_FILE="${PZ_CONFIG:-$SCRIPT_DIR/pz-server.conf}"

# ---------------------------------------------------------------- defaults --
SERVER_DIR=""                       # auto-detected; install target = ~/pzserver
ZOMBOID_DIR="$HOME/Zomboid"         # PZ data dir (saves, ini, logs)
SERVER_NAME="servertest"            # -> ~/Zomboid/Server/<name>.ini
BRANCH="public"                     # public = stable (B41) | unstable = B42
RAM_MAX="6g"                        # JVM max heap (2g..10g)
PORT=16261                          # DefaultPort (UDP)
UDP_PORT=16262                      # UDPPort (UDP)
MAX_PLAYERS=8
ADMIN_PASSWORD=""                   # only used on first start
WARN_SECONDS=60                     # in-game countdown before shutdown
BATTERY_STOP_PCT=15                 # auto save+stop on battery at/below this
DEFAULT_LID_MODE="safe"             # safe | keep
NICE_LEVEL=5                        # lower priority so the laptop stays snappy
PLAYERS_POLL_SECONDS=15             # dashboard 'players' poll interval
USE_STEAM="true"                    # true = Steam clients only | false = -nosteam (cracked/non-Steam allowed)
AUTO_SAVE_MINUTES=10                # auto-save interval in minutes when players are online (0 = disabled)
SAVED_WORKSHOP_ITEMS=""             # preserved list of Steam Workshop IDs

# shellcheck source=/dev/null
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

STATE_DIR="${PZ_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/pz-server}"
mkdir -p "$STATE_DIR"
SCREEN_SERVER="pzserver"
SCREEN_WATCH="pzwatch"
SCREEN_PLAYIT="pzplayit"
LOG_FILE="$ZOMBOID_DIR/server-console.txt"
LID_BACKUP="$STATE_DIR/lid-settings.bak"
MODE_FILE="$STATE_DIR/lid-mode"
LAST_SAVE_FILE="$STATE_DIR/last-save"
STARTED_FILE="$STATE_DIR/started"
STOP_LOCK="$STATE_DIR/stop.lock"
PUBIP_CACHE="$STATE_DIR/public-ip"
NET_CACHE="$STATE_DIR/net-cache"
NPROC=$(nproc 2>/dev/null || echo 1)
CLK_TCK=$(getconf CLK_TCK 2>/dev/null || echo 100)

# ------------------------------------------------------------------ colors --
if [ -t 1 ]; then
    R=$'\033[0;31m'; G=$'\033[0;32m'; Y=$'\033[1;33m'; B=$'\033[0;34m'
    C=$'\033[0;36m'; M=$'\033[0;35m'; W=$'\033[1;37m'; DIM=$'\033[2m'
    BOLD=$'\033[1m'; NC=$'\033[0m'
else
    R=""; G=""; Y=""; B=""; C=""; M=""; W=""; DIM=""; BOLD=""; NC=""
fi

SPINNER_INDEX=0
SPINNER_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
spinner_frame() {
    local col=${1:-$C}
    local f="${SPINNER_FRAMES[$((SPINNER_INDEX % 10))]}"
    echo "${col}${f}${NC}"
}
next_spinner() {
    SPINNER_INDEX=$(( (SPINNER_INDEX + 1) % 10 ))
}

info()    { echo -e "${C}[*]${NC} $*"; }
ok()      { echo -e "${G}[✓]${NC} $*"; }
warn()    { echo -e "${Y}[!]${NC} $*"; }
err()     { echo -e "${R}[✗]${NC} $*" >&2; }
pause()   { read -rp "  Press Enter to continue..." _; }
confirm() { local a; read -rp "  $1 [y/N] " a; [[ $a =~ ^[Yy] ]]; }
ts()      { date '+%Y-%m-%d %H:%M:%S'; }

# ================================================================== config ==
save_config() {
    {
        echo "# Project Zomboid server manager settings."
        echo "# Written by pz-server.sh - safe to edit by hand."
        printf 'SERVER_DIR=%q\n'           "$SERVER_DIR"
        printf 'ZOMBOID_DIR=%q\n'          "$ZOMBOID_DIR"
        printf 'SERVER_NAME=%q\n'          "$SERVER_NAME"
        echo "# public = stable build, unstable = Build 42 beta"
        printf 'BRANCH=%q\n'               "$BRANCH"
        echo "# Java max heap. 4g = small/vanilla, 6g = recommended, 8g = heavy mods. Max 10g."
        printf 'RAM_MAX=%q\n'              "$RAM_MAX"
        printf 'PORT=%q\n'                 "$PORT"
        printf 'UDP_PORT=%q\n'             "$UDP_PORT"
        printf 'MAX_PLAYERS=%q\n'          "$MAX_PLAYERS"
        echo "# Only used the very first time the server starts (creates the admin account)."
        printf 'ADMIN_PASSWORD=%q\n'       "$ADMIN_PASSWORD"
        printf 'WARN_SECONDS=%q\n'         "$WARN_SECONDS"
        printf 'BATTERY_STOP_PCT=%q\n'     "$BATTERY_STOP_PCT"
        echo "# safe = save+stop when lid closes, keep = keep running with lid closed"
        printf 'DEFAULT_LID_MODE=%q\n'     "$DEFAULT_LID_MODE"
        printf 'NICE_LEVEL=%q\n'           "$NICE_LEVEL"
        printf 'PLAYERS_POLL_SECONDS=%q\n' "$PLAYERS_POLL_SECONDS"
        echo "# true = Steam mode (Steam clients only), false = nosteam mode (cracked / non-Steam clients allowed)"
        printf 'USE_STEAM=%q\n'            "$USE_STEAM"
        echo "# Auto-save interval in minutes when players are online (0 = disabled)"
        printf 'AUTO_SAVE_MINUTES=%q\n'    "$AUTO_SAVE_MINUTES"
        printf 'SAVED_WORKSHOP_ITEMS=%q\n' "$SAVED_WORKSHOP_ITEMS"
    } > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
}

detect_server_dir() {
    local c
    for c in "$SERVER_DIR" \
             "$HOME/pzserver" \
             "$HOME/.steam/steam/steamapps/common/Project Zomboid Dedicated Server" \
             "$HOME/.local/share/Steam/steamapps/common/Project Zomboid Dedicated Server" \
             "/opt/pzserver"; do
        if [ -n "$c" ] && [ -f "$c/start-server.sh" ]; then
            SERVER_DIR="$c"
            return 0
        fi
    done
    return 1
}

ini_file() { echo "$ZOMBOID_DIR/Server/${SERVER_NAME}.ini"; }
ini_get()  { grep -m1 -E "^$1=" "$(ini_file)" 2>/dev/null | cut -d= -f2- | tr -d '\r'; }
ini_set() {
    local f; f=$(ini_file)
    [ -f "$f" ] || return 1
    if grep -qE "^$1=" "$f"; then
        sed -i -E "s|^$1=.*|$1=$2|" "$f"
    else
        echo "$1=$2" >> "$f"
    fi
}

# Patch the JVM heap in ProjectZomboid64.json (SteamCMD updates overwrite it,
# so this runs before every start).
apply_ram() {
    local json="$SERVER_DIR/ProjectZomboid64.json"
    if [ ! -f "$json" ]; then
        warn "ProjectZomboid64.json not found - cannot set RAM (using game default)."
        return 0
    fi
    [ -f "$json.orig" ] || cp "$json" "$json.orig"
    sed -i -E "s/\"-Xmx[0-9]+[gGmMkK]?\"/\"-Xmx${RAM_MAX}\"/" "$json"
    if grep -q "\"-Xmx${RAM_MAX}\"" "$json"; then
        ok "JVM max heap set to ${RAM_MAX}."
    else
        warn "Could not find -Xmx in $json - RAM setting not applied."
    fi
}

apply_ini() {
    [ -f "$(ini_file)" ] || return 0     # created by the server on first start
    ini_set UPnP true
    ini_set MaxPlayers "$MAX_PLAYERS"
    ini_set DefaultPort "$PORT"
    ini_set UDPPort "$UDP_PORT"

    local current_ws
    current_ws=$(ini_get WorkshopItems)
    if [ -n "$current_ws" ]; then
        SAVED_WORKSHOP_ITEMS="$current_ws"
    fi

    if [ "$USE_STEAM" = "false" ]; then
        ini_set SteamVAC false
        ini_set SteamScoreboard false
        # Suppress WorkshopItems in -nosteam mode so Java server won't crash querying Steam API
        ini_set WorkshopItems ""
    else
        if [ -n "$SAVED_WORKSHOP_ITEMS" ]; then
            ini_set WorkshopItems "$SAVED_WORKSHOP_ITEMS"
        fi
    fi
}

# ========================================================= process helpers ==
server_pid() {
    pgrep -u "$(id -u)" -f 'ProjectZomboid64|zombie\.network\.GameServer' 2>/dev/null | head -n1
}

screen_running() { screen -ls 2>/dev/null | grep -qE "[0-9]+\.$1[[:space:]]"; }

stop_in_progress() { [ -e "$STOP_LOCK" ] && ! flock -n "$STOP_LOCK" true 2>/dev/null; }

port_listening() { ss -uln 2>/dev/null | grep -qE "[:.]$1[[:space:]]"; }

server_state() {
    local pid; pid=$(server_pid)
    if stop_in_progress; then echo STOPPING; return; fi
    if [ -z "$pid" ]; then
        if screen_running "$SCREEN_SERVER"; then echo STARTING; else echo OFFLINE; fi
        return
    fi
    if [ -f "$LOG_FILE" ]; then
        if grep -q "SERVER STARTED" "$LOG_FILE" 2>/dev/null; then echo ONLINE; else echo STARTING; fi
    elif port_listening "$PORT"; then
        echo ONLINE
    else
        echo STARTING
    fi
}

send_cmd() {
    screen_running "$SCREEN_SERVER" || { err "Server console not available."; return 1; }
    screen -S "$SCREEN_SERVER" -p 0 -X stuff "$1"$'\r'
}

servermsg() { local m=${1//\"/}; send_cmd "servermsg \"$m\""; }

# ============================================================= save / stop ==
save_world() {
    local timeout=${1:-30} start_lines i=0
    if [ -z "$(server_pid)" ]; then warn "Server is not running."; return 1; fi
    start_lines=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
    info "Saving world..."
    send_cmd "save" || return 1
    while [ "$i" -lt "$timeout" ]; do
        if tail -n +"$((start_lines + 1))" "$LOG_FILE" 2>/dev/null \
            | grep -qiE 'world saved|saving finished|save(d)? (complete|done|finished)'; then
            sleep 2          # 'World saved' is printed when the save is queued
            date +%s > "$LAST_SAVE_FILE"
            printf '\r\033[K'; ok "World saved."
            return 0
        fi
        printf '\r  [%s] Saving world data... (%ds remaining) ' "$(spinner_frame "$Y")" "$((timeout - i))"
        next_spinner
        sleep 1; i=$((i + 1))
    done
    printf '\r\033[K'
    date +%s > "$LAST_SAVE_FILE"
    warn "No save confirmation in the log after ${timeout}s (quit also saves the world)."
}

# stop_server [warn_seconds] [reason]
stop_server() {
    local warn_s=${1:-$WARN_SECONDS} reason=${2:-"Server is shutting down"} pid t i
    exec 9>"$STOP_LOCK"
    if ! flock -n 9; then
        warn "A shutdown is already in progress."
        exec 9>&-
        return 1
    fi

    pid=$(server_pid)
    if [ -z "$pid" ]; then
        warn "Server is not running."
        screen_running "$SCREEN_SERVER" && screen -S "$SCREEN_SERVER" -X quit
        flock -u 9; exec 9>&-
        return 0
    fi

    if [ "$warn_s" -gt 0 ] 2>/dev/null; then
        info "Warning players: shutdown in ${warn_s}s (progress will be saved)."
        servermsg "$reason in ${warn_s} seconds. Progress will be saved."
        t=$warn_s
        while [ "$t" -gt 0 ]; do
            case $t in
                30|10|5) [ "$t" -lt "$warn_s" ] && servermsg "$reason in ${t} seconds." ;;
            esac
            printf '\r  [%s] Shutting down in %3ds... ' "$(spinner_frame "$R")" "$t"
            next_spinner
            sleep 1; t=$((t - 1))
        done
        printf '\r\033[K'
    fi

    save_world 30

    info "Sending quit (server saves again and exits)..."
    send_cmd "quit"
    i=0
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 120 ]; do
        printf '\r  [%s] Waiting for server process to exit... %3ds ' "$(spinner_frame "$Y")" "$i"
        next_spinner
        sleep 1; i=$((i + 1))
    done
    printf '\r\033[K'

    if kill -0 "$pid" 2>/dev/null; then
        warn "Server did not exit after 120s - sending SIGTERM."
        kill -TERM "$pid" 2>/dev/null
        i=0
        while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 30 ]; do sleep 1; i=$((i + 1)); done
        if kill -0 "$pid" 2>/dev/null; then
            err "Still running - forcing SIGKILL. The last few seconds may not be saved."
            kill -KILL "$pid" 2>/dev/null
        fi
    fi
    screen_running "$SCREEN_SERVER" && screen -S "$SCREEN_SERVER" -X quit
    rm -f "$STARTED_FILE"
    ok "Server stopped cleanly. ($(ts))"
    flock -u 9; exec 9>&-
    return 0
}

# ========================================================== laptop / power ==
lid_closed() {
    local v
    v=$(busctl get-property org.freedesktop.login1 /org/freedesktop/login1 \
            org.freedesktop.login1.Manager LidClosed 2>/dev/null)
    if [ -n "$v" ]; then [ "$v" = "b true" ]; return; fi
    grep -qi closed /proc/acpi/button/lid/*/state 2>/dev/null
}

battery_info() {   # prints "<pct>|<status>" or nothing
    local b
    for b in /sys/class/power_supply/BAT*; do
        [ -r "$b/capacity" ] || continue
        echo "$(cat "$b/capacity")|$(cat "$b/status" 2>/dev/null)"
        return 0
    done
    return 1
}

on_battery() { local i; i=$(battery_info) || return 1; [ "${i#*|}" = "Discharging" ]; }

# The desktop (Cinnamon/MATE) handles the lid itself, so its lid action is
# set to 'nothing' while the server runs and restored afterwards.
lid_backend() {
    if command -v gsettings >/dev/null 2>&1; then
        if gsettings list-keys org.cinnamon.settings-daemon.plugins.power 2>/dev/null | grep -qx 'lid-close-ac-action'; then
            echo cinnamon; return
        fi
        if gsettings list-keys org.mate.power-manager 2>/dev/null | grep -qx 'button-lid-ac'; then
            echo mate; return
        fi
    fi
    echo none
}

lid_disable_de_action() {
    [ -f "$LID_BACKUP" ] && return 0      # already disabled; keep the original backup
    local s
    case $(lid_backend) in
        cinnamon)
            s=org.cinnamon.settings-daemon.plugins.power
            { echo "be=cinnamon"
              echo "ac=$(gsettings get $s lid-close-ac-action)"
              echo "bat=$(gsettings get $s lid-close-battery-action)"; } > "$LID_BACKUP"
            gsettings set $s lid-close-ac-action "'nothing'"
            gsettings set $s lid-close-battery-action "'nothing'" ;;
        mate)
            s=org.mate.power-manager
            { echo "be=mate"
              echo "ac=$(gsettings get $s button-lid-ac)"
              echo "bat=$(gsettings get $s button-lid-battery)"; } > "$LID_BACKUP"
            gsettings set $s button-lid-ac "'nothing'"
            gsettings set $s button-lid-battery "'nothing'" ;;
    esac
}

lid_restore_de_action() {
    [ -f "$LID_BACKUP" ] || return 0
    local be ac bat s
    be=$(sed -n 's/^be=//p' "$LID_BACKUP")
    ac=$(sed -n 's/^ac=//p' "$LID_BACKUP")
    bat=$(sed -n 's/^bat=//p' "$LID_BACKUP")
    case $be in
        cinnamon)
            s=org.cinnamon.settings-daemon.plugins.power
            [ -n "$ac" ]  && gsettings set $s lid-close-ac-action "$ac"
            [ -n "$bat" ] && gsettings set $s lid-close-battery-action "$bat" ;;
        mate)
            s=org.mate.power-manager
            [ -n "$ac" ]  && gsettings set $s button-lid-ac "$ac"
            [ -n "$bat" ] && gsettings set $s button-lid-battery "$bat" ;;
    esac
    rm -f "$LID_BACKUP"
}

# Restore lid settings if a previous watcher died without cleaning up.
recover_stale_state() {
    if [ -f "$LID_BACKUP" ] && ! screen_running "$SCREEN_WATCH"; then
        lid_restore_de_action
        rm -f "$MODE_FILE"
        warn "Restored your normal lid-close settings (previous session ended unexpectedly)."
    fi
}

# Background watcher (runs inside its own screen session).
watch_main() {
    local mode=${1:-safe} what inhib_pid="" seen_open=0 i
    echo "$mode" > "$MODE_FILE"

    _watch_cleanup() {
        if [ -n "$inhib_pid" ]; then
            pkill -P "$inhib_pid" 2>/dev/null
            kill "$inhib_pid" 2>/dev/null
            inhib_pid=""
        fi
        lid_restore_de_action
        rm -f "$MODE_FILE"
    }
    trap _watch_cleanup EXIT
    trap 'exit 0' INT TERM HUP

    echo "[$(ts)] watcher started (mode=$mode)"
    lid_disable_de_action
    what="handle-lid-switch"
    [ "$mode" = "keep" ] && what="sleep:idle:handle-lid-switch"
    # 'tail --pid' ends the inhibitor automatically if this watcher dies.
    systemd-inhibit --what="$what" --who="PZ Server Manager" \
        --why="Project Zomboid server running (lid mode: $mode)" --mode=block \
        tail --pid=$$ -f /dev/null &
    inhib_pid=$!

    i=0
    while [ -z "$(server_pid)" ] && screen_running "$SCREEN_SERVER" && [ "$i" -lt 60 ]; do
        sleep 2; i=$((i + 1))
    done

    local last_autosave; last_autosave=$(date +%s)
    local now interval_sec

    while [ -n "$(server_pid)" ] || screen_running "$SCREEN_SERVER"; do
        if [ "$mode" = "safe" ]; then
            if lid_closed; then
                if [ "$seen_open" -eq 1 ]; then
                    echo "[$(ts)] lid closed -> saving and stopping before sleep"
                    stop_server 10 "Host laptop is going to sleep" \
                        || while [ -n "$(server_pid)" ]; do sleep 1; done
                    _watch_cleanup
                    trap - EXIT
                    echo "[$(ts)] suspending"
                    systemctl suspend
                    exit 0
                fi
            else
                seen_open=1
            fi
        fi

        if on_battery; then
            local pct; pct=$(battery_info); pct=${pct%%|*}
            if [ "${pct:-100}" -le "$BATTERY_STOP_PCT" ]; then
                echo "[$(ts)] battery at ${pct}% -> saving and stopping"
                stop_server 30 "Host laptop battery is low. Server shutting down"
                break
            fi
        fi

        # Auto-save every AUTO_SAVE_MINUTES if players are connected
        interval_sec=$(( ${AUTO_SAVE_MINUTES:-10} * 60 ))
        now=$(date +%s)
        if [ "${AUTO_SAVE_MINUTES:-10}" -gt 0 ] && [ $((now - last_autosave)) -ge "$interval_sec" ]; then
            parse_players
            if [ "${PLAYER_COUNT:-0}" -gt 0 ]; then
                echo "[$(ts)] Auto-saving world (${PLAYER_COUNT} player(s) online)..."
                save_world 30
            fi
            last_autosave=$(date +%s)
        fi

        sleep 2
    done
    echo "[$(ts)] server gone -> watcher exiting"
}

# ================================================================== start ===
CHOSEN_MODE=""
choose_lid_mode() {
    local a def=1
    [ "$DEFAULT_LID_MODE" = "keep" ] && def=2
    echo
    echo -e "  ${BOLD}What should happen when you close the laptop lid?${NC}"
    echo -e "   ${W}1)${NC} Safe Stop    - save the world, stop the server, then sleep ${DIM}(normal laptop behaviour)${NC}"
    echo -e "   ${W}2)${NC} Keep Running - block sleep, server stays online with the lid closed"
    read -rp "  Choose [1/2] (default $def): " a
    a=${a:-$def}
    if [ "$a" = "2" ]; then CHOSEN_MODE="keep"; else CHOSEN_MODE="safe"; fi
}

show_estimated_map_size() {
    local save_dir="$ZOMBOID_DIR/Saves/Multiplayer/${SERVER_NAME}"
    local free_disk current_size
    free_disk=$(df -h "$ZOMBOID_DIR" 2>/dev/null | awk 'NR==2 {print $4}')
    [ -z "$free_disk" ] && free_disk=$(df -h "$HOME" 2>/dev/null | awk 'NR==2 {print $4}')

    echo
    echo -e "${BOLD}${C}══════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${W}   PROJECT ZOMBOID MAP & SERVER SIZE ESTIMATION       ${NC}"
    echo -e "${BOLD}${C}══════════════════════════════════════════════════════${NC}"
    echo -e "  Server Name:      ${W}${SERVER_NAME}${NC}"
    echo -e "  RAM Limit:        ${W}${RAM_MAX}${NC} (JVM Heap)"
    echo -e "  Available Disk:   ${G}${free_disk:-unknown} free${NC} on disk"
    echo
    echo -e "  ${BOLD}Estimated Storage Usage:${NC}"
    echo -e "   • Initial Map Creation:  ${W}~150 MB - 300 MB${NC} (fresh world)"
    echo -e "   • Light Exploration:       ${W}~500 MB - 1.5 GB${NC} (town area)"
    echo -e "   • Extended Exploration:    ${W}~2.0 GB - 5.0+ GB${NC} (discovered map cells)"
    echo -e "   • Database & Logs:        ${W}~50 MB - 200 MB${NC}"
    echo
    if [ ! -d "$save_dir" ]; then
        info "Notice: A NEW map will be generated on server start."
    else
        current_size=$(du -sh "$save_dir" 2>/dev/null | awk '{print $1}')
        info "Current map size on disk: ${current_size:-unknown}"
    fi
    echo -e "${BOLD}${C}══════════════════════════════════════════════════════${NC}"
    echo
}

start_server() {
    local mode=${1:-} avail ram_gb pass="" pass2 args
    if ! detect_server_dir; then
        err "Project Zomboid Dedicated Server not found. Use 'Install / update server' first."
        return 1
    fi
    if [ -n "$(server_pid)" ] || screen_running "$SCREEN_SERVER"; then
        warn "Server is already running."
        return 1
    fi
    if port_listening "$PORT" || port_listening "$UDP_PORT"; then
        err "UDP port $PORT or $UDP_PORT is already in use by another program."
        return 1
    fi

    ram_gb=${RAM_MAX%[gG]}
    avail=$(awk '/MemAvailable/ {printf "%d", $2/1024/1024}' /proc/meminfo)
    if [ "${avail:-0}" -lt $((ram_gb + 2)) ]; then
        warn "Only ${avail} GB RAM available right now; server may use up to ${RAM_MAX}."
        warn "Close some apps (browser tabs!) or lower RAM in Settings."
        confirm "Start anyway?" || return 1
    fi

    if [ -z "$mode" ]; then choose_lid_mode; mode=$CHOSEN_MODE; fi
    [ "$mode" = "keep" ] || mode="safe"

    if on_battery; then
        warn "Laptop is on battery. Server will auto-save and stop at ${BATTERY_STOP_PCT}%."
    fi
    if [ "$mode" = "safe" ] && lid_closed; then
        warn "Lid is currently closed (docked?). Safe Stop only triggers after it has been opened and closed again."
    fi

    show_estimated_map_size

    # First start: the server asks for an admin password interactively, which
    # would hang a background session, so it is passed on the command line.
    if [ ! -f "$ZOMBOID_DIR/db/${SERVER_NAME}.db" ]; then
        pass=$ADMIN_PASSWORD
        if [ -z "$pass" ]; then
            info "First start of '${SERVER_NAME}': create the in-game admin password."
            while true; do
                read -rsp "  Admin password: " pass; echo
                read -rsp "  Repeat:         " pass2; echo
                [ -n "$pass" ] && [ "$pass" = "$pass2" ] && break
                warn "Passwords empty or do not match, try again."
            done
        fi
    fi

    apply_ram
    apply_ini

    args=(-servername "$SERVER_NAME")
    [ -n "$pass" ] && args+=(-adminpassword "$pass")
    [ "$ZOMBOID_DIR" != "$HOME/Zomboid" ] && args+=("-cachedir=$ZOMBOID_DIR")
    [ "$USE_STEAM" = "false" ] && args+=(-nosteam)

    # keep the previous console log, start fresh so status detection is accurate
    if [ -f "$LOG_FILE" ]; then
        cp -f "$LOG_FILE" "$STATE_DIR/server-console.prev.txt" 2>/dev/null
        : > "$LOG_FILE"
    fi
    mv -f "$STATE_DIR/server-screen.log" "$STATE_DIR/server-screen.prev.log" 2>/dev/null

    info "Starting server '${SERVER_NAME}' (RAM ${RAM_MAX}, lid mode: ${mode})..."
    screen -dmS "$SCREEN_SERVER" -L -Logfile "$STATE_DIR/server-screen.log" \
        bash -c 'cd "$1" || exit 1; shift; exec nice -n "$1" ./start-server.sh "${@:2}"' \
        _ "$SERVER_DIR" "$NICE_LEVEL" "${args[@]}"
    date +%s > "$STARTED_FILE"

    screen_running "$SCREEN_WATCH" && screen -S "$SCREEN_WATCH" -X quit
    screen -dmS "$SCREEN_WATCH" -L -Logfile "$STATE_DIR/watcher.log" \
        bash "$SCRIPT_PATH" __watch "$mode"

    sleep 2
    wait_for_online
}

wait_for_online() {
    local t=0 st
    info "Waiting for the world to load (first boot can take 2-5 min). Press any key to go back."
    while [ "$t" -lt 900 ]; do
        st=$(server_state)
        case $st in
            ONLINE)
                printf '\r\033[K'; ok "Server is ONLINE on UDP ${PORT}/${UDP_PORT}."
                return 0 ;;
            OFFLINE)
                printf '\r\033[K'; err "Server exited during startup. Last output:"
                tail -n 15 "$STATE_DIR/server-screen.log" 2>/dev/null | sed 's/^/    /'
                analyze_startup_failure
                if confirm "Open Troubleshooting & Reset menu now?"; then
                    troubleshoot_menu
                fi
                return 1 ;;
        esac
        printf '\r  [%s] Status: %s%s%s  (%ss elapsed) ' "$(spinner_frame "$Y")" "$Y" "$st" "$NC" "$t"
        next_spinner
        if [ -t 0 ]; then
            if read -rsn1 -t 2 _; then
                printf '\r\033[K'; info "Server keeps loading in the background."
                return 0
            fi
        else
            sleep 2
        fi
        t=$((t + 2))
    done
    echo; warn "Still not online after 15 minutes - check the console (menu option 6)."
}

# ==================================================== smart troubleshooting ===
analyze_startup_failure() {
    local log1="$LOG_FILE" log2="$STATE_DIR/server-screen.log"
    local combined; combined=$(cat "$log1" "$log2" 2>/dev/null)
    echo
    echo -e "  ${BOLD}${Y}SMART DIAGNOSTIC RESULTS:${NC}"

    if [ "$USE_STEAM" = "true" ]; then
        warn "Steam Auth Mode is ENABLED (USE_STEAM=true)."
        echo -e "  ${DIM}Notice: Cracked or non-Steam Project Zomboid clients CANNOT join when Steam auth is enabled.${NC}"
        echo -e "  ${W}Suggested Fix:${NC} If you or a friend use a non-Steam/cracked client, switch to -nosteam mode in Option 9 -> 11."
    else
        ok "Steam Auth Mode is DISABLED (-nosteam mode active - cracked/non-Steam clients allowed)."
    fi

    if echo "$combined" | grep -qiE 'WorldVersion|map_p\.bin|java\.sql\.SQLException|Failed to load world|corrupt|zpop_|db is locked'; then
        warn "Map save or database corruption detected!"
        echo -e "  ${DIM}The server crashed while loading or creating map save files.${NC}"
        echo -e "  ${W}Suggested Fix:${NC} Reset server map & database files (Option 10 in Main Menu)."
    elif echo "$combined" | grep -qiE 'Address already in use|BindException'; then
        warn "Port conflict detected!"
        echo -e "  ${DIM}UDP port $PORT or $UDP_PORT is currently locked by another process.${NC}"
    elif echo "$combined" | grep -qiE 'OutOfMemoryError|Could not reserve enough space'; then
        warn "Java Out-Of-Memory (OOM) error detected!"
        echo -e "  ${DIM}Lower the RAM limit in Settings or free up system memory.${NC}"
    elif echo "$combined" | grep -qiE 'onItemNotDownloaded|result=42|Workshop: item|download failed|Mod file missing|Install library folder not found'; then
        warn "Steam Workshop Mod Download Failure detected!"
        echo -e "  ${DIM}Project Zomboid failed to download Workshop mods because Steam Auth (USE_STEAM) was disabled or Steam content folder missing.${NC}"
        echo -e "  ${W}Suggested Fix:${NC}"
        echo -e "   1. Enable Steam Auth in Option 9 -> 11 (set to Enabled / USE_STEAM=true)."
        echo -e "   2. Start the server so Steam can download the mods once."
        echo -e "   3. Once mods are downloaded, you can switch back to -nosteam mode if desired."
    elif echo "$combined" | grep -qiE 'steam auth|invalid ticket|P2P|connection failed|p2p session'; then
        warn "Client authentication/connection issue detected in log!"
        echo -e "  ${DIM}If cracked/non-Steam players cannot join, ensure -nosteam mode is enabled (Option 9 -> 11).${NC}"
    else
        info "No critical server log errors detected. Check log files or server console."
    fi
}

wipe_server_data() {
    local save_dir="$ZOMBOID_DIR/Saves/Multiplayer/${SERVER_NAME}"
    local db_file="$ZOMBOID_DIR/db/${SERVER_NAME}.db"
    local backup_dir="$ZOMBOID_DIR/Backups"
    local confirm_input do_backup

    if [ -n "$(server_pid)" ]; then
        err "Cannot reset server files while the server is running. Stop it first."
        return 1
    fi

    echo
    echo -e "${BOLD}${R}══════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${R}   DANGER: RESET / DELETE MAP & SERVER SAVE FILES     ${NC}"
    echo -e "${BOLD}${R}══════════════════════════════════════════════════════${NC}"
    echo -e " Server Target: ${W}${SERVER_NAME}${NC}"
    echo -e " The following will be ${R}${BOLD}PERMANENTLY DELETED${NC}:"
    [ -d "$save_dir" ] && echo -e "  - Save dir: ${R}${save_dir}${NC}" || echo -e "  - Save dir: ${DIM}(not found)${NC}"
    [ -f "$db_file" ]  && echo -e "  - Database: ${R}${db_file}${NC}"  || echo -e "  - Database: ${DIM}(not found)${NC}"
    echo
    echo -e " ${Y}All player progress, base builds, and map data will be erased!${NC}"
    echo -e "${BOLD}${R}══════════════════════════════════════════════════════${NC}"
    echo

    if [ ! -d "$save_dir" ] && [ ! -f "$db_file" ]; then
        info "No save folder or database file exists for '${SERVER_NAME}'."
        return 0
    fi

    read -rp "  Create automatic backup zip before deleting? [Y/n]: " do_backup
    do_backup=${do_backup:-y}
    if [[ $do_backup =~ ^[Yy] ]]; then
        local bname="${SERVER_NAME}_backup_$(date +%Y%m%d_%H%M%S).tar.gz"
        mkdir -p "$backup_dir"
        info "Creating backup archive in $backup_dir/$bname ..."
        tar -czf "$backup_dir/$bname" -C "$ZOMBOID_DIR" "Saves/Multiplayer/${SERVER_NAME}" "db/${SERVER_NAME}.db" 2>/dev/null
        if [ -f "$backup_dir/$bname" ]; then
            ok "Backup created successfully: $backup_dir/$bname"
        else
            warn "Backup creation failed. Proceeding carefully..."
        fi
    fi

    echo
    echo -e "  ${R}${BOLD}SAFETY CONFIRMATION REQUIRED:${NC}"
    echo -e "  To permanently delete the map save & database, type ${R}${BOLD}DELETE${NC} below."
    read -rp "  Type 'DELETE' to confirm (or press Enter to cancel): " confirm_input

    if [ "$confirm_input" = "DELETE" ] || [ "$confirm_input" = "delete" ]; then
        info "Deleting map save directory and database..."
        rm -rf "$save_dir"
        rm -f "$db_file"
        rm -f "$LAST_SAVE_FILE"
        ok "Server map & database for '${SERVER_NAME}' reset successfully."
        ok "A fresh map will be generated on the next server start."
    else
        warn "Deletion cancelled. No files were deleted."
    fi
}

restore_save_backup() {
    local backup_dir="$ZOMBOID_DIR/Backups"
    local save_dir="$ZOMBOID_DIR/Saves/Multiplayer/${SERVER_NAME}"
    local db_file="$ZOMBOID_DIR/db/${SERVER_NAME}.db"
    local backups=() f date_str size_str choice target_archive pre_bname

    if [ -n "$(server_pid)" ]; then
        err "Cannot revert save files while the server is running. Stop the server first."
        return 1
    fi

    if [ ! -d "$backup_dir" ]; then
        warn "No Backups directory found at $backup_dir."
        return 1
    fi

    mapfile -t backups < <(find "$backup_dir" -maxdepth 1 \( -name "*${SERVER_NAME}*.tar.gz" -o -name "*${SERVER_NAME}*.zip" -o -name "*${SERVER_NAME}*.tar" \) -printf "%T@ %p\n" 2>/dev/null | sort -nr | cut -d' ' -f2-)

    if [ "${#backups[@]}" -eq 0 ]; then
        warn "No backup archives found for '${SERVER_NAME}' in $backup_dir."
        return 1
    fi

    echo
    echo -e "  ${BOLD}${C}REVERT / RESTORE SERVER MAP SAVE FROM BACKUP:${NC}"
    echo -e "  Select a backup archive to restore (newest first):"
    echo

    local idx=1
    for f in "${backups[@]}"; do
        date_str=$(stat -c %y "$f" 2>/dev/null | cut -d. -f1)
        size_str=$(du -sh "$f" 2>/dev/null | awk '{print $1}')
        echo -e "   ${W}${idx})${NC} ${G}$(basename "$f")${NC}  ${DIM}(${date_str}, ${size_str})${NC}"
        idx=$((idx + 1))
    done
    echo -e "   ${W}0)${NC} Cancel"
    echo
    read -rp "  Select backup to restore [1-${#backups[@]}]: " choice

    if [[ ! $choice =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#backups[@]}" ]; then
        info "Restore cancelled."
        return 0
    fi

    target_archive="${backups[$((choice - 1))]}"
    echo
    warn "Restoring world backup: $(basename "$target_archive")"
    confirm "Are you sure? Current map files will be replaced with this backup." || return 0

    if [ -d "$save_dir" ] || [ -f "$db_file" ]; then
        pre_bname="${SERVER_NAME}_presave_$(date +%Y%m%d_%H%M%S).tar.gz"
        info "Creating safety backup of current state: $pre_bname ..."
        tar -czf "$backup_dir/$pre_bname" -C "$ZOMBOID_DIR" "Saves/Multiplayer/${SERVER_NAME}" "db/${SERVER_NAME}.db" 2>/dev/null
    fi

    info "Restoring backup files..."
    rm -rf "$save_dir"
    rm -f "$db_file"

    if [[ $target_archive =~ \.zip$ ]]; then
        unzip -o "$target_archive" -d "$ZOMBOID_DIR" >/dev/null 2>&1
    else
        tar -xzf "$target_archive" -C "$ZOMBOID_DIR" 2>/dev/null || tar -xf "$target_archive" -C "$ZOMBOID_DIR" 2>/dev/null
    fi

    date +%s > "$LAST_SAVE_FILE"
    ok "Server world restored successfully from $(basename "$target_archive")!"
    info "You can now start the server with your restored world state."
}

troubleshoot_menu() {
    local a
    while true; do
        echo
        echo -e "  ${BOLD}${C}Troubleshooting & Reset Menu${NC}"
        echo -e "   1) Run Smart Diagnostic scan on logs"
        echo -e "   2) View map & server size estimation"
        echo -e "   3) Revert / Restore map save from backup"
        echo -e "   4) ${R}Reset / Delete server map & save files${NC} (fresh start)"
        echo -e "   5) View last 30 lines of startup log"
        echo -e "   6) View full server console log"
        echo -e "   0) Back"
        read -rp "  Choose: " a
        case $a in
            1) analyze_startup_failure; pause ;;
            2) show_estimated_map_size; pause ;;
            3) restore_save_backup; pause ;;
            4) wipe_server_data; pause ;;
            5) echo; tail -n 30 "$STATE_DIR/server-screen.log" 2>/dev/null | sed 's/^/    /'; pause ;;
            6) if [ -f "$LOG_FILE" ]; then less -R "$LOG_FILE"; else warn "Log file not found."; pause; fi ;;
            0|"") return ;;
        esac
    done
}

# ============================================================ info gather ===
local_ip()   { hostname -I 2>/dev/null | awk '{print $1}'; }
gateway_ip() { ip route 2>/dev/null | awk '/^default/ {print $3; exit}'; }

fetch_pubip() {
    local ip
    ip=$(curl -s --max-time 3 https://api.ipify.org 2>/dev/null \
      || curl -s --max-time 3 https://ifconfig.me 2>/dev/null \
      || curl -s --max-time 3 https://icanhazip.com 2>/dev/null \
      || curl -s --max-time 3 https://ipinfo.io/ip 2>/dev/null)
    ip=$(echo "$ip" | tr -d '\r\n ')
    if [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$ip"
    else
        echo "unavailable"
    fi
}

get_public_ip() {     # non-blocking: refreshes the cache in the background
    local age=999999
    [ -f "$PUBIP_CACHE" ] && age=$(( $(date +%s) - $(stat -c %Y "$PUBIP_CACHE") ))
    if [ "$age" -gt 300 ] && [ ! -f "$PUBIP_CACHE.lock" ]; then
        ( touch "$PUBIP_CACHE.lock"
          ip=$(fetch_pubip)
          echo "$ip" > "$PUBIP_CACHE"
          rm -f "$PUBIP_CACHE.lock" ) >/dev/null 2>&1 &
    fi
    cat "$PUBIP_CACHE" 2>/dev/null || echo "checking..."
}

ping_ms() { ping -c1 -W1 "$1" 2>/dev/null | sed -n 's/.*time=\([0-9.]*\).*/\1/p'; }

refresh_net_async() {
    [ -f "$NET_CACHE.lock" ] && return
    ( touch "$NET_CACHE.lock"
      inet=$(ping_ms 1.1.1.1); gw=""; g=$(gateway_ip); [ -n "$g" ] && gw=$(ping_ms "$g")
      echo "${inet:-x} ${gw:-x}" > "$NET_CACHE"
      rm -f "$NET_CACHE.lock" ) >/dev/null 2>&1 &
}

fmt_ping() {
    local v=$1
    if [ -z "$v" ] || [ "$v" = "x" ]; then echo "${R}timeout${NC}"; return; fi
    local i=${v%.*}
    if [ "$i" -lt 50 ]; then echo "${G}${v} ms${NC}"
    elif [ "$i" -lt 120 ]; then echo "${Y}${v} ms${NC}"
    else echo "${R}${v} ms${NC}"; fi
}

PLAYER_COUNT=""; PLAYER_NAMES=""
get_player_ip() {
    local uname="$1" ip
    ip=$(grep -hE "username=\"${uname}\"" "$ZOMBOID_DIR/Logs/"*connections.txt 2>/dev/null \
         | grep -oE 'ip="[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"' | tail -n1 | cut -d'"' -f2)
    echo "${ip}"
}

get_player_ping() {
    local ip="$1" ms
    if [ -z "$ip" ]; then echo "?ms"; return; fi
    if [ "$ip" = "127.0.0.1" ] || [ "$ip" = "localhost" ]; then echo "<1ms"; return; fi
    ms=$(ping -c1 -W1 "$ip" 2>/dev/null | sed -n 's/.*time=\([0-9.]*\).*/\1/p')
    if [ -n "$ms" ]; then
        ms=${ms%.*}
        [ -z "$ms" ] && ms=0
        echo "${ms}ms"
    else
        echo "?ms"
    fi
}

fmt_player_ping() {
    local name="$1" ip="$2" ms_str col
    ms_str=$(get_player_ping "$ip")
    if [[ $ms_str =~ ^([0-9]+)ms$ ]]; then
        local num="${BASH_REMATCH[1]}"
        if [ "$num" -lt 50 ]; then col=$G
        elif [ "$num" -lt 120 ]; then col=$Y
        else col=$R; fi
    elif [ "$ms_str" = "<1ms" ]; then
        col=$G
    else
        col=$DIM
    fi
    echo "${W}${name}${NC} (${col}${ms_str}${NC})"
}

parse_players() {
    PLAYER_COUNT=""; PLAYER_NAMES=""
    [ -f "$LOG_FILE" ] || return
    local ln raw_names=() formatted_list=() pname pip item formatted_str=""
    ln=$(grep -n "Players connected (" "$LOG_FILE" 2>/dev/null | tail -n1 | cut -d: -f1)
    [ -z "$ln" ] && return
    PLAYER_COUNT=$(sed -n "${ln}p" "$LOG_FILE" | sed -E 's/.*Players connected \(([0-9]+)\).*/\1/')
    [[ $PLAYER_COUNT =~ ^[0-9]+$ ]] || { PLAYER_COUNT=""; return; }
    if [ "$PLAYER_COUNT" -gt 0 ]; then
        mapfile -t raw_names < <(tail -n +"$((ln + 1))" "$LOG_FILE" | head -n "$PLAYER_COUNT" \
            | sed -E 's/^(.*[[:space:]>])?-//' | tr -d '\r' | sed '/^$/d')
        for pname in "${raw_names[@]}"; do
            [ -z "$pname" ] && continue
            pip=$(get_player_ip "$pname")
            formatted_list+=("$(fmt_player_ping "$pname" "$pip")")
        done
        for item in "${formatted_list[@]}"; do
            if [ -n "$formatted_str" ]; then
                formatted_str+=", ${item}"
            else
                formatted_str="${item}"
            fi
        done
        PLAYER_NAMES="$formatted_str"
    fi
}

PREV_T=""; PREV_NOW=""; PREV_PID=""; CPU_PCT="…"
proc_cpu() {     # sets CPU_PCT = % of the whole CPU since last call (no subshell!)
    local pid=$1 stat t now
    stat=$(sed 's/^.*) //' "/proc/$pid/stat" 2>/dev/null) || { CPU_PCT="0.0"; return; }
    # shellcheck disable=SC2086
    set -- $stat
    t=$(( ${12} + ${13} ))
    now=$(date +%s%N)
    if [ "$PREV_PID" = "$pid" ] && [ -n "$PREV_T" ]; then
        CPU_PCT=$(awk -v dt="$((t - PREV_T))" -v dn="$((now - PREV_NOW))" -v hz="$CLK_TCK" -v n="$NPROC" \
            'BEGIN { if (dn <= 0) dn = 1; printf "%.1f", (dt / hz) / (dn / 1e9) * 100 / n }')
    else
        CPU_PCT="…"
    fi
    PREV_T=$t; PREV_NOW=$now; PREV_PID=$pid
}

cpu_temp() {
    local z t
    for z in /sys/class/thermal/thermal_zone*; do
        if [ "$(cat "$z/type" 2>/dev/null)" = "x86_pkg_temp" ]; then
            t=$(cat "$z/temp" 2>/dev/null); echo $((t / 1000)); return
        fi
    done
    t=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null) && echo $((t / 1000))
}

bar() {   # bar <pct> <width>
    local p=${1%.*} w=$2 f e
    [ "$p" -gt 100 ] 2>/dev/null && p=100
    [ "$p" -lt 0 ] 2>/dev/null && p=0
    f=$(( p * w / 100 )); e=$(( w - f ))
    local col=$G; [ "$p" -ge 70 ] && col=$Y; [ "$p" -ge 90 ] && col=$R
    printf '%s' "$col"; printf '%*s' "$f" '' | sed 's/ /█/g'
    printf '%s' "$DIM"; printf '%*s' "$e" '' | sed 's/ /░/g'; printf '%s' "$NC"
}

ago() {
    local s=$(( $(date +%s) - $1 ))
    if [ "$s" -lt 60 ]; then echo "${s}s ago"
    elif [ "$s" -lt 3600 ]; then echo "$((s / 60))m ago"
    else echo "$((s / 3600))h $((s % 3600 / 60))m ago"; fi
}

state_colored() {
    case $1 in
        ONLINE)   echo "${G}${BOLD}● ONLINE${NC}" ;;
        STARTING) echo "$(spinner_frame "$Y") ${Y}${BOLD}STARTING${NC} ${DIM}(loading game world...)${NC}" ;;
        STOPPING) echo "$(spinner_frame "$M") ${M}${BOLD}STOPPING${NC} ${DIM}(saving & quitting...)${NC}" ;;
        *)        echo "${R}${BOLD}○ OFFLINE${NC}" ;;
    esac
}

lid_mode_text() {
    case $(cat "$MODE_FILE" 2>/dev/null) in
        safe) echo "Safe Stop (closing the lid saves, stops, then sleeps)" ;;
        keep) echo "${Y}Keep Running${NC} (sleep blocked, OK to close the lid)" ;;
        *)    echo "${DIM}n/a${NC}" ;;
    esac
}

playit_running() {
    screen_running "$SCREEN_PLAYIT" || systemctl is-active --quiet playit 2>/dev/null
}

# ============================================================== dashboard ===
render_dashboard() {
    local cols hr out state pid up cpu rss_kb rss_gb ram_gb mem_pct memt mema sys_used
    local bat pct bst lid temp maxp inet gw pub lip upnp ev last_save
    cols=$(tput cols 2>/dev/null || echo 80); [ "$cols" -gt 100 ] && cols=100
    hr=$(printf '%*s' "$cols" ''); hr=${hr// /─}
    out=""
    L() { out+="$*"$'\033[K\n'; }

    state=$(server_state); pid=$(server_pid)
    lip=$(local_ip); pub=$(get_public_ip)
    [ "$pub" = "checking..." ] && pub="$(spinner_frame "$C") ${DIM}checking...${NC}"
    read -r inet gw < "$NET_CACHE" 2>/dev/null
    maxp=$(ini_get MaxPlayers); maxp=${maxp:-$MAX_PLAYERS}
    upnp=$(ini_get UPnP); upnp=${upnp:-unknown}

    L "${BOLD}${C}${hr}${NC}"
    L "${BOLD}${W}  PROJECT ZOMBOID SERVER${NC}  ${DIM}·${NC}  ${C}${SERVER_NAME}${NC}  ${DIM}·  $(hostname)  ·  $(ts)${NC}"
    L "${BOLD}${C}${hr}${NC}"

    # --- server
    if [ -n "$pid" ]; then
        up=$(ps -p "$pid" -o etime= 2>/dev/null | tr -d ' ')
        L " ${BOLD}SERVER   ${NC} $(state_colored "$state")    PID ${pid}    Uptime ${up}"
    else
        L " ${BOLD}SERVER   ${NC} $(state_colored "$state")"
    fi
    last_save="never (this session)"
    [ -f "$LAST_SAVE_FILE" ] && last_save=$(ago "$(cat "$LAST_SAVE_FILE")")
    L "           Lid mode: $(lid_mode_text)"
    L "           Last manual save: ${last_save}    RAM limit: ${RAM_MAX}"

    # --- players
    parse_players
    if [ "$state" = "ONLINE" ]; then
        if [ -n "$PLAYER_COUNT" ]; then
            local pc=$G; [ "$PLAYER_COUNT" -eq 0 ] && pc=$DIM
            if [ "$PLAYER_COUNT" -gt 0 ]; then
                L " ${BOLD}PLAYERS  ${NC} ${pc}${BOLD}${PLAYER_COUNT}${NC} / ${maxp}   ${PLAYER_NAMES}"
            else
                L " ${BOLD}PLAYERS  ${NC} ${pc}${BOLD}${PLAYER_COUNT}${NC} / ${maxp}   ${DIM}(none connected)${NC}"
            fi
        else
            L " ${BOLD}PLAYERS  ${NC} $(spinner_frame "$C") ${DIM}querying players...${NC} / ${maxp}"
        fi
    elif [ "$state" = "STARTING" ]; then
        L " ${BOLD}PLAYERS  ${NC} $(spinner_frame "$Y") ${DIM}server loading...${NC} / ${maxp}"
    else
        L " ${BOLD}PLAYERS  ${NC} ${DIM}- / ${maxp}${NC}"
    fi

    # --- network & connection info
    local p1 p2 srv_pass adm_pass
    if port_listening "$PORT"; then p1="${G}✔${NC}"; else p1="${R}✘${NC}"; fi
    if port_listening "$UDP_PORT"; then p2="${G}✔${NC}"; else p2="${R}✘${NC}"; fi

    srv_pass=$(ini_get Password)
    if [ -n "$srv_pass" ]; then srv_pass="${W}${srv_pass}${NC}"; else srv_pass="${DIM}(none - public)${NC}"; fi

    if [ -n "$ADMIN_PASSWORD" ]; then adm_pass="${W}${ADMIN_PASSWORD}${NC}"; else adm_pass="${DIM}(configured on start)${NC}"; fi

    local pl="off"; playit_running && pl="${G}running${NC}"

    L " ${BOLD}NETWORK  ${NC} Public IP: ${pub}    Local IP: ${lip:-n/a}    UDP ${PORT} ${p1}  ${UDP_PORT} ${p2}"
    L " ${BOLD}JOIN INFO${NC} Host Laptop (You):  ${W}IP: 127.0.0.1${NC}   ${W}Port: ${PORT}${NC}"
    L "           Friends / WAN:    ${W}IP: ${pub}${NC}   ${W}Port: ${PORT}${NC}"
    L "           Server Name: ${W}${SERVER_NAME}${NC}    Pass: ${srv_pass}    Admin Pass: ${adm_pass}"
    L "           ${DIM}Note: Enter IP and Port in SEPARATE boxes in PZ (do NOT put :16261 in IP box).${NC}"
    L " ${BOLD}PING     ${NC} Internet (1.1.1.1) $(fmt_ping "$inet")    Router $(fmt_ping "$gw")"

    # --- resources
    memt=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    mema=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
    sys_used=$(( (memt - mema) * 100 / memt ))
    if [ -n "$pid" ]; then
        proc_cpu "$pid"; cpu=$CPU_PCT
        rss_kb=$(ps -p "$pid" -o rss= 2>/dev/null | tr -d ' '); rss_kb=${rss_kb:-0}
        rss_gb=$(awk -v k="$rss_kb" 'BEGIN{printf "%.1f", k/1048576}')
        ram_gb=${RAM_MAX%[gG]}
        mem_pct=$(awk -v k="$rss_kb" -v g="$ram_gb" 'BEGIN{printf "%d", k/1048576/g*100}')
        L " ${BOLD}RESOURCES${NC} Server CPU ${cpu}% of ${NPROC} threads    Server RAM $(bar "$mem_pct" 20) ${rss_gb} GB (limit ${RAM_MAX})"
    else
        L " ${BOLD}RESOURCES${NC} ${DIM}Server not running${NC}"
    fi
    temp=$(cpu_temp)
    L "           System RAM $(bar "$sys_used" 20) $(awk -v a="$mema" -v t="$memt" 'BEGIN{printf "%.1f GB free of %.1f GB", a/1048576, t/1048576}')    CPU temp ${temp:-?}°C"

    # --- laptop
    if bat=$(battery_info); then
        pct=${bat%%|*}; bst=${bat#*|}
        local bc=$G; [ "$pct" -le 40 ] && bc=$Y; [ "$pct" -le "$BATTERY_STOP_PCT" ] && bc=$R
        [ "$bst" = "Discharging" ] && bst="${Y}on battery${NC} (auto-stops at ${BATTERY_STOP_PCT}%)" || bst="${G}plugged in${NC} ($bst)"
    fi
    if lid_closed; then lid="closed"; else lid="open"; fi
    L " ${BOLD}LAPTOP   ${NC} Battery ${bc:-}${pct:-n/a}%${NC} ${bst:-}    Lid ${lid}"

    # --- events
    L "${DIM}${hr}${NC}"
    L " ${BOLD}${Y}RECENT EVENTS${NC}"
    if [ -s "$LOG_FILE" ]; then
        ev=$(grep -aiE 'fully.?connected|connected new client|disconnect|SERVER STARTED|world saved|servermsg|error|exception' "$LOG_FILE" 2>/dev/null \
             | grep -v 'Players connected' | tail -n 6 | tr -d '\r' | cut -c1-$((cols - 5)))
        if [ -n "$ev" ]; then
            while IFS= read -r line; do L "  ${B}›${NC} ${line}"; done <<< "$ev"
        else
            L "  ${DIM}No events yet.${NC}"
        fi
    else
        L "  ${DIM}No server log yet (${LOG_FILE}).${NC}"
    fi

    L "${BOLD}${C}${hr}${NC}"
    if [ -n "$pid" ]; then
        L " ${W}[S]${NC} Stop+save  ${W}[V]${NC} Save now  ${W}[B]${NC} Broadcast  ${W}[C]${NC} Command  ${W}[P]${NC} Refresh players  ${W}[Q]${NC} Back"
    else
        L " ${W}[R]${NC} Start server  ${W}[Q]${NC} Back"
    fi

    tput cup 0 0
    printf '%s' "$out"
    tput ed
}

dashboard() {
    local last_poll=0 key now msg dash_exit=0
    tput civis 2>/dev/null
    trap 'dash_exit=1' INT
    clear
    while [ "$dash_exit" -eq 0 ]; do
        next_spinner
        refresh_net_async
        now=$(date +%s)
        if [ "$(server_state)" = "ONLINE" ] && [ $((now - last_poll)) -ge "$PLAYERS_POLL_SECONDS" ]; then
            send_cmd "players" >/dev/null 2>&1
            last_poll=$now
            sleep 0.4
        fi
        render_dashboard
        key=""
        read -rsn1 -t 3 key
        case ${key,,} in
            q) break ;;
            s)
                [ -z "$(server_pid)" ] && continue
                tput cnorm; clear
                if confirm "Stop the server? The world is saved first."; then
                    read -rp "  In-game warning countdown in seconds [${WARN_SECONDS}]: " msg
                    stop_server "${msg:-$WARN_SECONDS}"
                    pause
                fi
                tput civis; clear ;;
            v)
                tput cnorm; clear; save_world 30; sleep 1; tput civis; clear ;;
            b)
                [ -z "$(server_pid)" ] && continue
                tput cnorm; clear
                read -rp "  Message to all players: " msg
                [ -n "$msg" ] && servermsg "$msg" && ok "Sent."
                sleep 1; tput civis; clear ;;
            c)
                [ -z "$(server_pid)" ] && continue
                tput cnorm; clear
                echo -e "  ${DIM}Examples: players | kickuser \"name\" | setaccesslevel \"name\" admin | help${NC}"
                read -rp "  Console command: " msg
                if [ -n "$msg" ]; then
                    send_cmd "$msg"; sleep 1.5
                    echo; tail -n 15 "$LOG_FILE" 2>/dev/null | sed 's/^/    /'; echo
                    pause
                fi
                tput civis; clear ;;
            p) last_poll=0 ;;
            r)
                [ -n "$(server_pid)" ] && continue
                tput cnorm; clear; start_server; pause; tput civis; clear ;;
        esac
    done
    trap - INT
    tput cnorm 2>/dev/null
    clear
}

# ================================================================ install ===
find_steamcmd() {
    command -v steamcmd 2>/dev/null && return
    [ -x /usr/games/steamcmd ] && { echo /usr/games/steamcmd; return; }
    [ -x "$HOME/steamcmd/steamcmd.sh" ] && { echo "$HOME/steamcmd/steamcmd.sh"; return; }
    return 1
}

install_update() {
    local steamcmd target beta=()
    if [ -n "$(server_pid)" ]; then
        err "Stop the server before updating."
        return 1
    fi
    if ! steamcmd=$(find_steamcmd); then
        warn "SteamCMD is not installed."
        if confirm "Install SteamCMD with apt now (needs sudo)?"; then
            sudo dpkg --add-architecture i386 && sudo apt update && sudo apt install -y steamcmd || {
                err "apt install failed."; return 1; }
            steamcmd=$(find_steamcmd) || { err "steamcmd still not found."; return 1; }
        else
            return 1
        fi
    fi
    detect_server_dir
    target=${SERVER_DIR:-$HOME/pzserver}
    read -rp "  Install directory [$target]: " a; target=${a:-$target}
    [ "$BRANCH" != "public" ] && beta=(-beta "$BRANCH")
    info "Installing/updating Project Zomboid Dedicated Server (branch: $BRANCH) into $target ..."
    mkdir -p "$target"
    if "$steamcmd" +force_install_dir "$target" +login anonymous +app_update 380870 "${beta[@]}" validate +quit; then
        SERVER_DIR=$target
        save_config
        rm -f "$SERVER_DIR/ProjectZomboid64.json.orig"
        ok "Server installed/updated in $SERVER_DIR"
    else
        err "SteamCMD failed. Run this option again (first runs sometimes fail while SteamCMD updates itself)."
        return 1
    fi
}

# ================================================================ network ===
is_private_ip() {
    [[ $1 =~ ^10\. || $1 =~ ^192\.168\. || $1 =~ ^172\.(1[6-9]|2[0-9]|3[01])\. \
        || $1 =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\. ]]
}

network_report() {
    local pub wan hops h st
    echo
    echo -e "  ${BOLD}Network report${NC}"
    echo -e "  Local IP:      $(local_ip)"
    echo -e "  Router:        $(gateway_ip)"
    rm -f "$PUBIP_CACHE"
    pub=$(fetch_pubip); echo "$pub" > "$PUBIP_CACHE"
    echo -e "  Public IP:     ${W}${pub}${NC}"
    echo -e "  Server ports:  UDP ${PORT}: $(port_listening "$PORT" && echo "${G}listening${NC}" || echo "${DIM}not listening${NC}")," \
            "UDP ${UDP_PORT}: $(port_listening "$UDP_PORT" && echo "${G}listening${NC}" || echo "${DIM}not listening${NC}")"
    if command -v ufw >/dev/null 2>&1; then
        st=$(systemctl is-active ufw 2>/dev/null)
        echo -e "  Firewall:      ufw service ${st} (use option 2 to allow the ports)"
    fi
    echo
    info "Checking for CGNAT (whether friends can reach you directly)..."
    if command -v upnpc >/dev/null 2>&1; then
        wan=$(upnpc -s 2>/dev/null | sed -n 's/^ExternalIPAddress = //p')
    fi
    if [ -n "$wan" ]; then
        echo -e "  Router WAN IP: $wan"
        if [ "$wan" = "$pub" ]; then
            ok "No CGNAT: your router has the public IP. UPnP or port forwarding will work."
        else
            warn "Router WAN IP ($wan) != public IP ($pub): you are behind CGNAT/double NAT."
            warn "Port forwarding will NOT work. Use playit.gg (option 4)."
        fi
    elif command -v tracepath >/dev/null 2>&1; then
        hops=$(tracepath -n -m 4 1.1.1.1 2>/dev/null | awk '$2 ~ /^[0-9.]+$/ {print $2}' | sort -u)
        local cg=0
        for h in $hops; do
            [ "$h" = "$(gateway_ip)" ] && continue
            is_private_ip "$h" && cg=1
        done
        if [ "$cg" -eq 1 ]; then
            warn "Private/CGNAT addresses found past your router - likely CGNAT."
            warn "Port forwarding probably won't work. Use playit.gg (option 4)."
        else
            ok "No CGNAT detected (heuristic). Port forwarding / UPnP should work."
        fi
        echo -e "  ${DIM}For a definite answer install miniupnpc (option 3) and run this report again.${NC}"
    else
        warn "Can't check for CGNAT (install miniupnpc via option 3)."
    fi
}

open_firewall() {
    if ! command -v ufw >/dev/null 2>&1; then
        info "ufw not installed - no local firewall rule needed."
        return
    fi
    info "Allowing UDP ${PORT} and ${UDP_PORT} in ufw (sudo)..."
    sudo ufw allow "${PORT}/udp" comment 'Project Zomboid' && \
    sudo ufw allow "${UDP_PORT}/udp" comment 'Project Zomboid' && ok "Firewall rules added."
    sudo ufw status | head -n 1
}

upnp_map() {
    if ! command -v upnpc >/dev/null 2>&1; then
        confirm "Install miniupnpc (UPnP tool) with apt (sudo)?" && sudo apt install -y miniupnpc
        command -v upnpc >/dev/null 2>&1 || return 1
    fi
    local ip; ip=$(local_ip)
    info "Asking router to forward UDP ${PORT}/${UDP_PORT} -> ${ip} ..."
    upnpc -e "Project Zomboid" -a "$ip" "$PORT" "$PORT" UDP >/dev/null 2>&1 \
        && ok "UDP $PORT mapped" || warn "UDP $PORT mapping failed (UPnP disabled on router?)"
    upnpc -e "Project Zomboid" -a "$ip" "$UDP_PORT" "$UDP_PORT" UDP >/dev/null 2>&1 \
        && ok "UDP $UDP_PORT mapped" || warn "UDP $UDP_PORT mapping failed"
    echo -e "  ${DIM}The server also tries UPnP itself (UPnP=true in $(ini_file)).${NC}"
}

playit_menu() {
    local a claim_link
    while true; do
        echo
        echo -e "  ${BOLD}${C}playit.gg Setup (Bypass CGNAT for Internet Friends)${NC}"
        echo -e "   1) Install playit (apt)"
        echo -e "   2) Start playit agent in background"
        echo -e "   3) ${W}${BOLD}Open playit live console (shows Claim Link)${NC}"
        echo -e "   4) Stop playit agent"
        echo -e "   5) Step-by-step playit instructions"
        echo -e "   6) Restart / Refresh playit session"
        echo -e "   7) ${R}${BOLD}Reset stale key & generate new Claim Link${NC} (fixes SessionNotSetup)"
        echo -e "   0) Back"
        read -rp "  Choose: " a
        case $a in
            1)
                curl -SsL https://playit-cloud.github.io/ppa/key.gpg | gpg --dearmor | sudo tee /etc/apt/trusted.gpg.d/playit.gpg >/dev/null \
                && echo "deb [signed-by=/etc/apt/trusted.gpg.d/playit.gpg] https://playit-cloud.github.io/ppa/data ./" \
                   | sudo tee /etc/apt/sources.list.d/playit-cloud.list >/dev/null \
                && sudo apt update && sudo apt install -y playit && ok "playit installed."; pause ;;
            2)
                command -v playit >/dev/null 2>&1 || { err "playit not installed. Use Option 1 first."; pause; continue; }
                if playit_running; then
                    warn "playit agent is already running."
                else
                    sudo systemctl start playit 2>/dev/null || screen -dmS "$SCREEN_PLAYIT" playit
                    ok "Started playit agent in background."
                fi
                pause ;;
            3)
                command -v playit >/dev/null 2>&1 || { err "playit not installed. Use Option 1 first."; pause; continue; }
                info "Opening playit.gg live interactive console..."
                echo -e "  ${Y}Copy your claim link from the screen below.${NC}"
                echo -e "  ${DIM}(Press Ctrl+C when done to return to this menu)${NC}"
                sleep 2
                sudo systemctl stop playit 2>/dev/null || true
                pkill -x playit 2>/dev/null || true
                screen -S "$SCREEN_PLAYIT" -X quit 2>/dev/null || true
                
                # Run playit in foreground terminal so claim link & TUI render live
                sudo playit || playit
                pause ;;
            4)
                if screen_running "$SCREEN_PLAYIT"; then
                    screen -S "$SCREEN_PLAYIT" -X quit
                fi
                if systemctl is-active --quiet playit 2>/dev/null; then
                    sudo systemctl stop playit 2>/dev/null || true
                fi
                pkill -x playit 2>/dev/null || true
                ok "Stopped playit agent."; pause ;;
            5)
                echo
                echo -e "  ${BOLD}${C}HOW TO SETUP PLAYIT.GG FOR PROJECT ZOMBOID${NC}"
                echo -e "  ${DIM}------------------------------------------------------${NC}"
                echo -e "   1. Select option ${W}3${NC} (Open playit live console)."
                echo -e "   2. Copy the ${W}https://playit.gg/claim/...${NC} link shown on screen."
                echo -e "   3. Open the link in your web browser & log in."
                echo -e "   4. In the playit web dashboard, click ${W}+ Add Tunnel${NC}."
                echo -e "   5. Select Tunnel Type: ${W}Custom UDP${NC}."
                echo -e "   6. Set Local IP to ${W}127.0.0.1${NC} and Local Port to ${W}${PORT}${NC} (16261)."
                echo -e "   7. Click ${W}Add Tunnel${NC}. playit will generate a unique domain and port."
                echo -e "      Example: ${W}pz-server.gl.at.ply.gg${NC} with Port ${W}24512${NC}."
                echo -e "   8. ${W}How Friends Join:${NC}"
                echo -e "      • IP / Domain box in PZ: ${W}pz-server.gl.at.ply.gg${NC}"
                echo -e "      • Port box in PZ:        ${W}24512${NC}"
                echo -e "  ${DIM}------------------------------------------------------${NC}"
                pause ;;
            6)
                info "Restarting playit agent session..."
                sudo systemctl stop playit 2>/dev/null || true
                pkill -x playit 2>/dev/null || true
                screen -S "$SCREEN_PLAYIT" -X quit 2>/dev/null || true
                sleep 1
                if command -v systemctl >/dev/null 2>&1; then
                    sudo systemctl restart playit 2>/dev/null || sudo systemctl start playit 2>/dev/null || screen -dmS "$SCREEN_PLAYIT" playit
                else
                    screen -dmS "$SCREEN_PLAYIT" playit
                fi
                ok "playit agent session refreshed successfully."
                pause ;;
            7)
                info "Resetting stale playit agent keys and configuration files..."
                sudo systemctl stop playit 2>/dev/null || true
                pkill -x playit 2>/dev/null || true
                screen -S "$SCREEN_PLAYIT" -X quit 2>/dev/null || true
                sudo rm -f /etc/playit/playit.toml /etc/playit/playit.conf ~/.config/playit/playit.toml ~/.config/playit/playit.conf 2>/dev/null || true
                ok "Stale agent configs deleted."
                info "Launching playit to generate a fresh claim key..."
                sleep 2
                sudo playit || playit
                pause ;;
            0|"") return ;;
        esac
    done
}

portforward_help() {
    cat <<EOF

  ${BOLD}Manual port forwarding${NC}
   1. Open your router page: http://$(gateway_ip)  (login is on the router's sticker)
   2. Give this laptop a fixed local IP (DHCP reservation): $(local_ip)
   3. Port forwarding / Virtual server: forward ${W}UDP ${PORT}-${UDP_PORT}${NC} to $(local_ip)
   4. Friends join with: ${W}$(get_public_ip):${PORT}${NC}
   ${DIM}If it still fails, your ISP probably uses CGNAT - use playit.gg instead.${NC}
   ${DIM}Tip: when you join from this same laptop, connect to 127.0.0.1 instead of the public IP.${NC}
EOF
}

network_menu() {
    local a
    while true; do
        echo
        echo -e "  ${BOLD}${C}Network / WAN access${NC}"
        echo -e "   1) Network report + CGNAT check"
        echo -e "   2) Open firewall ports (ufw)"
        echo -e "   3) UPnP: ask router to forward ports now"
        echo -e "   4) playit.gg tunnel (for CGNAT)"
        echo -e "   5) Manual port-forward instructions"
        echo -e "   0) Back"
        read -rp "  Choose: " a
        case $a in
            1) network_report; pause ;;
            2) open_firewall; pause ;;
            3) upnp_map; pause ;;
            4) playit_menu; pause ;;
            5) portforward_help; pause ;;
            0|"") return ;;
        esac
    done
}

# =============================================================== settings ===
settings_menu() {
    local a v
    while true; do
        detect_server_dir
        echo
        echo -e "  ${BOLD}${C}Settings${NC}  ${DIM}($CONFIG_FILE)${NC}"
        echo -e "   1) RAM limit            ${W}${RAM_MAX}${NC}"
        echo -e "   2) Server name          ${W}${SERVER_NAME}${NC}"
        echo -e "   3) Max players          ${W}${MAX_PLAYERS}${NC}"
        echo -e "   4) Admin password       ${W}$([ -n "$ADMIN_PASSWORD" ] && echo '(set)' || echo '(ask on first start)')${NC}"
        echo -e "   5) Shutdown countdown   ${W}${WARN_SECONDS}s${NC}"
        echo -e "   6) Battery auto-stop    ${W}${BATTERY_STOP_PCT}%${NC}"
        echo -e "   7) Default lid mode     ${W}${DEFAULT_LID_MODE}${NC}"
        echo -e "   8) Game branch          ${W}${BRANCH}${NC}"
        echo -e "   9) Server install dir   ${W}${SERVER_DIR:-not installed}${NC}"
        echo -e "  10) UDP Ports            ${W}Main: ${PORT} / Peer: ${UDP_PORT}${NC}"
        echo -e "  11) Steam auth mode      ${W}$([ "$USE_STEAM" = "false" ] && echo 'Disabled (-nosteam / cracked allowed)' || echo 'Enabled (Steam clients only)')${NC}"
        echo -e "  12) Player Auto-save     ${W}$([ "${AUTO_SAVE_MINUTES:-10}" -gt 0 ] && echo "every ${AUTO_SAVE_MINUTES} min (when players online)" || echo 'Disabled')${NC}"
        echo -e "  13) World & Sandbox      ${W}Configure Sleep, PvP, Starter Kit, Shutoffs...${NC}"
        echo -e "   0) Back"
        read -rp "  Choose: " a
        case $a in
            1)
                echo -e "   1) 4g - 1-4 players, vanilla"
                echo -e "   2) 6g - ${G}recommended${NC}: up to ~8 players, some mods"
                echo -e "   3) 8g - heavy mod packs / 10+ players"
                echo -e "   4) custom (2-10 GB)"
                read -rp "  Choose: " v
                case $v in
                    1) RAM_MAX=4g ;; 2) RAM_MAX=6g ;; 3) RAM_MAX=8g ;;
                    4) read -rp "  GB (2-10): " v
                       if [[ $v =~ ^[0-9]+$ ]] && [ "$v" -ge 2 ] && [ "$v" -le 10 ]; then RAM_MAX="${v}g"
                       else warn "Must be 2-10."; fi ;;
                esac ;;
            2) read -rp "  Server name (letters/numbers): " v
               [[ $v =~ ^[A-Za-z0-9_-]+$ ]] && SERVER_NAME=$v || warn "Invalid name." ;;
            3) read -rp "  Max players (1-32): " v
               [[ $v =~ ^[0-9]+$ ]] && [ "$v" -ge 1 ] && [ "$v" -le 32 ] && MAX_PLAYERS=$v || warn "Invalid." ;;
            4) read -rsp "  Admin password (empty = ask on first start): " v; echo; ADMIN_PASSWORD=$v ;;
            5) read -rp "  Seconds (0-300): " v
               [[ $v =~ ^[0-9]+$ ]] && [ "$v" -le 300 ] && WARN_SECONDS=$v || warn "Invalid." ;;
            6) read -rp "  Percent (5-50): " v
               [[ $v =~ ^[0-9]+$ ]] && [ "$v" -ge 5 ] && [ "$v" -le 50 ] && BATTERY_STOP_PCT=$v || warn "Invalid." ;;
            7) choose_lid_mode; DEFAULT_LID_MODE=$CHOSEN_MODE ;;
            8) read -rp "  Branch (public = stable, unstable = B42): " v
               [ -n "$v" ] && BRANCH=$v; warn "Run Install/update to switch builds." ;;
            9) read -rp "  Path containing start-server.sh: " v
               [ -f "$v/start-server.sh" ] && SERVER_DIR=$v || warn "start-server.sh not found there." ;;
            10) read -rp "  Main UDP Port (1024-65535, default 16261): " v
                if [[ $v =~ ^[0-9]+$ ]] && [ "$v" -ge 1024 ] && [ "$v" -le 65535 ]; then
                    PORT=$v
                    UDP_PORT=$((PORT + 1))
                    apply_ini
                    ok "Set Main Port to ${PORT}/UDP and Peer Port to ${UDP_PORT}/UDP."
                    warn "Important: You MUST restart the server for port changes to take effect."
                    warn "Also update firewall (Option 8 -> 2) or playit.gg to forward UDP ${PORT}."
                else
                    warn "Invalid port number."
                fi ;;
            11) echo -e "   1) Enabled  - Steam clients only (requires official Steam account)"
                echo -e "   2) Disabled - -nosteam mode (${G}allows cracked / non-Steam clients to join${NC})"
                read -rp "  Choose [1/2]: " v
                if [ "$v" = "2" ]; then
                    USE_STEAM="false"
                    ok "Steam auth disabled (-nosteam mode active)."
                    info "Cracked & non-Steam clients can now join via IP/Port!"
                else
                    USE_STEAM="true"
                    ok "Steam auth enabled (official Steam mode)."
                fi ;;
            12) echo -e "  Auto-save interval (minutes) when players are connected to the server:"
                echo -e "   1) 5 minutes"
                echo -e "   2) 10 minutes (${G}recommended${NC})"
                echo -e "   3) 15 minutes"
                echo -e "   4) 30 minutes"
                echo -e "   5) Disable auto-save"
                read -rp "  Choose [1-5]: " v
                case $v in
                    1) AUTO_SAVE_MINUTES=5 ;;
                    2) AUTO_SAVE_MINUTES=10 ;;
                    3) AUTO_SAVE_MINUTES=15 ;;
                    4) AUTO_SAVE_MINUTES=30 ;;
                    5) AUTO_SAVE_MINUTES=0 ;;
                esac
                ok "Auto-save set to ${AUTO_SAVE_MINUTES} minutes (only when players are online)." ;;
            13) world_settings_menu ;;
            0|"") return ;;
        esac
        save_config
        [ -n "$(server_pid)" ] && warn "Changes apply on next server start."
    done
}

# ========================================================== mods manager ====
lua_file() { echo "$ZOMBOID_DIR/Server/${SERVER_NAME}_SandboxVars.lua"; }
lua_get()  { grep -m1 -E "^[[:space:]]*$1[[:space:]]*=" "$(lua_file)" 2>/dev/null | sed -E 's/.*=[[:space:]]*([^,]+).*/\1/' | tr -d '\r" '; }
lua_set()  { local f; f=$(lua_file); [ -f "$f" ] && sed -i -E "s/^([[:space:]]*$1[[:space:]]*=).*/\1 $2,/" "$f"; }

world_settings_menu() {
    local a v sleep_al sleep_nd pvp pause_e start_k water_s elec_s
    while true; do
        sleep_al=$(ini_get SleepAllowed); sleep_al=${sleep_al:-false}
        sleep_nd=$(ini_get SleepNeeded); sleep_nd=${sleep_nd:-false}
        pvp=$(ini_get PVP); pvp=${pvp:-true}
        pause_e=$(ini_get PauseEmpty); pause_e=${pause_e:-true}
        start_k=$(lua_get StarterKit); start_k=${start_k:-false}
        water_s=$(lua_get WaterShut); water_s=${water_s:-2}
        elec_s=$(lua_get ElecShut); elec_s=${elec_s:-2}

        echo
        echo -e "  ${BOLD}${C}World Generation & Sandbox Settings${NC}  ${DIM}($(ini_file))${NC}"
        echo -e "   1) Sleep Allowed in MP:   ${W}${sleep_al}${NC} ${DIM}(allows players to sleep in beds)${NC}"
        echo -e "   2) Sleep Needed:          ${W}${sleep_nd}${NC} ${DIM}(players get tired & require sleep)${NC}"
        echo -e "   3) PvP Combat:            ${W}${pvp}${NC} ${DIM}(friendly fire between players)${NC}"
        echo -e "   4) Pause when Empty:      ${W}${pause_e}${NC} ${DIM}(pause game time when no players online)${NC}"
        echo -e "   5) Starter Kit on Spawn:  ${W}${start_k}${NC} ${DIM}(spawn with bag, bat, water, chips)${NC}"
        echo -e "   6) Water Shutoff:         ${W}Option ${water_s}${NC} ${DIM}(2 = 0-30 days, 6 = Never)${NC}"
        echo -e "   7) Electricity Shutoff:   ${W}Option ${elec_s}${NC} ${DIM}(2 = 0-30 days, 6 = Never)${NC}"
        echo -e "   0) Back"
        read -rp "  Choose: " a
        case $a in
            1) if [ "$sleep_al" = "true" ]; then ini_set SleepAllowed false; ok "Sleep Allowed set to false."; else ini_set SleepAllowed true; ok "Sleep Allowed set to true."; fi ;;
            2) if [ "$sleep_nd" = "true" ]; then ini_set SleepNeeded false; ok "Sleep Needed set to false."; else ini_set SleepNeeded true; ini_set SleepAllowed true; ok "Sleep Needed set to true (enabling Sleep Allowed too)."; fi ;;
            3) if [ "$pvp" = "true" ]; then ini_set PVP false; ok "PvP set to false (disabled)."; else ini_set PVP true; ok "PvP set to true (enabled)."; fi ;;
            4) if [ "$pause_e" = "true" ]; then ini_set PauseEmpty false; ok "Pause when Empty set to false."; else ini_set PauseEmpty true; ok "Pause when Empty set to true."; fi ;;
            5) if [ "$start_k" = "true" ]; then lua_set StarterKit false; ok "Starter Kit disabled."; else lua_set StarterKit true; ok "Starter Kit enabled."; fi ;;
            6) echo -e "   1) Instant shutoff"
               echo -e "   2) 0-30 days (default)"
               echo -e "   3) 0-2 months"
               echo -e "   4) 0-6 months"
               echo -e "   5) 6-12 months"
               echo -e "   6) Never shut off"
               read -rp "  Choose [1-6]: " v
               if [[ $v =~ ^[1-6]$ ]]; then lua_set WaterShut "$v"; ok "Water shutoff updated."; fi ;;
            7) echo -e "   1) Instant shutoff"
               echo -e "   2) 0-30 days (default)"
               echo -e "   3) 0-2 months"
               echo -e "   4) 0-6 months"
               echo -e "   5) 6-12 months"
               echo -e "   6) Never shut off"
               read -rp "  Choose [1-6]: " v
               if [[ $v =~ ^[1-6]$ ]]; then lua_set ElecShut "$v"; ok "Electricity shutoff updated."; fi ;;
            0|"") return ;;
        esac
        [ -n "$(server_pid)" ] && warn "Changes will take effect on next server restart."
    done
}
bulk_import_mods() {
    local input_file="$STATE_DIR/bulk_mods_input.txt"
    echo
    echo -e "  ${BOLD}${C}QUICK BULK MOD IMPORTER${NC}"
    echo -e "  ${DIM}Paste your list of mods below (e.g. Mod Name <tab> WorkshopID <tab> ModID).${NC}"
    echo -e "  ${Y}Instructions:${NC} Paste your text, press ${W}Enter${NC}, then press ${W}Ctrl+D${NC} to finish."
    echo

    mkdir -p "$STATE_DIR"
    cat > "$input_file"

    if [ ! -s "$input_file" ]; then
        warn "No text pasted."
        rm -f "$input_file"
        return 1
    fi

    local cur_mods cur_ws new_m_list=() new_w_list=() line ws_id mod_id count=0
    cur_mods=$(ini_get Mods)
    cur_ws=${SAVED_WORKSHOP_ITEMS:-$(ini_get WorkshopItems)}

    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        ws_id=$(echo "$line" | grep -oE '[0-9]{6,12}' | head -n1)
        mod_id=$(echo "$line" | awk -F'\t|  +' '{print $NF}' | tr -d '\r ')
        if [ "$mod_id" = "$ws_id" ] || [ -z "$mod_id" ]; then
            mod_id=$(echo "$line" | awk '{print $NF}' | tr -d '\r ')
        fi

        if [[ $ws_id =~ ^[0-9]+$ ]] && [ -n "$mod_id" ] && [ "$mod_id" != "$ws_id" ]; then
            if [[ ! ";$cur_ws;" =~ ";$ws_id;" ]] && [[ ! " ${new_w_list[*]} " =~ " $ws_id " ]]; then
                new_w_list+=("$ws_id")
            fi
            if [[ ! ";$cur_mods;" =~ ";$mod_id;" ]] && [[ ! " ${new_m_list[*]} " =~ " $mod_id " ]]; then
                new_m_list+=("$mod_id")
            fi
            count=$((count + 1))
        fi
    done < "$input_file"
    rm -f "$input_file"

    if [ "$count" -eq 0 ]; then
        warn "Could not parse any valid Workshop ID / Mod ID pairs from the pasted text."
        return 1
    fi

    for ws_id in "${new_w_list[@]}"; do
        if [ -z "$cur_ws" ]; then cur_ws="$ws_id"; else cur_ws="${cur_ws};${ws_id}"; fi
    done
    SAVED_WORKSHOP_ITEMS="$cur_ws"

    if [ "$USE_STEAM" = "true" ]; then
        ini_set WorkshopItems "$cur_ws"
    else
        ini_set WorkshopItems ""
    fi

    for mod_id in "${new_m_list[@]}"; do
        if [ -z "$cur_mods" ]; then cur_mods="$mod_id"; else cur_mods="${cur_mods};${mod_id}"; fi
    done
    ini_set Mods "$cur_mods"

    if [[ ";$cur_mods;" =~ ";RV_Interior;" ]]; then
        local cur_map; cur_map=$(ini_get Map)
        if [[ ! ";$cur_map;" =~ "RV_Interior_Map" ]]; then
            ini_set Map "RV_Interior_Map;${cur_map:-Muldraugh, KY}"
            ok "Automatically added RV_Interior_Map to Map load order."
        fi
    fi

    save_config
    echo
    ok "Successfully imported ${count} mod(s)!"
    info "Current Mods: ${cur_mods}"
    info "Current Workshop Items: ${cur_ws}"
}

test_mods_compatibility() {
    local cur_mods cur_ws ws_dir1 ws_dir2 m_list=() w_list=() m w m_found=0 m_missing=0
    cur_mods=$(ini_get Mods)
    cur_ws=${SAVED_WORKSHOP_ITEMS:-$(ini_get WorkshopItems)}

    echo
    echo -e "  ${BOLD}${C}MOD COMPATIBILITY & VERIFICATION TESTER${NC}"
    echo -e "  ${DIM}Checking configured mods against server storage...${NC}"
    echo

    if [ -z "$cur_mods" ] && [ -z "$cur_ws" ]; then
        warn "No mods are currently configured in $(ini_file)."
        return 0
    fi

    ws_dir1="$SERVER_DIR/steamapps/workshop/content/380870"
    ws_dir2="$HOME/.steam/steam/steamapps/workshop/content/380870"

    IFS=';' read -ra m_list <<< "$cur_mods"
    IFS=';' read -ra w_list <<< "$cur_ws"

    echo -e "  ${BOLD}Steam Auth Mode:${NC} $( [ "$USE_STEAM" = "true" ] && echo "${G}Enabled (Steam mode)${NC}" || echo "${Y}Disabled (-nosteam mode)${NC}" )"
    echo -e "  ${BOLD}Total Configured Mods:${NC} ${#m_list[@]} Mod IDs | ${#w_list[@]} Workshop Items"
    echo

    echo -e "  ${BOLD}Workshop Items Status on Disk:${NC}"
    for w in "${w_list[@]}"; do
        [ -z "$w" ] && continue
        if [ -d "$ws_dir1/$w" ] || [ -d "$ws_dir2/$w" ]; then
            echo -e "   ${G}[✓] Workshop ID ${w}${NC} - Downloaded on disk"
            m_found=$((m_found + 1))
        else
            echo -e "   ${Y}[!] Workshop ID ${w}${NC} - ${R}Not downloaded on disk yet${NC}"
            m_missing=$((m_missing + 1))
        fi
    done

    echo
    echo -e "  ${BOLD}Special Mod Checks:${NC}"
    if [[ ";$cur_mods;" =~ ";RV_Interior;" ]]; then
        local cur_map; cur_map=$(ini_get Map)
        if [[ ";$cur_map;" =~ "RV_Interior_Map" ]]; then
            ok "RV_Interior map requirement: RV_Interior_Map is configured in Map setting."
        else
            warn "RV_Interior map missing! RV_Interior requires 'RV_Interior_Map' in Map setting."
        fi
    fi

    if [[ ";$cur_mods;" =~ ";Arsenal(26)GunFighter;" ]] && [[ ! ";$cur_mods;" =~ ";tsarslib;" ]]; then
        warn "Brita / GunFighter notice: tsarslib (Tsar's Common Library) is recommended."
    fi

    echo
    if [ "$m_missing" -gt 0 ]; then
        warn "${m_missing} Workshop mod(s) are missing from disk."
        if [ "$USE_STEAM" = "false" ]; then
            echo -e "  ${Y}To download missing mods:${NC}"
            echo -e "   1. Go to Settings (Option 9 -> 11) and set Steam Auth to ${W}Enabled${NC}."
            echo -e "   2. Start the server once (${W}Option 1${NC}) so Steam downloads the mod files."
            echo -e "   3. Once online, stop server and switch back to ${W}-nosteam${NC} mode."
        else
            info "Start the server (Option 1) to let Steam download missing mods."
        fi
    else
        ok "All ${m_found} Workshop items are downloaded and ready to play!"
        [ "$USE_STEAM" = "false" ] && ok "Server is ready to launch in -nosteam mode for cracked/non-Steam players!"
    fi
}

mods_menu() {
    local a cur_mods cur_ws mod_input ws_input
    while true; do
        cur_mods=$(ini_get Mods)
        cur_ws=${SAVED_WORKSHOP_ITEMS:-$(ini_get WorkshopItems)}
        echo
        echo -e "  ${BOLD}${C}Steam Workshop Mod Manager${NC}  ${DIM}($(ini_file))${NC}"
        echo -e "   Current Mods:           ${W}${cur_mods:-(none)}${NC}"
        echo -e "   Current Workshop Items: ${W}${cur_ws:-(none)}${NC}"
        echo
        echo -e "   1) Quick Bulk Importer ${G}(Paste list/table of mods at once)${NC}"
        echo -e "   2) Run Mod Compatibility & Verification Tester"
        echo -e "   3) Add a single Steam Workshop Mod"
        echo -e "   4) Remove a Mod"
        echo -e "   5) Clear all Mods"
        echo -e "   6) How to find Mod ID & Workshop ID"
        echo -e "   0) Back"
        read -rp "  Choose: " a
        case $a in
            1) bulk_import_mods; pause ;;
            2) test_mods_compatibility; pause ;;
            3)
                echo
                echo -e "  ${BOLD}Adding a Steam Workshop Mod:${NC}"
                echo -e "  ${DIM}Example Workshop URL: https://steamcommunity.com/sharedfiles/filedetails/?id=2683801888${NC}"
                echo -e "  ${DIM}Workshop ID: 2683801888  |  Mod ID is shown on mod page (e.g. Arsenal26GunFighter)${NC}"
                echo
                read -rp "  Enter Workshop Item ID (or paste Steam URL): " ws_input
                ws_input=$(echo "$ws_input" | grep -oE '[0-9]{6,12}' | head -n1)
                if [[ ! $ws_input =~ ^[0-9]+$ ]]; then
                    warn "Invalid Workshop ID. Must be numbers (e.g. 2683801888)."
                    pause; continue
                fi
                read -rp "  Enter Mod ID (case-sensitive as shown on mod page): " mod_input
                mod_input=$(echo "$mod_input" | tr -d ' ')
                if [ -z "$mod_input" ]; then
                    warn "Mod ID cannot be empty."
                    pause; continue
                fi

                if [ -z "$cur_ws" ]; then
                    cur_ws="$ws_input"
                elif [[ ! ";$cur_ws;" =~ ";$ws_input;" ]]; then
                    cur_ws="${cur_ws};${ws_input}"
                fi
                SAVED_WORKSHOP_ITEMS="$cur_ws"
                if [ "$USE_STEAM" = "true" ]; then ini_set WorkshopItems "$cur_ws"; fi

                if [ -z "$cur_mods" ]; then
                    cur_mods="$mod_input"
                elif [[ ! ";$cur_mods;" =~ ";$mod_input;" ]]; then
                    cur_mods="${cur_mods};${mod_input}"
                fi
                ini_set Mods "$cur_mods"

                save_config
                ok "Added Mod '${mod_input}' (Workshop ID: ${ws_input}) to $(ini_file)."
                warn "Changes will apply on next server start."
                pause ;;
            4)
                if [ -z "$cur_mods" ] && [ -z "$cur_ws" ]; then
                    warn "No mods configured."
                    pause; continue
                fi
                read -rp "  Enter Mod ID or Workshop ID to remove: " mod_input
                mod_input=$(echo "$mod_input" | tr -d ' ')
                [ -z "$mod_input" ] && continue

                local new_m new_w
                new_m=$(echo ";$cur_mods;" | sed "s/;${mod_input};/;/g" | sed 's/^;//;s/;$//')
                ini_set Mods "$new_m"

                new_w=$(echo ";$cur_ws;" | sed "s/;${mod_input};/;/g" | sed 's/^;//;s/;$//')
                SAVED_WORKSHOP_ITEMS="$new_w"
                if [ "$USE_STEAM" = "true" ]; then ini_set WorkshopItems "$new_w"; fi

                save_config
                ok "Removed '${mod_input}'."
                pause ;;
            5)
                if confirm "Remove ALL mods from the server configuration?"; then
                    ini_set Mods ""
                    SAVED_WORKSHOP_ITEMS=""
                    ini_set WorkshopItems ""
                    save_config
                    ok "All mods cleared."
                fi
                pause ;;
            6)
                echo
                echo -e "  ${BOLD}${C}HOW TO FIND MOD ID AND WORKSHOP ID${NC}"
                echo -e "  ${DIM}------------------------------------------------------${NC}"
                echo -e "   1. Open the mod on Steam Workshop in your browser."
                echo -e "   2. Look at the URL: ${W}https://steamcommunity.com/.../?id=${BOLD}2683801888${NC}"
                echo -e "      The number at the end is the ${W}Workshop Item ID${NC} (2683801888)."
                echo -e "   3. Look near the bottom of the mod description text:"
                echo -e "      It lists ${W}Mod ID: Arsenal26GunFighter${NC}"
                echo -e "   4. Enter both in Option 3 or paste a list in Option 1."
                echo -e "  ${DIM}------------------------------------------------------${NC}"
                pause ;;
            0|"") return ;;
        esac
    done
}

# ========================================================== world profiles ====
world_profiles_menu() {
    local choice new_name src_name profiles=() profile p
    while true; do
        clear
        echo -e "${BOLD}${C}══════════════════════════════════════════════════════${NC}"
        echo -e "${BOLD}${W}   WORLD PROFILES MANAGER (MULTI-WORLD SUPPORT)${NC}"
        echo -e "${BOLD}${C}══════════════════════════════════════════════════════${NC}"
        echo -e "   Active Profile: ${BOLD}${G}${SERVER_NAME}${NC}"
        echo -e "   ${DIM}All worlds exist independently in ~/Zomboid/ and never corrupt each other.${NC}"
        echo

        profiles=()
        for p in "$ZOMBOID_DIR"/Server/*.ini; do
            [ -f "$p" ] || continue
            local base
            base=$(basename "$p" .ini)
            profiles+=("$base")
        done
        for p in "$ZOMBOID_DIR"/Saves/Multiplayer/*; do
            [ -d "$p" ] || continue
            local base
            base=$(basename "$p")
            local exists=false
            for ex in "${profiles[@]}"; do
                if [ "$ex" = "$base" ]; then exists=true; break; fi
            done
            if [ "$exists" = "false" ]; then profiles+=("$base"); fi
        done

        if [ ${#profiles[@]} -eq 0 ]; then
            profiles+=("servertest")
        fi

        echo -e "   ${BOLD}${W}Available Worlds on Server:${NC}"
        local idx=1
        for p in "${profiles[@]}"; do
            local mark="  "
            [ "$p" = "$SERVER_NAME" ] && mark="${G}➔ ${NC}"
            
            local save_info="no save map yet"
            if [ -d "$ZOMBOID_DIR/Saves/Multiplayer/$p" ]; then
                local sz
                sz=$(du -sh "$ZOMBOID_DIR/Saves/Multiplayer/$p" 2>/dev/null | cut -f1)
                save_info="save size: ${sz:-0B}"
            fi
            
            echo -e "   ${mark}${W}${idx})${NC} ${BOLD}${p}${NC} ${DIM}(${save_info})${NC}"
            idx=$((idx + 1))
        done

        echo
        echo -e "   ${W}S)${NC} Switch active world profile"
        echo -e "   ${W}N)${NC} Create NEW blank world profile"
        echo -e "   ${W}C)${NC} Clone existing world profile ${DIM}(e.g. duplicate main world for mod testing)${NC}"
        echo -e "   ${W}0)${NC} Back to main menu"
        echo
        read -rp "  Choose action: " choice
        case ${choice,,} in
            s)
                if [ -n "$(server_pid)" ]; then
                    warn "Server is currently running! Please stop the server before switching active profile."
                    pause; continue
                fi
                echo
                read -rp "  Enter profile number or exact name to activate: " p
                if [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le "${#profiles[@]}" ]; then
                    SERVER_NAME="${profiles[$((p-1))]}"
                    save_config
                    ok "Active world profile set to '${SERVER_NAME}'."
                elif [ -n "$p" ]; then
                    SERVER_NAME="$p"
                    save_config
                    ok "Active world profile set to '${SERVER_NAME}'."
                else
                    warn "Invalid selection."
                fi
                pause ;;
            n)
                if [ -n "$(server_pid)" ]; then
                    warn "Server is currently running! Please stop the server before creating a profile."
                    pause; continue
                fi
                echo
                read -rp "  Enter name for NEW world profile (e.g. mod_testing): " new_name
                new_name=$(echo "$new_name" | tr -cd 'a-zA-Z0-9_-')
                if [ -z "$new_name" ]; then
                    err "Invalid profile name."
                    pause; continue
                fi
                SERVER_NAME="$new_name"
                save_config
                mkdir -p "$ZOMBOID_DIR/Server" "$ZOMBOID_DIR/Saves/Multiplayer" "$ZOMBOID_DIR/db"
                if [ ! -f "$ZOMBOID_DIR/Server/${new_name}.ini" ]; then
                    cat <<EOFINI > "$ZOMBOID_DIR/Server/${new_name}.ini"
PVP=true
PauseEmpty=true
GlobalChat=true
Open=true
ServerWelcomeMessage=Welcome to Project Zomboid Server ($new_name)!
LogLocalic=true
AutoSaveMinutes=10
EOFINI
                fi
                ok "Created new profile '${new_name}' and set as ACTIVE."
                pause ;;
            c)
                if [ -n "$(server_pid)" ]; then
                    warn "Server is currently running! Please stop the server before cloning."
                    pause; continue
                fi
                echo
                read -rp "  Enter source profile name to clone [${SERVER_NAME}]: " src_name
                src_name="${src_name:-$SERVER_NAME}"
                read -rp "  Enter name for CLONED world profile (e.g. ${src_name}_test): " new_name
                new_name=$(echo "$new_name" | tr -cd 'a-zA-Z0-9_-')
                if [ -z "$new_name" ]; then
                    err "Invalid clone profile name."
                    pause; continue
                fi
                info "Cloning profile '${src_name}' to '${new_name}'..."
                mkdir -p "$ZOMBOID_DIR/Server" "$ZOMBOID_DIR/Saves/Multiplayer" "$ZOMBOID_DIR/db"
                
                [ -f "$ZOMBOID_DIR/Server/${src_name}.ini" ] && cp -f "$ZOMBOID_DIR/Server/${src_name}.ini" "$ZOMBOID_DIR/Server/${new_name}.ini"
                [ -f "$ZOMBOID_DIR/Server/${src_name}_SandboxVars.lua" ] && cp -f "$ZOMBOID_DIR/Server/${src_name}_SandboxVars.lua" "$ZOMBOID_DIR/Server/${new_name}_SandboxVars.lua"
                [ -f "$ZOMBOID_DIR/Server/${src_name}_spawnregions.lua" ] && cp -f "$ZOMBOID_DIR/Server/${src_name}_spawnregions.lua" "$ZOMBOID_DIR/Server/${new_name}_spawnregions.lua"
                [ -f "$ZOMBOID_DIR/db/${src_name}.db" ] && cp -f "$ZOMBOID_DIR/db/${src_name}.db" "$ZOMBOID_DIR/db/${new_name}.db"
                
                if [ -d "$ZOMBOID_DIR/Saves/Multiplayer/${src_name}" ]; then
                    cp -r "$ZOMBOID_DIR/Saves/Multiplayer/${src_name}" "$ZOMBOID_DIR/Saves/Multiplayer/${new_name}"
                fi

                SERVER_NAME="$new_name"
                save_config
                ok "Successfully cloned '${src_name}' into '${new_name}' and set as ACTIVE!"
                pause ;;
            0|"") return ;;
        esac
    done
}

# ================================================================== menu ====
main_menu() {
    local a st pc
    while true; do
        clear
        st=$(server_state)
        parse_players
        pc=""
        [ "$st" = "ONLINE" ] && [ -n "$PLAYER_COUNT" ] && pc="   Players: ${PLAYER_COUNT}"
        echo -e "${BOLD}${C}══════════════════════════════════════════════════════${NC}"
        echo -e "${BOLD}${W}   PROJECT ZOMBOID SERVER MANAGER${NC}"
        echo -e "${BOLD}${C}══════════════════════════════════════════════════════${NC}"
        echo -e "   Server '${SERVER_NAME}': $(state_colored "$st")${pc}"
        [ "$st" != "OFFLINE" ] && echo -e "   Lid mode: $(lid_mode_text)"
        detect_server_dir || echo -e "   ${Y}Server not installed yet - use option 7.${NC}"
        echo
        echo -e "   ${W}1)${NC} Start server"
        echo -e "   ${W}2)${NC} Live dashboard"
        echo -e "   ${W}3)${NC} Stop server ${DIM}(warns players, saves, then quits)${NC}"
        echo -e "   ${W}4)${NC} Save world now"
        echo -e "   ${W}5)${NC} Broadcast message to players"
        echo -e "   ${W}6)${NC} Open server console ${DIM}(advanced)${NC}"
        echo -e "   ${W}7)${NC} Install / update server"
        echo -e "   ${W}8)${NC} Network / WAN setup"
        echo -e "   ${W}9)${NC} Settings"
        echo -e "  ${W}10)${NC} ${Y}Troubleshoot / reset server data${NC} ${DIM}(wipe map/save on failure)${NC}"
        echo -e "  ${W}11)${NC} ${C}Steam Workshop Mods Manager${NC} ${DIM}(add/remove mods)${NC}"
        echo -e "  ${W}12)${NC} ${G}World Profiles Manager${NC} ${DIM}(switch / create / clone distinct worlds)${NC}"
        echo -e "   ${W}0)${NC} Exit ${DIM}(server keeps running in the background)${NC}"
        echo
        read -rp "  Choose: " a
        case $a in
            1) start_server; pause ;;
            2) dashboard ;;
            3) if [ -n "$(server_pid)" ] && confirm "Stop the server? The world is saved first."; then
                   read -rp "  In-game warning countdown in seconds [${WARN_SECONDS}]: " a
                   stop_server "${a:-$WARN_SECONDS}"
               elif [ -z "$(server_pid)" ]; then warn "Server is not running."; fi
               pause ;;
            4) save_world 30; pause ;;
            5) read -rp "  Message: " a; [ -n "$a" ] && servermsg "$a" && ok "Sent."; pause ;;
            6) if screen_running "$SCREEN_SERVER"; then
                   echo -e "  ${Y}Detach with Ctrl+A then D. Do NOT press Ctrl+C (it stops the server without the countdown).${NC}"
                   sleep 3; screen -r "$SCREEN_SERVER"
               else warn "Server is not running."; pause; fi ;;
            7) install_update; pause ;;
            8) network_menu ;;
            9) settings_menu ;;
            10) troubleshoot_menu ;;
            11) mods_menu ;;
            12) world_profiles_menu ;;
            0|q|Q) clear; exit 0 ;;
        esac
    done
}

usage() {
    cat <<EOF
Project Zomboid Server Manager
  $(basename "$0")                     interactive menu
  $(basename "$0") start [safe|keep]   start server (lid mode: safe = save+stop on lid close, keep = stay online)
  $(basename "$0") stop [seconds]      warn players, save and stop (default countdown ${WARN_SECONDS}s)
  $(basename "$0") save                save the world now
  $(basename "$0") dashboard           live status dashboard
  $(basename "$0") install             install / update via SteamCMD
  $(basename "$0") restore-lid         restore normal lid-close behaviour manually
EOF
}

# ================================================================== main ====
for dep in screen pgrep ss awk; do
    command -v "$dep" >/dev/null 2>&1 || { err "Missing required tool: $dep (sudo apt install $dep)"; exit 1; }
done

case "${1:-menu}" in
    __watch)        watch_main "${2:-safe}" ;;
    menu)           recover_stale_state; main_menu ;;
    start)          recover_stale_state; start_server "${2:-$DEFAULT_LID_MODE}" ;;
    stop)           stop_server "${2:-$WARN_SECONDS}" ;;
    save)           save_world 30 ;;
    dashboard|status) dashboard ;;
    install|update) install_update ;;
    mods)           mods_menu ;;
    world|sandbox)  world_settings_menu ;;
    profile|profiles|switch-world) world_profiles_menu ;;
    restore-save|revert-save) restore_save_backup ;;
    restore-lid)    lid_restore_de_action; ok "Lid settings restored." ;;
    reset-data|troubleshoot) troubleshoot_menu ;;
    -h|--help|help) usage ;;
    *)              usage; exit 1 ;;
esac
