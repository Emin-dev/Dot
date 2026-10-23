# Uninstall coverage: Dot leaves nothing of its own behind

Owner request (2026-10-23, verbatim): "some paid apps can clean Mac better then stantdart apple app
removal so research what and how they clean to add all in dot so dot will delete itself when needed
so macOS will same as after format. without touching other apps or files, only dot!"

How it was researched: the location list of Pearcleaner, an open-source uninstaller
(`Pearcleaner/Logic/Locations.swift` in github.com/alienator88/Pearcleaner), plus the per-app records
macOS keeps outside those folders (Keychain, TCC, Launch Services, Dock, quarantine history).
`scripts/uninstall-dot.sh` is the one removal path; the in-app "Remove Dot completely…" runs the same
script. Every removal matches Dot's bundle id `app.dot.local`, Dot's own file names or this
repository's release URLs, so no other app's data is touched.

| Place | What Dot can leave | Removed by |
| --- | --- | --- |
| `~/Applications/Dot.app` (or a legacy `/Applications/Dot.app` the user owns) | the app | `rm -rf`, never sudo |
| `~/Library/Containers/app.dot.local` | model (22.4 GB), memory, logs, settings, caches, queue, install id, folder bookmark | `rm -rf` |
| `~/Library/Group Containers/(group.)app.dot.local` | shared container | `rm -rf` |
| `~/Library/Application Support/Dot`, `.../app.dot.local`, `.../Caches/app.dot.local` | legacy data | `rm -rf` |
| `~/Library/Application Scripts/app.dot.local` | sandbox scripts folder | `rm -rf` |
| `~/Library/Caches/app.dot.local`, `.../com.apple.helpd/Generated/app.dot.local` | caches | `rm -rf` |
| `getconf DARWIN_USER_CACHE_DIR` / `DARWIN_USER_TEMP_DIR` + `app.dot.local` | Metal shader cache, temp | `rm -rf` |
| `~/Library/HTTPStorages`, `~/Library/Cookies`, `~/Library/WebKit` (Dot's entries) | HTTP and WebKit data | `rm -rf` |
| `~/Library/Preferences/app.dot.local.plist`, `ByHost/app.dot.local*` | preferences | `rm` |
| `~/Library/Saved Application State/app.dot.local.savedState` | window state | `rm -rf` |
| `~/Library/Autosave Information/app.dot.local` | autosave | `rm -rf` |
| `~/Library/Logs/Dot`, `~/Library/Logs/app.dot.local`, `DiagnosticReports/Dot*.ips` | logs, crash reports | `rm` |
| `~/Library/Application Support/CrashReporter/Dot_*.plist` | crash-reporter records | `rm` |
| `~/Library/LaunchAgents/app.dot.local*.plist` | none installed; removed if present | `launchctl bootout`, `rm` |
| `com.apple.LSSharedFileList.ApplicationRecentDocuments/app.dot.local.sfl*` | recent-documents list | `rm` |
| `<each folder chosen for file actions>/.dot-actions` | receipts and recovery copies | `rm -rf` only when it is a real folder owned by the user with Dot's `owner.lock`; folders come from `action-folders.txt` in Dot's container |
| Login Keychain item `dot-github-token` | optional log-upload token | `security delete-generic-password` |
| TCC (microphone, screen, calendars, Automation, Accessibility) | privacy approvals | `tccutil reset All app.dot.local` |
| Launch Services database | app registration | `lsregister -u` |
| Dock (`com.apple.dock` persistent/recent apps) | a pinned Dot tile | only Dot's tile, via `defaults export/import`, then the Dock restarts |
| `com.apple.LaunchServices.QuarantineEventsV2` | download-history rows for a browser download of Dot | only rows whose URL is `github.com/Emin-dev/Dot/` |
| `~/Applications` | created by the installer | removed only when the installer created it and it is empty |

Not applicable to Dot (it installs none of these): LaunchDaemons, PrivilegedHelperTools, kernel or
system extensions, `/usr/local`, package receipts, plug-ins, login items, background tasks.

What stays and why: macOS updates its own records whenever any app runs, including Apple's own
apps: Spotlight and Siri indexes, app-usage statistics (Biome, Duet), the Shortcuts index of App
Intents, preference caches and the unified system log. They hold no Dot data, they belong to macOS,
and removing them would need admin rights and would touch every other app's records. The no-trace
release lane lists each of these in `scripts/privacy_allowlist.txt` with its reason; any Dot-owned
path left behind fails the release.

Proof: `.github/workflows/privacy-clean.yml` snapshots about 357,000 paths before install and after
removal on a clean hosted Mac and fails the release on any difference outside that allowlist.
Guardrails in `scripts/check_contracts.py` pin the uninstaller rules above.
