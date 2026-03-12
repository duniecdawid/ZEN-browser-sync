# ZenSync

A lightweight macOS menu bar app that automatically syncs your [Zen Browser](https://zen-browser.app) profile between Macs using iCloud Drive.

## The Problem

Zen Browser is built on Firefox, and while Firefox Sync works for bookmarks, history, and passwords, it doesn't sync the things that make Zen special — your workspace layouts, sidebar configuration, custom CSS themes, and Zen-specific settings. If you use Zen on multiple Macs, the core Firefox data follows you but the Zen experience doesn't.

## How ZenSync Fixes It

ZenSync sits quietly in your menu bar and keeps your Zen profile in sync via iCloud Drive — no account, no server, no configuration.

- **When you quit Zen** (Cmd+Q): ZenSync pushes your profile to iCloud
- **When Zen isn't running**: ZenSync polls iCloud every 60 seconds and pulls any newer changes from your other Mac
- **When you open Zen**: Your profile is already up to date

It's invisible when it's working. Open Zen, use it, quit it — your other Mac picks up where you left off.

## Good to Know

Zen Browser (like many macOS apps) **stays running when you close the window** with the red button. ZenSync only syncs when Zen actually quits — use **Cmd+Q** to quit Zen and trigger a sync. You can verify Zen is truly closed by checking the menu bar status: it should show "Ready", not "Zen".

## Menu Bar

| Status | Meaning |
|---|---|
| 🧘 Ready | Idle, profile is current |
| ⬇︎ Syncing… | Pulling newer profile from iCloud |
| 🧘 Zen | Zen is running, sync paused |
| ⬆︎ Syncing… | Pushing profile to iCloud |
| ⚠️ ZenSync | Something went wrong (check `~/.zensync/zensync.log`) |

**Menu options:**
- **Force Sync** — manually push or pull, even while Zen is running (quits and relaunches Zen automatically)
- **Restore Backup…** — roll back to a previous day's profile (available when Zen is closed)
- **Quit** — stop ZenSync

## Backups

ZenSync keeps daily local backups of your profile at `~/.zensync/backups/`. Backups older than 30 days are pruned automatically. Use **Restore Backup…** from the menu to roll back if something goes wrong.

## First Launch

On first launch, ZenSync asks whether this Mac is your **primary** (push local profile to iCloud) or **secondary** (pull from iCloud). This only appears once.

## Requirements

- macOS 13 (Ventura) or later
- iCloud Drive enabled
- [Zen Browser](https://zen-browser.app) installed

## Installation

1. Download `ZenSync.zip` from the [latest release](https://github.com/duniecdawid/ZEN-browser-sync/releases/latest)
2. Unzip and move `ZenSync.app` to your Applications folder
3. Open it — ZenSync will ask to register as a login item so it starts automatically

Since the app is unsigned, macOS may block it on first launch. Right-click the app → Open, then click Open in the dialog.

## How It Works

ZenSync uses `rsync` to copy your Zen profile to and from `~/Library/Mobile Documents/com~apple~CloudDocs/ZenSync/`. iCloud Drive handles the cloud transport. No third-party services, no accounts, no dependencies beyond what's already on your Mac.

## License

MIT
