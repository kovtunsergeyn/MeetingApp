#!/bin/bash
# Сохранение готового саммари в Заметки. Вызывается кнопкой из истории, а не
# автоматически: куда отправлять результат — решение человека, а не приложения.
#
# Выгрузка в Notion живёт не здесь: приложение обращается к API Notion само,
# по токену из Связки ключей. Через claude это раньше шло и оказалось
# ненадёжным — подключения аккаунта claude.ai сессии приложения не достаются.
#
# Использование:
#   ./export_summary.sh notes "/путь/summary.md" "Название встречи"
set -e

TARGET="$1"
SUMMARY="$2"
NAME="$3"

if [ -z "$TARGET" ] || [ -z "$SUMMARY" ] || [ ! -s "$SUMMARY" ]; then
  echo "Использование: ./export_summary.sh notes <summary.md> <название>"
  exit 1
fi

# Свои копии компонентов лежат в <папка данных>/bin — папку находим по месту
# самого скрипта, поэтому тестовая и рабочая сборки берут каждая своё. Дальше
# идут системные пути: если у человека уже стоят ffmpeg или whisper, сгодятся
# и они. $HOME/.local/bin — туда ставит себя Claude Code.
BIN_DIR="$(cd "$(dirname "$0")/.." && pwd)/bin"
export PATH="$BIN_DIR:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$HOME/.npm-global/bin:/usr/bin:/bin:$PATH"

case "$TARGET" in
  notes)
    echo "Сохраняю саммари в Заметки…"
    # Notes.app хранит текст как HTML: обычные переносы строк схлопнулись бы
    # в один абзац, поэтому превращаем их в <br> и экранируем спецсимволы.
    BODY_FILE=$(mktemp)
    trap 'rm -f "$BODY_FILE"' EXIT
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/$/<br>/' "$SUMMARY" > "$BODY_FILE"

    if osascript - "Саммари: $NAME" "$BODY_FILE" <<'APPLESCRIPT'
on run argv
  set noteTitle to item 1 of argv
  set bodyPath to item 2 of argv
  set noteBody to (read (POSIX file bodyPath) as «class utf8»)
  tell application "Notes"
    make new note with properties {name:noteTitle, body:noteBody}
  end tell
end run
APPLESCRIPT
    then
      echo "Сохранено в Заметки."
    else
      echo "Не удалось сохранить в Заметки (проверь разрешение автоматизации для Notes)."
      exit 1
    fi
    ;;

  *)
    echo "Неизвестная цель выгрузки: $TARGET (ожидается notes)"
    exit 1
    ;;
esac

echo "Выгрузка завершена."
