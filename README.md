# Transkriptor (lokal macOS app)

## Native SwiftUI version
Der ligger nu en native macOS 14+ implementation i:

- `native/Transkriptor`

Læs `native/Transkriptor/README.md` for build/test, `.app`/`.dmg` og notarization.

Den eksisterende Electron/Python-version er stadig i repoet som reference og fallback under migrationen.

Lokal desktop-app til transskription af lange interviews med:
- OpenAI som primær transskriptionsmotor (`gpt-4o-transcribe-diarize`)
- Lokal fallback (WhisperX + pyannote diarization)
- Robust recovery via SQLite + checkpoints
- Eksport til TXT og DOCX i fast I/D-format

## Stack
- Electron + React + TypeScript (UI + desktop shell)
- Python worker (lydpipeline, OpenAI/fallback, eksport)
- Bundlet ffmpeg/ffprobe og worker-binær i distributionsbuilds

## Krav
- macOS
- Node.js 20+
- Python 3.10+
- (kun til udvikling/build af worker) Python + pip

## Installation
```bash
npm install
python3 -m venv .venv
source .venv/bin/activate
pip install -r python/requirements.txt
```

WhisperX kræver typisk også torch/torchaudio (platformafhængigt). Se note i `python/requirements.txt`.

## Konfigurer API-nøgler
Opret en `.env` fil i projektroden (eller brug den eksisterende) og indsæt:
```bash
OPENAI_API_KEY=sk-...
# valgfri:
HUGGINGFACE_TOKEN=hf_...
```

## Kør udvikling
```bash
npm run dev
```

Ved første opstart kan du også indtaste OpenAI API-nøglen i UI. Nøglen gemmes i macOS Keychain.

## Build
```bash
npm run build
npm run dist
```
`npm run dist` pakker automatisk:
- worker-binær (`build-assets/worker/transkriptor-worker`)
- ffmpeg/ffprobe (`build-assets/bin`)
- app med icon + DMG

Byg kun en lokal `.app` (uden DMG):
```bash
npm run dist:app
```
Output ligger typisk i `dist/mac-arm64/Transkriptor.app`.

## Funktionel oversigt
- Vælg lydfil (`mp3`, `m4a`, `wav`, `mp4`, `mov`)
- Chunking i ca. 4 minutter med overlap
- Retries mod OpenAI
- Fallback hvis OpenAI fejler
- Pause hvis fallback-diarization er for usikker
- Auto-resume af ufærdigt job ved app-start
- Eksport til TXT/DOCX

## Distribution (plug-and-play)
- Slutbrugeren behøver kun `.dmg`-filen.
- Slutbrugeren skal kun indtaste API-nøgle i appen (eller via `.env`).
- Ingen manuel installation af Python/ffmpeg hos slutbrugeren.
- `Transkriptor-Electron-Installer.dmg` er ikke versionsstyret i Git (filen er >100 MB).
  Generer den lokalt eller distribuer den via release artifacts.

## Sikkerhed
- OpenAI API-nøgle ligger i Keychain, ikke i repo.
- Ingen hardcodede nøgler i kildekoden.

## Noter
- Appen antager interviewformat med 2 talere (`I` og `D`).
- "Byt roller" kan anvendes før eksport.
