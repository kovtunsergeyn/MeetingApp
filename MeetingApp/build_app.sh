#!/bin/bash
# Собирает MeetingApp.app и раскладывает скрипты в ~/Встречи/scripts
set -e

APP_NAME="MeetingApp"
BUILD_DIR=".build/release"
APP_BUNDLE="$APP_NAME.app"
SCRIPTS_TARGET="$HOME/Встречи/scripts"
SIGN_IDENTITY="MeetingApp Local Signing"

# Создаёт локальный самоподписанный сертификат для подписи приложения, если
# его ещё нет в связке ключей. Нужен для того, чтобы «designated requirement»
# подписи был привязан к сертификату, а не к хэшу бинарника: иначе macOS после
# каждой пересборки считает приложение новым и сбрасывает выданные разрешения
# (запись экрана, календарь, доступ к папкам). Платный Developer ID для этого
# не требуется. Сертификат живёт 10 лет, лежит в login-связке ключей и
# удаляется через Связку ключей, если станет не нужен.
ensure_signing_certificate() {
  if security find-certificate -c "$SIGN_IDENTITY" >/dev/null 2>&1; then
    return 0
  fi

  echo "   Сертификата «$SIGN_IDENTITY» нет — создаю (один раз на этот компьютер)…"
  local workdir
  workdir=$(mktemp -d)
  # Ключ и временный контейнер удаляем сразу после импорта — в связке ключей
  # остаётся только сам сертификат с приватным ключом.
  trap 'rm -rf "$workdir"' RETURN

  cat > "$workdir/cert.conf" << 'CONF'
[req]
distinguished_name = dn
x509_extensions = v3_codesign
prompt = no

[dn]
CN = MeetingApp Local Signing

[v3_codesign]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CONF

  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$workdir/key.pem" -out "$workdir/cert.pem" \
    -config "$workdir/cert.conf" >/dev/null 2>&1

  # Apple Security не принимает PKCS12 с современными алгоритмами OpenSSL,
  # поэтому экспортируем в legacy-формате.
  openssl pkcs12 -export -out "$workdir/bundle.p12" \
    -inkey "$workdir/key.pem" -in "$workdir/cert.pem" \
    -name "$SIGN_IDENTITY" -passout pass:meetingapp \
    -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES >/dev/null 2>&1

  # Ключом разрешаем пользоваться только codesign (-T), без -A: иначе доступ
  # к приватному ключу без запроса получило бы любое приложение на машине.
  security import "$workdir/bundle.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
    -P meetingapp -T /usr/bin/codesign >/dev/null 2>&1

  if security find-certificate -c "$SIGN_IDENTITY" >/dev/null 2>&1; then
    echo "   Сертификат создан."
  else
    echo "   Не удалось создать сертификат — подпись будет ad-hoc."
  fi
}

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
ensure_signing_certificate
if security find-certificate -c "$SIGN_IDENTITY" >/dev/null 2>&1; then
  codesign --force --deep --sign "$SIGN_IDENTITY" --identifier "ru.sk.meetingapp" "$APP_BUNDLE"
else
  echo "   ВНИМАНИЕ: подписываю ad-hoc — разрешения macOS будут слетать при каждой пересборке."
  codesign --force --deep --sign - --identifier "ru.sk.meetingapp" "$APP_BUNDLE"
fi

echo "4/4 Копирую скрипты в $SCRIPTS_TARGET…"
mkdir -p "$SCRIPTS_TARGET"
cp scripts/*.sh "$SCRIPTS_TARGET/"
chmod +x "$SCRIPTS_TARGET"/*.sh

echo ""
echo "Готово: $(pwd)/$APP_BUNDLE"
echo "Перемести его в /Applications и запусти двойным кликом."
