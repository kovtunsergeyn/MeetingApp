#!/bin/bash
# Выгрузка готового саммари наружу. Вызывается кнопкой из истории, а не
# автоматически: куда отправлять результат — решение человека, а не приложения.
#
# Использование:
#   ./export_summary.sh notion "/путь/summary.md" "Название встречи" "Имя базы" ["/путь/transcript.txt"]
#   ./export_summary.sh notes  "/путь/summary.md" "Название встречи"
set -e

TARGET="$1"
SUMMARY="$2"
NAME="$3"

if [ -z "$TARGET" ] || [ -z "$SUMMARY" ] || [ ! -s "$SUMMARY" ]; then
  echo "Использование: ./export_summary.sh <notion|notes> <summary.md> <название> [имя базы] [транскрипт]"
  exit 1
fi

export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.npm-global/bin:/usr/bin:/bin:$PATH"

case "$TARGET" in
  notion)
    NOTION_DATABASE="${4:-Саммари встреч}"
    TRANSCRIPT="$5"

    if ! command -v claude &> /dev/null; then
      echo "Claude Code не найден — через него идёт доступ к Notion."
      exit 1
    fi

    # Имя MCP-сервера зависит от того, как у человека подключён Notion в Claude
    # Code: через аккаунт claude.ai он называется «claude.ai Notion», при ручном
    # подключении — как угодно. Спрашиваем у самого claude и превращаем имя в
    # префикс инструментов (всё, кроме букв и цифр, → подчёркивание).
    NOTION_SERVER=$(claude mcp list 2>/dev/null \
      | grep -i "notion" \
      | head -1 \
      | sed 's/ - .*//' \
      | sed 's/:.*//' \
      | sed 's/[^A-Za-z0-9]/_/g')
    if [ -n "$NOTION_SERVER" ]; then
      echo "Notion подключён как «$NOTION_SERVER»."
    else
      echo "Не нашёл подключённый Notion в claude mcp list — пробую стандартное имя."
      NOTION_SERVER="claude_ai_Notion"
    fi

    ATTACH_INSTRUCTION=""
    if [ -n "$TRANSCRIPT" ] && [ -s "$TRANSCRIPT" ]; then
      ATTACH_INSTRUCTION="
Прикрепи файл транскрипта ($TRANSCRIPT) к записи, если в базе есть поле для файлов.
Если файл больше ~180 КБ — разбей его на части по смысловым границам и прикрепи все."
    fi

    echo "Выгружаю саммари в Notion…"
    claude -p "Прочитай файл саммари: $SUMMARY (название встречи: \"$NAME\").
Сохрани его новой записью в базе Notion «$NOTION_DATABASE».
Найди базу поиском по названию; если такой базы нет — создай её.
Заполни атрибуты по смыслу саммари: название, дата встречи, участники, теги, статус —
только теми значениями, которые есть в тексте, ничего не выдумывая.
Содержимое страницы — само саммари.$ATTACH_INSTRUCTION

В самой последней строке ответа выведи только ссылку на созданную страницу." \
      --allowedTools "Read" "mcp__${NOTION_SERVER}__*" \
      --max-turns 30
    ;;

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
    echo "Неизвестная цель выгрузки: $TARGET (ожидается notion или notes)"
    exit 1
    ;;
esac

echo "Выгрузка завершена."
