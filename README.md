# Agent-Friendly Documentation Spec Checker

<img src="icon.jpeg" alt="Agent-Friendly Docs Checker" />

Checks all Sui docs sites against the [Agent-Friendly Documentation spec](https://agentdocsspec.com/spec/). Compares results against the previous day's run and flags any regression in the number of passing tests. Posts results to Slack.

**Docs Link Check — 2026-04-16**

| Status | Site | URL | Passed | Warnings | Failed | Skipped | Total |
|--------|------|-----|-------:|---------:|-------:|--------:|------:|
| ✅ PASS | Move Book | https://move-book.com | 17 | 1 | 2 | 2 | 22 |
| ✅ PASS | SDKs | https://sdk.mystenlabs.com/ | 17 | 1 | 2 | 2 | 22 |
| ✅ PASS | Seal | https://seal-docs.wal.app | 18 | 2 | 1 | 1 | 22 |
| ✅ PASS | Sui | https://docs.sui.io | 18 | 1 | 2 | 1 | 22 |
| ✅ PASS | SuiNS | https://docs.suins.io | 18 | 0 | 1 | 3 | 22 |
| ✅ PASS | Walrus | https://docs.wal.app | 17 | 2 | 2 | 1 | 22 |

Full spec: https://agentdocsspec.com/spec/
