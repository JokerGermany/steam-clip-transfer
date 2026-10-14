#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------------
# VAAPI_QP: Qualitätsstufe fuer den h264_vaapi-Encoder (0-51, kleiner
# = bessere Qualitaet/groessere Datei). Ohne explizite Angabe nutzt
# ffmpeg einen Treiber-Default (bei Tests: 20), der spuerbar staerker
# komprimiert als typische Steam-Game-Recordings. Kann per Umgebungs-
# variable ueberschrieben werden: VAAPI_QP=16 ./crop.sh ...
# Hinweis: 18 ist eine Schaetzung fuer "visuell nah am Original" -
# kein gemessener/garantierter Wert, ggf. selbst anpassen/testen.
# -----------------------------------------------------------------
VAAPI_QP="${VAAPI_QP:-1}"

# -----------------------------------------------------------------
# detect_crop <input> [manual_crop]
#
# Fuehrt die Cropdetection per Sampling durch (kurzer Ausschnitt,
# fps=1, cropdetect, Mehrheitsentscheid) und gibt AUSSCHLIESSLICH
# den ermittelten Wert (z.B. "crop=1920:1080:0:0") auf stdout aus.
# Alle Status-/Diagnosemeldungen gehen nach stderr, damit der
# Rueckgabewert per Command-Substitution sauber abgegriffen werden
# kann (CROP=$(detect_crop "$INPUT")).
#
# Kann sowohl innerhalb dieses Skripts genutzt werden, als auch von
# anderen Skripten per "source crop.sh" eingebunden werden.
# Rueckgabecode 2, falls kein stabiler Crop-Wert ermittelt werden
# konnte.
# -----------------------------------------------------------------
detect_crop() {
    local INPUT="$1"
    local MANUAL_CROP="${2:-}"

    if [ -n "$MANUAL_CROP" ]; then
        echo "Manueller Crop: $MANUAL_CROP" >&2
        echo "$MANUAL_CROP"
        return 0
    fi

    local DURATION START SAMPLE_LEN
    DURATION=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$INPUT" 2>/dev/null | cut -d. -f1)

    START=30
    SAMPLE_LEN=90
    if [ -n "${DURATION:-}" ] && [[ "$DURATION" =~ ^[0-9]+$ ]] && [ "$DURATION" -lt 150 ]; then
        START=5
        SAMPLE_LEN=30
    fi

    local CROPS
    mapfile -t CROPS < <(
        ffmpeg -hide_banner -ss "$START" -i "$INPUT" -t "$SAMPLE_LEN" \
            -vf "fps=1,cropdetect=limit=24:round=2:reset=120" \
            -f null - 2>&1 \
        | grep -oE 'crop=[0-9]+:[0-9]+:[0-9]+:[0-9]+'
    )

    if [ ${#CROPS[@]} -eq 0 ]; then
        echo "Keine cropdetect-Werte gefunden." >&2
        return 2
    fi

    local RESULT
    RESULT=$(
        printf '%s\n' "${CROPS[@]}" \
        | sort \
        | uniq -c \
        | sort -nr \
        | awk 'NR==1 {print $2}'
    )

    if [ -z "$RESULT" ]; then
        echo "Konnte keinen stabilen Crop-Wert bestimmen." >&2
        return 2
    fi

    echo "Auto-Crop (häufigster Wert): $RESULT" >&2
    echo "Erkannte Crop-Kandidaten (alle verschiedenen):" >&2
    printf '%s\n' "${CROPS[@]}" | sort | uniq -c | sort -nr >&2

    echo "$RESULT"
}

# -----------------------------------------------------------------
# Ab hier: nur ausfuehren, wenn crop.sh direkt aufgerufen wird
# (nicht, wenn es per "source crop.sh" eingebunden wird).
# -----------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    return 0
fi

INPUT="${1:-}"
MANUAL_CROP="${2:-}"

if [ -z "$INPUT" ]; then
    echo "Verwendung: $0 <video-datei> [crop=BREITE:HÖHE:X:Y]"
    exit 1
fi

if [ ! -f "$INPUT" ]; then
    echo "Datei nicht gefunden: $INPUT"
    exit 1
fi

pfad="/media/HDD"
frei_kb=$(df --output=avail -k "$pfad" | tail -n 1)
grenze_kb=10000000
# if [ "$frei_kb" -lt "$grenze_kb" ]; then
#     echo "Weniger als 10GB Speicher frei auf $pfad. Skript wird beendet."
#     exit 1
# fi

CODEC=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$INPUT")
WIDTH=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$INPUT")
HEIGHT=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$INPUT")

if [ -z "$CODEC" ] || [ -z "$WIDTH" ] || [ -z "$HEIGHT" ]; then
    echo "Konnte Codec oder Auflösung nicht ermitteln."
    exit 2
fi

echo "Erkannter Codec: $CODEC"

BASENAME="${INPUT%.*}"

USE_VAAPI=true
OUTPUT_EXT="mp4"

case "$CODEC" in
    vp8|vp9|av1)
        USE_VAAPI=false
        OUTPUT_EXT="webm"
        ;;
    h264|hevc)
        USE_VAAPI=true
        OUTPUT_EXT="mp4"
        ;;
    *)
        USE_VAAPI=false
        OUTPUT_EXT="mkv"
        ;;
esac

FIRST=$(detect_crop "$INPUT" "$MANUAL_CROP") || exit $?

IFS='=:' read -r _ CROP_W CROP_H CROP_X CROP_Y <<< "$FIRST"

for value in "$CROP_W" "$CROP_H" "$CROP_X" "$CROP_Y" "$WIDTH" "$HEIGHT"; do
    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        echo "Ungültiger Zahlenwert erkannt: $value"
        exit 2
    fi
done

if [ "$CROP_W" -le 0 ] || [ "$CROP_H" -le 0 ]; then
    echo "Ungültige Crop-Größe: ${CROP_W}x${CROP_H}"
    exit 2
fi

if [ "$CROP_X" -lt 0 ] || [ "$CROP_Y" -lt 0 ]; then
    echo "Ungültige Crop-Position: ${CROP_X}:${CROP_Y}"
    exit 2
fi

if [ $((CROP_X + CROP_W)) -gt "$WIDTH" ] || [ $((CROP_Y + CROP_H)) -gt "$HEIGHT" ]; then
    echo "Crop liegt außerhalb des Videos: Video=${WIDTH}x${HEIGHT}, Crop=${CROP_W}:${CROP_H}:${CROP_X}:${CROP_Y}"
    exit 2
fi

if [ "$CROP_W" -eq "$WIDTH" ] && [ "$CROP_H" -eq "$HEIGHT" ] && [ "$CROP_X" -eq 0 ] && [ "$CROP_Y" -eq 0 ]; then
    echo "Kein Crop notwendig."
    exit 0
fi

echo "Crop-Parameter: $CROP_W:$CROP_H:$CROP_X:$CROP_Y"
echo "Zuschnitt: ${WIDTH}x${HEIGHT} -> ${CROP_W}x${CROP_H}"

OUTPUT_FILE="${BASENAME}_geschnitten.${OUTPUT_EXT}"

if $USE_VAAPI; then
    ffmpeg -hide_banner -y \
        -hwaccel vaapi \
        -hwaccel_device /dev/dri/renderD128 \
        -hwaccel_output_format vaapi \
        -i "$INPUT" \
        -vf "hwdownload,format=yuv420p,$FIRST,format=nv12,hwupload" \
        -fps_mode cfr \
        -c:v h264_vaapi \
        -qp "$VAAPI_QP" \
        -c:a copy \
        "$OUTPUT_FILE"
else
    if [ "$OUTPUT_EXT" = "webm" ]; then
        ffmpeg -hide_banner -y \
            -i "$INPUT" \
            -vf "$FIRST" \
            -c:v libvpx-vp9 \
            -crf 30 \
            -b:v 0 \
            -c:a libopus \
            "$OUTPUT_FILE"
    else
        ffmpeg -hide_banner -y \
            -i "$INPUT" \
            -vf "$FIRST" \
            -c:v libx264 \
            -preset medium \
            -crf 23 \
            -c:a copy \
            "$OUTPUT_FILE"
    fi
fi

echo "Fertig: $OUTPUT_FILE"
