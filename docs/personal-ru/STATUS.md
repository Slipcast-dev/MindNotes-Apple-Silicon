# Статус

Ветка: `personal-ru`. Базовая метка: `baseline-1.4.2`. Текущий этап: **M1**.

## Выполнено

- M0: git, сверка с upstream, исправление сборки под Swift 5.8, обе архитектуры компилируются, тесты проходят.

## Шаги M1–M2

1. AppEdition и изоляция.
2. Каркас тестов и границы слоёв (`check-layers.sh`, `test-notes.sh`).
3. Domain: Page, Block, RichText, SortKey, ошибки, порты.
4. Оболочка M1: DesignTokens, ShellModel, RootView, NotesSidebar. Закрытие M1.
5. SQLite-обёртка, очереди, блокировка.
6. Migrator, схема v1, порядок открытия.
7. Репозитории страниц и блоков.
8. WorkspaceSession, PageService.
9. SaveCoordinator.
10. BlockDocument, EditCommand, UndoStack.
11. История (revisions).
12. BackupService.
13. RestoreService, копия перед миграцией.
14. Shell подключён к данным, InterimPageEditor.
15. Сквозной тест вертикального сценария.
16. Закрытие M2: замер `fullfsync`, сборка на двух архитектурах, ручной прогон.

## Следующий шаг

Шаг 1.
