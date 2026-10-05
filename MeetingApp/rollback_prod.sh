#!/bin/bash
# Откат промышленной сборки на предыдущий выпуск.
#
# Собирает приложение из помеченного коммита во временной копии репозитория и
# ставит его в /Applications. Рабочая ветка и незакоммиченные правки при этом не
# трогаются: откат — это подмена приложения, а не состояния разработки.
#
# Использование:
#   ./rollback_prod.sh                 — на предыдущий выпуск (prod-previous)
#   ./rollback_prod.sh prod-2026-09-18 — на конкретную метку
#   ./rollback_prod.sh --list          — показать доступные точки отката
set -e

cd "$(dirname "$0")"

if [ "$1" = "--list" ]; then
  echo "Точки отката:"
  git for-each-ref --sort=-creatordate --format='  %(refname:short) → %(objectname:short)  %(contents:subject)' refs/tags/prod-*
  exit 0
fi

TARGET="${1:-prod-previous}"

if ! git rev-parse "$TARGET" >/dev/null 2>&1; then
  echo "Метки «$TARGET» нет. Доступные:"
  git for-each-ref --format='  %(refname:short)' refs/tags/prod-* || echo "  (ни одной)"
  exit 1
fi

COMMIT=$(git rev-parse --short "$TARGET")
echo "Откат на $TARGET (коммит $COMMIT)"

if pgrep -f "transcribe.sh|summarize.sh|export_summary.sh|whisper-cli" >/dev/null 2>&1; then
  echo "Приложение сейчас занято обработкой — дождись окончания."
  exit 1
fi

# Собираем в отдельной рабочей копии, чтобы не трогать текущую ветку.
WORKTREE="/tmp/meetingapp-rollback-$COMMIT"
rm -rf "$WORKTREE"
git worktree add -f "$WORKTREE" "$TARGET" >/dev/null 2>&1
trap 'git worktree remove --force "$WORKTREE" >/dev/null 2>&1 || true' EXIT

echo "Собираю…"
(cd "$WORKTREE/MeetingApp" && ./build_app.sh >/dev/null)

pkill -f "MeetingApp.app/Contents/MacOS/MeetingApp" 2>/dev/null || true
sleep 2
rm -rf /Applications/MeetingApp.app
cp -R "$WORKTREE/MeetingApp/MeetingApp.app" /Applications/

# Текущим выпуском теперь считается то, на что откатились.
git tag -f prod-current "$TARGET" >/dev/null

open -a /Applications/MeetingApp.app
echo "Готово: в /Applications стоит сборка из $TARGET."
echo "Данные и настройки не затронуты — откат меняет только приложение."
