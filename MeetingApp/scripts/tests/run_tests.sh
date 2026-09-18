#!/bin/bash
# Тесты shell-скриптов обработки.
#
#   ./run_tests.sh          — быстрые тесты (секунды): сшивка дорожек, удаление вхолостую
#   ./run_tests.sh --full   — плюс медленные: настоящее распознавание синтетической речи
#
# Медленные отделены потому, что им нужны whisper-cli и модель на диске: в CI
# это гигабайты загрузки на каждый прогон, а локально — минута времени.
set -u

SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

FULL=0
[ "${1:-}" = "--full" ] && FULL=1

PASSED=0
FAILED=0

check() {
  local what="$1"
  local condition="$2"
  if [ "$condition" = "1" ]; then
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1))
    echo "  ✗ $what"
  fi
}

contains() {
  grep -qF "$2" "$1" && echo 1 || echo 0
}

echo "• Сшивка дорожек в диалог"
mkdir -p "$WORK_DIR/merge"
cat > "$WORK_DIR/merge/others.srt" <<'EOF'
1
00:00:01,000 --> 00:00:04,000
Проверка связи, раз, два, три.

2
00:00:04,200 --> 00:00:07,000
Первая фраза для проверки эха.

3
00:00:12,000 --> 00:00:15,000
Последняя фраза первой дорожки.
EOF
cat > "$WORK_DIR/merge/me.srt" <<'EOF'
1
00:00:04,300 --> 00:00:07,100
Первая фраза для проверки эха

2
00:00:08,000 --> 00:00:11,000
Вторая дорожка, начало.

3
00:00:11,200 --> 00:00:12,000
Вторая дорожка, продолжение.
EOF
python3 "$SCRIPTS_DIR/merge_tracks.py" \
  "$WORK_DIR/merge/others.srt" "$WORK_DIR/merge/me.srt" "$WORK_DIR/merge/transcript.txt" >/dev/null
MERGED="$WORK_DIR/merge/transcript.txt"

check "реплики идут по времени" \
  "$([ "$(head -1 "$MERGED" | cut -c2-9)" = "00:00:01" ] && echo 1 || echo 0)"
check "голос собеседников подписан «Собеседники»" "$(contains "$MERGED" "Собеседники: Проверка связи")"
check "свой голос подписан «Я»" "$(contains "$MERGED" "Я: Вторая дорожка, начало")"
# Микрофон слышит и колонки: та же фраза не должна попасть в транскрипт дважды
# от разных людей, иначе саммари решит, что это сказали оба.
check "эхо из колонок отброшено" \
  "$([ "$(grep -c "проверки эха" "$MERGED")" = "1" ] && echo 1 || echo 0)"
check "подряд идущие реплики склеены в абзац" "$(contains "$MERGED" "начало. Вторая дорожка, продолжение")"

echo "• Удаление компонентов вхолостую"
DRY_OUT="$WORK_DIR/uninstall.txt"
mkdir -p "$WORK_DIR/data/models"
echo "данные" > "$WORK_DIR/data/history.json"
"$SCRIPTS_DIR/uninstall.sh" --dry-run ffmpeg "data:$WORK_DIR/data" > "$DRY_OUT" 2>&1
check "показывает, что будет удалено" "$(contains "$DRY_OUT" "будет удалено: $WORK_DIR/data")"
check "предупреждает, что это проверка" "$(contains "$DRY_OUT" "Ничего не удалено")"
# Главное свойство проверки: она ничего не трогает.
check "данные на месте после проверки" "$([ -f "$WORK_DIR/data/history.json" ] && echo 1 || echo 0)"
check "неизвестный компонент не ломает работу" \
  "$("$SCRIPTS_DIR/uninstall.sh" --dry-run чепуха >/dev/null 2>&1 && echo 1 || echo 0)"

if [ "$FULL" = "1" ]; then
  echo "• Распознавание двух дорожек (настоящий whisper)"
  # Берём любую установленную модель, начиная с самых лёгких: раньше тест
  # искал только base и medium и молча пропускался, когда на машине осталась
  # одна large — то есть самая важная проверка не выполнялась вовсе.
  MODEL=""
  for dir in "$HOME/MeetingApp/models" "$HOME/MeetingApp-Test/models" "$HOME/whisper-models"; do
    for name in ggml-tiny.bin ggml-base.bin ggml-small.bin ggml-medium.bin ggml-large-v3.bin; do
      if [ -f "$dir/$name" ]; then MODEL="$dir/$name"; break 2; fi
    done
  done

  if [ -z "$MODEL" ] || ! command -v whisper-cli >/dev/null 2>&1; then
    echo "  — пропускаю: нет whisper-cli или модели"
  else
    # Голоса есть не на каждом Mac — если нужного нет, берём системный по умолчанию.
    voice_args() {
      say -v '?' 2>/dev/null | grep -q "^$1 " && echo "-v $1" || echo ""
    }
    say $(voice_args Milena) -o "$WORK_DIR/system.aiff" "Это системный звук, говорит собеседник" 2>/dev/null
    say $(voice_args Yuri) -o "$WORK_DIR/mic.aiff" "А это микрофон, говорю я сам" 2>/dev/null
    ffmpeg -y -i "$WORK_DIR/system.aiff" -c:a aac "$WORK_DIR/system.m4a" -loglevel error
    ffmpeg -y -i "$WORK_DIR/mic.aiff" -c:a aac "$WORK_DIR/mic.m4a" -loglevel error

    "$SCRIPTS_DIR/transcribe.sh" "$WORK_DIR/system.m4a" "$WORK_DIR/out" ru "$MODEL" "" "$WORK_DIR/mic.m4a" \
      > "$WORK_DIR/transcribe.log" 2>&1
    REAL="$WORK_DIR/out/transcript.txt"
    check "транскрипт создан" "$([ -s "$REAL" ] && echo 1 || echo 0)"
    # Ровно та ошибка, которую страшно не заметить: перепутанные дорожки
    # приписали бы слова собеседников тебе и наоборот.
    check "системный звук подписан «Собеседники»" \
      "$(grep -q "Собеседники:.*систем" "$REAL" && echo 1 || echo 0)"
    check "микрофон подписан «Я»" "$(grep -q "Я:.*микрофон" "$REAL" && echo 1 || echo 0)"
    check "промежуточные wav удалены" \
      "$([ ! -f "$WORK_DIR/out/audio.wav" ] && [ ! -f "$WORK_DIR/out/mic.wav" ] && echo 1 || echo 0)"

    echo "• Распознавание одной дорожкой"
    "$SCRIPTS_DIR/transcribe.sh" "$WORK_DIR/system.m4a" "$WORK_DIR/out-single" ru "$MODEL" \
      > "$WORK_DIR/transcribe-single.log" 2>&1
    SINGLE="$WORK_DIR/out-single/transcript.txt"
    check "одна дорожка тоже распознаётся" "$([ -s "$SINGLE" ] && echo 1 || echo 0)"
    check "без второй дорожки подписей нет" \
      "$(grep -q "Собеседники:" "$SINGLE" && echo 0 || echo 1)"
  fi
else
  echo "• Медленные тесты пропущены (запусти с --full)"
fi

echo ""
if [ "$FAILED" = "0" ]; then
  echo "Проверок пройдено: $PASSED. Всё в порядке."
  exit 0
else
  echo "Провалено $FAILED из $((PASSED + FAILED))."
  exit 1
fi
