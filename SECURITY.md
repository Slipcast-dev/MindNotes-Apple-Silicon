# Security · Безопасность

**English**

MindNotes is a personal local app. The latest release on the Releases page and the `personal-ru` branch are supported.

Report security issues to the owner directly: <https://github.com/Slipcast-dev>. Do not put details in public issues.

Areas that matter most: parsing of files and backup archives, paths inside the workspace, SQLite queries, the update installer, the only network code in `Shell/Network/` (link previews, updates and the optional AI client), AI API keys in the keychain and prompt injection through page content.

No secrets, keys or personal data are added to the repository.

---

**Русский**

MindNotes — личное локальное приложение. Поддерживается последний выпуск со страницы Releases и ветка `personal-ru`.

О проблеме безопасности сообщайте владельцу напрямую: <https://github.com/Slipcast-dev>. Не указывайте подробности в открытых задачах.

Важно для проекта: разбор файлов и архивов резервных копий, пути внутри пространства, запросы к SQLite, установщик обновлений, единственный сетевой код в `Shell/Network/` (превью ссылок, обновления и необязательный клиент ИИ), ключи API ИИ в связке ключей и prompt injection через содержимое страниц.

Секреты, ключи и личные данные в репозиторий не добавляются.
