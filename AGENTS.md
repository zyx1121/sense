# sense

Swift macOS menu bar app: live captions of system audio with SpeechAnalyzer and transcript cleanup with a small model. It also has push-to-talk, shake-to-capture, and headless Claude Code for questions. Read [README.md](README.md) and [docs/](docs/) first.

## Rules

- Audio stays on the Mac. Only transcript text goes to the cleanup model, and only a question, the recent transcript and the captures go to Claude Code.
- Never bundle an API key or route data through a server of ours. The OpenAI key comes from `OPENAI_API_KEY` or the Keychain item `sense`/`openai`, and the agent is the user's own `claude` CLI.
- The microphone is open only while the user holds right ⇧ or meeting mode is on.
- Draft text is for display only. Cleanup sees finals only.
- Everything persistent lives in `~/.sense`.
- Repository documents and code comments are English. The design notes in `docs/` are Traditional Chinese.

## Verify

```sh
make bundle
make run
make logs
```

The build needs macOS 26, so it is an exception to the sandbox rule. Play a video and watch the caption and the `asr` and `polish` events. Ask one question in the overlay and watch the `agent` events.

## Release

Push a `v*` tag. `release.yml` imports the Developer ID certificate from repo secrets, runs `make release` (sign, notarize, staple, DMG) and creates the GitHub release. The DMG name comes from `APP_NAME` and the version in `Resources/Info.plist`. `make publish` does the same from the Mac.
