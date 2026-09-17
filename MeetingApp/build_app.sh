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
cp Resources/AppIcon.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

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
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
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

echo "3/4 Подписываю .app…"
# Почему не ad-hoc (--sign -): у ad-hoc подписи «designated requirement» — это
# буквально хэш бинарника (cdhash H"..."). Любая пересборка меняет хэш, и для
# TCC это уже другое приложение: выданные разрешения (запись экрана, календарь,
# доступ к папкам) перестают действовать, хотя в Системных настройках строка
# приложения остаётся и выглядит включённой. Поэтому подписываем локальным
# самоподписанным сертификатом — тогда требование становится
# «identifier + certificate leaf», от хэша не зависит, и разрешения переживают
# пересборки. Сертификат создаётся один раз и лежит в login-связке ключей.
SIGN_IDENTITY="MeetingApp Local Signing"
if security find-certificate -c "$SIGN_IDENTITY" >/dev/null 2>&1; then
  codesign --force --deep --sign "$SIGN_IDENTITY" --identifier "ru.sk.meetingapp" "$APP_BUNDLE"
else
  echo "  ВНИМАНИЕ: сертификат «$SIGN_IDENTITY» не найден в связке ключей."
  echo "  Подписываю ad-hoc — разрешения macOS будут слетать при каждой пересборке."
  codesign --force --deep --sign - --identifier "ru.sk.meetingapp" "$APP_BUNDLE"
fi

echo "4/4 Копирую скрипты в $SCRIPTS_TARGET…"
mkdir -p "$SCRIPTS_TARGET"
cp scripts/*.sh "$SCRIPTS_TARGET/"
chmod +x "$SCRIPTS_TARGET"/*.sh

echo ""
echo "Готово: $(pwd)/$APP_BUNDLE"
echo "Перемести его в /Applications и запусти двойным кликом."
