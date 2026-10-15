#!/usr/bin/env bash
#
# clip-mover.sh  (SteamOS, Benachrichtigungs-Variante)
#
# Beobachtet alle  ~/.local/share/Steam/userdata/<userid>/gamerecordings/video
# auf neue Ordner. Ist ein Ordner fertig geschrieben, meldet das Skript ihn
# per SSH an den Server. Der Server-Key ist dort auf ein festes Programm
# (clip-pull.sh) beschraenkt - der Deck darf auf dem Server NICHTS anderes.
# Der Server holt den Ordner daraufhin selbst per rsync ab (auf dem Deck
# nur Lesezugriff ueber rrsync -ro). Liefert der Server Exit-Code 0, ist
# der Ordner vollstaendig und atomar abgelegt -> erst dann loescht der
# Deck die Quelle selbst. Der Server braucht also keinerlei Schreib- oder
# Loeschrechte auf dem Deck.
#
# Vor dem Melden wird der Spielname (Steam-Spiele aus appmanifest_*.acf,
# Steamfremde Spiele aus shortcuts.vdf) als game_name.txt in den Ordner
# geschrieben. Der Server hat diese Infos nicht - mpdToMP4.sh liest sie.
#
# Abhaengigkeiten auf dem Deck: bash, ssh, du (alles in SteamOS enthalten),
# optional python3 (Spielname), optional inotifywait.

set -uo pipefail

CONF_FILE="${CLIP_MOVER_CONF:-$HOME/.config/clip-mover.conf}"
# shellcheck source=/dev/null
[ -r "$CONF_FILE" ] && . "$CONF_FILE"

STEAM_USERDATA="${CLIP_MOVER_STEAM_USERDATA:-${STEAM_USERDATA:-$HOME/.local/share/Steam/userdata}}"
WATCH_SUBPATH="${CLIP_MOVER_WATCH_SUBPATH:-${WATCH_SUBPATH:-gamerecordings/video}}"

# Server-Account, dessen authorized_keys den Key auf clip-pull.sh zwingt
NOTIFY_TARGET="${CLIP_MOVER_NOTIFY_TARGET:-${NOTIFY_TARGET:-clipsync@server}}"   # ANPASSEN
# Benutzername auf diesem Geraet, wird dem Server mitgeschickt
# (Steam Deck: deck, Steam Frame: steamos)
DEVICE_USER="${CLIP_MOVER_DEVICE_USER:-${DEVICE_USER:-$(id -un)}}"
NOTIFY_KEY="${CLIP_MOVER_NOTIFY_KEY:-${NOTIFY_KEY:-$HOME/.ssh/clip_notify}}"
SSH_OPTS="${CLIP_MOVER_SSH_OPTS:-${SSH_OPTS:--o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=4}}"

LOG_FILE="${CLIP_MOVER_LOG_FILE:-${LOG_FILE:-$HOME/clip-mover.log}}"
POLL_INTERVAL="${CLIP_MOVER_POLL_INTERVAL:-${POLL_INTERVAL:-60}}"
STABLE_CHECKS_REQUIRED="${CLIP_MOVER_STABLE_CHECKS:-${STABLE_CHECKS_REQUIRED:-2}}"
STABLE_CHECK_INTERVAL="${CLIP_MOVER_STABLE_INTERVAL:-${STABLE_CHECK_INTERVAL:-10}}"
STABLE_MAX_WAIT="${CLIP_MOVER_STABLE_MAX_WAIT:-${STABLE_MAX_WAIT:-1800}}"
GAME_NAME_FILE="${CLIP_MOVER_GAME_NAME_FILE:-${GAME_NAME_FILE:-game_name.txt}}"
STEAM_ROOT="${CLIP_MOVER_STEAM_ROOT:-${STEAM_ROOT:-$HOME/.local/share/Steam}}"
NOTIFY_MAX_ATTEMPTS="${CLIP_MOVER_NOTIFY_ATTEMPTS:-${NOTIFY_MAX_ATTEMPTS:-3}}"
NOTIFY_RETRY_DELAY="${CLIP_MOVER_NOTIFY_RETRY_DELAY:-${NOTIFY_RETRY_DELAY:-30}}"

log() {
    local line
    line="$(date '+%Y-%m-%d %H:%M:%S') $*"
    echo "$line"
    echo "$line" >> "$LOG_FILE" 2>/dev/null
}

for cmd in ssh du; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "Fehler: '$cmd' fehlt." >&2; exit 1; }
done
[ -r "$NOTIFY_KEY" ] || { echo "Fehler: SSH-Key '$NOTIFY_KEY' fehlt." >&2; exit 1; }
HAVE_INOTIFY=0
command -v inotifywait >/dev/null 2>&1 && HAVE_INOTIFY=1
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

wait_until_stable() {
    local dir="$1" start_ts now elapsed last_size="" size stable_count=0 human
    start_ts=$(date +%s)
    while true; do
        [ -d "$dir" ] || return 1
        now=$(date +%s); elapsed=$(( now - start_ts ))
        if [ "$elapsed" -ge "$STABLE_MAX_WAIT" ]; then
            log "WARNUNG: '$dir' seit ${STABLE_MAX_WAIT}s nicht stabil. Spaeter erneut."
            return 1
        fi
        size=$(du -sb "$dir" 2>/dev/null | cut -f1)
        human=$(du -sh "$dir" 2>/dev/null | cut -f1)
        if [ -n "$size" ] && [ "$size" = "$last_size" ]; then
            stable_count=$(( stable_count + 1 ))
            log "  ... unveraendert (${human:-?}), stabil ${stable_count}/${STABLE_CHECKS_REQUIRED}"
            [ "$stable_count" -ge "$STABLE_CHECKS_REQUIRED" ] && return 0
        else
            log "  ... Groesse ${human:-?}, warte (${elapsed}s)"
            stable_count=0
        fi
        last_size="$size"
        sleep "$STABLE_CHECK_INTERVAL"
    done
}

# Spielname zur AppID lokal ermitteln (acf / shortcuts.vdf). Ausgabe auf
# stdout, Rueckgabe 1 wenn nichts gefunden.
resolve_game_name() {
    local app_id="$1"
    [[ "$app_id" =~ ^[0-9]+$ ]] || return 1
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "$app_id" "$STEAM_ROOT" <<'PY'
import sys, os, glob, re
app_id, root = sys.argv[1], sys.argv[2]

def steamapps_dirs():
    dirs = [os.path.join(root, 'steamapps')]
    try:
        txt = open(os.path.join(root, 'steamapps', 'libraryfolders.vdf'), encoding='utf-8', errors='replace').read()
        dirs += [os.path.join(p, 'steamapps') for p in re.findall(r'"path"\s*"([^"]+)"', txt)]
    except OSError:
        pass
    return [d for d in dict.fromkeys(dirs) if os.path.isdir(d)]

def from_acf():
    for sa in steamapps_dirs():
        try:
            txt = open(os.path.join(sa, 'appmanifest_%s.acf' % app_id), encoding='utf-8', errors='replace').read()
        except OSError:
            continue
        m = re.search(r'"name"\s*"([^"]*)"', txt)
        if m and m.group(1).strip():
            return m.group(1).strip()

def parse_vdf(data, i=0):
    res = {}
    while i < len(data):
        t = data[i]; i += 1
        if t == 0x08:
            return res, i
        end = data.index(0, i); key = data[i:end].decode('utf-8', 'replace'); i = end + 1
        if t == 0x00:
            res[key], i = parse_vdf(data, i)
        elif t == 0x01:
            end = data.index(0, i); res[key] = data[i:end].decode('utf-8', 'replace'); i = end + 1
        elif t == 0x02:
            res[key] = int.from_bytes(data[i:i+4], 'little', signed=True); i += 4
        elif t == 0x07:
            res[key] = int.from_bytes(data[i:i+8], 'little'); i += 8
        else:
            raise ValueError(t)
    return res, i

def from_shortcuts():
    target = int(app_id)
    cands = {target, target & 0xFFFFFFFF}
    if target >= 2**31: cands.add(target - 2**32)
    if target > 0xFFFFFFFF:                      # 64-bit GameID -> obere 32 Bit
        high = target >> 32
        cands |= {high, high - 2**32 if high >= 2**31 else high}
    for f in glob.glob(os.path.join(root, 'userdata', '*', 'config', 'shortcuts.vdf')):
        try:
            sc = parse_vdf(open(f, 'rb').read())[0].get('shortcuts') or {}
        except Exception:
            continue
        for e in sc.values():
            if not isinstance(e, dict): continue
            low = {k.lower(): v for k, v in e.items()}
            aid = low.get('appid')
            if aid is not None and (aid in cands or (aid & 0xFFFFFFFF) in cands):
                n = str(low.get('appname') or '').strip()
                if n: return n

name = from_acf() or from_shortcuts()
if name:
    print(name); sys.exit(0)
sys.exit(1)
PY
}

# Schreibt game_name.txt in den Aufnahme-Ordner (falls ermittelbar und
# noch nicht vorhanden). Ordnername: bg_<appid>_... oder clip_<appid>_...
write_game_name() {
    local dir="$1" name app_id game
    [ -s "$dir/$GAME_NAME_FILE" ] && return 0
    name=$(basename "$dir")
    app_id=$(cut -d'_' -f2 <<< "$name")
    if game=$(resolve_game_name "$app_id") && [ -n "$game" ]; then
        printf '%s\n' "$game" > "$dir/$GAME_NAME_FILE" \
            && log "  Spielname: AppID $app_id -> '$game'"
    else
        log "  Spielname fuer AppID '$app_id' nicht ermittelbar."
    fi
}

# Meldet dem Server einen Ordner (Pfad relativ zu userdata). Der Aufruf
# blockiert, bis der Server fertig abgeholt hat. Exit 0 = sicher abgelegt.
notify_server() {
    local rel="$1"
    # shellcheck disable=SC2086
    ssh $SSH_OPTS -i "$NOTIFY_KEY" -o IdentitiesOnly=yes "$NOTIFY_TARGET" "$DEVICE_USER $rel"
}

handle_folder() {
    local src="${1%/}" name rel attempt=1
    name=$(basename "$src")
    case "$name" in .*) return 0 ;; esac
    # Nur unkritische Namen melden (der Server prueft ebenfalls)
    [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || { log "Ueberspringe Ordner mit ungueltigem Namen: '$name'"; return 0; }
    rel="${src#"$STEAM_USERDATA"/}"

    log "Neu: '$rel' - warte auf Ende des Schreibvorgangs ..."
    wait_until_stable "$src" || return 0
    write_game_name "$src"

    local rc
    while [ "$attempt" -le "$NOTIFY_MAX_ATTEMPTS" ]; do
        log "Melde '$rel' an Server (Versuch $attempt/$NOTIFY_MAX_ATTEMPTS) ..."
        notify_server "$rel"; rc=$?
        if [ "$rc" -eq 0 ]; then
            rm -rf "$src"
            log "'$rel' vom Server abgeholt, lokal geloescht."
            return 0
        fi
        if [ "$rc" -eq 255 ] && ! server_reachable; then
            log "  Verbindung zum Server verloren - '$rel' bleibt liegen."
            return 2
        fi
        log "  Server meldet Fehler (rc=$rc), warte ${NOTIFY_RETRY_DELAY}s ..."
        sleep "$NOTIFY_RETRY_DELAY"
        attempt=$(( attempt + 1 ))
    done
    log "FEHLER: '$rel' nicht abgeholt. Bleibt liegen, naechster Scan versucht es erneut."
    return 1
}

watch_dirs() {
    local d
    for d in "$STEAM_USERDATA"/*/"$WATCH_SUBPATH"; do
        [ -d "$d" ] && printf '%s\n' "$d"
    done
}

# Schneller Erreichbarkeitstest: clip-pull.sh beantwortet "ping" mit Exit 0.
server_reachable() {
    # shellcheck disable=SC2086
    ssh $SSH_OPTS -i "$NOTIFY_KEY" -o IdentitiesOnly=yes "$NOTIFY_TARGET" ping </dev/null >/dev/null 2>&1
}

LAST_REACHABLE=1
scan_once() {
    local wd sub
    # Nur pruefen, wenn ueberhaupt etwas liegt
    local -a pending=()
    while IFS= read -r wd; do
        for sub in "$wd"/*/; do [ -d "$sub" ] && pending+=("$sub"); done
    done < <(watch_dirs)
    [ "${#pending[@]}" -eq 0 ] && return 0

    if ! server_reachable; then
        [ "$LAST_REACHABLE" -eq 1 ] && log "Server nicht erreichbar - ${#pending[@]} Ordner warten (weitere Meldungen unterdrueckt)."
        LAST_REACHABLE=0
        return 0
    fi
    [ "$LAST_REACHABLE" -eq 0 ] && log "Server wieder erreichbar - hole ${#pending[@]} Ordner nach."
    LAST_REACHABLE=1

    while IFS= read -r wd; do
        for sub in "$wd"/*/; do
            [ -d "$sub" ] || continue
            # Rueckgabe 2 = Server weg -> Rest dieses Durchlaufs abbrechen
            handle_folder "$sub"
            if [ $? -eq 2 ]; then LAST_REACHABLE=0; return 0; fi
        done
    done < <(watch_dirs)
}

wait_for_event() {
    if [ "$HAVE_INOTIFY" -eq 1 ]; then
        local -a dirs=()
        mapfile -t dirs < <(watch_dirs)
        if [ "${#dirs[@]}" -gt 0 ]; then
            inotifywait -qq -t "$POLL_INTERVAL" -e create -e moved_to "${dirs[@]}" "$STEAM_USERDATA" 2>/dev/null
            return 0
        fi
    fi
    sleep "$POLL_INTERVAL"
}

trap 'log "clip-mover wird beendet."; exit 0' INT TERM
shopt -s nullglob
log "clip-mover gestartet (Server: $NOTIFY_TARGET | inotify: $HAVE_INOTIFY)"
while IFS= read -r wd; do log "  beobachte: $wd"; done < <(watch_dirs)

while true; do
    scan_once
    wait_for_event
done
