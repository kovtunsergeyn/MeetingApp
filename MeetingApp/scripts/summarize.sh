#!/bin/bash
# Шаг 2: транскрипт -> саммари -> сохранение в Заметки и/или в базу Notion «Саммари встреч»
# Использование: ./summarize.sh "/путь/к/transcript.txt" "Название встречи" [saveNotes:0|1] [saveNotion:0|1]
set -e

TRANSCRIPT="$1"
NAME="$2"
SAVE_NOTES="${3:-0}"
SAVE_NOTION="${4:-1}"

if [ -z "$TRANSCRIPT" ] || [ ! -s "$TRANSCRIPT" ]; then
  echo "Не найден или пуст файл транскрипта: $TRANSCRIPT"
  exit 1
fi

export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.npm-global/bin:/usr/bin:/bin:$PATH"

if ! command -v claude &> /dev/null; then
  echo "Claude Code не найден. Установка: npm install -g @anthropic-ai/claude-code"
  exit 1
fi

OUT_DIR=$(dirname "$TRANSCRIPT")
SUMMARY_FILE="$OUT_DIR/summary.md"
rm -f "$SUMMARY_FILE"

echo "Делаю саммари…"

NOTION_INSTRUCTION=""
if [ "$SAVE_NOTION" = "1" ]; then
  NOTION_INSTRUCTION="
Затем сохрани саммари новой записью в базе Notion «Саммари встреч».
Найди эту базу поиском по названию. Заполни атрибуты по смыслу транскрипта:
Название, Дата встречи, Направление, Участники, Теги, Статус.
Прикрепи файл транскрипта ($TRANSCRIPT) к записи в поле «Исходный файл».
Если файл больше ~180 КБ — разбей его на несколько частей по смысловым границам
и прикрепи все части.
В самой последней строке ответа выведи только ссылку на созданную страницу Notion."
else
  NOTION_INSTRUCTION="
В Notion сохранять не нужно."
fi

ALLOWED_TOOLS=(--allowedTools "Read" "Write")
if [ "$SAVE_NOTION" = "1" ]; then
  # Имя MCP-сервера зависит от того, как подключён Notion в Claude Code
  # (Настройки -> Connectors). У большинства при подключении через
  # аккаунт claude.ai сервер называется "claude.ai Notion", что даёт
  # инструменты вида mcp__claude_ai_Notion__notion-search и т.п.
  # Если у тебя Notion подключён иначе, узнай точное имя командой:
  #   claude mcp list
  # и поправь паттерн ниже под него.
  ALLOWED_TOOLS+=("mcp__claude_ai_Notion__*")
fi

claude -p "Прочитай файл транскрипта встречи: $TRANSCRIPT (название встречи: \"$NAME\").
Транскрипт получен автоматическим распознаванием речи, поэтому в нём бывают ошибки, повторы
и зацикленные фразы — ориентируйся на смысл, а не на дословность.

Сделай структурированное саммари на русском языке со следующими разделами:
контекст и проблема; принятые решения; договорённости и следующие шаги; открытые вопросы.
Если чего-то в разговоре не было — раздел пропусти, не выдумывай.

Запиши получившееся саммари целиком (в формате markdown, без лишних комментариев от себя)
в файл $SUMMARY_FILE с помощью инструмента Write.
$NOTION_INSTRUCTION

Ничего не уточняй и не спрашивай — выполни все шаги самостоятельно." \
  "${ALLOWED_TOOLS[@]}" \
  --max-turns 40

if [ ! -s "$SUMMARY_FILE" ]; then
  echo "Саммари не было сохранено в файл — что-то пошло не так на стороне Claude Code."
  exit 1
fi

if [ "$SAVE_NOTES" = "1" ]; then
  echo "Сохраняю саммари в Заметки…"
  # Notes.app хранит body как HTML — обычные переносы строк схлопываются в один
  # абзац, поэтому превращаем их в <br> и экранируем спецсимволы.
  NOTES_BODY_FILE="$OUT_DIR/summary.notesbody.html"
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/$/<br>/' "$SUMMARY_FILE" > "$NOTES_BODY_FILE"

  if osascript - "Саммари: $NAME" "$NOTES_BODY_FILE" <<'APPLESCRIPT'
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
  fi
  rm -f "$NOTES_BODY_FILE"
fi

echo "Шаг саммари завершён."
