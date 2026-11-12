# SpaceSaver for Windows (MVP)

A Windows port of SpaceSaver, the free MIT-licensed disk cleaner for developers. It finds
regenerable developer junk (build folders in dormant projects, package-manager and editor caches,
AI models, old temp files), moves what you choose to the **Recycle Bin**, logs every cleanup and
can put it back. It also reports **WSL and Docker Desktop virtual disks** (`ext4.vhdx`,
`docker_data.vhdx`), which never shrink by themselves, and shows the exact steps to compact them.
It never deletes them.

This folder is a Rust workspace:

```text
windows/
  core/   spacesaver-core: rules, parallel scanner, safety guard, cleanup, activity log (+ tests)
  cli/    spacesaver.exe: status, scan, clean, activity, restore
  app/    Tauri 2 desktop app; plain HTML/CSS/JS frontend in app/ui (no bundler)
```

## What it finds

| Category | Examples | Risk |
| --- | --- | --- |
| Project Artifacts | 46 rules ported from the macOS app: `node_modules` + `package.json`, `target` + `Cargo.toml`/`pom.xml`, `bin`/`obj` + `*.csproj`/`*.fsproj`, `.venv` + `pyproject.toml`/`requirements.txt`, `build`/`.gradle` + `build.gradle(.kts)`, `.next` + `next.config.*`… | Safe in dormant projects; Review when active, with no lockfile, or for venvs and `dist` |
| Package Caches | npm (`%LOCALAPPDATA%\npm-cache`), npx, pnpm store, Yarn, Bun, pip, uv, Poetry, NuGet `v3-cache`/`plugins-cache`, NuGet global packages, Gradle, Maven, Cargo registry, Go build and module caches, Deno, node-gyp, Playwright, Puppeteer, Cypress, Electron, Android AVDs and system images | Safe, or Review for big shared stores (pnpm, NuGet packages, Maven, Go modules, Playwright, Android) |
| IDEs & Editors | VS Code, VS Code Insiders, Cursor, Windsurf, VSCodium (`Cache`, `CachedData`, `CachedExtensionVSIXs`, `Code Cache`, `GPUCache`, `logs` under `%APPDATA%\<Editor>`), JetBrains `%LOCALAPPDATA%\JetBrains\*\caches` per IDE version, Android Studio | Safe; blocked while the editor is running |
| AI Models | Hugging Face (per model or dataset), Ollama, LM Studio (per model), PyTorch Hub, Whisper | Review |
| WSL & Docker | WSL distro disks (from the `Lxss` registry key and `%LOCALAPPDATA%\Packages\*\LocalState`, `%LOCALAPPDATA%\wsl\*`) and Docker Desktop's disk (`%LOCALAPPDATA%\Docker\wsl\...`) | Manual: never deleted |
| System Junk | `%LOCALAPPDATA%\CrashDumps`, top-level `%TEMP%` entries nothing has modified for 7 days | Safe |

A project is **dormant** when neither the newest `.git/logs/HEAD` reflog entry, the git index nor
any file at the project root changed in 45 days. Active projects are tagged "Active Xd ago" and
never recommended. Only Safe items are recommended (Smart Clean).

Sizes are logical sizes, measured by a parallel (rayon) walk that **never follows symlinks,
junctions or any other reparse point**, so pnpm junctions and OneDrive placeholders aren't
double-counted or followed out of the folder.

## Safety model

* **Scans only read.** Nothing changes until you confirm (`clean --yes` in the CLI, the review
  dialog in the app).
* **Every removal goes through `SafetyGuard`.** It refuses drive roots; `C:\Windows`, `Program
  Files`, `Program Files (x86)`, `ProgramData` and other system folders; the user profile and
  every top-level folder in it (Desktop, Documents, Downloads, OneDrive…); `AppData`,
  `AppData\Local`, `AppData\Roaming` and `%TEMP%` themselves; `.ssh`, `.aws`, `.azure`, `.gnupg`,
  `.kube`, `.docker` and Windows credential folders; anything inside a `.git` folder; any reparse
  point; and any path that isn't inside the user profile or `%TEMP%` once junctions and 8.3 short
  names in its parent are resolved. Comparison is case-insensitive and `\\?\` prefixes, `/`, `..`
  and trailing dots are normalised first. The scanner runs the same checks, so the UI never
  offers something the cleaner would refuse.
* **Recycle Bin first.** Items go to the Recycle Bin (via the `trash` crate), never deleted
  outright. Items bigger than the drive's Recycle Bin limit, or on a drive where the Recycle Bin
  is turned off, are refused, because Windows would delete them permanently. Space is freed when
  the Recycle Bin is emptied.
* **Undo.** Each cleanup is written to `%LOCALAPPDATA%\SpaceSaver\activity.json` with every
  original path. Restore finds those paths in the Recycle Bin and puts them back, and refuses to
  overwrite anything that has appeared there since.
* **Manual and command items are never run.** WSL and Docker disks come with copyable steps:
  `wsl --shutdown`, then `Optimize-VHD -Path <file> -Mode Full` (Hyper-V module, elevated) or the
  `diskpart` sequence (`select vdisk file=…`, `attach vdisk readonly`, `compact vdisk`,
  `detach vdisk`), and `wsl --manage <distro> --set-sparse true` so the disk shrinks by itself.

## Command line

```text
spacesaver status [--json]                 disk space, last scan, activity
spacesaver scan [--json] [-c <category>] [--root <folder>]...
spacesaver clean [--yes] [--include-review] [-c <category>] [--json]
                                           dry run unless --yes
spacesaver activity [--json]
spacesaver restore <id>                    an activity id or a unique prefix of one
spacesaver help
```

Categories: `projects`, `caches`, `ide`, `ai`, `wsl`, `junk`. `spacesaver scan -c wsl` prints the
full compaction steps. Data lives in `%LOCALAPPDATA%\SpaceSaver` (set `SPACESAVER_DATA_DIR` to
use another folder).

## Build

Builds and tests run on GitHub Actions (`.github/workflows/windows.yml`, `windows-latest`): core
tests, a release CLI, a smoke test that scans the runner and cleans and restores a dormant
project through the real Recycle Bin, and the Tauri app with its NSIS installer. Both the
installer and `spacesaver.exe` are uploaded as workflow artifacts.

On a Windows machine with Rust (stable) and Node.js:

```powershell
cd windows
cargo test -p spacesaver-core
cargo build --release -p spacesaver-cli        # target\release\spacesaver.exe

cd app
npx @tauri-apps/cli@2 icon ..\..\docs\assets\icon-512.png -o icons   # once; icons aren't committed
npx @tauri-apps/cli@2 dev                      # run the app
npx @tauri-apps/cli@2 build --bundles nsis     # target\release\bundle\nsis\SpaceSaver_*_x64-setup.exe
```

The frontend also runs in any browser with built-in demo data when `window.__TAURI__` is
absent, so you can work on it without Windows:

```bash
python3 -m http.server -d windows/app/ui 8000   # then open http://localhost:8000
```

## Not done yet

* The desktop app hasn't been seen running on Windows yet; CI builds it and the installer but
  doesn't launch it. The UI has only been checked in a browser with demo data.
* No code signing, so SmartScreen will warn about the installer. No auto-update, no release
  pipeline (CI artifacts only).
* No `Cargo.lock` is committed yet; CI resolves the latest compatible crates.
* Not ported from the macOS app yet: Storage Map, Large Files, Duplicates, Old Downloads, browser
  and chat-app caches, AI session logs and the secrets audit, the MCP server, scheduling, the
  "make room for X GB" planner, custom rules, settings and exclusions, free-space history.
* Docker is only reported as a disk image; there's no `docker system df`/prune integration.
* Running-app detection covers editors, JetBrains IDEs, Ollama, LM Studio, Cargo and the
  Android emulator only.
* The Recycle Bin size limit falls back to 5% of the drive when Windows hasn't stored a
  per-drive setting, which may be stricter than the real limit.
* Sizes are logical, not allocated (compressed or sparse files are counted at full size).
