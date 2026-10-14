#!/usr/bin/env bash
#
# clip-pull.sh  -  laeuft auf dem SERVER als erzwungener SSH-Befehl
#
# Eintrag in ~clipsync/.ssh/authorized_keys (eine Zeile):
#   restrict,command="/usr/local/bin/clip-pull.sh" ssh-ed25519 AAAA... deck-notify
# Optional zusaetzlich  from="192.168.x.y"  voranstellen.
#
# Der Deck uebergibt nur einen relativen Pfad (SSH_ORIGINAL_COMMAND), z. B.
#   123456789/gamerecordings/video/bg_1234_20261014_201500
# Dieses Skript prueft ihn streng, holt den Ordner mit eigenem Key vom Deck
# (dort nur rrsync -ro auf userdata), legt ihn atomar ab und meldet per
# Exit-Code Erfolg zurueck. Der Deck loescht danach selbst.

set -uo pipefail

DEST="${CLIP_PULL_DEST:-/media/HDD/steamexport/unfertig/gamerecording/clips}"
PULL_KEY="${CLIP_PULL_KEY:-$HOME/.ssh/clip_pull}"
DECK_USER="${CLIP_PULL_DECK_USER:-steamos}"
# Leer = IP-Adresse der eingehenden Verbindung verwenden (Deck per DHCP).
DECK_HOST="${CLIP_PULL_DECK_HOST:-}"
LOG_FILE="${CLIP_PULL_LOG_FILE:-$HOME/clip-pull.log}"
LOCK_FILE="${CLIP_PULL_LOCK:-$HOME/.clip-pull.lock}"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE"; echo "$*" >&2; }

rel="${SSH_ORIGINAL_COMMAND:-}"

# Erreichbarkeitstest des Decks
[ "$rel" = "ping" ] && exit 0

# Strenge Pruefung: <ziffern>/gamerecordings/video/<name>, kein '..'
if ! [[ "$rel" =~ ^[0-9]+/gamerecordings/video/([A-Za-z0-9._-]+)$ ]]; then
    log "ABGELEHNT: ungueltige Anfrage '$rel'"
    exit 2
fi
name="${BASH_REMATCH[1]}"
case "$name" in .*|*..*) log "ABGELEHNT: '$name'"; exit 2 ;; esac

if [ -z "$DECK_HOST" ]; then
    DECK_HOST="${SSH_CLIENT%% *}"
    [[ "$DECK_HOST" == *:* ]] && DECK_HOST="[$DECK_HOST]"   # IPv6
fi

# Nur ein Abholvorgang gleichzeitig
exec 9>"$LOCK_FILE"
flock -w 600 9 || { log "FEHLER: Lock nicht erhalten"; exit 3; }

mkdir -p "$DEST" || exit 4
tmp="$DEST/.pull-tmp-$name"
final="$DEST/$name"

log "Hole '$rel' von $DECK_HOST ..."
# HostKeyAlias: Host-Key des Decks ist fest hinterlegt, egal welche IP.
# --partial + kein Loeschen von $tmp: Wiederholungen setzen fort.
# --timeout: rsync bricht ab, wenn 60s keine Daten fliessen
# ServerAlive*: tote SSH-Verbindung nach ~90s erkennen
if ! rsync -a --partial --timeout=60 \
        -e "ssh -i $PULL_KEY -o IdentitiesOnly=yes -o BatchMode=yes -o HostKeyAlias=steamdeck -o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=3" \
        "$DECK_USER@$DECK_HOST:$rel/" "$tmp/"; then
    log "FEHLER: rsync fuer '$rel' fehlgeschlagen"
    exit 5
fi

if [ -d "$final" ]; then
    rsync -a "$tmp/" "$final/" && rm -rf "$tmp" || { log "FEHLER beim Zusammenfuehren '$name'"; exit 6; }
else
    mv "$tmp" "$final" || { log "FEHLER: mv '$name'"; exit 6; }
fi
sync -f "$final" 2>/dev/null || true

log "OK: '$name' abgelegt."
exit 0
