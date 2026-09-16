#!/bin/bash
# Шаг 0: ссылка YouTube -> аудиофайл source.m4a
# Использование: ./download_youtube.sh "https://youtube.com/watch?v=..." "/папка/для/результата"
set -e

URL="$1"
OUT_DIR="$2"

if [ -z "$URL" ] || [ -z "$OUT_DIR" ]; then
  echo "Использование: ./download_youtube.sh <ссылка> <папка результата>"
  exit 1
fi

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

mkdir -p "$OUT_DIR"
LOG_FILE="$OUT_DIR/.yt-dlp.log"

# Выводим прогресс живьём (не буферизуем) — приложение парсит строки вида
# "42.3% of ... ETA 00:12" для индикатора хода загрузки, но всё равно
# сохраняем сырой вывод в файл, чтобы проверить причину неудачи после.
download() {
  local extra_args=("$@")
  yt-dlp -x --audio-format m4a --audio-quality 0 \
    --no-playlist \
    -o "$OUT_DIR/source.%(ext)s" \
    "${extra_args[@]}" \
    "$URL" 2>&1 | tee "$LOG_FILE"
  return "${PIPESTATUS[0]}"
}

echo "Скачиваю аудио с YouTube…"
set +e
download
STATUS=$?
set -e

# YouTube иногда требует подтверждения «я не робот» для незалогиненных запросов.
# В этом случае пробуем ещё раз, подставив куки из браузера пользователя.
if [ $STATUS -ne 0 ] && grep -qi "sign in to confirm" "$LOG_FILE"; then
  echo "YouTube просит подтверждение — пробую ещё раз через куки браузера…"
  for browser in chrome safari edge brave; do
    set +e
    download --cookies-from-browser "$browser"
    STATUS=$?
    set -e
    if [ $STATUS -eq 0 ]; then
      echo "Получилось через куки браузера: $browser"
      break
    fi
  done
  if [ $STATUS -ne 0 ]; then
    echo "Не удалось обойти проверку YouTube. Открой этот же ролик один раз в Chrome/Safari,"
    echo "войди в свой аккаунт Google и повтори попытку — куки браузера подставляются автоматически."
  fi
fi

rm -f "$LOG_FILE"

if [ ! -s "$OUT_DIR/source.m4a" ]; then
  echo "Не удалось получить аудиофайл."
  exit 1
fi

TITLE=$(yt-dlp --no-playlist --skip-download --print "%(title)s" "$URL" 2>/dev/null | head -n 1)
echo "TITLE:$TITLE"
echo "Аудио сохранено: $OUT_DIR/source.m4a"
