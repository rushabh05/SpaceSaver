# SpaceSaver

A native macOS disk cleaner for developers. It finds the gigabytes that macOS lumps into
"System Data" (stale `node_modules`, Xcode DerivedData, simulators, Docker build cache,
package-manager caches, local AI models, AI-agent transcripts) and removes them safely, with
undo.

It's free and open source under the MIT licence. Everything runs on your Mac with no account,
licence key or telemetry, and every feature is included. The only network request it makes on
its own is a once-a-day check for a new version on GitHub, which you can turn off.

**Download:** [rushabh05.github.io/SpaceSaver](https://rushabh05.github.io/SpaceSaver/) (Apple
silicon, macOS 14 or later).

**Highlights**
- Native SwiftUI and Swift: a ~3 MB DMG and a 9 MB app.
- A parallel `getattrlistbulk` scanner that reports allocated size (it matches `du`) and counts
  hard links once.
- An MCP server built into the bundled CLI, with no Node required.
- Trash first, with one-click restore from Activity and automatic purge after a configurable
  number of days. It tells you that bytes moved to the Trash aren't free until it's emptied, and
  offers "Free now".
- A CLI, "what grew since last scan", a free-space history chart, a "make room for X GB"
  planner, orphaned editor workspace detection, per-model Ollama sizing, custom rules, and
  LaunchAgent scheduling that works with the app closed.

## Features

**Overview.** Disk gauge with used, reviewable, safe-to-clean, free and purgeable space, a
30-day free-space chart, Smart Clean (recommended items only), and "Make room for X GB", which
picks the least risky items that cover X.

**Storage Map.** Interactive squarified treemap with two levels of nesting, a size-sorted side
list, breadcrumbs, and a right-click menu (Reveal, Explain, Move to Trash). Each scan is
snapshotted, so **Changes since last scan** shows which folders grew. Maps Home, the whole
disk (via firmlinks, without double counting), or any folder.

**Developer categories**
- **Project Artifacts:** 45 artifact rules (`node_modules`, `.next`, `target`, `.venv`, `Pods`,
  `.gradle`, `.build`, `.dart_tool`, `.terraform`, `bin/obj`…), each recognised only when the
  matching manifest sits next to it. Activity comes from the git reflog and index (no `git`
  subprocess) plus root file edits. Active projects are never recommended. Missing lockfiles
  are flagged, and orphaned `node_modules` are detected.
- **Xcode & Simulators:** DerivedData, device support per OS version, archives (Caution),
  previews, simulator caches, and every simulator with runtime and last boot. Simulators
  whose runtime is gone are marked Safe. Uses `simctl delete` when Xcode is installed.
- **Docker:** asks the engine (`docker system df`) and prunes build cache, stopped
  containers, unused images and volumes (volumes are Caution and never preselected). Shows the
  VM disk image, which it never deletes. Supports Docker Desktop, OrbStack and colima.
- **Package Caches:** npm, npx, Yarn, pnpm, Bun, pip, uv, Poetry, Conda, Cargo, rustup, Go,
  Gradle, Maven, Homebrew, CocoaPods, SwiftPM, Composer, NuGet, Playwright, Puppeteer,
  Cypress, Electron, nvm, pyenv, Flutter, Bazel, ccache, Android AVDs and images…
- **IDEs & Editors:** caches and logs for VS Code, Cursor, Windsurf, VSCodium, Trae, Kiro, Zed,
  JetBrains and Android Studio, plus **workspace storage for project folders that no longer
  exist**.
- **AI Models:** Hugging Face (per model), Ollama (per model, counting only blobs no other
  model shares), LM Studio, PyTorch Hub, Whisper, GPT4All, ComfyUI, MLX and llama.cpp.
- **AI Session Logs:** Claude Code (per project, with real project paths decoded and deleted
  projects tagged), Codex (per month), Copilot, Cline, Roo, Windsurf, Gemini CLI, Continue and
  Cursor. Shows conversation previews. **Audit for Secrets** runs an offline regex scan for
  Anthropic, OpenAI, GitHub, AWS, Google, Slack, Stripe, Hugging Face and npm keys and private
  keys, with redacted output. Logs are **archived to a verified tar.gz vault** (SHA-256
  manifest) before going to the Trash. Files touched in the last 24 hours and Claude Code
  `memory/` are never included.

- **Agent Worktrees:** the git worktrees Claude Code creates in `<repo>/.claude/worktrees`. Removing
  one never loses commits or branches (they live in the repository), so SpaceSaver checks each
  with `git status`: clean and older than a week is Safe, uncommitted changes are Caution with
  the count shown, worktrees whose repository moved are flagged, and anything touched in the last
  day is treated as in use.

**Cleanup categories:** app, browser and chat caches (skipped while the app runs), logs,
crash reports, iOS backups and firmware, leftover macOS installers, old Downloads (flags
installers for apps you already have and archives you already extracted), Large Files,
Duplicates (size, then head/tail hash, then full SHA-256; hard links and undownloaded iCloud
files are skipped), App Leftovers (support files, containers and saved state of apps that are no
longer installed, only when no installed app from the same vendor could own them), and Trash.

**Apps.** Every app in /Applications and ~/Applications with its size, when it was last opened,
and the files it keeps in your Library (Application Support, caches, sandbox containers, saved
state, web storage, logs). Uninstall removes the app and the files you tick, through the same
review sheet, Trash and undo as everything else. Apple's apps and running apps can't be removed,
and apps with system extensions (security, VPN, drivers) get a warning to use their own
uninstaller.

**Updates.** SpaceSaver checks GitHub once a day and offers new versions in the Overview, the menu
bar and the island. Each release DMG is signed with an Ed25519 key; the app installs an update
only if the signature matches the public key it ships with, the app inside has the right bundle
ID and version, and its code signature is valid. The old version is kept and put back if
anything fails.

**Activity.** Every cleanup from the app, CLI, scheduler or an approved agent is logged with
one-click **Restore** to the original location.

**Dynamic Island.** A black island grows out of the MacBook notch (or the top of the menu bar
on Macs without one):
- **Live:** scan or cleanup progress, a mapping file count, or a low-disk warning, shown beside the notch.
- **Peek:** a notification drops down for a few seconds when a scan finishes, a cleanup completes,
  or an AI agent asks for space.
- **Expanded:** hover to open a mini control center with a disk ring, safe-to-clean total, live
  progress, and Quick Clean (two-step confirm), Scan and Open buttons.

It uses no Accessibility or Screen Recording permission, and you can configure it in
Settings › General.

**Menu bar.** Live free space, a ring gauge, Quick Clean (recommended Safe items, Trash only, two-step
confirm), pending agent requests, and SpaceSaver-cleaned bytes still sitting in the Trash.

**Design.** Liquid Glass on macOS 26 (materials on 14–15), animated ring gauges, rolling numbers,
staggered entrances, hover-lift cards, shimmering call-to-action buttons, and a success burst after
each cleanup.

**Schedule.** A per-user LaunchAgent runs `spacesaver auto` daily or weekly, even with the app
closed. It skips on battery or Low Power Mode, can run only below a free-space threshold,
cleans only recommended Safe items, and purges expired Trash items.

**Local AI explainer.** Built-in offline knowledge of each location, plus optional
explanations from a local Ollama model, with paths anonymized.

## Safety model

1. **Scans only read.** Nothing changes until you confirm in a review sheet that separates
   undoable moves from permanent actions.
2. **Risk levels.** Safe (regenerates by itself), Review (costly to rebuild or re-download) and
   Caution (may be personal data). Smart Clean, Quick Clean and the scheduler only ever touch Safe.
3. **Guards.** Running apps' caches are skipped (process and bundle-ID matching), and active
   projects (recent commits or edits) are held back.
4. **SafetyGuard.** Every removal, from any source, passes through it. It refuses system
   folders; home and its top-level folders; `~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.kube`; keychains,
   Mail, Messages and iCloud Drive; anything inside `.git`; Claude Code memory; your exclusions;
   and symlink tricks (the parent path is resolved first).
5. **Trash first.** Items are restorable from Activity until the retention window ends
   (default 7 days). Only items SpaceSaver itself put in the Trash are ever purged.

## Build and run

You only need the Xcode Command Line Tools (Swift 5.10 or later); full Xcode isn't required. The
app runs on macOS 14+ and has been tested on Apple Silicon running macOS 26.

```bash
scripts/build-app.sh --dmg      # → build/SpaceSaver.app and build/SpaceSaver.dmg
```

```bash
open build/SpaceSaver.app
```

```bash
scripts/test.sh                 # 27 tests
```

To install, drag `build/SpaceSaver.app` to Applications. For a complete scan, grant
**Full Disk Access** (System Settings › Privacy & Security). The app prompts you and links there.

The build is ad-hoc signed. That's fine on your own Mac. Two consequences: macOS resets
privacy grants such as Full Disk Access after each rebuild, and other Macs will show a
Gatekeeper warning. To distribute it, sign with a Developer ID
(`SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh --dmg`) and notarize.

## Website and releases

`docs/` is a static download site (plain HTML, CSS and JS, no build step) meant for GitHub
Pages: Settings › Pages › Deploy from a branch › `main` / `docs`. Its app screens are HTML
mock-ups with demo data, so they never show anyone's real disk.

Every Download button points at `releases/latest/download/SpaceSaver.dmg`, and the page reads
the version, size and SHA-256 of the latest release from the GitHub API. To publish a new
version, bump `AppVersion.current` in `Sources/SpaceSaverCore/Support/Version.swift`, then run:

```bash
scripts/release.sh
```

`release.sh` signs the DMG for in-app updates with the private key at
`~/.spacesaver-release/update-signing.key` and uploads `SpaceSaver.dmg.sig` next to it. Create the
key once with `swift scripts/update-signing.swift generate` (this also writes the public key to
`scripts/update-public-key.txt`, which the build embeds). **Back the private key up**: without it,
installed copies won't accept your updates and people would have to download new versions by
hand.

To preview the site locally, run `python3 -m http.server -d docs` and open http://localhost:8000.

## Command line

The CLI ships inside the app at `SpaceSaver.app/Contents/Helpers/spacesaver` and shares
settings, history and activity with it (`~/.spacesaver`).

```text
spacesaver status                 disk, purgeable space, last scan
spacesaver scan [-c category]     reclaimable space (● = recommended), --json
spacesaver clean [--yes]          dry run unless --yes; --include-review; -c category
spacesaver map ~/Library -d 2     top folders + what changed since last map
spacesaver large --min 1GB        largest files
spacesaver dupes ~/Projects       duplicates by SHA-256
spacesaver explain <path>         what a folder is and whether it's safe
spacesaver preflight 20           will 20 GB fit? (exit code 2 if not)
spacesaver make-room 30GB         free 30 GB with the safest items first (dry run unless --yes)
spacesaver make-room 50GB --until-free --yes --free-now   for CI: make sure 50 GB is free
spacesaver apps [--unused]        installed apps by size, with their Library files
spacesaver update [--check|--yes] check for, or install, a signed new version
spacesaver secrets                audit AI logs for leaked keys (exit code 3 if found)
spacesaver activity / restore <id> / purge --days 7
spacesaver auto [--force]         the scheduled run
spacesaver mcp                    MCP server on stdio
```

## AI agents (MCP)

```bash
claude mcp add spacesaver -- /Applications/SpaceSaver.app/Contents/Helpers/spacesaver mcp
```

The server exposes six tools: `get_disk_status`, `preflight_check`, `list_reclaim_candidates`,
`explain_path`, `propose_cleanup` and `get_plan_status`.

**Agents cannot delete anything.** `propose_cleanup` validates each path (SafetyGuard, plus
"is this a known regenerable location?", plus "not inside the agent's own workspace") and
creates a pending request. The request appears in **Agent Requests** in the app and in the menu
bar, expires after 24 hours, and only runs when you approve it. Folder names are stripped of
control and ANSI sequences before being sent to the agent. Every call is logged to
`~/.spacesaver/mcp-audit.jsonl`. Settings › AI & Agents has copy-paste setup for Claude Code,
Codex and Cursor/Windsurf.

## Custom rules

Add locations to `~/.spacesaver/rules.json` (Settings › Scanning › Open rules.json):

```json
[{ "id": "my-cache", "category": "custom", "title": "My tool cache",
   "paths": ["~/.mytool/cache"], "risk": "safe",
   "explanation": "Download cache for mytool.", "regenerate": "Re-downloaded automatically.",
   "processes": ["mytool"], "perChild": false }]
```

## Layout

```text
Sources/SpaceSaverCore/    engine (no UI): scanning, rules, analyzers, safety, cleanup, MCP
  Scan/                    getattrlistbulk reader, parallel walker, tree scanner, sizer
  Rules/                   rule catalog + evaluator
  Analyzers/               projects, simulators, Docker, Ollama, editors, downloads, trash,
                           AI sessions + secrets, duplicates, apps + leftovers
  Update/                  signed in-app updates (feed, Ed25519 check, staged install)
  Cleanup/                 trash/restore/purge, archive vault, activity log
  Engine/                  orchestrator, knowledge base, history, plans, scheduler
  Agent/MCPServer.swift    JSON-RPC MCP server
Sources/SpaceSaverApp/     SwiftUI app + menu bar
Sources/spacesaver/        CLI
Tests/                     Swift Testing suite
scripts/                   build-app.sh, release.sh, test.sh, stats.sh, update-signing.swift,
                           make-icon.swift, make-social-card.swift
docs/                      download website (GitHub Pages)
```

`SPACESAVER_SNAPSHOT=/tmp/shots build/SpaceSaver.app/Contents/MacOS/SpaceSaver` renders each
screen to PNG and quits. It's a development aid that needs no Screen Recording permission.

## Not included

- A Windows version.
- Intel builds. They should compile with `swift build --arch x86_64`, but haven't been tested.
- Deleting Time Machine local snapshots. SpaceSaver shows how many there are; macOS
  thins them automatically, or run `tmutil thinlocalsnapshots / 999999999999 4`.

## Licence

MIT. See [LICENSE](LICENSE).
