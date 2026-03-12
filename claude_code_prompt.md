# ZenSync – Claude Code Spec

## What it is
A macOS background menu bar agent (Swift, AppKit, no SwiftUI) that automatically syncs the Zen Browser profile via iCloud Drive. It watches for Zen launching and quitting using NSWorkspace notifications, pulls before launch and pushes after quit. The user launches Zen normally — no wrapper, no special launcher needed.

## Dependencies
- `rsync` (pre-installed on every Mac)
- iCloud Drive enabled on the machine
- Zen Browser installed at `/Applications/Zen Browser.app`

## App lifecycle
- Runs at login as a Launch Agent (LSBackgroundOnly = YES)
- Lives only in the menu bar — no Dock icon, no window
- Stays idle and near-zero CPU until Zen launches or quits

## Core sync logic

### Continuous pull (Zen not running)
When Zen is not running, ZenSync polls iCloud every 60 seconds:
1. Compare modification times of key files between iCloud folder and local profile
2. If iCloud is newer → rsync pull: iCloud → Zen profile
3. Go back to waiting

This means by the time the user opens Zen, the profile is already current. No race condition.

Stop polling as soon as Zen launches. Resume polling as soon as Zen quits.

### On Zen quit detected
```
NSWorkspace.didTerminateApplicationNotification → bundleIdentifier == "app.zen.browser"
```
1. rsync push: Zen profile → iCloud
2. rsync backup: Zen profile → `~/.zensync/backups/YYYY-MM-DD/`
3. Prune backups older than 30 days
4. Resume polling loop
5. Update menu bar status throughout

### On Zen launch detected
```
NSWorkspace.didLaunchApplicationNotification → bundleIdentifier == "app.zen.browser"
```
1. Stop polling loop
2. Update menu bar status (Zen is now running)

## iCloud path
```
~/Library/Mobile Documents/com~apple~CloudDocs/ZenSync/
```

## Zen profile path resolution
Resolve at runtime — the folder name has a random prefix:
```
~/Library/Application Support/zen/Profiles/<first entry ending in ".Default (release)">
```

## rsync flags
```bash
rsync -a --delete \
  --exclude="cache/" \
  --exclude="storage/" \
  --exclude="sessionstore-backups/" \
  --exclude="crashes/" \
  --exclude="*.lock"
```
Used for all three operations: pull, push, backup.

## Local version backups

### Location
```
~/.zensync/backups/YYYY-MM-DD/
```
One snapshot per calendar day, retained for 30 days. Pruned automatically after each push.
Same-day pushes overwrite the existing folder for that day.

### Restore flow
1. User opens menu → "Restore Backup…"
2. Simple NSWindow lists available dated snapshots newest first
3. User selects a date → clicks "Restore"
4. Confirmation dialog: "This will overwrite your current profile. Continue?"
5. On confirm:
   - rsync from selected backup → Zen profile
   - rsync push: Zen profile → iCloud (so other machine picks it up)
   - Show notification: "Restored from YYYY-MM-DD. You can now open Zen."

**Constraint:** Restore is only available when Zen is not running. Menu item is greyed out with tooltip "Close Zen first" if Zen is active.

## Menu bar

### Status labels
| State | Label |
|---|---|
| Idle, Zen not running, profile is current | `🧘 Ready` |
| Pulling (background poll detected newer iCloud) | `⬇︎ Syncing…` |
| Zen is running | `🧘 Zen` |
| Pushing (Zen just quit) | `⬆︎ Syncing…` |
| Error | `⚠️ ZenSync` |

### Menu items
```
[status label — not clickable]
─────────────────────
Force Sync           ← always available
Restore Backup…      ← disabled + tooltip if Zen is running
─────────────────────
Quit
```

### Force Sync behavior
Clicking "Force Sync" opens a small confirmation sheet with two options:

```
┌─────────────────────────────────────┐
│  Force Sync                         │
│                                     │
│  Which version should win?          │
│                                     │
│  [↑ This Mac → iCloud]              │
│  [↓ iCloud → This Mac]              │
│                                     │
│  [Cancel]                           │
└─────────────────────────────────────┘
```

**"This Mac → iCloud" (local wins):**
1. Quit Zen gracefully if running
2. Push local profile → iCloud
3. Relaunch Zen

Use when: you've been working on this machine and want to push your session to the other machine.

**"iCloud → This Mac" (cloud wins):**
1. Quit Zen gracefully if running
2. Pull iCloud → local profile
3. Relaunch Zen

Use when: you've been working on another machine and want to pull that session here.

## First run experience
On first launch, if the iCloud folder does not exist or is empty, show a one-time setup window:

```
┌─────────────────────────────────────┐
│  Welcome to ZenSync                 │
│                                     │
│  Which machine are you setting up   │
│  from?                              │
│                                     │
│  [Primary — push local to iCloud]   │
│  [Secondary — pull iCloud to local] │
└─────────────────────────────────────┘
```

- **Primary:** rsync push local profile → iCloud. This is the source of truth.
- **Secondary:** rsync pull iCloud → local profile. Assumes primary was set up first.

Store a flag in `~/.zensync/config.json` after first run so this never shows again.

## iCloud placeholder detection
iCloud evicts file contents and replaces them with `.icloud` stub files (e.g. `places.sqlite.icloud`) when storage is low or files haven't been accessed recently. Syncing stubs into the Zen profile would corrupt it.

Before every pull:
1. Scan the iCloud ZenSync folder for any file matching `*.icloud`
2. If any found: skip the pull, log a warning, retry on next poll cycle
3. Optionally: trigger a download using `brctl download <path>` and retry after a short wait

## Zen bundle identifier
The NSWorkspace observer depends on the correct bundle identifier. Verify at build time:
```bash
mdls -name kMDItemCFBundleIdentifier /Applications/Zen\ Browser.app
```
Store the identifier as a constant in `SyncEngine.swift`. If Zen is not found at launch, show a notification and log the error rather than silently failing.

## Graceful quit timeout (Force Sync)
When Force Sync quits Zen via `NSRunningApplication.terminate()`:
1. Wait up to 10 seconds for `didTerminateApplicationNotification`
2. If Zen hasn't quit after 10 seconds: show alert "Zen is not responding. Force quit and sync anyway?" with "Force Quit" and "Cancel" options
3. On Force Quit: use `NSRunningApplication.forceTerminate()`
4. On Cancel: abort Force Sync entirely, leave Zen running

## Log rotation
Write all events to `~/.zensync/zensync.log`. Rotate when the file exceeds 1MB:
1. Rename `zensync.log` → `zensync.log.1` (overwrite any existing)
2. Start a fresh `zensync.log`
Keep only one rotated file — no need for more history since errors surface as notifications.

## Error handling
- Pull fails → show macOS notification "ZenSync: pull failed before Zen launched"
- Push fails → show macOS notification "ZenSync: push failed after Zen quit"
- Profile folder not found → notification + skip sync (don't corrupt anything)
- All errors: log to `~/.zensync/zensync.log`

## Launch at login
Install as a Launch Agent plist at:
```
~/Library/LaunchAgents/app.zensync.plist
```
The app installs this automatically on first launch using SMAppService (macOS 13+).

## Project structure
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
  README.md              — setup, usage, releasing new versions via git tags
.github/
  workflows/
    release.yml          — build and publish on git tag push
```

No storyboard, no SwiftUI, no third-party packages.

## GitHub Actions — automatic release

### Trigger
Push a version tag: `git tag v1.0.0 && git push --tags`
This triggers the release workflow.

### Workflow: `.github/workflows/release.yml`
Steps:
1. Checkout repo
2. Select latest stable Xcode with `xcode-select`
3. Build with `xcodebuild`:
   ```bash
   xcodebuild \
     -scheme ZenSync \
     -configuration Release \
     -archivePath build/ZenSync.xcarchive \
     archive
   ```
4. Export the `.app` from the archive:
   ```bash
   xcodebuild \
     -exportArchive \
     -archivePath build/ZenSync.xcarchive \
     -exportPath build/export \
     -exportOptionsPlist ExportOptions.plist
   ```
5. Zip the app:
   ```bash
   cd build/export && zip -r ../../ZenSync.zip ZenSync.app
   ```
6. Create a GitHub Release using the tag name as the version title
7. Upload `ZenSync.zip` as the release asset

### ExportOptions.plist
Include in the repo root. For unsigned/local distribution (no Apple Developer account required):
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" ...>
<plist version="1.0">
<dict>
  <key>method</key>
  <string>mac-application</string>
  <key>signingStyle</key>
  <string>automatic</string>
</dict>
</plist>
```

### GitHub Actions runner
Use `macos-latest` — required for Xcode and codesigning tools.

### Release notes
Auto-generate from commits since the last tag using GitHub's built-in `generate-release-notes: true` option in the Create Release step.

### Versioning convention
- `v1.0.0` → stable release
- `v1.0.0-beta.1` → pre-release (mark as `prerelease: true` in the workflow based on tag containing `-`)

## Out of scope (v1)
- Settings UI
- Multiple backend support
- Conflict resolution beyond last-write-wins
- Sync while Zen is running
