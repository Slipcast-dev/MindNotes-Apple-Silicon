# Contributing to Grizzly

Thanks for your interest! Bug reports, ideas, translations and pull requests are welcome.

## Before you start

- Read the [Code of Conduct](CODE_OF_CONDUCT.md).
- Search existing [issues](https://github.com/Slipcast-dev/Grizzly/issues) first.
- For anything larger than a small fix, open an issue to discuss it before writing code.
- Security problems go through [SECURITY.md](SECURITY.md), never a public issue.

## Development setup

See [docs/en/building.md](docs/en/building.md).

```bash
./scripts/build-app.sh            # macOS app
cd electron && npm ci && npm start # Windows port, run from source
```

## Guidelines

- Keep the macOS and Windows apps behaviorally in sync; a feature change usually touches both `Sources/` and `electron/`.
- UI strings: Russian text is the key in `resources/ru.lproj`, English goes in `resources/en.lproj`. Run
  `npm run strings` in `electron/` after editing.
- No new network access (the update check against GitHub Releases is the only one), telemetry or new runtime dependencies without prior discussion.
- Match the surrounding code style; keep changes focused.
- Test by opening the files in [`samples/`](samples). For the Electron app, `npx electron scripts/smoke.js <files>` is a quick check.
- Never commit secrets, personal paths, build output (`build/`, `dist/`) or third-party assets you do not have the right to redistribute.

## Pull requests

1. Fork, create a branch from `main`.
2. Make the change, update docs and [CHANGELOG.md](CHANGELOG.md) when behavior changes.
3. Fill in the pull request template. CI must pass.

By contributing you agree to the contribution terms in the [Grizzly Proprietary License](LICENSE) (section 4): the author may use, modify and distribute your contribution as part of Grizzly.
