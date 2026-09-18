#!/bin/bash
# Шаг 1: медиафайл (видео ИЛИ аудио) -> transcript.txt
# Использование: ./transcribe.sh "/путь/к/файлу" "/папка/для/результата" [язык|auto] [/путь/к/модели.bin] ["словарь терминов"] [/путь/к/дорожке микрофона]
#
# Шестой аргумент — отдельная дорожка микрофона. Если он передан, первый файл
# считается системным звуком (собеседники), дорожки распознаются по отдельности
# и сшиваются в диалог с подписями «Я» и «Собеседники»: наложенная речь так не
# портит распознавание, и в саммари видно, кто что сказал.
set -e

INPUT_FILE="$1"
OUT_DIR="$2"
LANGUAGE="${3:-auto}"
MODEL="${4:-$HOME/whisper-models/ggml-medium.bin}"
GLOSSARY="$5"
MIC_FILE="$6"
VAD_MODEL="$HOME/whisper-models/ggml-silero-v5.1.2.bin"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ -z "$INPUT_FILE" ] || [ -z "$OUT_DIR" ]; then
  echo "Использование: ./transcribe.sh <входной файл> <папка результата> [язык] [модель] [словарь] [дорожка микрофона]"
  exit 1
fi

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

mkdir -p "$OUT_DIR"

if [ ! -f "$MODEL" ]; then
  echo "Не найдена модель: $MODEL"
  exit 1
fi

echo "Готовлю аудио…"

# Длительность источника — печатаем отдельной строкой, чтобы приложение
# могло прикинуть оставшееся время распознавания.
DURATION=$(ffprobe -v quiet -show_entries format=duration -of csv=p=0 "$INPUT_FILE" 2>/dev/null)
echo "DURATION_SECONDS:${DURATION:-0}"

# ffmpeg одинаково работает и с видео, и с чистым аудио:
# из видео берётся звуковая дорожка, аудио просто перекодируется в нужный формат.
ffmpeg -y -i "$INPUT_FILE" -vn -ar 16000 -ac 1 -c:a pcm_s16le "$OUT_DIR/audio.wav" -loglevel error

HAS_MIC=0
if [ -n "$MIC_FILE" ] && [ -s "$MIC_FILE" ]; then
  HAS_MIC=1
  ffmpeg -y -i "$MIC_FILE" -vn -ar 16000 -ac 1 -c:a pcm_s16le "$OUT_DIR/mic.wav" -loglevel error
fi

# =====================================================================
# ОПРЕДЕЛЕНИЕ ЯЗЫКА
# Сам whisper при -l auto смотрит только на первые 30 секунд. Запись встречи
# почти всегда начинается с тишины или шума — и тогда язык определяется
# наугад (на реальной записи: «en» с уверенностью 55% вместо «ru» с 99.7%),
# после чего русская речь «распознаётся» как английский текст, то есть
# фактически переводится. Поэтому собираем образец из трёх мест записи
# (20%, 50%, 80%) и определяем язык по нему, а дальше передаём явно.
# =====================================================================
DUR_INT=${DURATION%.*}
DUR_INT=${DUR_INT:-0}
if [ "$LANGUAGE" = "auto" ] && [ "$DUR_INT" -gt 90 ]; then
  echo "Определяю язык по фрагментам из разных частей записи…"
  P1=$((DUR_INT * 20 / 100))
  P2=$((DUR_INT * 50 / 100))
  P3=$((DUR_INT * 80 / 100))
  ffmpeg -y -i "$OUT_DIR/audio.wav" -filter_complex \
    "[0:a]atrim=start=$P1:duration=10,asetpts=PTS-STARTPTS[a];[0:a]atrim=start=$P2:duration=10,asetpts=PTS-STARTPTS[b];[0:a]atrim=start=$P3:duration=10,asetpts=PTS-STARTPTS[c];[a][b][c]concat=n=3:v=0:a=1[out]" \
    -map "[out]" -ar 16000 -ac 1 -c:a pcm_s16le "$OUT_DIR/lang_sample.wav" -loglevel error

  DETECT_LINE=$(whisper-cli -m "$MODEL" -f "$OUT_DIR/lang_sample.wav" -l auto -dl 2>&1 | grep -i "auto-detected language" || true)
  rm -f "$OUT_DIR/lang_sample.wav"
  DETECTED=$(echo "$DETECT_LINE" | sed -n 's/.*auto-detected language: \([a-z]*\).*/\1/p')
  if [ -n "$DETECTED" ]; then
    echo "Язык определён: $DETECTED ($(echo "$DETECT_LINE" | sed -n 's/.*(\(p = [0-9.]*\)).*/\1/p'))"
    LANGUAGE="$DETECTED"
  else
    echo "Не удалось определить язык по образцу — оставляю автоопределение whisper."
  fi
fi

# =====================================================================
# ЗАЩИТА ОТ ЗАЦИКЛИВАНИЯ
# Модель «залипает» на тишине, музыке ожидания и фоновом шуме,
# повторяя одну фразу сотни раз. Помогают:
#   -mc 0   не переносить текст предыдущего окна в следующее
#           (именно перенос контекста и раскручивает петлю)
#   -et     порог энтропии: слишком однообразный вывод бракуется
#   -lpt    порог правдоподобия: неуверенные сегменты отбрасываются
#   -nt     без таймкодов в .txt (для одной дорожки)
# Словарь терминов и имён: без него whisper коверкает аббревиатуры
# (слышит обрывки аббревиатур) и фамилии. Из-за -mc 0 обычная подсказка действовала
# бы только на первое окно, поэтому --carry-initial-prompt подставляет её в
# каждое окно — при этом ранее распознанный текст по-прежнему не переносится,
# так что защита от зацикливания сохраняется.
# VAD (если модель рядом) вырезает тишину ещё до распознавания: зацикливаться
# становится не на чем, заодно пропадают галлюцинации вида «you», «foreign».
# =====================================================================
run_whisper() {
  local wav="$1"
  local prefix="$2"
  local format="$3"   # txt — одна дорожка, srt — нужны таймкоды для сшивки
  local args=(
    -m "$MODEL"
    -f "$wav"
    -l "$LANGUAGE"
    -of "$prefix"
    -mc 0
    -et 2.8
    -lpt -1.0
  )

  if [ "$format" = "srt" ]; then
    args+=( -osrt )
  else
    args+=( -otxt -nt )
  fi

  if [ -n "$GLOSSARY" ]; then
    args+=( --prompt "$GLOSSARY" --carry-initial-prompt )
  fi

  if [ -f "$VAD_MODEL" ]; then
    args+=( --vad --vad-model "$VAD_MODEL" )
  fi

  whisper-cli "${args[@]}"
}

if [ -n "$GLOSSARY" ]; then
  echo "Использую словарь терминов."
fi
if [ -f "$VAD_MODEL" ]; then
  echo "Использую VAD (тишина будет пропущена)…"
else
  echo "VAD-модель не найдена — работаю без неё."
fi

if [ "$HAS_MIC" = "1" ]; then
  echo "Распознаю речь собеседников (1 из 2)… язык: $LANGUAGE"
  run_whisper "$OUT_DIR/audio.wav" "$OUT_DIR/others" srt
  echo "Распознаю речь с микрофона (2 из 2)… язык: $LANGUAGE"
  run_whisper "$OUT_DIR/mic.wav" "$OUT_DIR/me" srt

  echo "Свожу дорожки в диалог…"
  python3 "$SCRIPT_DIR/merge_tracks.py" \
    "$OUT_DIR/others.srt" "$OUT_DIR/me.srt" "$OUT_DIR/transcript.txt"
  rm -f "$OUT_DIR/others.srt" "$OUT_DIR/me.srt"
else
  echo "Распознаю речь (это самая долгая часть)… язык: $LANGUAGE"
  run_whisper "$OUT_DIR/audio.wav" "$OUT_DIR/transcript" txt
fi

if [ ! -s "$OUT_DIR/transcript.txt" ]; then
  echo "Транскрипт пустой или не создан."
  exit 1
fi

# Схлопываем подряд идущие одинаковые строки, если петля всё же проскочила.
awk 'BEGIN { prev = "" }
{
  line = $0
  gsub(/^[ \t]+|[ \t]+$/, "", line)
  if (line != prev || line == "") print $0
  if (line != "") prev = line
}' "$OUT_DIR/transcript.txt" > "$OUT_DIR/transcript.clean.txt"
mv "$OUT_DIR/transcript.clean.txt" "$OUT_DIR/transcript.txt"

# Промежуточные wav больше не нужны — они весят заметно больше текста.
rm -f "$OUT_DIR/audio.wav" "$OUT_DIR/mic.wav"

echo "Транскрипт сохранён: $OUT_DIR/transcript.txt"
