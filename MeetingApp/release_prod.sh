#!/bin/bash
# Выпуск промышленной сборки с точкой отката.
#
# Собирает приложение из текущей ветки, устанавливает его в /Applications и
# помечает коммит меткой. Предыдущая метка выпуска сохраняется как
# prod-previous — именно на неё откатывает rollback_prod.sh.
#
# Использование:
#   ./release_prod.sh            — собрать, установить и пометить
#   ./release_prod.sh --dry-run  — показать, что будет сделано
set -e

cd "$(dirname "$0")"

DRY_RUN=0
[ "$1" = "--dry-run" ] && DRY_RUN=1

CURRENT_TAG="prod-current"
PREVIOUS_TAG="prod-previous"
STAMP=$(date +%Y-%m-%d-%H%M)
RELEASE_TAG="prod-$STAMP"

BRANCH=$(git rev-parse --abbrev-ref HEAD)
COMMIT=$(git rev-parse --short HEAD)

echo "Ветка: $BRANCH, коммит: $COMMIT"

if [ -n "$(git status --porcelain)" ]; then
  echo "В дереве есть незакоммиченные изменения — выпускать нечего:"
  git status --short | head -10
  echo "Сначала зафиксируй или отмени их."
  exit 1
fi

# Приложение не должно обрываться на полуслове: шаги обработки идут минутами,
# и переустановка посреди распознавания прервёт работу над реальной встречей.
if pgrep -f "transcribe.sh|summarize.sh|export_summary.sh|whisper-cli" >/dev/null 2>&1; then
  echo "Приложение сейчас занято обработкой — дождись окончания."
  exit 1
fi

if [ "$DRY_RUN" = "1" ]; then
  echo "Будет сделано:"
  echo "  1. сборка и установка /Applications/MeetingApp.app из коммита $COMMIT"
  echo "  2. метка $PREVIOUS_TAG → $(git rev-parse --short "$CURRENT_TAG" 2>/dev/null || echo "нет текущей метки")"
  echo "  3. метки $CURRENT_TAG и $RELEASE_TAG → $COMMIT"
  exit 0
fi

echo "Собираю промышленную сборку…"
./build_app.sh >/dev/null

pkill -f "MeetingApp.app/Contents/MacOS/MeetingApp" 2>/dev/null || true
sleep 2
rm -rf /Applications/MeetingApp.app
cp -R MeetingApp.app /Applications/
echo "Установлено: /Applications/MeetingApp.app"

# Прежний выпуск становится точкой отката.
if git rev-parse "$CURRENT_TAG" >/dev/null 2>&1; then
  git tag -f "$PREVIOUS_TAG" "$CURRENT_TAG" >/dev/null
  echo "Точка отката: $PREVIOUS_TAG → $(git rev-parse --short "$PREVIOUS_TAG")"
fi

git tag -f "$CURRENT_TAG" HEAD >/dev/null
git tag -f "$RELEASE_TAG" HEAD >/dev/null
echo "Метки выпуска: $CURRENT_TAG и $RELEASE_TAG → $COMMIT"

open -a /Applications/MeetingApp.app
echo "Готово. Откат: ./rollback_prod.sh"
