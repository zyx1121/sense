```text
██╗  ██╗██╗██╗      ██████╗
██║ ██╔╝██║██║     ██╔═══██╗
█████╔╝ ██║██║     ██║   ██║
██╔═██╗ ██║██║     ██║   ██║
██║  ██╗██║███████╗╚██████╔╝
╚═╝  ╚═╝╚═╝╚══════╝ ╚═════╝
```

# kilo-sense

> macOS sensory agent — hears what you're hearing, sees what you point at; transcribes, cleans up, analyzes, and remembers, in real time.

`SpeechAnalyzer` · `ScreenCaptureKit` · `codex` · `gpt-5.4-mini` · `shake-to-capture`

**English** · [繁體中文](README.zh-TW.md)

## What it does

Leave kilo-sense running while you watch a video, sit in a meeting, take a class:

- **Notch captions** — system audio transcribed live; volatile text types out in grey, finalizes to white, scrolling one line beneath the notch
- **Auto CN/EN switching** — two `SpeechTranscriber` paths run at once; it compares each path's per-final confidence (EMA + hysteresis) and follows whichever language you're speaking
- **Continuous transcript** — a draggable overlay accumulates the full text; a small model cleans the raw stream in the background (punctuation, mis-recognition fixes, paragraph breaks) — the grey tail keeps flowing in and is replaced by polished white text seconds later. Each section is headed by its timestamp and the source app it came from (`Safari: <video title>`, etc.); a new section starts on a silence gap or a source change
- **Ask Kilo** — the input field talks straight to a codex agent (carrying the recent transcript + session memory); tool-use steps surface live, replies stream typewriter-style; tell it to take a note and it writes into `~/.kilo/`, and paths in its replies open on click
- **Push-to-talk** — hold **right ⇧** and speak; your words type into the input field live (transcribed on-device), release to edit, Enter to send. The mic is only open while the key is held
- **Meeting mode** — system loopback never contains your own voice, so in a call the transcript would miss your side; toggle this from the menu bar and the mic records continuously, your speech landing in the transcript labeled **我** while system audio stays the other side
- **Shake to capture** — wiggle the cursor to enter selection mode: the screen dims, the UI element under the cursor lights up, left-click collects it (text as text, anything else as a screenshot), right-click ends. Captures become chips above the input field, handed to codex on the next turn

## Architecture

```mermaid
flowchart TD
    ear["👂 System audio<br/>what you hear"]
    eye["👆 Shake-to-capture<br/>what you point at"]
    asr["Live transcription<br/>SpeechAnalyzer · dual-language routing"]
    notch["Notch captions<br/>grey volatile → white final"]
    hub["📝 Transcript + context hub"]
    polish["Transcript cleanup<br/>gpt-5.4-mini"]
    agent["Codex agent<br/>codex exec --json"]
    ui["Ask Kilo<br/>main window · feed · chips"]
    disk[("~/.kilo · local<br/>notes · transcripts · captures · training")]

    ear --> asr
    asr --> notch
    asr --> hub
    eye --> hub
    hub --> polish
    hub --> ui
    ui <--> agent
    hub --> agent
    polish --> disk
    agent --> disk

    classDef device fill:#e6f4ea,stroke:#34a853,color:#0b3d20;
    classDef cloud fill:#e8f0fe,stroke:#4285f4,color:#0b2a5b;
    classDef store fill:#fef7e0,stroke:#f9ab00,color:#5b4300;
    class ear,eye,asr,notch,hub,ui device;
    class polish,agent cloud;
    class disk store;
```

> 🟩 **on-device** — sensing + UI; system audio never leaves your Mac. 🟦 **cloud** — your own OpenAI key / codex CLI (cleanup + reasoning only). 🟨 **local** — everything persists under `~/.kilo`.

## Transcription pipeline

```mermaid
flowchart TD
    audio["🔊 System audio<br/>ScreenCaptureKit · 16 kHz mono"]
    asr["🍎 Apple ASR — SpeechAnalyzer<br/>zh-TW + en-US, both running at once"]
    router["⚖️ Language referee — LanguageRouter<br/>per-final confidence EMA + hysteresis, one path wins"]
    draft["Draft text (volatile — may still be rewritten)<br/>notch grey + window dim tail, display only"]
    queue["📥 Final-text queue (already on screen in grey)<br/>flush on: 60 chars · language switch · 4 s idle"]
    polish["☁️ Cleanup — gpt-5.4-mini<br/>punctuation + mis-recognition fixes<br/>the only cloud hop; on failure raw passes through"]
    post["🔧 Deterministic post-processing<br/>paragraph breaks · seam stitching · echo dedup"]
    white["⚪ Polished transcript — white text"]
    archive[("~/.kilo/transcripts/<br/>YYYY-MM-DD.md")]
    pairs[("~/.kilo/training/polish-pairs.jsonl<br/>raw → cleaned corpus")]

    audio --> asr --> router
    router -->|volatile| draft
    router -->|final| queue
    queue --> polish --> post --> white
    white --> archive
    polish -.->|raw ≠ cleaned| pairs

    classDef device fill:#e6f4ea,stroke:#34a853,color:#0b3d20;
    classDef cloud fill:#e8f0fe,stroke:#4285f4,color:#0b2a5b;
    classDef store fill:#fef7e0,stroke:#f9ab00,color:#5b4300;
    class audio,asr,router,draft,queue,post,white device;
    class polish cloud;
    class archive,pairs store;
```

Apple's recognizer emits each utterance twice: first as **volatile** drafts that it keeps rewriting while you speak, then as a **final**. Volatile text is display-only — grey in the notch, dim tail in the window. Finals queue up and are cleaned in batches; a batch flushes on whichever comes first: **60 chars accumulated**, a **language switch**, or **4 s of silence**.

Why batch instead of cleaning every final? Micro-batching (size-or-idle, the same shape as Kafka's `batch.size` + `linger.ms`) buys three things: more context per chunk (typo fixes need surrounding words), fewer batch seams (every seam needs stitching and dedup guards), and fewer API round-trips. It costs almost nothing perceptually — raw finals are already readable the moment they land; cleanup just upgrades them from grey to white a few seconds later. The LLM only does what is genuinely uncertain (punctuation, mis-recognitions); everything that can be deterministic (paragraph breaks, stitching, dedup) is plain code.

## Running it (no Xcode)

```bash
make run       # build + bundle + codesign + open
make install   # install into /Applications (needed for launch-at-login and stable TCC)
make locales   # dump SpeechTranscriber supported languages
make logs      # live Telemetry (asr / polish / agent / shake)
```

Once installed, a Kilo item appears in the menu bar — open the transcript folder, resize the overlay (⌘= / ⌘- / ⌘0 while the overlay is focused), clear the conversation + on-screen transcript (or type `/clear` in the input; archived transcripts untouched), permission shortcuts, launch-at-login, restart, quit. The overlay moves by dragging its title bar; standard ⌘C / ⌘V / ⌘X / ⌘A / ⌘Z work in the input field and on selected text. Drop files from Finder onto the overlay to attach them (images go to the agent as pictures, other files by path); the pin button in the title bar keeps the overlay from auto-collapsing.

## Distribution (sharing it)

```bash
make dmg       # dev-build app into a DMG (recipient must right-click → Open past Gatekeeper)
make release   # Developer ID sign + Apple notarize + DMG; recipient double-clicks to install
make publish   # make release + upload the DMG to a GitHub Release (signing key stays on your machine)
```

One-time setup for `release`: an **Developer ID Application** cert from the Apple Developer Program, `xcrun notarytool store-credentials kilo-notary …` to save notary credentials, and `DEV_ID_APP` in `Makefile.local` (see the `release` comment in the Makefile).

Requirements:

- **macOS 26+** (SpeechAnalyzer)
- **Apple Development cert** — hash in `Makefile.local` as `SIGN_ID` (gitignored); falls back to ad-hoc signing without one
- **codex CLI** on PATH (the agent engine; loaded via `zsh -lc`, works through an fnm shim)
- **OpenAI key** in the Keychain (`service=kilo account=openai`) — used by the agent and transcript cleanup; without it, captions and the transcript still work, the agent is disabled
- Permissions: **Screen Recording** (system audio + capture screenshots) and **Accessibility** (shake's element probing + click interception), prompted on first launch; **Microphone** (push-to-talk / meeting mode), prompted on first use

Transcript cleanup goes through `gpt-5.4-mini` over the API directly (no OpenAI key → raw text passes through unpolished).

```bash
./build/Kilo.app/Contents/MacOS/Kilo --langs zh-TW,en-US   # dual-path confidence routing (default)
./build/Kilo.app/Contents/MacOS/Kilo --lang ja-JP          # single language
./build/Kilo.app/Contents/MacOS/Kilo --diarize             # experimental: tag system-audio speakers 講者 A/B/C
                                                           #   (separate diarization track, labels overlaid asynchronously;
                                                           #    --diarize-threshold 0.7 to tune; downloads a CoreML model on first run)
```

## Privacy — where data goes

kilo-sense is a sensory agent: it records system audio and screenshots what you select. The data flow, spelled out:

| Data | Where it goes |
|---|---|
| System audio | **On-device** SpeechAnalyzer transcription — audio never leaves your Mac |
| Mic audio (push-to-talk / meeting mode) | **On-device** transcription — push-to-talk opens the mic only while the key is held; meeting mode records only while toggled on, and the transcript stays local |
| Transcript | Sent to **OpenAI** `gpt-5.4-mini` for cleanup |
| Your instruction + recent transcript + selected screenshots | Sent to **codex / OpenAI** to generate a reply |
| Notes / transcript archive | **Local** `~/.kilo`, never uploaded |

**The key and codex are your own** — kilo-sense uses the OpenAI key in your Keychain and the codex CLI on your PATH; it bundles neither, manages neither, and routes nothing through the author's servers. What gets sent to OpenAI is decided by how you use it; kilo-sense just wires it up. Transcripts and notes live only in your local `~/.kilo`.

## Layout

```
Sources/kilo-sense/
├── App/         main.swift — wiring & launch
├── Audio/       ScreenCaptureKit system audio → PCM
├── Transcript/  SpeechAnalyzer transcription + store + small-model cleanup
├── Agent/       codex exec --json streaming + session resume
├── Overlay/     notch captions + main window (transcript / feed / chips)
├── Core/        Telemetry / Keychain / Metrics
└── Shake/       cursor-shake capture (ported from zyx1121/shake)
```

## Design notes

`docs/` — [SpeechAnalyzer survey](docs/speechanalyzer-survey.md), [notch overlay notes](docs/macos-notch-overlay.md), [CLI dev workflow](docs/macos-cli-dev.md), [AX-actions feasibility](docs/ax-actions-survey.md), [distribution checklist](docs/distribution-checklist.md). (Written in 繁體中文.)
