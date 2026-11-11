# Архитектура MindNotes

Статус: действующее устройство приложения после M0–M14 (схема пространства v10). Что сделано — `STATUS.md`, решения — ADR в `adr/`.

Ограничения: один модуль, сборка `swiftc`, без внешних зависимостей, только arm64 и macOS 26 (ADR-0009, `scripts/target.sh`). Сеть — только превью ссылок и обновления, в `Shell/Network/` (ADR-0011, ADR-0014). Цель: 10 тыс. страниц, 100 тыс. блоков, один пользователь, один процесс на пространство.

## 1. Модули и границы

```text
Sources/MindNotes/
  App/                       # точка входа, AppDelegate, настройки оформления
  Core/                      # AppEdition (имя, id, каталог данных, перенос со старых имён), локализация
  Workspace/Domain/          # Page, Block, RichText, базы и формулы, хронология, упоминания, комментарии, разделы, расширения, обновления
  Workspace/Services/        # WorkspaceSession, EditorSession (в т. ч. синхронизированные блоки), SaveCoordinator, перенос данных
  Persistence/               # SQLiteConnection, очереди, блокировка, Migrations/ (v1–v10), SQLiteWorkspace+*, SearchIndex
  BlockEditor/Commands/      # BlockDocument, EditCommand, UndoStack, фрагменты, данные неделимых блоков
  BlockEditor/UI/            # нативный редактор (Native/), панели и модель страницы
  Backup/                    # TarArchive, BackupService, RestoreService
  ImportExport/              # Markdown, CSV, папки, экспорт Notion, экспорт пространства
  Shell/                     # RootView, ShellModel, боковая панель, Screens/, Database/, расширения, токены оформления
  Shell/Network/             # единственное место с сетью: превью ссылок и обновления
```

| Слой | Импорт | Может использовать |
|---|---|---|
| Workspace/Domain | Foundation | ничего |
| BlockEditor/Commands | Foundation | Domain |
| Workspace/Services | Foundation | Domain, Commands, порты |
| Persistence | Foundation, SQLite3 | Domain |
| Backup | Foundation, CryptoKit | Domain, порт снимков |
| BlockEditor/UI, Shell | SwiftUI, AppKit | всё выше; зависимости собираются только в Shell |

Границы проверяет `scripts/check-layers.sh`: grep запрещённых импортов и `swiftc -typecheck` по нарастающим подмножествам (ссылка на верхний слой даёт ошибку компиляции).

Тесты новых слоёв: `tests/swift-notes/` и `scripts/test-notes.sh`, `-Onone`, файлы через `find`. Аварии имитируются самоперезапуском с `--crash-at=<точка>` и `_exit`; заполненный диск — `PRAGMA max_page_count`; отсутствие прав — `chmod 0500`; время — порт `SaveScheduler`.


## 2. Схема

UUID — TEXT в нижнем регистре, время — INTEGER (мс UTC). `application_id=0x47525A4E`, `user_version` — номер последней миграции (сейчас 10), `foreign_keys=ON`.

| Таблица | Поля | Индексы |
|---|---|---|
| workspace_meta | key PK, value | WITHOUT ROWID |
| schema_migrations | version PK, name, applied_at, app_version | |
| pages | id, parent_id FK SET NULL, sort_key, title, icon, cover_asset_id FK, full_width, favorite_key, created_at, updated_at, last_opened_at, deleted_at, trash_batch_id, content_rev | частичные (deleted_at IS NULL): (parent_id, sort_key, id), (favorite_key), (last_opened_at DESC); (deleted_at); (cover_asset_id) |
| blocks | id, page_id FK CASCADE, parent_id FK CASCADE, sort_key, type (без CHECK), content_v, content_json, plain_text, created_at, updated_at | (page_id, parent_id, sort_key, id); (parent_id) |
| revisions | id, page_id FK CASCADE, seq, created_at, reason, format_v, codec, payload, content_hash, byte_size | UNIQUE(page_id, seq); (page_id, created_at DESC) |
| tags (v2) | id, name, name_key UNIQUE, color, created_at | сравнение без учёта регистра и ё/е |
| page_tags (v2) | page_id FK CASCADE, tag_id FK CASCADE | WITHOUT ROWID; (tag_id) |
| assets | id, rel_path UNIQUE, original_name, mime, byte_size, sha256, created_at, unreferenced_since | (sha256); частичный по unreferenced_since |
| block_assets, revision_assets | owner_id FK CASCADE, asset_id FK RESTRICT | WITHOUT ROWID; (asset_id) |

- Содержимое блока — `{"runs":[{"t":"Привет","m":["b"]}], ...}`. Неизвестные поля сохраняются; неизвестный `type` или более новый `content_v` хранятся непрозрачно.
- Вид пространства (логотип, обложка) — JSON в `workspace_meta.look`; изображения — управляемые файлы `assets/`.
- Версии: v2 — теги; v3 — `search_index` (FTS5), `page_links`; v4 — базы (`databases`, `property_definitions`, `property_options`, `property_values`, `property_value_options`, `database_views`, `pages.database_id`); v5 — `templates`; v6 — связи; v7 — формулы; v8 — люди, файлы в свойствах, ручной порядок (`people`, `property_value_people`, `property_value_assets`, `view_record_order`); v9 — разделы (`page_sections`, `page_section_members`); v10 — `comments`.
- База — страница (`databases.page_id`), запись — страница с `database_id` и родителем-страницей базы: дерево, корзина, поиск, архив и редактор общие. Записи скрыты из боковой панели, пока их база не в корзине.
- Дата без времени — строка `ГГГГ-ММ-ДД`, в момент не преобразуется. Момент — `value_ts` (мс UTC), `value_tz` и настенное время в `value_date` для сравнения.
- Запрос (`DatabaseQuerySQL`): операции из белого списка `FilterOp.available(for:)`, значения и ID свойств только параметрами. Неполное или неизвестное правило пропускается. Сравнение текста — функция `mindnotes_norm` на читающем соединении, в схеме не используется.
- Смена типа: значение → текст → новый тип. Один расчёт для просмотра и применения; неудача сохраняется в `property_values.unconverted`.
- Виды: `table`, `board`, `list`, `calendar`, `gallery`, `timeline`. Группа — обычное правило фильтра поверх состояния (`narrowed(by:)`), поэтому механизм запроса один, а столбцы и разделы загружаются порциями. Календарь запрашивает записи месяца теми же правилами. Перенос меняет значение свойства обычной записью, и другие виды видят его при чтении.
- Встроенное представление — неделимый блок `database_view`: страница базы, вид и своё состояние в JSON блока. Записи не копируются. В тексте — живое представление (тот же экран базы поверх места в тексте, ADR-0013); без него — карточка с первыми записями.
- Шаблон — скрытая копия страницы с поддеревом: `deleted_at` задан, `trash_batch_id` пуст (ADR-0008). Создание идёт через `copySubtree`, общую с дублированием.
- Состояние представления — JSON в `database_views.state_json`; неизвестные поля и операции сохраняются. Удаление свойства или варианта и смена типа чистят правила в той же транзакции.
- Ключ порядка — дробная строка base-62, сравнение BINARY, разрешение ничьей по `id`; длина больше 48 символов — перенумерация соседей в той же транзакции.
- Корзина: поддерево получает общий `trash_batch_id`. Перемещение: `BEGIN IMMEDIATE`, проверка цикла рекурсивным CTE, обновление.

## 3. Хранилище и сохранение

- Три соединения, каждое на своей последовательной `DispatchQueue`: запись, чтение UI, снимки. Снаружи — `async`-обёртка.
- Все соединения: `foreign_keys=ON`, `busy_timeout=5000`, `trusted_schema=OFF`. Запись: WAL, `synchronous=FULL`, `fullfsync=ON`, `checkpoint_fullfsync=ON`. Чтение: `query_only=ON`.
- Блокировка: `.workspace.lock`, `flock(LOCK_EX|LOCK_NB)` на всю сессию; файл не удаляется.
- Открытие: права → `flock` → READONLY-проверка `application_id`, `user_version`, `quick_check` → более новая схема: отказ без записи → более старая: проверенный полный backup и миграция → открытие на запись и чтение.
- Миграция: отдельная `BEGIN EXCLUSIVE`, шаг, `foreign_key_check`, `user_version`, `schema_migrations`, `COMMIT`. Исходная схема для тестов миграций — `tests/fixtures/notes/schema_v1.sql`; каждая следующая версия проверяется тестом обновления с предыдущей.
- `SaveCoordinator`: `editSeq` растёт с каждой правкой; таймер `min(lastEdit+500 мс, firstDirty+2 с)`; в записи один пакет. Статус вычисляется: `saved` только при `editSeq == committedSeq` после подтверждения COMMIT.
- Ошибка записи: пакет возвращается под новые правки, повторы через 1/2/5/15 с и вручную, аварийный экспорт из памяти.
- Запись никогда не возвращает данные в открытый редактор. Переход на другую страницу и завершение приложения ждут `flush`; через 5 с завершение показывает диалог «Повторить / Аварийный экспорт / Выйти без сохранения».
- История: снимок не чаще раза в 10 минут при изменении, при уходе со страницы и перед восстановлением, zlib, пропуск при том же хэше. Удержание (`RevisionRetention`): всё за 24 ч, почасово 7 дней, посуточно 30 дней, дальше понедельно; самый новый снимок всегда. Прореживание после каждого снимка страницы.
- Вложения: `tmp/` на том же томе, `fsync`, `rename` в `assets/<2hex>/<uuid>[.ext]`, затем транзакция. Файлы неизменяемы. Уборка сирот с безопасным периодом, не во время backup.

## 4. Резервная копия

Формат: один файл `.mindnotesbackup` (архивы прежних версий того же формата тоже читаются), несжатый ustar (см. `adr/0003-backup-format.md`).

Создание: `sqlite3_backup` во временный файл → `integrity_check`, `foreign_key_check` на копии → список вложений из копии → потоковая запись в `.partial` с SHA-256 и сверкой с `assets.sha256` → `manifest.json` и `manifest.sha256` последними → `fsync`, `rename`. Нет манифеста — архив обрезан. Отсутствующие файлы попадают в `missing`, и копия не считается полной.

Восстановление: только в новый или пустой каталог, работа в `<цель>.restoring`. Только обычные файлы; имена по белому списку; лишние и дублирующиеся записи — отказ. Проверки SHA-256, состава, версии схемы, `integrity_check`, соответствия вложений. Новый `workspace_id`, старый в `restored_from`, затем `rename`.

Перед миграцией всегда делается полная проверенная копия (решение M0: прямое чтение ТЗ §8).

## 5. Изоляция

Единая точка: `Core/AppEdition.swift`. Отдельные идентификатор и каталог данных; `UserDefaults` разделяются автоматически; сборка не заявляет себя обработчиком по умолчанию.

Настоящие данные принадлежат только сборке с официальным идентификатором (`AppDataScope`). Копия с другим идентификатором получает каталог `MindNotes-Test-<идентификатор>` и не выполняет перенос со старого имени. Такую копию запускает `scripts/run-isolated.sh`.

## 6. Оболочка

- Корень окна — `RootView`, раскладка `NotesLayout`: боковая панель (240 по умолчанию, 200–480, сворачивается ⌘\\), строка пути 54, содержимое; поверх — Peek и окно обновления.
- Заголовок окна: название и переключатель темы, больше ничего.
- `ShellModel` принадлежит `AppDelegate`, новых singleton нет. Навигация последовательна (`enqueue`).
- `Shell/DesignTokens.swift`: динамические `NSColor` со значениями из CSS макета.
- Экран «Импорт»: источники (Markdown, CSV, папка, экспорт Notion) и недавние файлы с просмотром.
- Производные от списка страниц (`PageTree`, избранное, недавние) `ShellModel` считает один раз при изменении: интерфейс читает их при каждой перерисовке.
- Боковая панель — плоский `LazyVStack` из `PageTree.rows`: строятся только строки на экране. Перемещение страницы — окно `MovePageSheet`, а не подменю в контекстном меню: содержимое контекстного меню SwiftUI вычисляет вместе со строкой.

## 7. Редактор

Единый `NSTextView` на страницу, TextKit 1: см. `adr/0005-block-editor.md`.

Пункты меню, панель и «/» строятся из единого списка `EditorAction`.

Команды — чистая функция `apply(EditCommand, BlockDocument, BlockSelection, IDGenerator) -> EditResult`: `changes` идут в `SaveCoordinator`, `inverse` в `UndoStack`.

Вид: `BlockEditor/UI/Native/` (`BlockEditorController`, `BlockTextView`); проверяется автотестами без оболочки. Колонки и живые представления — отдельные виды поверх места в тексте (ADR-0013): у колонки свой контроллер со `scope` на той же сессии. Синхронизированный блок — слой перевода в `EditorSession` (ADR-0012).

## 8. Правила

- SwiftUI/AppKit запрещены в Domain, Services, Commands, Persistence, Backup; `sqlite3_*` только в Persistence.
- Запись только через `WriteQueue`, одна транзакция на пакет; соединение не покидает свою очередь.
- «Сохранено» выводится только из подтверждённого `committedSeq`.
- Любая правка блока идёт через `EditCommand`.
- Неизвестные тип, версия и поля сохраняются без потерь.
- Сначала файл, затем ссылка в БД; пути только относительные и проверяются.
- Новая версия схемы никогда не открывается на запись.

## 9. Риски

1. Вложенные виды поверх `NSTextView` (колонки, живые представления): высота места и положение пересчитываются после правок; ошибки вида проявятся как смещение, а не как потеря данных.
2. Замеры на устройстве слабее контрольного не являются приёмочными.
3. Задержка `fullfsync`: при проблеме — только пакетирование.
4. Своя обёртка SQLite: время жизни statement, `SQLITE_TRANSIENT`.
5. Свой TAR-читатель — вход недоверенных данных: тесты на `../`, символьные ссылки, дубликаты, обрезку.
6. Обновление без подписи Developer ID проверяет образ только суммой из того же выпуска (ADR-0014).
