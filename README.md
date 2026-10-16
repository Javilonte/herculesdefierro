# Hercules de Fierro

Reverse-engineering notes and Ghidra-decompiled analysis of the **Hercules mainframe emulator** as shipped inside the **TK4- v1.00 update 5** distribution.

> Hercules emulates the IBM System/370, ESA/390, and z/Architecture instruction sets on commodity hardware. TK4- is a pre-packaged turnkey MVS 3.8j system that runs on top of Hercules. This repository is a structured walk-through of how the Windows version boots and how the CPU emulator is organized, produced with the [REA](https://github.com/morluto/rea) reverse-engineering toolchain and [Ghidra](https://ghidra-sre.org/).

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
├── README.md        # this file
├── LICENSE          # MIT (for the analysis notes)
├── .gitignore
└── odd/             # the entire REA evidence trail
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

The `odd/tasks/` subdirectory holds the two feature documents that drive the analysis. Every other file in `odd/` is an evidence artifact referenced from those documents.

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
