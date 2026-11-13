<p align="center"><img src="docs/assets/logo.png" alt="Значок MindNotes" width="128"></p>

# MindNotes

[English](README.md) · **Русский**

[![CI](https://github.com/Slipcast-dev/MindNotes-Apple-Silicon/actions/workflows/ci.yml/badge.svg?branch=personal-ru)](https://github.com/Slipcast-dev/MindNotes-Apple-Silicon/actions/workflows/ci.yml)

Личная локальная база знаний для Mac: страницы, блочный редактор, поиск, ссылки и базы данных в духе Notion. Данные хранятся на этом Mac, аккаунт не нужен.

**Скачать:** [MindNotes — последний выпуск](https://github.com/Slipcast-dev/MindNotes-Apple-Silicon/releases/latest) — образ `.dmg` для Mac на Apple Silicon с macOS 15 или новее (с версии 1.7.0; 1.6.x требует macOS 26).

> **Только Apple Silicon: arm64, macOS 15 Sequoia или новее** (с версии 1.7.0; ADR-0020).

## Возможности

- Страницы и подстраницы, блочный редактор, корзина, история версий с восстановлением
- Поиск ⌘K, ссылки `[[`, обратные ссылки, избранное, теги, шаблоны
- `@`-упоминания страниц, людей и дат с локальным напоминанием
- Закладки с превью ссылок, встраивания (YouTube, Vimeo, Figma, Google Maps), синхронизированные блоки, колонки, цвет блока
- Комментарии к тексту и к странице, ветки и «Решено»
- Базы данных: таблица, доска, список, календарь, галерея и хронология; связи, свёртки, формулы, свойства «Человек» и «Файлы и медиа»; фильтры, сортировка, группировка и ручной порядок; живые базы прямо в тексте страницы
- Картинки, файлы, видео
- Импорт Markdown, CSV, папок и экспорта Notion; экспорт в Markdown и CSV
- Резервные копии вручную и автоматически
- Сворачиваемая боковая панель со своими разделами, которые перетаскиваются, Peek, светлая, тёмная и чёрно-белая темы
- Пароль на страницу, запись, базу или папку (пароль, Touch ID или пароль Mac)
- Обновления автоматически или вручную; расширения для своих тем и иконок приложения
- Плагины с разрешениями, выпускаются отдельно; первый — [Web Clipper](Plugins/WebClipper/README.md) для Chrome и Safari ([последний выпуск](https://github.com/Slipcast-dev/MindNotes-Apple-Silicon/releases/tag/webclipper-v1.0.0))
- Необязательный ИИ (выключен по умолчанию): «Спросить ИИ» над выделением, чат с агентом, который предлагает изменения до их применения, ИИ-свойства баз; Claude, OpenAI, OpenRouter, Gemini, DeepSeek, Mistral, xAI, Groq или локальная модель через Ollama и LM Studio

Интерфейс — на русском и английском.

## Сеть

Только по вашему выбору: превью ссылок (выключено по умолчанию), проверка обновлений на GitHub (можно переключить на «Вручную») и ИИ (выключен по умолчанию). Данные пространства уходят только выбранному провайдеру ИИ и только тот текст, к которому вы обращаетесь; с Ollama и LM Studio они остаются на этом Mac. Подробнее — [ИИ в MindNotes](docs/personal-ru/AI_GUIDE.md).

## Документы

- [Сборка, запуск и восстановление](docs/personal-ru/BUILD_AND_USE.md)
- [Расширения: темы, иконки и плагины](docs/personal-ru/EXTENSIONS.md)
- [ИИ](docs/personal-ru/AI_GUIDE.md)
- [Архитектура](docs/personal-ru/ARCHITECTURE.md)
- [Известные ограничения](docs/personal-ru/KNOWN_LIMITATIONS.md)
- [Текущий статус](docs/personal-ru/STATUS.md) и [план](docs/personal-ru/PLAN.md)
- [Список изменений](CHANGELOG.ru.md)

Основано на Grizzly. © 2026 Slipcast-dev, см. [LICENSE](LICENSE).
