#!/bin/bash
# Собирает MeetingApp.app и раскладывает скрипты в ~/Встречи/scripts
set -e

APP_NAME="MeetingApp"
BUILD_DIR=".build/release"
APP_BUNDLE="$APP_NAME.app"
SCRIPTS_TARGET="$HOME/Встречи/scripts"

echo "1/4 Собираю приложение…"
swift build -c release

echo "2/4 Формирую .app…"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

cat > "$APP_BUNDLE/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>MeetingApp</string>
    <key>CFBundleDisplayName</key>
    <string>Обработка встреч</string>
    <key>CFBundleIdentifier</key>
    <string>ru.sk.meetingapp</string>
    <key>CFBundleVersion</key>
    <string>3.0</string>
    <key>CFBundleShortVersionString</key>
    <string>3.0</string>
    <key>CFBundleExecutable</key>
    <string>MeetingApp</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Нужно для записи голоса и последующей транскрибации.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Нужно, чтобы сохранять саммари в Заметки и определять открытую встречу по вкладке браузера.</string>
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>Нужно, чтобы находить в календаре встречи со ссылкой на видеозвонок и предлагать их записать.</string>
    <key>NSCalendarsUsageDescription</key>
    <string>Нужно, чтобы находить в календаре встречи со ссылкой на видеозвонок и предлагать их записать.</string>
</dict>
</plist>
EOF

echo "3/4 Подписываю .app стабильным идентификатором…"
# swift build оставляет «сырую» ad-hoc-подпись без привязки к Info.plist и с
# именем бинарника вместо CFBundleIdentifier. Из-за этого каждая пересборка
# выглядела для TCC как новое приложение, и разрешения (микрофон, управление
# Заметками) не сохранялись между запусками build_app.sh. Подписываем сам
# .app целиком с фиксированным идентификатором — тогда macOS считает его
# одним и тем же приложением и держит выданные разрешения.
codesign --force --deep --sign - --identifier "ru.sk.meetingapp" "$APP_BUNDLE"

echo "4/4 Копирую скрипты в $SCRIPTS_TARGET…"
mkdir -p "$SCRIPTS_TARGET"
cp scripts/*.sh "$SCRIPTS_TARGET/"
chmod +x "$SCRIPTS_TARGET"/*.sh

echo ""
echo "Готово: $(pwd)/$APP_BUNDLE"
echo "Перемести его в /Applications и запусти двойным кликом."
