#!/usr/bin/env bash
set -x

# Cropdetection wird ausgelagert nach crop.sh (Funktion detect_crop).
# Annahme: crop.sh liegt im selben Verzeichnis wie dieses Skript.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -f "${SCRIPT_DIR}/crop.sh" ]; then
    echo "Fehler: crop.sh nicht gefunden unter ${SCRIPT_DIR}/crop.sh" >&2
    echo "Bitte crop.sh in dasselbe Verzeichnis wie mpdToMP4.sh legen." >&2
    exit 1
fi

# shellcheck source=crop.sh
source "${SCRIPT_DIR}/crop.sh"

if ! declare -f detect_crop >/dev/null; then
    echo "Fehler: Funktion detect_crop wurde nicht aus crop.sh geladen." >&2
    exit 1
fi

# Globale Konfiguration Lokal
pfad="/media/HDD"
grenze_kb=$((10000000)) # 10 GB lokaler Puffer
base_path="/media/HDD/steamexport/unfertig/gamerecording/clips"
#base_path="/home/jokergermany/.steam/debian-installation/userdata/2208717/gamerecordings/video"
#base_path="/media/HDD/steamexport/gamerecording/clips"
EXPORT_DIR="/media/HDD/steamexport/"

# Globale Konfiguration Remote (SSH / rsync)
REMOTE_USER="root"
REMOTE_HOST="192.168.2.10"
REMOTE_DIR="/Raid1-1/creator/unfertig"

video_mode=false

# -----------------------------------------------------------------
# Spielordner-Modus (Schalter)
# -----------------------------------------------------------------
# Ist dieser Schalter aktiv, wird aus der AppID der Spielename
# LOKAL ermittelt (Steam UND Steamfremde Spiele), ein Unterordner
# mit dem Spielenamen unterhalb von EXPORT_DIR angelegt (falls nicht
# vorhanden) und die Videodateien (geschnitten + ungeschnitten) dort
# gespeichert. Kann keine AppID/kein Name ermittelt werden, wird -
# wie bisher - direkt in EXPORT_DIR gespeichert.
#
# Aktivierung dauerhaft: gamefolder_mode=true setzen.
# Aktivierung pro Aufruf: -gamefolder / --gamefolder
gamefolder_mode=false

# -----------------------------------------------------------------
# Limit-Modus (Schalter)
# -----------------------------------------------------------------
# Ist dieser Schalter aktiv, wird pro AppID nur so lange gearbeitet,
# bis im Zielverzeichnis (Spielordner bei -gamefolder, sonst
# EXPORT_DIR) zwei VERSCHIEDENE Videos derselben AppID liegen.
# Geschnittene und ungeschnittene Fassung einer Aufnahme teilen sich
# das Namenspraefix "<datum>_<appid>_" und zaehlen daher als EIN
# Video. Ist die Grenze bereits erreicht, wird der betreffende
# Quellordner uebersprungen (nicht verarbeitet, nicht geloescht) und
# bleibt fuer einen spaeteren Lauf erhalten.
#
# Aktivierung dauerhaft: limit_mode=true setzen.
# Aktivierung pro Aufruf: -limit / --limit
# Grenze anpassbar per Umgebungsvariable, z.B.:
#   VIDEO_LIMIT_PRO_APPID=3 ./mpdToMP4.sh -gamefolder -limit
limit_mode=false
VIDEO_LIMIT_PRO_APPID="${VIDEO_LIMIT_PRO_APPID:-2}"

# Steam-Wurzelverzeichnisse, in denen lokal nach Spielenamen gesucht
# wird:
#   - appmanifest_<appid>.acf   (installierte Steam-Spiele)
#   - <root>/steamapps/libraryfolders.vdf (weitere Bibliotheken)
#   - <root>/userdata/*/config/shortcuts.vdf (Steamfremde Spiele)
# Bei Bedarf anpassen/ergaenzen. Nicht existierende Pfade werden
# ignoriert.
STEAM_ROOTS=(
    "/home/jokergermany/.steam/debian-installation"
    "/home/jokergermany/.steam/steam"
    "/home/jokergermany/.local/share/Steam"
    "${HOME}/.steam/steam"
    "${HOME}/.local/share/Steam"
)

# Optionale, manuell gepflegte Zuordnungsdatei AppID -> Name.
# Format je Zeile:  <appid>=<Spielename>   (oder <appid><TAB><Name>)
# Zeilen mit fuehrendem # werden ignoriert. Diese Datei hat Vorrang
# vor der automatischen Ermittlung und ist der zuverlaessige Weg,
# einzelne (z.B. nie erkannte) Spiele fest zuzuordnen.
APPID_NAME_MAP="${SCRIPT_DIR}/appid_names.conf"

# Vom Quellgeraet (clip-mover.sh auf dem Steam Deck) mitgelieferter
# Spielname. Liegt als einzeilige Textdatei im Aufnahme-Ordner. Wichtig
# v. a. fuer Steamfremde Spiele, deren shortcuts.vdf nur auf dem Deck
# existiert. Reihenfolge: APPID_NAME_MAP > diese Datei > lokale Suche.
GAME_NAME_FILE="${GAME_NAME_FILE:-game_name.txt}"

usage() {
    echo "Verwendung: $0 [OPTIONS]"
    echo "Optionen:"
    echo "  -video, --video          Video-Mode (clips -> video/clips)"
    echo "  -gamefolder, --gamefolder Spielename aus AppID ermitteln und"
    echo "                           Ausgabe in Unterordner je Spiel ablegen"
    echo "  -limit, --limit          Pro AppID nur arbeiten, bis zwei"
    echo "                           verschiedene Videos im Zielverzeichnis"
    echo "                           liegen (geschnitten+ungeschnitten = ein"
    echo "                           Video). Grenze per VIDEO_LIMIT_PRO_APPID."
    echo "  -h, --help               Diese Hilfe anzeigen"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -video|--video)
            video_mode=true
            shift
            ;;
        -gamefolder|--gamefolder)
            gamefolder_mode=true
            shift
            ;;
        -limit|--limit)
            limit_mode=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unbekanntes Argument: $1"
            usage
            exit 1
            ;;
    esac
done

if $video_mode; then
    case "$base_path" in
        */clips)
            base_path="${base_path%/clips}/video"
            ;;
        clips)
            base_path="video"
            ;;
    esac
fi

if ! [[ "$VIDEO_LIMIT_PRO_APPID" =~ ^[0-9]+$ ]] || [ "$VIDEO_LIMIT_PRO_APPID" -lt 1 ]; then
    echo "Fehler: VIDEO_LIMIT_PRO_APPID muss eine positive Ganzzahl sein (aktuell: '$VIDEO_LIMIT_PRO_APPID')." >&2
    exit 1
fi

# Im Limit-Modus wird immer pro Spielordner gezaehlt. Daher wird der
# Spielordner-Modus hier automatisch aktiviert.
if $limit_mode && ! $gamefolder_mode; then
    gamefolder_mode=true
    echo "Limit-Modus aktiv: Spielordner-Modus (-gamefolder) wird automatisch aktiviert." >&2
fi

mkdir -p "$EXPORT_DIR"

# -----------------------------------------------------------------
# sanitize_name <string>
# Wandelt einen Spielenamen in einen sicheren Ordnernamen um:
#   - problematische Zeichen (/ \ : * ? " < > |) -> _
#   - Steuerzeichen entfernen
#   - fuehrende/abschliessende Leerzeichen und Punkte entfernen
# Gibt bei leerem Ergebnis nichts aus (Aufrufer behandelt das als
# "nicht ermittelbar").
# -----------------------------------------------------------------
sanitize_name() {
    local raw="$1" cleaned
    # Steuerzeichen entfernen
    cleaned=$(printf '%s' "$raw" | tr -d '\000-\037')
    # problematische Zeichen ersetzen
    cleaned=$(printf '%s' "$cleaned" | sed -e 's#[/\\:*?"<>|]#_#g')
    # fuehrende/abschliessende Leerzeichen entfernen
    cleaned="${cleaned#"${cleaned%%[![:space:]]*}"}"
    cleaned="${cleaned%"${cleaned##*[![:space:]]}"}"
    # abschliessende Punkte/Leerzeichen entfernen
    cleaned="${cleaned%"${cleaned##*[![:space:].]}"}"
    printf '%s' "$cleaned"
}

# -----------------------------------------------------------------
# resolve_game_name <app_id>
# Ermittelt den Spielenamen LOKAL. Reihenfolge:
#   1. manuelle Zuordnungsdatei (APPID_NAME_MAP)     -> Vorrang
#   2. Steam appmanifest_<appid>.acf                 (Steam-Spiele)
#   3. shortcuts.vdf                                 (Steamfremde)
# Gibt den (unbereinigten) Namen auf stdout aus; Rueckgabe 0 bei
# Treffer, 1 falls nichts gefunden wurde. Es findet KEIN Netzwerk-
# zugriff statt - alles rein lokal.
# -----------------------------------------------------------------
resolve_game_name() {
    local app_id="$1" line key val name

    if [ -z "$app_id" ] || [ "$app_id" = "unknown" ] || ! [[ "$app_id" =~ ^[0-9]+$ ]]; then
        return 1
    fi

    # 1) Manuelle Zuordnungsdatei (hat Vorrang)
    if [ -f "$APPID_NAME_MAP" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in
                ''|\#*) continue ;;
            esac
            # erlaubt "appid=Name" und "appid<TAB>Name"
            key="${line%%[=$'\t']*}"
            val="${line#*[=$'\t']}"
            key="${key//[[:space:]]/}"
            if [ "$key" = "$app_id" ] && [ -n "$val" ]; then
                printf '%s\n' "$val"
                return 0
            fi
        done < "$APPID_NAME_MAP"
    fi

    # Nur die Zuordnungsdatei gewuenscht -> hier abbrechen
    [ -n "${APPID_NAME_MAP_ONLY:-}" ] && return 1

    # 2)/3) Automatische Ermittlung per Python (robuster Parser fuer
    #       .acf-Text und binaere shortcuts.vdf).
    if command -v python3 >/dev/null 2>&1; then
        name=$(python3 - "$app_id" "${STEAM_ROOTS[@]}" <<'PY'
import sys, os, glob, re

def find_steamapps_dirs(roots):
    dirs = []
    for r in roots:
        sa = os.path.join(r, 'steamapps')
        if os.path.isdir(sa):
            dirs.append(sa)
        lf = os.path.join(sa, 'libraryfolders.vdf')
        try:
            txt = open(lf, encoding='utf-8', errors='replace').read()
            for p in re.findall(r'"path"\s*"([^"]+)"', txt):
                d = os.path.join(p, 'steamapps')
                if os.path.isdir(d):
                    dirs.append(d)
        except OSError:
            pass
    seen, out = set(), []
    for d in dirs:
        if d not in seen:
            seen.add(d)
            out.append(d)
    return out

def from_acf(app_id, roots):
    for sa in find_steamapps_dirs(roots):
        f = os.path.join(sa, 'appmanifest_%s.acf' % app_id)
        if os.path.isfile(f):
            try:
                txt = open(f, encoding='utf-8', errors='replace').read()
                m = re.search(r'"name"\s*"([^"]*)"', txt)
                if m and m.group(1).strip():
                    return m.group(1).strip()
            except OSError:
                pass
    return None

def parse_vdf(data, i=0):
    res = {}
    while i < len(data):
        t = data[i]; i += 1
        if t == 0x08:
            return res, i
        end = data.index(0, i)
        key = data[i:end].decode('utf-8', 'replace'); i = end + 1
        if t == 0x00:
            val, i = parse_vdf(data, i); res[key] = val
        elif t == 0x01:
            end = data.index(0, i)
            res[key] = data[i:end].decode('utf-8', 'replace'); i = end + 1
        elif t == 0x02:
            res[key] = int.from_bytes(data[i:i+4], 'little', signed=True); i += 4
        elif t == 0x07:
            res[key] = int.from_bytes(data[i:i+8], 'little', signed=False); i += 8
        else:
            raise ValueError('unknown type %d' % t)
    return res, i

def from_shortcuts(app_id, roots):
    try:
        target = int(app_id)
    except ValueError:
        return None
    # Steamfremde AppIDs werden in shortcuts.vdf als signed int32
    # gespeichert; der Aufnahme-Ordnername kann die unsigned-Form
    # tragen. Deshalb gegen beide Formen matchen.
    cands = {target, target & 0xFFFFFFFF}
    if target >= 2**31:
        cands.add(target - 2**32)
    # Aufnahme-Ordner nutzen fuer Steamfremde Spiele die 64-bit GameID
    # (appid32 << 32 | flags, z.B. 0x02000000). In shortcuts.vdf steht
    # aber nur die 32-bit-AppID -> obere 32 Bit als Kandidat ergaenzen.
    if target > 0xFFFFFFFF:
        high = target >> 32
        cands.add(high)
        if high >= 2**31:
            cands.add(high - 2**32)
    for r in roots:
        for f in glob.glob(os.path.join(r, 'userdata', '*', 'config', 'shortcuts.vdf')):
            try:
                data = open(f, 'rb').read()
            except OSError:
                continue
            try:
                root, _ = parse_vdf(data, 0)
            except Exception:
                continue
            sc = root.get('shortcuts') or {}
            if not isinstance(sc, dict):
                continue
            for entry in sc.values():
                if not isinstance(entry, dict):
                    continue
                low = {k.lower(): v for k, v in entry.items()}
                aid = low.get('appid')
                if aid is None:
                    continue
                if aid in cands or (aid & 0xFFFFFFFF) in cands:
                    name = low.get('appname')
                    if name and str(name).strip():
                        return str(name).strip()
    return None

app_id = sys.argv[1]
roots = sys.argv[2:]
name = from_acf(app_id, roots) or from_shortcuts(app_id, roots)
if name:
    print(name)
    sys.exit(0)
sys.exit(1)
PY
        )
        if [ -n "$name" ]; then
            printf '%s\n' "$name"
            return 0
        fi
    else
        # Fallback ohne python3: nur Steam-.acf per Glob (keine
        # libraryfolders-Aufloesung, keine shortcuts.vdf).
        echo "Hinweis: python3 nicht gefunden - nur eingeschraenkte AppID-Aufloesung (.acf)." >&2
        local root acf
        for root in "${STEAM_ROOTS[@]}"; do
            acf="${root}/steamapps/appmanifest_${app_id}.acf"
            if [ -f "$acf" ]; then
                name=$(sed -n 's/.*"name"[[:space:]]*"\(.*\)".*/\1/p' "$acf" | head -n 1)
                if [ -n "$name" ]; then
                    printf '%s\n' "$name"
                    return 0
                fi
            fi
        done
    fi

    return 1
}

# -----------------------------------------------------------------
# Gemeinsame ffmpeg-Basisoptionen fuer stabile A/V-Synchronisation
# -fflags +genpts        : erzeugt konsistente Timestamps neu,
#                          falls das DASH-Manifest (session.mpd)
#                          fehlende/inkonsistente PTS liefert.
# -avoid_negative_ts make_zero : verhindert negative/verschobene
#                          Startzeitstempel, die beim Remux/Copy
#                          zu A/V-Versatz fuehren koennen.
# -----------------------------------------------------------------
FFMPEG_INPUT_OPTS=(-fflags +genpts -avoid_negative_ts make_zero)

# -----------------------------------------------------------------
# VAAPI_QP: siehe Kommentar in crop.sh. Seit der Umstellung von
# reinem "-codec copy" auf echtes Re-Encoding (fuer -fps_mode cfr,
# siehe unten) wird sonst ein unkontrollierter Treiber-Default (bei
# Tests: 20) genutzt, der die Datei staerker komprimiert als das
# Original. Ueberschreibbar per: VAAPI_QP=16 ./mpdToMP4.sh ...
# -----------------------------------------------------------------
VAAPI_QP="${VAAPI_QP:-1}"

# -----------------------------------------------------------------
# Toleranz fuer den Dauer-Abgleich zwischen Quelle (session.mpd) und
# fertigem Output. Ersetzt die alte Datei-Groessen-Pruefung, die bei
# echtem Re-Encoding (statt reinem Remux) systematisch fehlschlaegt,
# weil re-encodete Dateien legitim kleiner sein koennen als das
# Original. Ein Dauer-Abgleich prueft stattdessen, ob der Output
# ungefaehr die gleiche Laenge hat wie die Quelle (Indiz gegen
# abgebrochene/unvollstaendige Verarbeitung).
# -----------------------------------------------------------------
DURATION_TOLERANZ_SEK=3

# -----------------------------------------------------------------
# Merkt sich Quellordner, die im Limit-Modus uebersprungen wurden
# (Grenze pro AppID bereits erreicht). So werden sie bei der
# Ordnerauswahl nicht erneut gewaehlt (sonst Endlosschleife, da der
# Ordner nicht geloescht wird). Die Liste gilt nur fuer den aktuellen
# Lauf; bei einem spaeteren Aufruf wird erneut geprueft.
# -----------------------------------------------------------------
declare -A skip_folders

while true; do
    frei_kb=$(df --output=avail -k "$pfad" | tail -n 1 | tr -d ' ')
    if [ -z "$frei_kb" ] || ! [[ "$frei_kb" =~ ^[0-9]+$ ]]; then
        echo "Fehler: Freier Speicherplatz auf $pfad konnte nicht ermittelt werden."
        exit 1
    fi

    if [ "$frei_kb" -lt "$grenze_kb" ]; then
        echo "Weniger als 10GB Speicher frei auf $pfad. Skript wird beendet."
        exit 1
    fi

    if ! cd "$base_path"; then
        echo "Fehler: Verzeichnis $base_path nicht gefunden."
        exit 1
    fi

    # Aeltesten Ordner waehlen, dabei im Limit-Modus bereits
    # uebersprungene Ordner ueberspringen (sie bleiben auf Platte,
    # werden aber nicht erneut ausgewaehlt -> kein Endlosloop).
    videoFolder=""
    while IFS= read -r cand; do
        [ -z "$cand" ] && continue
        if [ -n "${skip_folders["$cand"]:-}" ]; then
            continue
        fi
        videoFolder="$cand"
        break
    done < <(find . -maxdepth 1 -mindepth 1 -type d -printf '%T@ %p\n' | sort -n | cut -d' ' -f2-)

    if [ -z "$videoFolder" ]; then
        echo "Keine weiteren Ordner zum Verarbeiten gefunden. Fertig!"
        exit 0
    fi

    folder_name=$(basename "$videoFolder")

    # Mitgelieferten Spielnamen einlesen (erste Zeile, max. 200 Zeichen)
    supplied_game_name=""
    if [ -s "${videoFolder}/${GAME_NAME_FILE}" ]; then
        IFS= read -r supplied_game_name < "${videoFolder}/${GAME_NAME_FILE}" || true
        supplied_game_name="${supplied_game_name:0:200}"
        [ -n "$supplied_game_name" ] && echo "Mitgelieferter Spielname gefunden: '$supplied_game_name'"
    fi

    # -----------------------------------------------------------------
    # Ordnertyp erkennen:
    #   bg_<appid>_<datum>_<zeit>   -> Videodateien (session.mpd) liegen
    #                                  direkt im Ordner
    #   clip_<appid>_<datum>_<zeit> -> Videodateien liegen unter
    #                                  video/<unterordner>/
    # Im Video-Mode wird wie bisher immer direkt im Ordner gearbeitet.
    # -----------------------------------------------------------------
    flat_folder=false
    if $video_mode || [[ "$folder_name" == bg_* ]] || [ -f "${videoFolder}/session.mpd" ]; then
        flat_folder=true
    fi

    if $flat_folder; then
        if ! cd "$videoFolder"; then
            echo "Fehler: Ordner $videoFolder konnte nicht geoeffnet werden."
            exit 1
        fi
    else
        if ! cd "${videoFolder}/video/"; then
            echo "Unterordner video/ existiert nicht in $videoFolder."
            exit 1
        fi

        shopt -s nullglob
        dirs=(*/)
        shopt -u nullglob
        count=${#dirs[@]}

        if [ "$count" -ne 1 ]; then
            echo "Warnung: Es sind $count Ordner in ${videoFolder}/video/ vorhanden. Vorgang abgebrochen."
            exit 1
        fi

        cd "${dirs[0]}" || exit 1
    fi

    if [ ! -f "session.mpd" ]; then
        echo "Fehler: session.mpd nicht gefunden in $(pwd)"
        exit 1
    fi

    input_size=$(find . -type f -exec stat -c %s {} + | awk '{sum+=$1} END {print sum}')
    input_size=${input_size:-0}

    frei_bytes=$((frei_kb * 1024))
    if [ "$input_size" -gt "$frei_bytes" ]; then
        echo "Zu wenig lokaler Speicherplatz frei in $pfad. Skript beendet."
        exit 1
    fi

    prefix_part=$(echo "$folder_name" | cut -d'_' -f1)
    app_id=$(echo "$folder_name" | cut -d'_' -f2)
    date_part=$(echo "$folder_name" | cut -d'_' -f3)
    time_part=$(echo "$folder_name" | cut -d'_' -f4)

    if [[ ${#date_part} -eq 8 ]] && [[ ${#time_part} -eq 6 ]]; then
        date_str="${date_part:0:4}-${date_part:4:2}-${date_part:6:2}_${time_part:0:2}-${time_part:2:2}-${time_part:4:2}"
    else
        first_file=$(find . -maxdepth 1 -type f -printf '%T@ %p\n' | sort -n | head -n 1 | cut -d' ' -f2-)
        if [ -z "$first_file" ]; then
            echo "Fehler: Kein Fallback-Timestamp moeglich, da keine Dateien gefunden wurden."
            exit 1
        fi

        timestamp=$(stat --format='%W' "$first_file" 2>/dev/null)
        if [ -z "$timestamp" ] || [ "$timestamp" = "0" ]; then
            timestamp=$(stat --format='%Y' "$first_file")
        fi

        date_str=$(date -d "@$timestamp" +"%Y-%m-%d_%H-%M-%S")
        app_id=$(echo "$folder_name" | cut -d'_' -f2)
        if [ -z "$app_id" ] || [ "$app_id" = "$folder_name" ]; then
            app_id="unknown"
        fi
    fi

    # -----------------------------------------------------------------
    # Zielverzeichnis bestimmen. Standard: EXPORT_DIR direkt.
    # Bei aktivem Spielordner-Modus: Spielename aus AppID lokal
    # ermitteln und - falls gefunden - in Unterordner je Spiel
    # ablegen. Ohne Treffer bleibt es bei EXPORT_DIR.
    # -----------------------------------------------------------------
    out_dir="$EXPORT_DIR"
    if $gamefolder_mode; then
        game_name=""
        game_name_raw=""
        game_name_src=""
        # 1) manuelle Zuordnung hat Vorrang (nur Map-Datei pruefen)
        if [ -f "$APPID_NAME_MAP" ] && game_name_raw=$(APPID_NAME_MAP_ONLY=1 resolve_game_name "$app_id"); then
            game_name_src="Zuordnungsdatei"
        # 2) vom Deck mitgeliefert
        elif [ -n "$supplied_game_name" ]; then
            game_name_raw="$supplied_game_name"
            game_name_src="mitgeliefert ($GAME_NAME_FILE)"
        # 3) lokale Suche (acf / shortcuts.vdf)
        elif game_name_raw=$(resolve_game_name "$app_id"); then
            game_name_src="lokal ermittelt"
        fi
        [ -n "$game_name_raw" ] && game_name=$(sanitize_name "$game_name_raw")

        if [ -n "$game_name" ]; then
            out_dir="${EXPORT_DIR%/}/${game_name}/"
            if ! mkdir -p "$out_dir"; then
                echo "Warnung: Unterordner '$out_dir' konnte nicht angelegt werden. Speichere in $EXPORT_DIR." >&2
                out_dir="$EXPORT_DIR"
            else
                echo "Spielordner-Modus: AppID $app_id -> '$game_name' [$game_name_src] (Ziel: $out_dir)"
            fi
        else
            echo "Spielordner-Modus: Kein Spielename fuer AppID '$app_id' ermittelbar. Speichere in $EXPORT_DIR." >&2
        fi
    fi

    # -----------------------------------------------------------------
    # Limit-Modus: pro AppID nur arbeiten, bis zwei verschiedene Videos
    # im Zielverzeichnis liegen. Ein "Video" ist eine Aufnahme,
    # eindeutig ueber das Praefix "<datum>_<appid>_"; geschnittene und
    # ungeschnittene Fassung teilen dieses Praefix und zaehlen als EIN
    # Video. Ist die Grenze erreicht, wird der Quellordner uebersprungen
    # (nicht verarbeitet, nicht geloescht) und bleibt erhalten.
    # Bei nicht ermittelbarer AppID ("unknown"/nicht numerisch) ist eine
    # zuverlaessige Zaehlung pro Spiel nicht moeglich. Solche Ordner
    # werden im Limit-Modus NICHT verarbeitet, sondern mit einer Warnung
    # uebersprungen (bleiben auf Platte erhalten).
    # -----------------------------------------------------------------
    if $limit_mode; then
        if ! [[ "$app_id" =~ ^[0-9]+$ ]]; then
            echo "Warnung: Limit-Modus - AppID nicht ermittelbar ('$app_id'). Ordner ${videoFolder} wird nicht verarbeitet und uebersprungen." >&2
            skip_folders["$videoFolder"]=1
            cd "$base_path" || exit 1
            continue
        fi

        existing_videos=$(find "$out_dir" -maxdepth 1 -type f \
                -name "*_${app_id}_*.mp4" 2>/dev/null \
            | sed -E "s#.*/##; s#_${app_id}_[^/]*\$#_${app_id}#" \
            | sort -u | grep -c . || true)
        existing_videos=${existing_videos:-0}

        if [ "$existing_videos" -ge "$VIDEO_LIMIT_PRO_APPID" ]; then
            echo "Limit-Modus: AppID $app_id hat bereits ${existing_videos} verschiedene Video(s) in ${out_dir} (Grenze: ${VIDEO_LIMIT_PRO_APPID}). Ueberspringe Ordner ${videoFolder}." >&2
            skip_folders["$videoFolder"]=1
            cd "$base_path" || exit 1
            continue
        fi
    fi

    base_output="${out_dir%/}/${date_str}_${app_id}_"

    # -----------------------------------------------------------------
    # Cropdetect: ausgelagert nach crop.sh (detect_crop). Dort erfolgt
    # Sampling (kurzer Ausschnitt statt gesamtem Video) + Mehrheits-
    # entscheid ueber die Crop-Kandidaten.
    # -----------------------------------------------------------------
    do_crop=false
    FIRST=""

    if FIRST=$(detect_crop "session.mpd"); then
        read -r VIDEO_WIDTH VIDEO_HEIGHT < <(
            ffprobe -v error -select_streams v:0 \
                -show_entries stream=width,height \
                -of csv=p=0:s=x "session.mpd" | tr 'x' ' '
        )

        if [ -z "$VIDEO_WIDTH" ] || [ -z "$VIDEO_HEIGHT" ]; then
            echo "Konnte Videoauflösung nicht ermitteln!"
            exit 2
        fi

        IFS='=:' read -r _ CROP_W CROP_H CROP_X CROP_Y <<< "$FIRST"

        if [[ "$CROP_W" -ne "$VIDEO_WIDTH" ]] || [[ "$CROP_H" -ne "$VIDEO_HEIGHT" ]]; then
            do_crop=true
        fi
    else
        echo "Cropdetection lieferte keinen stabilen Wert, es wird ohne Crop weiterverarbeitet."
    fi

    # -----------------------------------------------------------------
    # Encoding/Copy: genpts + avoid_negative_ts + fps_mode cfr sorgen
    # dafuer, dass Audio/Video auf einer gemeinsamen, konstanten
    # Zeitbasis landen, auch wenn die DASH-Quelle VFR/Luecken hat.
    # -c:a copy bleibt unveraendert (kein Audio-Reencode noetig).
    # -----------------------------------------------------------------
    if $do_crop; then
        echo "Erstelle gecroppte Version..."
        ffmpeg "${FFMPEG_INPUT_OPTS[@]}" \
            -hwaccel vaapi \
            -hwaccel_device /dev/dri/renderD128 \
            -hwaccel_output_format vaapi \
            -i "session.mpd" \
            -vf "hwdownload,format=yuv420p,$FIRST,format=nv12,hwupload" \
            -c:v h264_vaapi \
            -qp "$VAAPI_QP" \
            -fps_mode cfr \
            -c:a copy \
            "${base_output}.mp4" || exit 1

        final_output="${base_output}ungeschnitten.mp4"
    else
        final_output="${base_output}.mp4"
    fi

    # -----------------------------------------------------------------
    # WICHTIG: "-codec copy" (reiner Remux) uebernimmt evtl. vorhandene
    # A/V-Versaetze aus dem DASH-Manifest 1:1. genpts + avoid_negative_ts
    # sind hier die einzige Korrekturmoeglichkeit, da kein Re-Encode
    # stattfindet. Falls trotzdem Desync auftritt, muss hier auf
    # Re-Encode (wie im do_crop-Zweig) umgestellt werden.
    # -----------------------------------------------------------------
    ffmpeg "${FFMPEG_INPUT_OPTS[@]}" \
    -hwaccel vaapi \
    -hwaccel_device /dev/dri/renderD128 \
    -hwaccel_output_format vaapi \
    -i "session.mpd" \
    -vf "hwdownload,format=yuv420p,format=nv12,hwupload" \
    -c:v h264_vaapi \
    -qp "$VAAPI_QP" \
    -fps_mode cfr \
    -c:a copy \
    "$final_output"

    rc=$?

    validierung_ok=false

    if [ $rc -eq 0 ] && [ -s "$final_output" ]; then
        # ---------------------------------------------------------
        # 1) Grobe Plausibilitaet: Datei nicht verdaechtig winzig
        #    (faengt z.B. abgebrochene/leere Outputs ab, die ffmpeg
        #    trotzdem mit rc=0 verlassen haben koennte).
        # ---------------------------------------------------------
        output_stat=$(stat -c%s "$final_output")

        if [ "$output_stat" -lt 1000000 ]; then
            echo "Warnung: Output-Datei ist verdaechtig klein (${output_stat} Bytes)." >&2
        else
            # -------------------------------------------------------
            # 2) Dauer-Abgleich Quelle vs. Output. ffprobe kann nur
            #    lesen, wenn der Output nicht korrupt/abgeschnitten
            #    ist - das ist zugleich ein zusaetzlicher Integritaets-
            #    check. Fehlt die Dauer (z.B. leerer/kaputter Output),
            #    schlaegt die Pruefung bewusst fehl.
            # -------------------------------------------------------
            input_duration=$(ffprobe -v error -show_entries format=duration \
                -of default=noprint_wrappers=1:nokey=1 "session.mpd" 2>/dev/null | cut -d. -f1)
            output_duration=$(ffprobe -v error -show_entries format=duration \
                -of default=noprint_wrappers=1:nokey=1 "$final_output" 2>/dev/null | cut -d. -f1)

            if [[ "$input_duration" =~ ^[0-9]+$ ]] && [[ "$output_duration" =~ ^[0-9]+$ ]]; then
                diff=$(( input_duration - output_duration ))
                (( diff < 0 )) && diff=$(( -diff ))

                if (( diff <= DURATION_TOLERANZ_SEK )); then
                    validierung_ok=true
                else
                    echo "Warnung: Dauer weicht zu stark ab (Quelle=${input_duration}s, Output=${output_duration}s, Diff=${diff}s)." >&2
                fi
            else
                echo "Warnung: Konnte Dauer von Quelle oder Output nicht ermitteln (Quelle='$input_duration', Output='$output_duration')." >&2
            fi
        fi
    fi

    if $validierung_ok; then
        echo "Lokale Bearbeitung erfolgreich (Dauer stimmt ueberein). Quelle wird entfernt..."

        cd "$base_path" || exit 1
        rm -rf "$videoFolder"

        echo "Ordner $videoFolder verarbeitet. MP4 liegt in $out_dir."
        continue
    fi

    echo "Fehler bei der lokalen Verarbeitung oder Validierung fehlgeschlagen. Quelle bleibt erhalten: $(pwd)" >&2
    exit 1
done
