#!/bin/bash
# Удаление компонентов, которые приложение установило само.
#
# Использование:
#   ./uninstall.sh --dry-run ffmpeg whisper claude     # только показать, что будет удалено
#   ./uninstall.sh --apply   ffmpeg whisper claude     # удалить
#
# Правило: удаляется только то, что приложение поставило само. Список того, что
# было установлено, ведёт приложение (installed_components.json) — здесь мы лишь
# выполняем то, что оно передало. Компоненты, которые были на компьютере до
# установки приложения, в этот список не попадают и не удаляются.
set -e

MODE="$1"
shift || true

if [ "$MODE" != "--dry-run" ] && [ "$MODE" != "--apply" ]; then
  echo "Использование: ./uninstall.sh --dry-run|--apply <компоненты…>"
  exit 1
fi

# Свои копии компонентов лежат в <папка данных>/bin — папку находим по месту
# самого скрипта, поэтому тестовая и рабочая сборки берут каждая своё. Дальше
# идут системные пути: если у человека уже стоят ffmpeg или whisper, сгодятся
# и они. $HOME/.local/bin — туда ставит себя Claude Code.
BIN_DIR="$(cd "$(dirname "$0")/.." && pwd)/bin"
export PATH="$BIN_DIR:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$HOME/.npm-global/bin:/usr/bin:/bin:$PATH"

run() {
  if [ "$MODE" = "--dry-run" ]; then
    echo "   будет выполнено: $*"
  else
    echo "   выполняю: $*"
    "$@" || echo "   не удалось: $* (пропускаю)"
  fi
}

remove_path() {
  local target="$1"
  if [ ! -e "$target" ]; then
    echo "   нечего удалять: $target"
    return
  fi
  local size
  size=$(du -sh "$target" 2>/dev/null | cut -f1)
  if [ "$MODE" = "--dry-run" ]; then
    echo "   будет удалено: $target ($size)"
  else
    echo "   удаляю: $target ($size)"
    rm -rf "$target"
  fi
}

if [ "$MODE" = "--dry-run" ]; then
  echo "Проверка без удаления — ничего с компьютера не пропадёт."
fi

for COMPONENT in "$@"; do
  case "$COMPONENT" in
    ffmpeg)
      echo "ffmpeg:"
      remove_path "$BIN_DIR/ffmpeg"
      remove_path "$BIN_DIR/ffprobe"
      remove_path "$BIN_DIR/ffmpeg.LICENSE"
      ;;
    whisper)
      echo "whisper.cpp:"
      remove_path "$BIN_DIR/whisper-cli"
      remove_path "$BIN_DIR/whisper-cli.LICENSE"
      ;;
    ytdlp)
      echo "yt-dlp:"
      remove_path "$BIN_DIR/yt-dlp"
      ;;
    claude)
      echo "Claude Code:"
      remove_path "$HOME/.local/bin/claude"
      remove_path "$HOME/.local/share/claude"
      ;;
    models:*)
      echo "Языковые модели whisper:"
      remove_path "${COMPONENT#models:}"
      ;;
    data:*)
      echo "Данные приложения (записи, транскрипты, история):"
      remove_path "${COMPONENT#data:}"
      ;;
    app:*)
      echo "Само приложение:"
      remove_path "${COMPONENT#app:}"
      ;;
    *)
      echo "Неизвестный компонент: $COMPONENT (пропускаю)"
      ;;
  esac
done

if [ "$MODE" = "--dry-run" ]; then
  echo "Это была проверка. Ничего не удалено."
else
  echo "Удаление завершено."
fi
