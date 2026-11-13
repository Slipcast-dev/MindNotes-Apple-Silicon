<p align="center"><img src="docs/assets/logo.png" alt="MindNotes icon" width="128"></p>

# MindNotes

**English** · [Русский](README.ru.md)

[![CI](https://github.com/Slipcast-dev/MindNotes-Apple-Silicon/actions/workflows/ci.yml/badge.svg?branch=personal-ru)](https://github.com/Slipcast-dev/MindNotes-Apple-Silicon/actions/workflows/ci.yml)

A personal, local knowledge base for Mac: pages, a block editor, search, links and Notion-style databases. Your data stays on this Mac; no account is needed.

**Download:** [MindNotes — latest release](https://github.com/Slipcast-dev/MindNotes-Apple-Silicon/releases/latest) — a `.dmg` for Apple silicon Macs with macOS 15 or later (from 1.7.0; 1.6.x needs macOS 26).

> **Apple silicon only: arm64, macOS 15 Sequoia or newer** (from 1.7.0; ADR-0020).

## Features

- Pages and subpages, a block editor, trash and version history with restore
- ⌘K search, `[[` links, backlinks, favourites, tags, templates
- `@`-mentions of pages, people and dates with local reminders
- Bookmarks with link previews, embeds (YouTube, Vimeo, Figma, Google Maps), synced blocks, columns, block colours
- Comments on text and pages, with threads and “Resolved”
- Databases: table, board, list, calendar, gallery and timeline views; relations, rollups, formulas, people and file properties; filters, sorts, grouping and manual order; live databases inside a page
- Images, files and video attachments
- Import of Markdown, CSV, folders and Notion exports; export to Markdown and CSV
- Manual and automatic backups
- Collapsible sidebar with custom sections you can drag to reorder, Peek, light/dark and black-and-white themes
- Password lock for a page, record, database or folder (password, Touch ID or Mac password)
- Automatic or manual updates; extensions for custom themes and app icons
- Plugins with permissions, released separately; the first one is [Web Clipper](Plugins/WebClipper/README.md) for Chrome and Safari ([latest release](https://github.com/Slipcast-dev/MindNotes-Apple-Silicon/releases/tag/webclipper-v1.0.0))
- Optional AI (off by default): Ask AI on a selection, chat with an agent that proposes changes before applying them, AI-filled database properties; Claude, OpenAI, OpenRouter, Gemini, DeepSeek, Mistral, xAI, Groq or a local model via Ollama or LM Studio

The interface is available in English and Russian.

## Network

Only when you choose it: link previews (off by default), checking GitHub for updates (can be set to “Manual”) and AI (off by default). Workspace data is sent only to the AI provider you chose, and only the text you ask AI about; with Ollama or LM Studio it stays on this Mac. See the [AI guide](docs/en/AI_GUIDE.md).

## Documentation

- [Build, run and restore](docs/en/BUILD_AND_USE.md)
- [Extensions: themes, icons and plugins](docs/en/EXTENSIONS.md)
- [AI](docs/en/AI_GUIDE.md)
- [Architecture](docs/en/ARCHITECTURE.md)
- [Known limitations](docs/en/KNOWN_LIMITATIONS.md)
- [Changelog](CHANGELOG.md)

Development logs (status, plan, test report, ADRs) are kept in Russian in [docs/personal-ru](docs/personal-ru/STATUS.md).

Based on Grizzly. © 2026 Slipcast-dev, see [LICENSE](LICENSE).
