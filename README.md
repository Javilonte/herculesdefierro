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
│   ├── setup.ps1       # extracts hercules_run/ from a TK4- v1.00 update 5 zip
│   └── open-console.bat  # opens a wc3270 console against the local daemon
└── odd/               # the entire REA evidence trail
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

Hercules starts in the background without a local console. It opens four TCP listeners for remote 3270 access:

- `127.0.0.1:27415` (CPU 0 console)
- `127.0.0.1:27416` (CPU 1 console)
- `127.0.0.1:27417` (CPU 2 console)
- `127.0.0.1:27418` (CPU 3 console)

#### Connecting with wc3270 (recommended)

The repo ships a helper at `scripts/open-console.bat` that wraps wc3270. Install wc3270 once (download the no-installer zip from the [x3270 wiki](https://x3270.bgp.nu/download.html) and extract to `C:\tools\wc3270-4.5ga6\` -- add that directory to `PATH` for convenience -- or install `wc3270-4.5ga6-setup.exe` with admin rights). Then:

```powershell
# open the default CPU 0 console
..\herculesdefierro\scripts\open-console.bat
# or open CPU 1
..\herculesdefierro\scripts\open-console.bat 1
```

The helper auto-detects wc3270 on `PATH` or at the default location, and passes `-model 4` (24x80 screen, the standard MVS console model). From the panel you can type the same commands as in foreground mode.

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
