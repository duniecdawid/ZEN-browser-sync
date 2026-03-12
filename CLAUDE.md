# ZenSync

macOS menu bar agent (Swift, AppKit) that automatically syncs the Zen Browser profile via iCloud Drive. Watches for Zen launching/quitting via NSWorkspace notifications, pulls before launch and pushes after quit.

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
- **Launch Agent:** `~/Library/LaunchAgents/app.zensync.plist`

## Project Structure

```
ZenSync/
  AppDelegate.swift      — NSWorkspace observer, sync orchestration, status bar
  SyncEngine.swift       — rsync wrapper, path resolution, bundle ID constant
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

- **Background poll (Zen not running):** Check iCloud every 60s, pull if newer
- **On Zen quit:** Push profile to iCloud, backup locally, prune backups >30 days
- **On Zen launch:** Stop polling
- **Zen bundle ID:** `app.zen-browser.zen`

## rsync Flags

```bash
rsync -a --delete \
  --exclude="cache/" \
  --exclude="storage/" \
  --exclude="sessionstore-backups/" \
  --exclude="crashes/" \
  --exclude="*.lock"
```

## Constraints

- No storyboard, no SwiftUI, no third-party packages
- LSBackgroundOnly = YES (no Dock icon, no window)
- Restore only available when Zen is not running
- iCloud `.icloud` stub detection required before every pull
- Full spec in `claude_code_prompt.md`
