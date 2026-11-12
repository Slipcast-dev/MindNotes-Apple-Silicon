# AI in MindNotes

AI is optional and off by default. While it is off, the app sends no requests and does not read any keys.

## Turning it on

Settings → “AI” → “Turn on AI” → consent window. Then:

1. **Provider**: Anthropic (Claude), OpenAI, OpenRouter, Google Gemini, DeepSeek, Mistral, xAI (Grok), Groq, Ollama or LM Studio on this Mac, or “Custom (OpenAI-compatible)” at an `https://…` or `http://localhost…` address.
2. **API key** — paste it and click “Save”. Keys are stored in the macOS keychain, one per provider. Local servers need no key.
3. **“Check”** loads the model list; pick a model, find it by searching part of its name, or type one.

Text you ask AI about is sent to the chosen provider. Pricing follows the provider's rates; “Usage” shows token counts (and an estimated cost for Claude).

## Where it works

- **On a selection:** “✦ Ask AI” on the formatting toolbar or ⌘J → an action or your own prompt. The answer is a preview first: “Replace selection”, “Insert below”, “Try again”, or a follow-up. Inserting is undone with one ⌘Z.
- **On an empty line:** Space → “Continue writing”, “Summarize page”, drafts.
- **Chat** — “Notes AI” in the sidebar (between Search and Home) or ⌘L. Drag the panel's left edge to resize it; the provider and model are shown at the bottom, where the model can be switched. Sources: “This page”, “All pages”, “Tools only”; “@” attaches a page, 📎 an image, PDF or text file. Chat history is stored in the workspace.
- **The agent in chat** searches and reads pages and databases, and proposes changes — new pages, text, database records, properties, trash — as a card first. Nothing changes until “Apply”; editing existing content and trash always ask; “Undo” reverts everything.
- **AI properties in databases:** “Properties” → property → ✦ → fill mode → “Fill empty”, “Update AI-filled” or “Overwrite all…”. AI-filled cells show ✦; a manual edit removes the mark. “Undo fill” reverts the last fill. “Update when the record changes” is optional (each update is a paid request). With Claude, more than 50 records can be sent as a half-price batch.

## Privacy

- “…” on a page → “Don't send to AI”: the page and its subpages are excluded from search, reading and agent edits. Password-locked pages are never sent either.
- “AI instructions” (button in Settings) is a page with style and rules that AI reads before every answer.
- Page and file contents are passed to the model as data: the agent does not follow commands found in page text.

See [Known limitations](KNOWN_LIMITATIONS.md).
