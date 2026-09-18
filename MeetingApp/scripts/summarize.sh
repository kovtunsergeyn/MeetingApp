#!/bin/bash
# Шаг 2: транскрипт -> саммари -> сохранение в Заметки и/или в базу Notion
# Использование: ./summarize.sh "/путь/к/transcript.txt" "Название встречи" [saveNotes:0|1] [saveNotion:0|1] ["словарь терминов"] ["имя базы Notion"]
set -e

TRANSCRIPT="$1"
NAME="$2"
SAVE_NOTES="${3:-0}"
SAVE_NOTION="${4:-1}"
GLOSSARY="$5"
NOTION_DATABASE="${6:-Саммари встреч}"

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
Затем сохрани саммари новой записью в базе Notion «$NOTION_DATABASE».
Найди эту базу поиском по названию. Если такой базы нет — создай её. Заполни атрибуты по смыслу транскрипта:
Название, Дата встречи, Направление, Участники, Теги, Статус.
Прикрепи файл транскрипта ($TRANSCRIPT) к записи в поле для файлов,
если такое поле в базе есть.
Если файл больше ~180 КБ — разбей его на несколько частей по смысловым границам
и прикрепи все части.
В самой последней строке ответа выведи только ссылку на созданную страницу Notion."
else
  NOTION_INSTRUCTION="
В Notion сохранять не нужно."
fi

ALLOWED_TOOLS=(--allowedTools "Read" "Write")
if [ "$SAVE_NOTION" = "1" ]; then
  # Имя MCP-сервера зависит от того, как у человека подключён Notion в Claude
  # Code: через аккаунт claude.ai сервер называется «claude.ai Notion», при
  # ручном подключении — как угодно. Поэтому спрашиваем у самого claude и
  # превращаем имя в префикс инструментов (точки и пробелы → подчёркивания).
  NOTION_SERVER=$(claude mcp list 2>/dev/null \
    | grep -i "notion" \
    | head -1 \
    | sed 's/ - .*//' \
    | sed 's/:.*//' \
    | sed 's/[^A-Za-z0-9]/_/g')
  if [ -n "$NOTION_SERVER" ]; then
    echo "Notion подключён как «$NOTION_SERVER»."
    ALLOWED_TOOLS+=("mcp__${NOTION_SERVER}__*")
  else
    echo "Не нашёл подключённый Notion в claude mcp list — пробую стандартное имя."
    ALLOWED_TOOLS+=("mcp__claude_ai_Notion__*")
  fi
fi

GLOSSARY_INSTRUCTION=""
if [ -n "$GLOSSARY" ]; then
  GLOSSARY_INSTRUCTION="
Справочник терминов и имён, которые встречаются в этих разговорах: $GLOSSARY
Если в транскрипте явно искажённое написание термина или имени из справочника
используй правильное написание из справочника."
fi

claude -p "Прочитай файл транскрипта встречи: $TRANSCRIPT (название встречи: \"$NAME\").
Транскрипт получен автоматическим распознаванием речи одной общей дорожкой, без разметки,
кто говорит. В нём бывают ошибки распознавания, особенно в аббревиатурах, фамилиях и
названиях систем, а также повторы — ориентируйся на смысл, а не на дословность.
$GLOSSARY_INSTRUCTION

Точность важнее гладкости. Строгие правила:
- Аббревиатуры, названия систем и имена, которых нет в справочнике и которые распознались
  неуверенно, НЕ расшифровывай и не «исправляй» наугад — оставь как услышано и пометь [?].
- Не приписывай людям роли, должности и связи, которые прямо не прозвучали. Не объединяй
  разных людей или организации в одно, если это не сказано явно.
- Цифры, суммы, даты и сроки — только те, что прозвучали; не округляй и не додумывай.
- В договорённостях указывай ответственного и срок, только если они прямо названы;
  иначе пиши «ответственный не назван» / «срок не назван».
- Если запись начинается или обрывается на полуслове — отметь, что контекст неполный.
- Если чего-то в разговоре не было — раздел пропусти, не выдумывай.

Сделай структурированное саммари на русском языке со следующими разделами:
контекст и проблема; принятые решения; договорённости и следующие шаги; открытые вопросы;
сомнительные места распознавания (термины и фразы, которые стоит перепроверить по записи).

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
