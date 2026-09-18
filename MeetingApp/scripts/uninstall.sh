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

export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.npm-global/bin:/usr/bin:/bin:$PATH"

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
      run brew uninstall --ignore-dependencies ffmpeg
      ;;
    whisper)
      echo "whisper.cpp:"
      run brew uninstall --ignore-dependencies whisper-cpp
      ;;
    ytdlp)
      echo "yt-dlp:"
      run brew uninstall --ignore-dependencies yt-dlp
      ;;
    node)
      echo "Node.js:"
      run brew uninstall --ignore-dependencies node
      ;;
    claude)
      echo "Claude Code:"
      run npm uninstall -g @anthropic-ai/claude-code
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
