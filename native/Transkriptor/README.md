# Transkriptor Native (SwiftUI)

Native macOS 14+ version af Transkriptor med SwiftUI/AppKit og Swift-baseret pipeline.

## Moduler
- `AppUI`: SwiftUI + AppKit UI (upload, progress, resultat, editor med linjenumre)
- `Domain`: Delte typer (jobstatus, progress, transcript)
- `Storage`: SQLite state/checkpoints via GRDB (`JobStore` actor)
- `Pipeline`: Chunking, OpenAI-transskription, lokal fallback, merge/filter, editor-parser
- `Export`: TXT + DOCX (OpenXML)
- `SecurityKit`: Keychain-lagring af API-nøgle

## Krav
- macOS 14+
- Xcode 26+
- Swift 6.2+

## Build og test
```bash
cd native/Transkriptor
swift test
swift build --product TranskriptorApp
```

## Kør appen
```bash
cd native/Transkriptor
swift run TranskriptorApp
```

## Byg .app + .dmg
```bash
cd native/Transkriptor
./scripts/build_dmg.sh
```

Output:
- `native/Transkriptor/dist/Transkriptor.app`
- `native/Transkriptor/dist/Transkriptor-Installer.dmg` (drag-and-drop)

## Byg installer (.pkg)
Hvis du vil have klassisk installer-flow (i stedet for drag-and-drop), byg en `.pkg`:
```bash
cd native/Transkriptor
./scripts/build_pkg.sh
```

Output:
- `native/Transkriptor/dist/Transkriptor.pkg`
- `native/Transkriptor/dist/Transkriptor-PKG-Installer.dmg` (wrapper omkring `.pkg`)

## Notarization
Først opret et notarytool keychain profile (Apple docs). Derefter:
```bash
cd native/Transkriptor
NOTARY_PROFILE=<dit-profile-navn> ./scripts/notarize_dmg.sh
```

Valgfri signering inden DMG:
```bash
MAC_CODESIGN_IDENTITY="Developer ID Application: ..." ./scripts/build_dmg.sh
```
