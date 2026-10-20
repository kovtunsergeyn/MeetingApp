#!/bin/bash
# Сводит системный звук (голоса собеседников) и микрофон в один файл.
# Использование: ./mix_meeting_audio.sh <системный звук> <микрофон|/dev/null> <результат.m4a>
set -e

SYSTEM_AUDIO="$1"
MIC_AUDIO="$2"
OUTPUT="$3"

if [ -z "$SYSTEM_AUDIO" ] || [ -z "$OUTPUT" ]; then
  echo "Использование: ./mix_meeting_audio.sh <системный звук> <микрофон> <результат>"
  exit 1
fi

# Свои копии компонентов лежат в <папка данных>/bin — папку находим по месту
# самого скрипта, поэтому тестовая и рабочая сборки берут каждая своё. Дальше
# идут системные пути: если у человека уже стоят ffmpeg или whisper, сгодятся
# и они. $HOME/.local/bin — туда ставит себя Claude Code.
BIN_DIR="$(cd "$(dirname "$0")/.." && pwd)/bin"
export PATH="$BIN_DIR:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$HOME/.npm-global/bin:/usr/bin:/bin:$PATH"

if [ -s "$SYSTEM_AUDIO" ] && [ -s "$MIC_AUDIO" ]; then
  echo "Свожу системный звук и микрофон…"
  ffmpeg -y -i "$SYSTEM_AUDIO" -i "$MIC_AUDIO" \
    -filter_complex "amix=inputs=2:duration=longest:normalize=0" \
    -c:a aac "$OUTPUT" -loglevel error
elif [ -s "$SYSTEM_AUDIO" ]; then
  echo "Микрофон пуст — использую только системный звук."
  ffmpeg -y -i "$SYSTEM_AUDIO" -c:a aac "$OUTPUT" -loglevel error
elif [ -s "$MIC_AUDIO" ]; then
  echo "Системный звук пуст — использую только микрофон."
  ffmpeg -y -i "$MIC_AUDIO" -c:a aac "$OUTPUT" -loglevel error
else
  echo "Обе дорожки пустые — записывать нечего."
  exit 1
fi

if [ ! -s "$OUTPUT" ]; then
  echo "Не удалось создать сведённый файл."
  exit 1
fi

echo "Свёл в: $OUTPUT"
