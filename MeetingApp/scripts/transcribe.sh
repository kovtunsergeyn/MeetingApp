#!/bin/bash
# Шаг 1: медиафайл (видео ИЛИ аудио) -> transcript.txt
# Использование: ./transcribe.sh "/путь/к/файлу" "/папка/для/результата" [язык|auto] [/путь/к/модели.bin]
set -e

INPUT_FILE="$1"
OUT_DIR="$2"
LANGUAGE="${3:-auto}"
MODEL="${4:-$HOME/whisper-models/ggml-medium.bin}"
VAD_MODEL="$HOME/whisper-models/ggml-silero-v5.1.2.bin"

if [ -z "$INPUT_FILE" ] || [ -z "$OUT_DIR" ]; then
  echo "Использование: ./transcribe.sh <входной файл> <папка результата> [язык] [модель]"
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

echo "Распознаю речь (это самая долгая часть)… язык: $LANGUAGE"

# =====================================================================
# ЗАЩИТА ОТ ЗАЦИКЛИВАНИЯ
# Модель «залипает» на тишине, музыке ожидания и фоновом шуме,
# повторяя одну фразу сотни раз. Помогают:
#   -mc 0   не переносить текст предыдущего окна в следующее
#           (именно перенос контекста и раскручивает петлю)
#   -et     порог энтропии: слишком однообразный вывод бракуется
#   -lpt    порог правдоподобия: неуверенные сегменты отбрасываются
#   -nt     без таймкодов в .txt
# =====================================================================
WHISPER_ARGS=(
  -m "$MODEL"
  -f "$OUT_DIR/audio.wav"
  -l "$LANGUAGE"
  -otxt
  -of "$OUT_DIR/transcript"
  -nt
  -mc 0
  -et 2.8
  -lpt -1.0
)

# Если рядом лежит модель VAD — включаем детектор речи: тишина вырезается
# ещё до распознавания, и зацикливаться становится просто не на чем.
if [ -f "$VAD_MODEL" ]; then
  echo "Использую VAD (тишина будет пропущена)…"
  WHISPER_ARGS+=( --vad --vad-model "$VAD_MODEL" )
else
  echo "VAD-модель не найдена — работаю без неё."
fi

whisper-cli "${WHISPER_ARGS[@]}"

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

# Промежуточный wav больше не нужен — он весит заметно больше текста.
rm -f "$OUT_DIR/audio.wav"

echo "Транскрипт сохранён: $OUT_DIR/transcript.txt"
