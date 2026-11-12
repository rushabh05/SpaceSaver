// Demo data and a fake backend, used when the page runs in a normal browser (no window.__TAURI__),
// so the UI can be previewed without Windows. Nothing here touches the real disk.
'use strict';

const DemoBackend = (() => {
  const GB = 1024 ** 3;
  const MB = 1024 ** 2;
  const DAY = 86400;
  const now = () => Math.floor(Date.now() / 1000);
  const HOME = 'C:\\Users\\you';
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const clone = (v) => JSON.parse(JSON.stringify(v));

  const bin = { kind: 'recycleBin' };
  let n = 0;
  function item(category, title, path, size, risk, extra) {
    const recommended = risk === 'safe';
    return Object.assign({
      id: 'demo:' + (n++),
      category, title,
      subtitle: path.replace(HOME, '~'),
      paths: [path],
      size: Math.round(size),
      files: Math.round(size / 40000),
      risk,
      method: bin,
      explanation: '',
      regenerate: '',
      tags: [],
      recommended,
      blockedReason: null,
      lastActivity: now() - 30 * DAY,
      group: null,
    }, extra || {});
  }

  function project(name, folder, size, risk, eco, tags, regen, idle) {
    const root = HOME + '\\code\\' + name;
    const active = idle < 45;
    return item('projectArtifacts', name + ' \u203a ' + folder, root + '\\' + folder, size, risk, {
      tags: [eco].concat(tags),
      recommended: risk === 'safe' && !active,
      group: '~\\code\\' + name,
      lastActivity: now() - idle * DAY,
      explanation: eco + ' ' + folder + ' folder for ' + name + ". It's generated from the project's manifest and can be rebuilt." +
        (active ? ' You worked on this project ' + (idle === 0 ? 'today' : idle + ' days ago') + '. Cleaning it means a rebuild next time you open it.' : ''),
      regenerate: 'Run `' + regen + '` in ~\\code\\' + name,
    });
  }

  function wslSteps(file, distro) {
    return 'This virtual disk holds the ' + distro + ' Linux file system. It grows as Linux writes files but never shrinks by itself, even after you delete them.\n\n' +
      '1. Delete what you don\'t need inside Linux, then stop WSL:\n   wsl --shutdown\n\n' +
      '2. Compact the file in an elevated PowerShell (needs the Hyper-V module):\n   Optimize-VHD -Path "' + file + '" -Mode Full\n\n' +
      '   Without Hyper-V (Windows Home), use diskpart in an elevated terminal instead:\n   diskpart\n   select vdisk file="' + file + '"\n   attach vdisk readonly\n   compact vdisk\n   detach vdisk\n   exit\n\n' +
      '3. Let it shrink automatically from now on (WSL 2.0 or later):\n   wsl --manage ' + distro + ' --set-sparse true';
  }

  const ubuntu = HOME + '\\AppData\\Local\\Packages\\CanonicalGroupLimited.Ubuntu22.04LTS_79rhkp1fndgsc\\LocalState\\ext4.vhdx';
  const docker = HOME + '\\AppData\\Local\\Docker\\wsl\\disk\\docker_data.vhdx';

  const items = [
    project('rust-playground', 'target', 3.1 * GB, 'safe', 'Rust', ['Dormant 3mo', 'git', 'Cargo.lock'], 'cargo build', 96),
    project('ml-experiments', '.venv', 2.4 * GB, 'review', 'Python venv', ['Dormant 2mo', 'uv.lock'], 'uv sync / pip install -r requirements.txt', 64),
    project('spacesaver', 'target', 1.9 * GB, 'review', 'Rust', ['Active today', 'git', 'Cargo.lock'], 'cargo build', 0),
    project('old-portfolio', 'node_modules', 1.42 * GB, 'safe', 'Node.js', ['Dormant 5mo', 'git', 'package-lock.json'], 'npm ci', 150),
    project('hackathon-2024', 'node_modules', 868 * MB, 'safe', 'Node.js', ['Dormant 7mo', 'pnpm-lock.yaml'], 'pnpm install', 214),
    project('old-portfolio', '.next', 312 * MB, 'safe', 'Next.js', ['Dormant 5mo', 'git'], 'next build', 150),
    project('InvoiceApi', 'bin', 210 * MB, 'safe', '.NET', ['Dormant 4mo', 'git'], 'dotnet build', 122),
    project('InvoiceApi', 'obj', 96 * MB, 'safe', '.NET', ['Dormant 4mo', 'git'], 'dotnet build', 122),

    item('packageCaches', 'pnpm store', HOME + '\\AppData\\Local\\pnpm\\store', 6.2 * GB, 'review', {
      explanation: "pnpm's content-addressed store. Every pnpm project hard-links into it.",
      regenerate: '`pnpm store prune` removes only unreferenced packages; deleting all of it means re-downloading everything.' }),
    item('packageCaches', 'NuGet global packages', HOME + '\\.nuget\\packages', 4.6 * GB, 'review', {
      explanation: ".NET's global packages folder. Every project restores from it.",
      regenerate: 'Restored by `dotnet restore`, which re-downloads every package.' }),
    item('packageCaches', 'Gradle caches', HOME + '\\.gradle\\caches', 3.3 * GB, 'safe', {
      explanation: "Gradle's dependency cache and downloaded wrapper distributions.", regenerate: 'Re-downloaded on the next Gradle build.' }),
    item('packageCaches', 'npm cache', HOME + '\\AppData\\Local\\npm-cache\\_cacache', 2.8 * GB, 'safe', {
      explanation: "npm's content-addressed download cache and debug logs.", regenerate: 'Re-downloaded on the next npm install.' }),
    item('packageCaches', 'Cargo registry', HOME + '\\.cargo\\registry\\cache', 1.7 * GB, 'safe', {
      subtitle: '~\\.cargo\\registry\\cache (+3 more)',
      explanation: 'Downloaded crate sources and git dependencies.', regenerate: 'Re-downloaded on the next cargo build.' }),
    item('packageCaches', 'Playwright browsers', HOME + '\\AppData\\Local\\ms-playwright', 1.2 * GB, 'review', {
      explanation: 'Browser builds downloaded by Playwright.', regenerate: '`npx playwright install`.' }),
    item('packageCaches', 'NuGet HTTP cache', HOME + '\\AppData\\Local\\NuGet\\v3-cache', 1.1 * GB, 'safe', {
      explanation: 'Package metadata and .nupkg downloads NuGet keeps between restores.',
      regenerate: 'Re-downloaded on the next `dotnet restore`.' }),
    item('packageCaches', 'pip cache', HOME + '\\AppData\\Local\\pip\\Cache', 940 * MB, 'safe', {
      explanation: 'Downloaded wheels and HTTP cache for pip.', regenerate: 'Re-downloaded on the next pip install.' }),
    item('packageCaches', 'Go build cache', HOME + '\\AppData\\Local\\go-build', 640 * MB, 'safe', {
      explanation: 'Compiled package cache.', regenerate: 'Equivalent to `go clean -cache`.' }),

    item('ideCaches', 'JetBrains caches \u00b7 IntelliJIdea2023.3', HOME + '\\AppData\\Local\\JetBrains\\IntelliJIdea2023.3\\caches', 2.1 * GB, 'safe', {
      explanation: 'Indexes and caches for one JetBrains IDE version. Old versions leave theirs behind.', regenerate: 'Re-indexed when the IDE opens a project.' }),
    item('ideCaches', 'JetBrains caches \u00b7 Rider2024.2', HOME + '\\AppData\\Local\\JetBrains\\Rider2024.2\\caches', 1.4 * GB, 'safe', {
      explanation: 'Indexes and caches for one JetBrains IDE version. Old versions leave theirs behind.', regenerate: 'Re-indexed when the IDE opens a project.' }),
    item('ideCaches', 'Cursor caches', HOME + '\\AppData\\Roaming\\Cursor\\CachedData', 1.3 * GB, 'safe', {
      subtitle: '~\\AppData\\Roaming\\Cursor\\CachedData (+4 more)',
      explanation: 'Electron, GPU and extension download caches for Cursor.', regenerate: 'Rebuilt when Cursor starts.' }),
    item('ideCaches', 'VS Code caches', HOME + '\\AppData\\Roaming\\Code\\CachedData', 820 * MB, 'safe', {
      subtitle: '~\\AppData\\Roaming\\Code\\CachedData (+5 more)', recommended: false,
      blockedReason: 'VS Code is running. Close it first.',
      explanation: 'Electron, GPU and extension download caches for VS Code.', regenerate: 'Rebuilt when VS Code starts.' }),

    item('aiModels', 'Ollama models', HOME + '\\.ollama\\models', 9.8 * GB, 'review', {
      explanation: 'Model weights pulled with `ollama pull`.', regenerate: '`ollama pull <model>` downloads them again.' }),
    item('aiModels', 'Hugging Face \u00b7 meta-llama/Llama-3.2-3B-Instruct', HOME + '\\.cache\\huggingface\\hub\\models--meta-llama--Llama-3.2-3B-Instruct', 6.4 * GB, 'review', {
      explanation: 'A model or dataset snapshot downloaded by transformers, diffusers or huggingface-cli.', regenerate: 'Re-downloaded from the Hub the next time code loads it.' }),
    item('aiModels', 'Hugging Face \u00b7 openai/whisper-large-v3', HOME + '\\.cache\\huggingface\\hub\\models--openai--whisper-large-v3', 3.1 * GB, 'review', {
      explanation: 'A model or dataset snapshot downloaded by transformers, diffusers or huggingface-cli.', regenerate: 'Re-downloaded from the Hub the next time code loads it.' }),

    item('wslDocker', 'WSL \u00b7 Ubuntu22.04LTS', ubuntu, 48.3 * GB, 'review', {
      recommended: false, files: 1, tags: ['VHDX', 'Never deleted', 'Ubuntu22.04LTS'],
      method: { kind: 'manual', instructions: wslSteps(ubuntu, 'Ubuntu22.04LTS'),
        commands: ['wsl --shutdown', 'Optimize-VHD -Path "' + ubuntu + '" -Mode Full', 'wsl --manage Ubuntu22.04LTS --set-sparse true'] },
      explanation: "A WSL distro's virtual disk. SpaceSaver never deletes it: that would delete the whole Linux install and its files.",
      regenerate: 'Nothing is deleted. Compacting keeps all your Linux files and gives back the unused space.' }),
    item('wslDocker', 'Docker Desktop data disk', docker, 31.7 * GB, 'review', {
      recommended: false, files: 1, tags: ['VHDX', 'Never deleted'],
      method: { kind: 'manual',
        instructions: 'Docker Desktop keeps images, containers, volumes and build cache in this virtual disk. It grows as you pull and build, and never shrinks by itself.\n\n' +
          '1. Free space inside it first (removes stopped containers, unused networks, dangling images and build cache):\n   docker system prune\n\n' +
          '2. Quit Docker Desktop, then stop WSL:\n   wsl --shutdown\n\n' +
          '3. Compact the file in an elevated PowerShell (needs the Hyper-V module):\n   Optimize-VHD -Path "' + docker + '" -Mode Full',
        commands: ['docker system prune', 'wsl --shutdown', 'Optimize-VHD -Path "' + docker + '" -Mode Full'] },
      explanation: "Docker Desktop's virtual disk. SpaceSaver never deletes it: that would wipe every image, container and volume.",
      regenerate: 'Nothing is deleted. Compacting keeps all your Linux files and gives back the unused space.' }),

    item('systemJunk', 'Old temporary files', HOME + '\\AppData\\Local\\Temp\\setup-4f2a', 2.3 * GB, 'safe', {
      subtitle: '~\\AppData\\Local\\Temp \u00b7 214 entries untouched for 7+ days', tags: ['214 entries'],
      explanation: 'Files and folders in your temp folder that nothing has changed for 7 days. Installers and apps leave these behind. Anything still in use is skipped.',
      regenerate: 'Not needed. Apps recreate temp files when they need them.' }),
    item('systemJunk', 'Crash dumps', HOME + '\\AppData\\Local\\CrashDumps', 1.1 * GB, 'safe', {
      explanation: "Memory dumps Windows writes when an app crashes. Only useful to that app's developers.", regenerate: 'Not needed.' }),
  ];

  const disk = { drive: 'C:\\', total: 476.3 * GB, free: 31.4 * GB };
  let scan = { version: 1, date: now() - 120, durationMs: 4200, disk, categories: [], items };
  let activity = [
    {
      id: '3f9c2a71', date: now() - 3 * DAY, title: '14 items', source: 'app', bytes: Math.round(9.6 * GB), status: 'completed', errors: [],
      records: [
        { original: HOME + '\\code\\weather-app\\node_modules', title: 'weather-app \u203a node_modules', category: 'projectArtifacts', bytes: Math.round(1.2 * GB), restored: false },
        { original: HOME + '\\AppData\\Local\\Yarn\\Cache', title: 'Yarn cache', category: 'packageCaches', bytes: Math.round(8.4 * GB), restored: false },
      ],
    },
    {
      id: 'b18e04d5', date: now() - 12 * DAY, title: 'JetBrains caches \u00b7 PyCharm2023.1', source: 'cli', bytes: Math.round(1.8 * GB), status: 'restored', errors: [],
      records: [{ original: HOME + '\\AppData\\Local\\JetBrains\\PyCharm2023.1\\caches', title: 'JetBrains caches \u00b7 PyCharm2023.1', category: 'ideCaches', bytes: Math.round(1.8 * GB), restored: true }],
    },
  ];
  const removed = new Map(); // activity id -> items taken out of the scan
  const listeners = [];

  return {
    demo: true,
    disk: async () => clone(scan.disk),
    lastScan: async () => clone(scan),
    scan: async () => {
      await sleep(1600);
      scan.date = now();
      return clone(scan);
    },
    clean: async (ids) => {
      const chosen = scan.items.filter((i) => ids.includes(i.id) && i.method.kind === 'recycleBin' && !i.blockedReason);
      let bytes = 0;
      for (let k = 0; k < chosen.length; k++) {
        listeners.forEach((cb) => cb({ done: k, total: chosen.length, current: chosen[k].title, bytes }));
        await sleep(260 + Math.random() * 260);
        bytes += chosen[k].size;
      }
      listeners.forEach((cb) => cb({ done: chosen.length, total: chosen.length, current: '', bytes }));
      const entry = {
        id: Math.random().toString(16).slice(2, 10), date: now(), source: 'app', bytes, status: 'completed', errors: [],
        title: chosen.length === 1 ? chosen[0].title : chosen.length + ' items',
        records: chosen.map((i) => ({ original: i.paths[0], title: i.title, category: i.category, bytes: i.size, restored: false })),
      };
      activity.unshift(entry);
      removed.set(entry.id, chosen);
      // Disk free space doesn't change: the bytes sit in the Recycle Bin until it's emptied.
      scan.items = scan.items.filter((i) => !chosen.includes(i));
      return {
        dryRun: false, bytes, skipped: [], errors: [], entry: clone(entry),
        items: chosen.map((i) => ({ id: i.id, title: i.title, size: i.size, paths: i.paths })),
        movedIds: chosen.map((i) => i.id),
      };
    },
    activity: async () => clone(activity),
    restore: async (id) => {
      await sleep(500);
      const entry = activity.find((e) => e.id === id);
      if (!entry) throw new Error('No activity entry with id ' + id);
      const pending = entry.records.filter((r) => !r.restored);
      pending.forEach((r) => { r.restored = true; });
      entry.status = 'restored';
      const back = removed.get(id);
      if (back) { scan.items = scan.items.concat(back); removed.delete(id); }
      return { entry: clone(entry), restored: pending.length, errors: [] };
    },
    reveal: async () => { throw new Error('Explorer opens here in the Windows app.'); },
    onCleanProgress: (cb) => { listeners.push(cb); },
  };
})();
