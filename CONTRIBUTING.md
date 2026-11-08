# Contributing

Issues and pull requests are welcome. Keep changes small and focused, and match the surrounding code.

Start from the latest [`main`](https://github.com/onehumanbeing/esp32-iphone-agent/tree/main) and open
pull requests against `main`. `release-1.0` is no longer the branch for contributions. Before you open a
pull request, update your branch from the latest `main` (fetch and rebase, or merge in the latest `main`).

Before sending a change, run the checks for what you touched:

```bash
# app (Xcode 26+)
cd ios && xcodegen && xcodebuild test -scheme IPhoneAgent -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
# firmware
hardware/flash.sh --build-only && make -C hardware/tests
# legacy server
cd server && pip install -e ".[dev]" && ruff check . && pytest
```

Never commit secrets: `ios/Config/Local.xcconfig` and `hardware/hid_bridge/secrets.h` are git-ignored on purpose.
Review and Diagnostics export raw run data; Settings › Privacy provides a separate redacted export.
See [Export runs for agent review](docs/run-data-export.md), and check archives before attaching them to an issue.

Code under `hardware/hid_bridge/src/airplay/` is GPL-3.0 (ported from UxPlay); contributions there are GPL-3.0 too.
