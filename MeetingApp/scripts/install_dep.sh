#!/bin/bash
# Установка недостающих компонентов. Вызывается из приложения.
# Использование:
#   ./install_dep.sh ffmpeg
#   ./install_dep.sh whisper
#   ./install_dep.sh ytdlp
#   ./install_dep.sh vad <папка моделей>
#   ./install_dep.sh model <modelID> <fileName> <downloadURL> <папка моделей>
set -e

COMPONENT="$1"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

need_brew() {
  if ! command -v brew &> /dev/null; then
    echo "Homebrew не найден. Установи его с https://brew.sh и повтори."
    exit 1
  fi
}

case "$COMPONENT" in
  ffmpeg)
    need_brew
    echo "Ставлю ffmpeg через Homebrew…"
    brew install ffmpeg
    ;;

  whisper)
    need_brew
    echo "Ставлю whisper.cpp через Homebrew…"
    # Формула называется whisper-cpp (переименована в whisper.cpp),
    # исполняемый файл внутри — whisper-cli.
    brew install whisper-cpp
    ;;

  ytdlp)
    need_brew
    echo "Ставлю yt-dlp через Homebrew…"
    brew install yt-dlp
    ;;

  vad)
    # Папку моделей передаёт приложение: она внутри его папки данных.
    MODELS_DIR="${2:-$HOME/MeetingApp/models}"
    mkdir -p "$MODELS_DIR"
    echo "Скачиваю детектор речи (VAD)…"
    curl -L --fail --progress-bar \
      "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin" \
      -o "$MODELS_DIR/ggml-silero-v5.1.2.bin.part"
    mv "$MODELS_DIR/ggml-silero-v5.1.2.bin.part" "$MODELS_DIR/ggml-silero-v5.1.2.bin"
    ;;

  claude)
    export PATH="$HOME/.npm-global/bin:$PATH"
    if ! command -v npm &> /dev/null; then
      need_brew
      echo "Node.js (npm) не найден — ставлю через Homebrew…"
      brew install node
    fi
    echo "Ставлю Claude Code через npm…"
    npm install -g @anthropic-ai/claude-code
    # Вход в аккаунт Anthropic делает само приложение отдельным диалогом —
    # claude auth login интерактивный (ждёт код из браузера), обычный
    # запуск скрипта для этого не годится.
    ;;

  model)
    MODEL_ID="$2"
    FILE_NAME="$3"
    DOWNLOAD_URL="$4"
    MODELS_DIR="${5:-$HOME/MeetingApp/models}"
    if [ -z "$FILE_NAME" ] || [ -z "$DOWNLOAD_URL" ]; then
      echo "Использование: ./install_dep.sh model <modelID> <fileName> <downloadURL> [папка моделей]"
      exit 1
    fi
    mkdir -p "$MODELS_DIR"
    echo "Скачиваю модель $FILE_NAME (id: $MODEL_ID)…"
    curl -L --fail --progress-bar \
      "$DOWNLOAD_URL" \
      -o "$MODELS_DIR/$FILE_NAME.part"
    mv "$MODELS_DIR/$FILE_NAME.part" "$MODELS_DIR/$FILE_NAME"
    echo "Модель загружена."
    ;;

  *)
    echo "Неизвестный компонент: $COMPONENT"
    exit 1
    ;;
esac

echo "Компонент $COMPONENT готов."
