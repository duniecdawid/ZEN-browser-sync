# ZenSync

macOS menu bar agent (Swift, AppKit) that manually syncs the Zen Browser profile via iCloud Drive. User triggers Push/Pull from the menu bar. Each push creates a versioned snapshot (YYYY-MM-DD-NNN) tracked in a manifest.json on iCloud.

## Tech Stack

- **Language:** Swift (no SwiftUI, no third-party packages)
- **Framework:** AppKit, NSWorkspace notifications
- **Sync:** rsync (pre-installed on macOS)
- **Storage:** iCloud Drive
- **CI:** GitHub Actions (xcodebuild on macos-latest)
- **Login:** SMAppService (macOS 13+)

## Key Paths

- **iCloud sync folder:** `~/Library/Mobile Documents/com~apple~CloudDocs/ZenSync/`
- **Zen profile:** `~/Library/Application Support/zen/Profiles/<*.Default (release)>` (resolved at runtime)
- **Backups:** `~/.zensync/backups/YYYY-MM-DD/`
- **Config:** `~/.zensync/config.json`
- **Log:** `~/.zensync/zensync.log` (rotate at 1MB, keep 1 rotated file)
- **Zen Links output:** `~/Library/Mobile Documents/com~apple~CloudDocs/ZenLinks/index.html`
- **Launch Agent:** `~/Library/LaunchAgents/app.zensync.plist`

## Project Structure

```
ZenSync/
  AppDelegate.swift      — NSWorkspace observer, sync orchestration, status bar
  SyncEngine.swift       — rsync wrapper, path resolution, bundle ID constant
  LinkExporter.swift     — extract workspace links from zen-sessions.jsonlz4, generate HTML
  BackupManager.swift    — daily backups, pruning, restore
  RestoreWindow.swift    — NSWindow backup picker UI
  FirstRunWindow.swift   — one-time setup UI
  LaunchAgent.swift      — SMAppService login item registration
  Logger.swift           — log writer with rotation
  main.swift             — NSApplication bootstrap
  Info.plist             — LSBackgroundOnly = YES
  ExportOptions.plist    — for xcodebuild export (unsigned, mac-application)
.github/workflows/
  release.yml            — build and publish on git tag push
```

## Build & Release

```bash
# Archive
xcodebuild -scheme ZenSync -configuration Release -archivePath build/ZenSync.xcarchive archive

# Export
xcodebuild -exportArchive -archivePath build/ZenSync.xcarchive -exportPath build/export -exportOptionsPlist ExportOptions.plist
```

Release triggered by version tags: `git tag v1.0.0 && git push --tags`

## Core Behavior

- **Manual sync only:** User clicks "Push to iCloud" or "Pull from iCloud" in menu bar
- **Versioning:** Each push assigns a version ID (YYYY-MM-DD-NNN) stored in `manifest.json` on iCloud
- **Menu displays:** Local version, iCloud version, and whether a newer version is available (checked on menu open via NSMenuDelegate)
- **On Zen quit:** State returns to ready (no auto-sync)
- **On Zen launch:** Push/Pull disabled in menu
- **Zen bundle ID:** `app.zen-browser.zen`
- **Link export:** On each push, reads `zen-sessions.jsonlz4` (Mozilla LZ4), extracts pinned/essential tabs per workspace, generates a mobile-friendly HTML page to `ZenLinks/index.html` on iCloud. Non-fatal — push succeeds even if export fails.

## rsync Flags

```bash
rsync -a --delete \
  --exclude="cache/" \
  --include="storage/" \
  --include="storage/default/" \
  --include="storage/default/chrome/" \
  --include="storage/default/chrome/**" \
  --exclude="storage/**" \
  --exclude="sessionstore-backups/" \
  --exclude="sessionstore-logs/" \
  --exclude="crashes/" \
  --exclude="datareporting/" \
  --exclude="gmp-*/" \
  --exclude="security_state/" \
  --exclude="*.lock" \
  --exclude=".parentlock" \
  --exclude="*.sqlite-wal" \
  --exclude="*.sqlite-journal" \
  --exclude="places.sqlite" \
  --exclude="favicons.sqlite" \
  --exclude="cookies.sqlite" \
  --exclude="formhistory.sqlite" \
  --exclude="sessionstore.jsonlz4" \
  --exclude="sessionCheckpoints.json" \
  --exclude="weave/" \
  --exclude="key4.db" \
  --exclude="cert9.db" \
  --exclude="manifest.json"
```

## Constraints

- No storyboard, no SwiftUI, no third-party packages
- LSBackgroundOnly = YES (no Dock icon, no window)
- Restore only available when Zen is not running
- iCloud `.icloud` stub detection required before every pull
- Full spec in `claude_code_prompt.md`
