#!/bin/bash
# Установка недостающих компонентов. Вызывается из приложения.
#
# Компоненты кладутся в <папка данных>/bin и больше ниоткуда не берутся:
# ни Homebrew, ни Node, ни Xcode для работы приложения не нужны. Это сделано
# ради человека, которому приложение просто передали: он ставит .app и всё.
#
# Использование:
#   ./install_dep.sh ffmpeg  [папка bin]
#   ./install_dep.sh whisper [папка bin]
#   ./install_dep.sh ytdlp   [папка bin]
#   ./install_dep.sh claude
#   ./install_dep.sh vad   <папка моделей>
#   ./install_dep.sh model <modelID> <fileName> <downloadURL> <папка моделей>
set -e

COMPONENT="$1"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

# Папка данных определяется по месту самого скрипта: он лежит в
# <папка данных>/scripts, поэтому тестовая и рабочая сборки сами попадают
# каждая в свою папку, без договорённостей и настроек.
DATA_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIR="${2:-$DATA_DIR/bin}"

ARCH=$(uname -m)
case "$ARCH" in
  arm64)  PLATFORM="darwin-arm64" ;;
  x86_64) PLATFORM="darwin-x64" ;;
  *)      echo "Неизвестный процессор: $ARCH"; exit 1 ;;
esac

FFMPEG_RELEASE="https://github.com/eugeneware/ffmpeg-static/releases/download/b6.1.1"
WHISPER_RELEASE="https://github.com/kovtunsergeyn/MeetingApp/releases/download/bin-whisper-1.9.5"

# Скачивание одного файла: сначала во временный .part, потом переименование.
# Иначе оборванная загрузка оставляет полуфайл, который выглядит как готовый
# компонент и падает в середине обработки встречи.
download_binary() {
  local url="$1"
  local target="$2"
  mkdir -p "$(dirname "$target")"
  echo "Скачиваю $(basename "$target")…"
  curl -L --fail --progress-bar "$url" -o "$target.part"
  chmod +x "$target.part"
  mv "$target.part" "$target"
}

case "$COMPONENT" in
  ffmpeg)
    # Готовые статические сборки ffmpeg и ffprobe под macOS.
    download_binary "$FFMPEG_RELEASE/ffmpeg-$PLATFORM" "$BIN_DIR/ffmpeg"
    download_binary "$FFMPEG_RELEASE/ffprobe-$PLATFORM" "$BIN_DIR/ffprobe"
    # Лицензия рядом с бинарником: сборка под GPL, её условия должны быть
    # доступны тому, у кого этот файл оказался.
    curl -L --fail --silent "$FFMPEG_RELEASE/$PLATFORM.LICENSE" -o "$BIN_DIR/ffmpeg.LICENSE" || true
    ;;

  whisper)
    # Своя сборка whisper.cpp: готовых под macOS авторы не выкладывают.
    # Собрана с Metal, лежит в релизах этого же проекта, лицензия MIT.
    download_binary "$WHISPER_RELEASE/whisper-cli-$PLATFORM" "$BIN_DIR/whisper-cli"
    curl -L --fail --silent "$WHISPER_RELEASE/whisper.cpp.LICENSE" -o "$BIN_DIR/whisper-cli.LICENSE" || true
    ;;

  ytdlp)
    download_binary "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos" "$BIN_DIR/yt-dlp"
    ;;

  claude)
    # Родной установщик Anthropic: кладёт claude в ~/.local/bin и дальше
    # обновляет себя сам. Node, npm и Homebrew для этого не нужны.
    echo "Ставлю Claude Code…"
    curl -fsSL https://claude.ai/install.sh | bash
    # Вход в аккаунт делает само приложение отдельным диалогом: он
    # интерактивный и ждёт подтверждения в браузере.
    ;;

  vad)
    MODELS_DIR="${2:-$DATA_DIR/models}"
    mkdir -p "$MODELS_DIR"
    echo "Скачиваю детектор речи (VAD)…"
    curl -L --fail --progress-bar \
      "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin" \
      -o "$MODELS_DIR/ggml-silero-v5.1.2.bin.part"
    mv "$MODELS_DIR/ggml-silero-v5.1.2.bin.part" "$MODELS_DIR/ggml-silero-v5.1.2.bin"
    ;;

  model)
    MODEL_ID="$2"
    FILE_NAME="$3"
    DOWNLOAD_URL="$4"
    MODELS_DIR="${5:-$DATA_DIR/models}"
    if [ -z "$FILE_NAME" ] || [ -z "$DOWNLOAD_URL" ]; then
      echo "Использование: ./install_dep.sh model <modelID> <fileName> <downloadURL> [папка моделей]"
      exit 1
    fi
    mkdir -p "$MODELS_DIR"
    echo "Скачиваю модель $FILE_NAME (id: $MODEL_ID)…"
    curl -L --fail --progress-bar "$DOWNLOAD_URL" -o "$MODELS_DIR/$FILE_NAME.part"
    mv "$MODELS_DIR/$FILE_NAME.part" "$MODELS_DIR/$FILE_NAME"
    echo "Модель загружена."
    ;;

  *)
    echo "Неизвестный компонент: $COMPONENT"
    exit 1
    ;;
esac

echo "Компонент $COMPONENT готов."
