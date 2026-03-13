# Debug: Sync runs but data doesn't transfer

## Problem
ZenSync reports a successful sync (push from Mac A), but when pulled on Mac B, the Zen-specific customizations (workspaces, sidebar, themes) are not present.

## Investigation Steps

### 1. Check what's actually in the iCloud folder
```bash
ls -la ~/Library/Mobile\ Documents/com~apple~CloudDocs/ZenSync/
```
Are the expected files there? Is the folder empty or sparse?

### 2. Check what's in the local Zen profile
```bash
ls -la ~/Library/Application\ Support/zen/Profiles/*.Default\ \(release\)/
```

### 3. Check if `storage/` contains Zen-specific data
```bash
ls -R ~/Library/Application\ Support/zen/Profiles/*.Default\ \(release\)/storage/ | head -50
```
We currently exclude `storage/` from rsync. If Zen stores workspace/sidebar data here, that's why it's not syncing.

### 4. Check ZenSync log for errors
```bash
cat ~/.zensync/zensync.log
```

### 5. Diff what's synced vs what's in the profile
```bash
# Files in profile but NOT in iCloud (these are excluded or missing)
diff <(ls ~/Library/Application\ Support/zen/Profiles/*.Default\ \(release\)/ | sort) \
     <(ls ~/Library/Mobile\ Documents/com~apple~CloudDocs/ZenSync/ | sort)
```

### 6. Check for iCloud stub files (not yet downloaded)
```bash
find ~/Library/Mobile\ Documents/com~apple~CloudDocs/ZenSync/ -name ".*.icloud"
```

## Likely Cause
The `storage/` directory is excluded from rsync but probably contains Zen workspace layouts, sidebar configuration, and extension localStorage. Removing it from the exclude list may fix the issue — but first confirm by checking its contents (step 3).

## Current rsync excludes
```
cache/  storage/  sessionstore-backups/  sessionstore-logs/  crashes/
datareporting/  gmp-*/  security_state/  *.lock  .parentlock
*.sqlite-wal  *.sqlite-journal  places.sqlite  favicons.sqlite
cookies.sqlite  formhistory.sqlite  sessionstore.jsonlz4
sessionCheckpoints.json  weave/  key4.db  cert9.db
```
