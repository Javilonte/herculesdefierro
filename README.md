# Hercules de Fierro

Reverse-engineering notes and Ghidra-decompiled analysis of the **Hercules mainframe emulator** as shipped inside the **TK4- v1.00 update 5** distribution.

> Hercules emulates the IBM System/370, ESA/390, and z/Architecture instruction sets on commodity hardware. TK4- is a pre-packaged turnkey MVS 3.8j system that runs on top of Hercules. This repository is a structured walk-through of how the Windows version boots and how the CPU emulator is organized, produced with the [REA](https://github.com/morluto/rea) reverse-engineering toolchain and [Ghidra](https://ghidra-sre.org/).

## Quick start

You only need the **TK4- v1.00 update 5** distribution zip (obtain it from the [official TK4- site](https://wotho.ethz.ch/tk4-/) -- do not redistribute it from this repo) and a 64-bit Windows machine. No admin rights required.

```powershell
# from this repo's root
.\scripts\setup.ps1
cd ..\hercules_run
.\hercules\windows\64\hercules.exe -f conf\tk4-.cnf
```

The first command extracts the Windows 64-bit emulator, the 28 MVS 3.8j DASD images, the configuration tree, and the JCL/scripts into a sibling directory `hercules_run/`. The second command changes into that directory. The third command starts the emulator in the foreground; you will see the 3270 console in your terminal. Press Ctrl+C to stop.

For headless operation, daemon mode listens on TCP ports 27415 through 27418 so you can connect with a 3270 client (`telnet localhost 27415` after enabling the Windows Telnet Client, or any wc3270-class emulator). See [Running the emulator](#running-the-emulator) for the full guide.

## Quick start

The TK4- v1.00 update 5 zip doesn't ship macOS or Linux binaries that are usable from a different host. The `scripts/setup.ps1` script extracts the parts you need for Windows; on macOS/Linux, follow the [Running on macOS](#running-on-macos) section below for a step-by-step setup.

You only need the **TK4- v1.00 update 5** distribution zip (obtain it from the [official TK4- site](https://wotho.ethz.ch/tk4-/) -- do not redistribute it from this repo) and a 64-bit Windows machine, a Mac, or Linux box. No admin rights required on macOS or Linux.

```powershell
# from this repo's root (Windows)
.\scripts\setup.ps1
cd ..\hercules_run
.\hercules\windows\64\hercules.exe -f conf\tk4-.cnf
```

```bash
# from this repo's root (macOS / Linux)
bash scripts/setup.sh
cd ../hercules_run
./hercules/darwin/64/hercules -f conf/tk4-.cnf
```

The first command extracts the emulator, the 28 MVS 3.8j DASD images, the configuration tree, and the JCL/scripts into a sibling directory `hercules_run/`. The second command changes into that directory. The third command starts the emulator in the foreground; you will see the 3270 console in your terminal. Press Ctrl+C to stop.

For headless operation, daemon mode listens on TCP port 3270 (or one of 27415..27418 for per-CPU COMM threads); see [Running the emulator](#running-the-emulator) for the full guide.

## Running on macOS (step by step)

The TK4- v1.00 update 5 zip only ships binaries for Windows and Linux. To run Hercules on macOS you have to combine the TK4- configs and DASD images with the macOS-built `hercules` binaries from the official Hercules DMG.

Everything below is a copy-paste recipe that assumes you have a Mac with macOS 11 (Big Sur) or newer and admin access. About 1 GB of free disk space is required.

### Step 0 - Prerequisites

Download these two files before doing anything else. Save both to `~/Downloads/`:

- **TK4- v1.00 update 5 zip** (~119 MB): `tk4-_v1.00_current-v05.zip` from [wotho.ethz.ch/tk4-](https://wotho.ethz.ch/tk4-/) (look for the v1.00 update 5 entry on that page).
- **Hercules 4.x macOS DMG** (~30 MB): from [hercules-390.org](https://www.hercules-390.org/) (the latest stable release; the DMG installs `Hercules.app` into `/Applications/`).

### Step 1 - Install Homebrew (one-time)

Open Terminal (Cmd+Space, type "Terminal", hit Enter) and run:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

Follow the on-screen instructions. When the installer finishes, it shows a block like:

```bash
==> Next steps:
- Run these commands in your shell to add Homebrew to your PATH:
  echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zshrc
  eval "$(/opt/homebrew/bin/brew shellenv)"
```

Run those two commands (the `echo` line persists across Terminal sessions, the `eval` line is for the current session only). Verify:

```bash
brew --version
```

You should see something like `Homebrew 4.x.y`.

### Step 2 - Install the wx3270 3270 GUI client (one-time)

```bash
brew install --cask x3270
```

That puts `wx3270.app` into `/Applications/`. (If Homebrew's prefix is `/usr/local/` instead of `/opt/homebrew/`, the app lands in the same `/Applications/`.)

Verify:

```bash
ls -d /Applications/wx3270.app
```

You should see the path printed. Open it once from Finder so macOS registers it as a known GUI app.

### Step 3 - Install the Hercules emulator from the DMG

You already downloaded the DMG in Step 0. Double-click it in Finder, then drag the `Hercules` icon onto the `Applications` shortcut the DMG provides. When the copy finishes, eject the DMG.

Verify:

```bash
ls /Applications/Hercules.app/Contents/MacOS/
```

You should see a list of files including `hercules` (the main executable), `hengine.dylib`, `hdt3270.dylib`, `hutil.dylib`, `hsys.dylib`, plus several `dasd*` and `hdt*.dylib` plugins.

### Step 4 - Clone this repo into your working folder

```bash
mkdir -p ~/work && cd ~/work
git clone https://github.com/Javilonte/herculesdefierro.git
cd herculesdefierro
```

(`~/work` is just a suggestion -- any folder will do.)

### Step 5 - Extract TK4- with `scripts/setup.sh`

The script auto-discovers the zip in `~/Downloads/` or `../tk4-...zip` relative to the repo. If your zip is elsewhere, pass the path:

```bash
bash scripts/setup.sh
# or, if the zip is somewhere else:
bash scripts/setup.sh ~/Downloads/tk4-_v1.00_current-v05.zip
```

You should see output like:

```
Using zip: /Users/you/Downloads/tk4-_v1.00_current-v05.zip
Dest dir: /Users/you/work/hercules_run
Extracted 136 files (skipped 601 unnecessary entries).
...
hercules_run/ ready (DASD images in dasd/: 28 files)
Detected platform: macOS

  NEXT STEPS on macOS:
  1. Install the official Hercules DMG from https://www.hercules-390.org/.
  2. Copy the macOS binaries into a darwin/ subdirectory of hercules_run/:
  ...
```

Quick sanity check that the configs and DASD images landed correctly:

```bash
ls ../hercules_run/dasd | wc -l          # should print 28
test -f ../hercules_run/conf/tk4-.cnf && echo "config OK"
test -f ../hercules_run/scripts/ipl.rc && echo "ipl.rc OK"
```

### Step 6 - Copy the macOS Hercules binaries into `hercules_run/`

`scripts/setup.sh` extracted Linux x64 binaries from the zip. Replace them with the Mach-O binaries from the official Hercules DMG, in a `darwin/64/` subdirectory:

```bash
HERSRC=/Applications/Hercules.app/Contents/MacOS
HERDEST=../hercules_run/hercules/darwin/64
mkdir -p "$HERDEST"

cp "$HERSRC/hercules"           "$HERDEST/"
cp "$HERSRC/hengine.dylib"      "$HERDEST/"
cp "$HERSRC/hutil.dylib"        "$HERDEST/"
cp "$HERSRC/hsys.dylib"         "$HERDEST/"
for f in "$HERSRC"/hdt*.dylib; do
  [ -f "$f" ] && cp "$f" "$HERDEST/"
done
# The official DMG also ships a few CLI helpers (dasdcopy, dasdls, etc.).
# They're optional for running the emulator itself; copy them if you want them.
for f in "$HERSRC"/dasd*; do
  [ -x "$f" ] && cp "$f" "$HERDEST/"
done
chmod +x "$HERDEST/hercules" "$HERDEST"/dasd* 2>/dev/null || true

ls "$HERDEST"
```

You should see at least: `hercules`, `hdt3270.dylib`, `hdt3088.dylib`, `hengine.dylib`, `hutil.dylib`, `hsys.dylib`, plus the `dasd*` helpers you copied.

If your Hercules DMG packaged the files under slightly different paths (e.g. `Contents/Resources/` instead of `Contents/MacOS/`), list the app's Contents with `ls -R /Applications/Hercules.app` and adjust the source path accordingly.

### Step 7 - Apply the welcome-banner patch

The macOS binary is **different** from the Windows one (Mach-O vs PE), so its SHA-256 won't match the known Windows SHA. Use `--discover` first -- the script will find the 8 banner-line strings in your binary and show their offsets, so the maintainer can add macOS support:

```bash
bash scripts/patch-banner.sh --discover
```

You should see something like:

```
=== discover mode ===
file:   /Users/you/work/hercules_run/hercules/darwin/64/hdt3270.dylib
size:   49152 bytes
sha256: <NEW_SHA_FOR_MACOS>

Searching for the 'Hercules Version' ASCII marker...
  'Hercules Version' found 1 time(s):
    file offset 0x8c40: ...b'Hercules Version  :\x00\x00...'...

Note: the Windows build (hdt3270.dll @ SHA 0B85525C...) has 'Hercules Version'
      at file offset 0x77B0 with the 8 lines spanning 0x766B to 0x77EB.
      Other builds will have different offsets; use the data above to find them.
```

The `--discover` output is the data the script needs to be extended for macOS. Save it:

```bash
bash scripts/patch-banner.sh --discover | tee /tmp/hercules-discover.txt
cat /tmp/hercules-discover.txt
```

**Two paths from here:**

- **(a) Open an issue** at https://github.com/Javilonte/herculesdefierro/issues and paste the discover output. The maintainer (me, or anyone with a Mac) can extend `scripts/patch-banner.sh` with the macOS offsets and commit it. Next time you run `bash scripts/patch-banner.sh --apply`, it will patch your Mac binary the same way.

- **(b) Compute the offsets yourself.** Open `hdt3270.dylib` in a hex editor (e.g. `xxd` from the CLI or Hex Fiend from the App Store). Find the 8 strings that end the original banner (one per line, in the same order as the Windows binary -- see the offset table below). All 8 sit within ~256 bytes of each other in `.rdata`/`.rodata`. The banner pattern is:
  - "Hercules Version" (label), "$(VERSION)" (value)
  - "Host name" / "$(HOSTNAME)"
  - "Host OS" / "$(HOSTOS)-$(HOSTOSREL) $(HOSTOSVER)"
  - "Host Architecture" / "$(HOSTARCH)"
  - "Processors" / "$(HOSTNUMCPUS)"
  - "LPAR Name" / "$(LPARNAME)"
  - "Device number" / "$(CSS):$(CCUU)"
  - "Subchannel" / "$(SUBCHAN)"

  Each label slot is 24 bytes (19 chars content + null + 4 bytes padding). Each value slot is 16 bytes (40 for "Host OS"). Add the offsets you found to `scripts/patch-banner.sh` (`KNOWN_SHAS_MACOS_*` block + `do_apply` for macOS) and commit via a PR.

The patch-banner script's `--apply` mode will refuse if the SHA doesn't match any known whitelist, so you can't accidentally patch the wrong offsets.

### Step 8 - Start the daemon

The default config (`conf/tk4-.cnf`) launches MVS 3.8j automatically after IPL. For interactive use, foreground mode is simplest:

```bash
cd ../hercules_run
./hercules/darwin/64/hercules -f conf/tk4-.cnf
```

You'll see the welcome banner (now patched) followed by an ASCII-art `HHHH ... HERCULES ...` block, then the operator panel prompt `>`. Press Ctrl+C to quit.

For headless daemon mode (`-d`), the daemon opens TCP port 3270 for remote 3270 clients (don't use 27415-27418 -- those are internal per-CPU COMM threads that drop connections):

```bash
cd ../hercules_run
./hercules/darwin/64/hercules -d -f conf/tk4-.cnf
```

### Step 9 - Connect wx3270

Open a second Terminal window and run:

```bash
/Applications/wx3270.app/Contents/MacOS/wx3270 -model 4 localhost:3270 &
# or just `open /Applications/wx3270.app` and connect with host=localhost port=3270 model=4
```

A 3270 GUI window opens. The first screen is the same welcome banner (now patched on the daemon side), followed by MVS prompts after you type `ipl 0280`.

### Step 10 - Shut down cleanly

In the daemon's Terminal, press Ctrl+C. The daemon catches `SIGINT`, runs the cleanup callback, and exits. (The `system_cleanup` symbol from `hengine.dll` is a no-op in 4.00.0 -- that's a quirk of the source, not of our patch -- but the daemon's own signal handler still runs orderly shutdown.)

### Troubleshooting on macOS

| Symptom | Likely cause | Fix |
|---|---|---|
| `bash: python3: command not found` during `setup.sh` / `patch-banner.sh --discover` | macOS doesn't ship `python3` by default on 10.13 or earlier | `brew install python` |
| `error: cannot find hercules` after starting the daemon | macOS binaries are in the wrong path or not made executable | `chmod +x ../hercules_run/hercules/darwin/64/hercules` and double-check the path |
| `dlopen(... hdt3270.dylib ...): image not found` | `hdt*.dylib` siblings are missing from `darwin/64/` | Re-run the `cp` lines in Step 6 with the full set of `*.dylib` files from your Hercules install |
| `Illegal instruction: 4` on Apple Silicon | The Mach-O binaries are Intel-only but you ran them under Rosetta without Rosetta enabled | Either install Rosetta (`softwareupdate --install-rosetta`) or get an arm64 build of Hercules |
| wc3270/`open-console.bat` works on Windows but wx3270 on Mac reports "Connection refused" | wx3270 is connecting to port 27415 (wrong) instead of 3270 (right) | In wx3270, set Host=`localhost`, Port=`3270` explicitly |
| `setup.sh: zip file not found` and your zip IS in `~/Downloads/` | The zip filename doesn't exactly match `tk4-_v1.00_current-v05.zip` | `bash scripts/setup.sh /full/path/to/your.zip` |
| `Tk4-` window 3270 panel shows garbage characters | Terminal codepage is not 037/500 | In the panel preferences, set Terminal codepage to `cp037` |

## Running on Linux

The same flow applies -- `scripts/setup.sh` was designed cross-platform. After step 6 you already have working Linux x64 binaries under `hercules_run/hercules/linux/64/`, so you can skip copying platform binaries. Just:

```bash
cd ../hercules_run
./hercules/linux/64/hercules -d -f conf/tk4-.cnf
```

For the patch, the Linux `hdt3270.so` has the same SHA as Windows `hdt3270.dll` only if both were built from the exact same commit with identical toolchain inputs (rare). Most likely you'll see a different SHA -- run `bash scripts/patch-banner.sh --discover` to see offsets for *your* Linux build.

## What is here

This is **analysis output only**, not redistributed source code or binaries. The original `hercules.exe` and `hengine.dll` are part of the TK4- distribution, released under the **Q Public License** by Juergen Winkelmann. The underlying Hercules source code is (c) 1999-2012 Roger Bowler, Jan Jaeger, and others.

Everything in this repository is the **static-analysis output** of REA against the unmodified binaries, plus narrative documentation explaining how the emulator fits together.

## Method

- **Tool**: [REA](https://github.com/morluto/rea) v6.5.0 (CLI)
- **Decompiler**: [Ghidra](https://ghidra-sre.org/) 12.1.4 PUBLIC
- **Provider**: REA Windows Ghidra **P0** (read-only, 26 operations)
- **Host**: Windows 11 Pro x64, Node.js 24.20.0, JDK 21.0.12.1
- **No dynamic analysis.** **No PDB loading** (REA P0 does not accept caller-supplied PDBs; function names below are what Ghidra recovered from static analysis plus the strings the bootstrap expects).

All SHA-256 hashes of the analysed binaries are recorded in the analysis output for reproducibility.

## Repository layout

```
.
├── README.md          # this file
├── LICENSE            # MIT (for the analysis notes)
├── .gitignore
├── scripts/
│   ├── setup.ps1        # Windows: extracts hercules_run/ from a TK4- v1.00 update 5 zip
│   ├── setup.sh         # macOS / Linux: same as setup.ps1 (cross-platform)
│   ├── open-console.bat # Windows: opens a wc3270 console against the local daemon
│   └── patch-banner.sh  # macOS / Linux: patches hdt3270 to show a custom banner
└── odd/                # the entire REA evidence trail
    ├── tasks/
    │   ├── hercules-re.md   # bootstrap .exe analysis
    │   └── hengine-re.md    # CPU-emulator DLL analysis
    ├── hercules_inspect.json                # REA overview of hercules.exe
    ├── hercules_exe_loadimage.json          # PE header + entry point
    ├── hercules.exe_procedures_pretty.txt   # 117 procedures
    ├── hercules.exe_strings_pretty.txt      # 190 strings
    ├── hercules.exe_imports.txt             # imports per DLL
    ├── hercules_decompile_*.txt             # 9 decompiled functions
    ├── hercules_xref_*.txt                  # 7 cross-reference reports
    ├── hengine_inspect.json                 # REA overview of hengine.dll
    ├── hengine_procs_all.json               # 4,828 procedures
    ├── hengine_decompile_impl.txt           # entry-point trace (impl)
    ├── hengine_decompile_*.txt              # 17 decompiled functions
    └── ... (full set of REA outputs)
```

The `scripts/` directory holds the setup helper that produces the runnable environment. The `odd/tasks/` subdirectory holds the two feature documents that drive the static analysis. Every other file in `odd/` is an evidence artifact referenced from those documents.

Each REA output is saved twice when relevant: a `.txt` view (UTF-16 with BOM, as REA emits it) and a `_utf8.txt` view (re-encoded to UTF-8 for portable grep/git tooling).

## What we learned

### `hercules.exe` (21 KB) is just a bootstrap

The `.exe` is a tiny shim. Its entry point is the standard MSVC `__tmainCRTStartup`; the application `main` at `0x401000` does only Windows-specific prep:

- Sets the bootstrap thread name.
- Disables the console window's close button via `GetSystemMenu` + `EnableMenuItem(SC_CLOSE, MF_GRAYED)`.
- Loads `DbgHelp.dll` dynamically and installs a `SetUnhandledExceptionFilter` that prints an ASCII `* OOPS! *` banner and offers to write a MiniDump.
- Calls `hengine.dll::impl(argc, argv)` and waits.

The `.exe` exports five callbacks (`hdl_depc`, `hdl_init`, `hdl_ddev`, `hdl_reso`, `hdl_fini`) that hengine calls back into to register the dependency structs, the 19 named callbacks (`parse_args`, `panel_command`, `replace_opcode`, ...), the 17 IBM device types (`2305`, `2311`, `2314`, `3330`, `3340`, `3350`, `3375`, `3380`, `3390`, `9345`, `0671`, `3310`, `3370`, `9313`, `9332`, `9335`, `9336`), and to resolve the symbol table.

### `hengine.dll` (3.2 MB) is the actual emulator

`hengine.dll` contains **4,828 procedures** and **5,345 strings**. Its `impl` function at `0x815570`:

1. Self-tests the pthread mutex model.
2. Initializes the 0xc720-byte `SYSBLK` and writes its version markers (`"4.00.0"`, build date `Jul 15 2013`).
3. Spins up to 32 CPU mutex/cond slots.
4. Parses argv (`-h -f -d -b -v -s -p -l`).
5. **Builds the 256-entry opcode-handler tables** for every architecture (S/370, ESA/390, z/Architecture + a no-op 4th) via `FUN_0082a860`.
6. **Delegates plugin loading to `HUTIL.DLL::hdl_main()`** -- hengine never `LoadLibraryA`s `hdasd`/`hsys` itself.
7. Enters the 3270 console panel (or the daemon task, when `-d`).

The CPU **dispatcher is a jump-table machinery**, not a single function. `FUN_0082a860` runs once at startup and fills **18+ per-arch opcode tables** in `.data` (one cell = 8-byte function pointer). The per-CPU `run_cpu` loop reads `[arch][opcode1*256 + opcode2]` from `regs->insttab[]` and tail-calls the handler with `regs`. The `ARCH_DEP` macro in the source produces one copy per architecture; you can see the per-arch regions in the procedure inventory.

The `replace_opcode` hook (`replace_opcode_r` at `0x82a6d0`) and the `panel_command` plumbing are wired through the bootstrap callbacks -- they are not fired per-instruction. `system_cleanup` is a no-op stub, a contract marker for the shutdown handshake.

## Running the emulator

The standard way to run Hercules is via the setup helper plus the existing TK4- distribution zip. The helper extracts only the parts you need (Windows 64-bit binaries, configs, DASD, scripts, JCL) into a sibling directory `hercules_run/`, leaving the Linux binaries, 32-bit Windows build, source, and PDFs behind.

### Prerequisites

- **Windows 10 or 11, 64-bit** (Windows Server 2016+ also works).
- The **TK4- v1.00 update 5** zip (`tk4-_v1.00_current-v05.zip`, ~119 MB). Obtain it from the [official TK4- site](https://wotho.ethz.ch/tk4-/); it is not redistributed here.
- The zip must be reachable from the script. The default search order is:
  1. The parent directory of this repo (alongside `herculesdefierro/`).
  2. `%USERPROFILE%\Downloads`.
  3. The current directory.

  Pass `-ZipPath <path>` to `setup.ps1` to override.

### What the setup script does

`scripts/setup.ps1` is a PowerShell script that:

- Finds or accepts the TK4- zip.
- Creates `hercules_run/` as a sibling of this repo.
- Extracts only the Windows 64-bit subpaths:
  - `hercules/windows/64/` (hercules.exe + 18 plugin DLLs)
  - `conf/`, `local_conf/`, `dasd/`, `scripts/`, `log/`, `jcl/`, `tapes/`, `pch/`, `unattended/`, `rdr/`
- Skips Linux binaries, 32-bit Windows builds, source, documentation PDFs, and the Q Public License text.
- Verifies that `hercules.exe`, `hengine.dll`, `conf\tk4-.cnf`, and `scripts\ipl.rc` are present.
- Prints the exact commands to start the emulator.

### Foreground mode (interactive 3270 console)

```powershell
cd <repo-parent>\hercules_run
.\hercules\windows\64\hercules.exe -f conf\tk4-.cnf
```

You will see the Hercules banner, then the 3270 console screen rendered in your terminal. From the panel you can type commands like:

| Command | What it does |
|---|---|
| `ipl 0280` | Initial Program Load: boots MVS 3.8j from the SYS1.IPLPARM on dasd pub002.280. |
| `ipl 0190` | Same, from the work03.190 volume (sometimes used as alternate). |
| `devlist` | Lists the configured DASD volumes and their device addresses. |
| `q cpu` or `q` | Shows CPU status (running, stopped, wait state). |
| `help` | Lists the panel commands. |
| `start` / `stop` | Start or stop a CPU. |
| `restart` | Restart the current CPU from its PSW. |
| `step` | Single-step one instruction (when CPU is stopped). |
| `shutdown` | Initiate an orderly shutdown of Hercules. |

To exit: press Ctrl+C in the terminal, or type `shutdown` and wait for the orderly power-down.

### Daemon mode (headless, remote 3270)

```powershell
cd <repo-parent>\hercules_run
.\hercules\windows\64\hercules.exe -d -f conf\tk4-.cnf
```

Hercules starts in the background without a local console. It opens the **standard TN3270 console listener on TCP port 3270** (logged as `HHC01024I Waiting for console connections on port 3270`). It also opens per-device COMM threads on TCP ports 27415 through 27418 (one per configured CPU), but **those ports are for internal Hercules device traffic (CTC, LCS, channel-attached devices) -- they do NOT accept 3270 client connections and will silently drop them.** Connect wc3270 to port 3270.

#### Connecting with wc3270 (recommended)

The repo ships a helper at `scripts/open-console.bat` that wraps wc3270. Install wc3270 once (download the no-installer zip from the [x3270 wiki](https://x3270.bgp.nu/download.html) and extract to `C:\tools\wc3270-4.5ga6\` -- add that directory to `PATH` for convenience -- or install `wc3270-4.5ga6-setup.exe` with admin rights). Then:

```powershell
..\herculesdefierro\scripts\open-console.bat
```

The helper auto-detects wc3270 on `PATH` or at the default location, and passes `-model 4` (43x80 colour screen, the standard MVS console model). You should see the Hercules banner with version, host info and the `'HHHH...' HERCULES ...` ASCII art, then the prompt `>`. From there, the same foreground-mode commands work: `devlist`, `ipl 0280`, `q cpu`, `help`, etc.

To stop the daemon, kill the `hercules.exe` process from Task Manager (or `Stop-Process -Name hercules` from PowerShell). The emulator catches `SIGINT` and `SIGTERM` and runs the shutdown callback before exiting.

### Configuration files

- `conf\tk4-.cnf` -- the main configuration; it includes `conf\cbt_dasd.cnf`, `conf\source_dasd.cnf`, `conf\tk4-_updates.cnf` (which in turn pulls in `conf\tk4-_updates\01` through `10`), and `conf\local.cnf` (which pulls in `local_conf\01` through `10`).
- `local_conf\01..10` -- per-user local overrides. Each number is a TK4- update level; the last one present takes effect. Use these to customise CPU count, main storage size, etc., without editing the upstream config.
- `scripts\ipl.rc` -- the Hercules RC file that runs after MVS comes up. You can drop MVS commands or Hercules panel commands here.
- `log\3033.log` -- the main log file, created on first start. Watch this for `HHC*` informational messages and any `HHCA*` warnings.

### Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `ERROR: the following required files are missing after extraction` | The zip is not TK4- v1.00 update 5, or it is corrupted. | Re-download from the official site and verify the SHA-256 against the value published in the TK4- update notes. |
| `Could not auto-discover the TK4- ... zip` | The script cannot find the zip in any default location. | Pass `-ZipPath "C:\full\path\to\tk4-_v1.00_current-v05.zip"` to `setup.ps1`. |
| Hercules exits immediately with `HHC00107E ... file not found` | You are running `hercules.exe` from the wrong directory; the relative paths in `conf\tk4-.cnf` resolve against the cwd. | `cd` to the `hercules_run\` directory before running `hercules.exe`. |
| The 3270 panel renders as garbage characters | Your terminal codepage is not CP437/CP850. | Run `chcp 437` (or `chcp 850`) before launching Hercules. |
| Telnet connection to `localhost:27415` refused | The daemon is not running, or you are in foreground mode. | Start with `-d`, or use the foreground terminal console. |

## Reproducing

To rerun the analysis:

1. Install [Node.js](https://nodejs.org/) 22.x (>=22.19), 24.x (>=24.11), or 26+.
2. Install [JDK](https://adoptium.net/) 21 or newer.
3. Install [Ghidra](https://ghidra-sre.org/) 12.1.x (verified with 12.1.4).
4. Install REA: `npm install -g rea-agents@latest`.
5. Set the environment:
   - `JAVA_HOME=<jdk21 path>`
   - `GHIDRA_INSTALL_DIR=<ghidra 12.1.4 PUBLIC path>`
   - `REA_ANALYSIS_PROVIDER=ghidra`
6. `rea doctor --provider ghidra --json` -- all Ghidra P0 checks should report healthy.
7. Drop `hercules.exe` and `hengine.dll` from the TK4- distribution (or get them from the [Hercules project](https://www.hercules-390.org/)) and run the `rea inspect` / `rea decompile` commands documented in `odd/tasks/`.

## Attribution and license

- **Hercules** (c) 1999-2012 Roger Bowler, Jan Jaeger, and others. Source under the [Q Public License 1.0](https://opensource.org/licenses/QPL-1.0).
- **TK4-** (MVS 3.8j Tur(n)key 4-) (c) 2013-2014 Juergen Winkelmann. Distribution under the Q Public License.
- The PDB path leak in `hercules.exe`'s `.rdata` references `C:\Users\juergen\Desktop\hercules_patched-source\msvc.AMD64.pdb\hercules.pdb`, confirming Juergen Winkelmann compiled the binaries on his own machine in 2013.
- This repository is licensed under the **MIT License** -- see `LICENSE`. The reverse-engineering notes and JSON/TXT outputs are original work produced by static analysis. **No Hercules or TK4- source code or binaries are redistributed here**; obtain them from the official channels linked above.
