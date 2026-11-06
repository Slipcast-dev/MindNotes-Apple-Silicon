# Сборка из исходников

## Приложение для macOS (SwiftUI)

Нужно: macOS 13+, Xcode Command Line Tools (`xcode-select --install`). Полный Xcode не требуется —
скрипты вызывают `swiftc` напрямую.

```bash
./scripts/build-app.sh          # -> build/Grizzly.app (архитектура хоста, ad-hoc подпись)
./scripts/make-dmg.sh           # -> build/Grizzly-<версия>.dmg
```

Другая архитектура и отдельная папка вывода:

```bash
ARCH=arm64  OUT=build/arm64 ./scripts/build-app.sh && ARCH=arm64 OUT=build/arm64 ./scripts/make-dmg.sh   # -> Grizzly-<версия>-arm64.dmg
ARCH=x86_64 OUT=build/x64   ./scripts/build-app.sh && ARCH=x64   OUT=build/x64   ./scripts/make-dmg.sh   # -> Grizzly-<версия>-x64.dmg
```

`build-app.sh` принимает архитектуру компилятора (`x86_64`), `make-dmg.sh` — метку для имени файла (`x64`): встроенное обновление ищет `*-arm64.dmg` и `*-x64.dmg`.

Подпись и нотаризация для собственной раздачи (по желанию):

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="my-notary-profile" ./scripts/make-dmg.sh
```

Тесты (Swift-ядро компилируется через `swiftc`, затем `node --test tests/` для JS-порта):

```bash
./scripts/test.sh
```

`Package.swift` нужен редакторам с поддержкой SwiftPM; релизные сборки делаются скриптами выше.

## Приложение для Windows (Electron)

Нужно: актуальный Node.js LTS и npm. Portable .exe можно собрать и на macOS / Linux, не только на Windows. На Apple Silicon нужен Rosetta 2 (упаковщик NSIS — x86_64): `softwareupdate --install-rosetta --agree-to-license`.

```bash
cd electron
npm ci
npm start          # запуск из исходников
npm run dist       # -> dist/Grizzly-<версия>-portable.exe (x64)
```

Прочее:

```bash
npm run strings                          # пересобрать английскую таблицу из ../resources/en.lproj
npx electron scripts/smoke.js a.md b.csv # запустить настоящее приложение и вывести состояние
```

## Чек-лист релиза

1. Задайте версию в файле `VERSION` и в `electron/package.json` (`tests/version.test.cjs` проверяет, что они совпадают и что в CHANGELOG есть запись).
2. Обновите [CHANGELOG.md](../../CHANGELOG.md).
3. Запустите `./scripts/test.sh`, соберите артефакты и посчитайте суммы `shasum -a 256`.
4. Поставьте тег `vX.Y.Z` и создайте релиз на GitHub с артефактами и суммами. Встроенное обновление ищет файлы `*-arm64.dmg`, `*-x64.dmg` и `*-portable.exe` и берёт SHA-256 каждого из описания релиза (строка с именем файла и 64-значным хешем), поэтому сохраняйте этот формат. Релиз без строки с суммой обновление отклоняет.

## Патчи обновления

После `build-app.sh`: `./scripts/make-patch.sh build/release-X.Y.Z/Grizzly-X.Y.Z-arm64.dmg arm64` (образ предыдущего релиза) создаёт
`build/Grizzly-patch-<from>-to-<to>-arm64.zip` и печатает его SHA-256. Загрузите файл в релиз вместе с `.dmg` и добавьте напечатанную
строку в описание релиза, как контрольные суммы образов. То же для `x86_64`. Приложения на версии `<from>` скачают патч, остальные — образ.
