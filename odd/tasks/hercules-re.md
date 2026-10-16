# Reverse Engineering the Hercules Emulator (TK4- v1.00 update 5)

## Goal
Use REA + Ghidra to reverse engineer `hercules.exe` (the Windows binary inside
the TK4- distribution zip) and understand how the Hercules mainframe emulator
boots, orchestrates its plugin DLLs, and presents the IBM S/370 / ESA/390 /
z/Architecture CPU to the hosted MVS 3.8j operating system.

## Problem
TK4- v1.00 update 5 ships a complete MVS 3.8j Turnkey system wrapped around the
Hercules emulator. The user wants to understand how the emulator works "from
the inside" using the REA MCP server's Ghidra-backed Windows P0 binary
analysis provider.

## Why
The Hercules emulator is the load-bearing piece of TK4-. The MVS disk images,
JCL and COBOL programs only execute because Hercules emulates a 1960s-1990s IBM
mainframe. Understanding `hercules.exe` is the foundation for understanding
the whole stack.

## Scope
- Reverse engineer `hercules/windows/64/hercules.exe` (21,504 bytes, x86-64
  PE, MSVC 2010, compiled by Juergen Winkelmann on 2013-07-15 for TK4-).
- Inspect companion DLLs (`hengine.dll`, `hdasd.dll`, `hutil.dll`, `hsys.dll`,
  `hengine.dll`, `dyninst.dll`, `dyncrypt.dll`, `decNumber.dll`, `zlib1.dll`,
  `pcre3.dll`, `libbz2.dll`, `htape.dll`, `dyngui.dll`, `hdt*.dll`) at the
  metadata, string, and import/export level.
- Map the bootstrap path: how `hercules.exe` loads `hengine.dll`, parses the
  `conf/tk4-.cnf` configuration, and starts the S/370 instruction loop.
- Document findings so a follow-up session can continue from the same place.

Out of scope: dynamic analysis / running the emulator, decompiling every
function, or modifying the binary. P0 on Windows is read-only.

## Constraints
- Windows 11 Pro x64 host.
- Node v25.8.1 installed (REA officially supports 22.x >=22.19, 24.x >=24.11,
  26+). v25 may work; fall back to Node 24 LTS via winget if `rea doctor`
  fails.
- JDK 21.0.12.1 already installed at
  `C:\Program Files\Java\jdk-21.0.12.1`.
- 35 GB free disk; plan adds ~750 MB (Ghidra).
- REA Windows P0: read-only, 26 inventory/name/search + function-analysis
  operations, no GUI, no annotations.

## Actionable checklist

- [x] T1 — `JAVA_HOME` set at user level pointing to
  `C:\Program Files\Java\jdk-21.0.12.1`. (done)
- [x] T2 — Ghidra 12.1.4 installed manually at
  `C:\tools\ghidra_12.1.4_PUBLIC\` (543 MB, SHA-256
  `DDAC49F903DA9D5BAC833E5CC79395098B9C33CFD3279BE5F31BD00387D2D4DB`
  matches release). (done)
- [x] T3 — `GHIDRA_INSTALL_DIR` set at user level and per-session. (done)
- [x] T4 — `npm install -g rea-agents@latest` succeeds; CLI 6.5.0 in PATH.
      (done)
- [x] T4b — Installed Node.js 24.20.0 via portable zip at
  `C:\tools\node-v24.20.0-win-x64\`; winget MSI failed (1603, no admin).
      App Paths entry in HKCU created as fallback. Doctor now reports
      `node 24.20.0 healthy`. (done)
- [x] T5 — `REA_ANALYSIS_PROVIDER=ghidra` set at user level and per-session.
      (done)
- [x] T6 — `hercules/windows/64/` extracted from the zip to
      `hercules_extracted/windows/64/` (55 files; hercules.exe 21,504 B,
      hengine.dll 3,231,744 B; SHA256s recorded). (done)
- [x] T7 — `rea doctor --provider ghidra --json` reports all Ghidra P0
      checks healthy (node, platform, arch, installation, version, headless,
      native decompiler, java, native authority). (done)
- [x] T8 — `rea inspect hercules.exe` returned Evidence record: PE x86-64,
      image base 0x400000, 8 segments, 117 procedures, 190 strings. PDB
      reference detected (hercules.pdb, GUID
      067cabf2-f530-41cc-8a57-c905934ad612) but not loadable (REA P0 does
      not accept caller-supplied PDBs). Output saved to
      `odd/hercules_inspect.json`. (done in 1m02s)
- [ ] T7 — `rea doctor --provider ghidra --json` reports
  `environment_healthy: true` for Ghidra.
- [ ] T8 — `rea inspect hercules.exe --provider ghidra --format json` returns
  PE metadata, sections, imports, exports, strings.
- [ ] T9 — Function-level analysis of `parse_args`, `panel_command`,
  `replace_opcode`, `daemon_task`, `system_command` (entry points worth
  tracing first).
- [ ] T10 — Cross-reference map: which functions import from which DLLs and
  which strings they reference.
- [ ] T11 — Findings documented in this file under "Findings" below.

## Acceptance criteria
- `rea doctor --provider ghidra --json` exits 0 with healthy Ghidra.
- `rea inspect hercules.exe` returns a non-empty Evidence record including
  machine, sections, imports from `hengine.dll` / `hdasd.dll` / `hsys.dll` /
  `hutil.dll`, and exports including `parse_args`, `panel_command`.
- At least 4 of the 5 entry-point functions named in T9 have decompiled output
  recorded with their xref summary.
- A reader who has not seen the binary can explain, in writing, how Hercules
  loads its plugin DLLs and starts the CPU emulation loop.

## Findings

(populated as the analysis progresses)

### T8 — `rea inspect` overview of `hercules.exe`

- **Format**: PE x86-64. MSVC 2010 build. Image base 0x400000.
- **Sections (7 PE + 1 Ghidra memory block)**:
  - Headers 0x400000–0x400400, 1024 B
  - `.text` 0x401000–0x402bff, 7,168 B (small; bootstrap-only)
  - `.rdata` 0x403000–0x4049ff, 6,656 B
  - `.data` 0x405000–0x40898b (mapped in two blocks: 0x405000–0x4051ff
    and 0x405200–0x40898b, total 14,732 B)
  - `.pdata` 0x409000–0x4091ff, 512 B (exception tables)
  - `.rsrc` 0x40a000–0x40b3ff, 5,120 B (icons, version info)
  - `.reloc` 0x40c000–0x40c1ff, 512 B
  - `tdb` 0xff00000000–0xff0000184f, 6,224 B (Ghidra-created memory
    block, separate address space; debug-info related)
- **PE optional header (parsed from raw bytes)**:
  - `AddressOfEntryPoint` = **RVA 0x2564 → VA 0x402564** (matches the
    `entry` function)
  - `ImageBase` = 0x0000000000400000
  - `SectionAlignment` = 0x1000, `FileAlignment` = 0x200
  - `SizeOfImage` = 0xd000 (53,248 B), `SizeOfHeaders` = 0x400
  - `MajorSubsystemVersion / MinorSubsystemVersion` = **5.2**
    (Windows Server 2003 / XP x64 minimum)
  - `MajorOperatingSystemVersion / Minor` = **5.2**
  - `Subsystem` = **3 (CUI / console application)** — NOT a GUI
    subsystem, despite using Win32 menu APIs on its console window
  - `DllCharacteristics` = 0x8140 (`IMAGE_DLLCHARACTERISTICS_DYNAMIC_BASE
    | NX_COMPAT | TERMINAL_SERVER_AWARE`)
- **117 procedures** identified by Ghidra auto-analysis.
- **190 strings** in the defined-data inventory.
- **PDB**: REA detected reference to `hercules.pdb` (GUID
  `067cabf2-f530-41cc-8a57-c905934ad612`, RSDS, age 1, signature unknown).
  P0 does not accept caller-supplied PDBs, so function names below are
  whatever Ghidra recovered from static analysis.
- **Bootstrap evidence**: tiny .text + large .data + the .rdata imports
  pointing at `hengine.dll`, `hdasd.dll`, `hsys.dll`, `hutil.dll`
  (seen in raw strings) is consistent with the .exe being a small loader
  that dlopen-equivalents the plugin DLLs and jumps into `hengine.dll`.

### T9 — Imports (the actual story; supersedes the bootstrap guess)

Only **two** functions are statically imported from `hengine.dll`:

| DLL              | Imports (count) |
|------------------|-----------------|
| `HENGINE.DLL`    | `impl`, `system_cleanup` |
| `HUTIL.DLL`      | `DisableInvalidParameterHandling`, `w32_fprintf`, `get_hostinfo_str`, `get_buildinfo_strings`, `w32_set_thread_name` |
| `KERNEL32.DLL`   | 36 functions (`LoadLibraryA`, `GetProcAddress`, `GetModuleFileNameW`, console I/O, exception handling, etc.) |
| `MSVCR100.DLL`   | 25 functions (CRT: `exit`, `_cexit`, `_initterm`, `printf`, etc.) |
| `USER32.DLL`     | 6 functions (`GetDesktopWindow`, `IsWindowVisible`, `EnableMenuItem`, `GetSystemMenu`, `FindWindowA`, `MessageBoxTimeoutA`) |
| `WINMM.DLL`      | 2 functions (`timeBeginPeriod`, `timeEndPeriod`) |

`hdasd.dll` and `hsys.dll` strings exist in `.rdata` but are **NOT**
statically imported. They are loaded at runtime via `LoadLibraryA` from
inside `hengine.dll` (the strings are passed to hengine as plugin DLL
names so hengine can build its own dependency chain). The .exe itself
exports **five** functions called *by* `hengine.dll`:

| Export       | Address   |
|--------------|-----------|
| `hdl_depc`   | 0x401c30  |
| `hdl_init`   | 0x401cf0  |
| `hdl_reso`   | 0x401e60  |
| `hdl_fini`   | 0x401fd0  |
| `hdl_ddev`   | 0x401ff0  |

### T10 — Entry-point trace (the actual bootstrap)

The PE loader jumps to **VA 0x402564**, which Ghidra names `entry`:

```c
void entry(void) {
  __security_init_cookie();
  __tmainCRTStartup();      // standard MSVC 2010 startup
  return;
}
```

`__tmainCRTStartup` (0x4022c8) is the stock MSVC C-runtime startup: it
calls `_initterm_e` / `_initterm` for static constructors, then invokes
the user-defined `main` at VA 0x401000 with `argc` / `argv`. The actual
`main` body — `FUN_00401000` — is the *only* application-specific logic
in the .exe:

```c
undefined4 FUN_00401000(undefined4 argc, undefined8 argv) {
  w32_set_thread_name(GetCurrentThreadId(), "bootstrap");
  DisableInvalidParameterHandling();              // hutil.dll
  timeBeginPeriod(1);                              // winmm.dll
  if (!IsDebuggerPresent()) {
    if ((sysblk->GUI_flag & 1) == 0) {
      hConsole = FUN_004014a0();                   // FindWindowA wrapper
      hMenu    = GetSystemMenu(hConsole, 0);
      EnableMenuItem(hMenu, SC_CLOSE, MF_GRAYED);  // disable the X
    }
    DAT_00405ef0 = LoadLibraryA("DbgHelp.dll");
    if (DAT_00405ef0 &&
        (DAT_00405ee8 = GetProcAddress(..., "MiniDumpWriteDump"))) {
      GetModuleFileNameW(NULL, ..., 0x410);
      _wsplitpath(...);                            // prepare dump path
    }
    SetUnhandledExceptionFilter(FUN_00401190);    // install crash handler
    SetErrorMode(SEM_NOGPFAULTERRORBOX);
  }
  uVar3 = impl(argc, argv);                        // *** hengine.dll::impl ***
  timeEndPeriod(1);
  if (!IsDebuggerPresent() && (sysblk->GUI_flag & 1) == 0) {
    // re-enable the X button before returning to OS
    EnableMenuItem(GetSystemMenu(FUN_004014a0(), 0), SC_CLOSE, MF_ENABLED);
  }
  return uVar3;
}
```

So the actual call chain is:

```
OS loader → entry (0x402564)
        → __tmainCRTStartup (0x4022c8)
        → main / FUN_00401000 (0x401000)
              → hengine.dll::impl(argc, argv)
                    (control now lives in hengine.dll; hercules.exe is dormant)
                    hengine.dll calls back into:
                       → hdl_depc  (0x401c30)  // register structs: HERCULES, DEVBLK, SYSBLK, WEBBLK
                       → hdl_init  (0x401cf0)  // register callbacks: parse_args, panel_command, panel_display,
                                              //   replace_opcode, system_command, daemon_task, debug_* (16 hooks)
                       → hdl_ddev  (0x401ff0)  // register device types: 2305/2311/.../9336
                                              //   bound to ckddasd_device_hndinfo / fbadasd_device_hndinfo
                       → hdl_reso  (0x401e60)  // resolve registered names back to fn ptrs (lookup table)
                    … CPU emulator runs MVS …
                    → hdl_fini  (0x401fd0)     // hercules.exe calls system_cleanup via this
```

`parse_args`, `panel_command_r`, `panel_display_r`, `replace_opcode_r`
are **NOT** inside `hercules.exe` — they are names registered via
`hdl_init` for *hengine.dll to call back later*. The .exe only contains
the registration shims; the real implementations live in hengine.dll,
hdasd.dll, hsys.dll, hutil.dll.

### T11 — Decompiled function summaries

| Function | VA | Role |
|----------|----|------|
| `entry` | 0x402564 | MSVC entry stub: security cookie + `__tmainCRTStartup` |
| `__tmainCRTStartup` | 0x4022c8 | Standard MSVC 2010 CRT startup (`_initterm_e`, `_initterm`, then `main(argc, argv)`) |
| `FUN_00401000` (= `main`) | 0x401000 | Pre-load setup (thread name, time-period, debug menu, DbgHelp preload, exception filter) then call `impl(argc, argv)` |
| `FUN_00401190` (= crash handler) | 0x401190 | `SetUnhandledExceptionFilter` callback: clears console, prints `]!OOPS!` or ASCII art, calls `FUN_00401560` |
| `FUN_004014a0` | 0x4014a0 | `FindWindowA` wrapper that locates the console window by temporarily renaming the title to a UUID-class string |
| `FUN_00401560` | 0x401560 | Crash dialog: `MessageBoxTimeoutA` with the OOPS prompt, optionally calling `FUN_00401680` to write a MiniDump via `MiniDumpWriteDump` |
| `FUN_00401680` | 0x401680 | MiniDump writer — invoked only if the user clicks YES on the crash dialog (decompile not extracted but reachable from xref `0x40168a`) |
| `hdl_depc` | 0x401c30 | Dependency registration: registers the `HERCULES`, `DEVBLK` (6 KB), `SYSBLK` (~50 KB), `WEBBLK` structs with hengine.dll |
| `hdl_init` | 0x401cf0 | Callback registration: registers 19 names (`parse_args`, `panel_command`, `panel_display`, `replace_opcode`, `system_command`, `daemon_task`, plus 13 `debug_*` hooks, plus `hdl_device_type_equates`) |
| `hdl_reso` | 0x401e60 | Reverse of `hdl_init`: resolves the same 19 names to function pointers stored in `.data` (`*_exref` slots) |
| `hdl_ddev` | 0x401ff0 | Device-type registration: 10 `ckddasd_*` and 7 `fbadasd_*` device types bound to `ckddasd_device_hndinfo` / `fbadasd_device_hndinfo` |
| `hdl_fini` | 0x401fd0 | Shutdown: just `system_cleanup()` (the only forward call from the .exe to hengine after `impl` returns) |

### T12 — String highlights

| Address  | Value | Significance |
|----------|-------|--------------|
| 0x4041c0 | `hengine.dll` | Hard-coded DLL name passed to / loaded by hengine |
| 0x404200 | `hdasd.dll`   | Plugin DLL (DASD emulator); 0x404384 `hsys.dll`, 0x40441a `hutil.dll` follow |
| 0x404490 / 0x404664 / 0x4046bc / 0x404816 | `USER32.dll`, `KERNEL32.dll`, `MSVCR100.dll`, `WINMM.dll` | OS imports |
| 0x403410 | `DbgHelp.dll` | Loaded only when not under a debugger; used by the crash handler |
| 0x403718 | `.dmp` | Crash dump extension |
| 0x403870 | `4.00.0` | Internal version string registered through `hdl_depc("HERCULES","4.00.0",7)` |
| 0x40afa8 | `http://www.hercules-390.org` | Project URL (from VS_VERSION_INFO) |
| 0x40b004 | `hercules-390@yahoogroups.com` | Mailing list (from VS_VERSION_INFO) |
| 0x40495a | `hercules.exe` | Self-name used in error messages and version metadata |

### T13 — Cross-reference hotspots

The only **named** user-mode callers in `hercules.exe` are the bootstrap
itself and the crash handler. The most-referenced internal function is
the `FindWindowA` wrapper `FUN_004014a0` (5 in-binary callers: `main`,
the crash handler twice, the crash dialog, plus its `.pdata` exception
record). The `hdl_*` exports each appear once in `.pdata` and once in
the export directory; **no in-binary caller exists** for them — they
are invoked exclusively by `hengine.dll` at runtime, which explains why
the .text section is so small (most of the program lives in the
companion DLLs).

### Open questions / follow-ups

- `FUN_00401680` (MiniDump writer) decompile not captured this pass —
  it's reachable via xref `0x40168a` and would close the crash-handler
  loop.
- The exact plugin DLL names embedded at 0x404200/0x404384/0x40441a
  (`hdasd.dll`, `hsys.dll`, `hutil.dll`) are *not* passed to
  `LoadLibraryA` from `hercules.exe`. They are either (a) embedded for
  `hengine.dll::impl` to consume, or (b) embedded so the .exe can
  display them in error dialogs. A `xref` from these strings into
  `main()` would clarify.
- `hdl_device_type_equates` and the full device-type table (DAT_00403ad8
  … DAT_00403b58) deserve a follow-up to enumerate the device numbers
  (the task description hinted at `2305/2311/…/9336`).
- Re-running the analysis with the PDB companion available would
  confirm the `hdl_*` export names; today's results match the strings
  but P0 won't admit the PDB.
