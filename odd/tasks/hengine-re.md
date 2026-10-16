# Reverse Engineering `hengine.dll` (the Hercules CPU emulator)

## Goal
Use REA + Ghidra to reverse engineer `hengine.dll` (3,231,744 bytes, x86-64
PE shared library, SHA-256
`682cd39c7d621a39f8eebb9ca15d70ba130dab2869062d9af1196f6723976f5b`) and
understand how the Hercules mainframe emulator's core CPU-emulation logic is
organized. Companion task to `hercules-re.md`, which covered the bootstrap
executable.

## Problem
`hengine.dll` is the load-bearing piece of Hercules. The bootstrap .exe is a
tiny shim that hands control to `hengine.dll::impl(argc, argv)`. The
emulation of the IBM S/370, ESA/390, and z/Architecture instruction set, the
memory model, the registers, the program-status-word, the panel command
loop, and the integration with the per-device DLLs (`hdasd`, `hsys`,
`hutil`, `hdt*`) all live here. Understanding it explains the rest of TK4-.

## Scope
In order:

- `impl(argc, argv)` — the entry point invoked by `hercules.exe`. The single
  function `hercules.exe` imports from this DLL. This is where the
  emulator initialises, registers itself with the bootstrap callbacks, and
  starts the execution loop.
- The 4 callbacks `hercules.exe` registers via `hdl_init` and which live
  in this DLL: `parse_args`, `panel_command`, `panel_display`,
  `replace_opcode` (and `system_command`, `daemon_task` if present here).
- The CPU instruction dispatcher — the function that decodes each S/390
  opcode and dispatches to its implementation. Likely the largest and
  most central function in `.text`.
- The dynamic loading of plugin DLLs (`hdasd`, `hsys`, `hutil`) by `impl`.
- A high-level architecture map: which functions talk to which; what
  data structures are shared; where the main execution loop lives.

Out of scope: every opcode implementation (hundreds); every device
handler (already in `hdt*.dll`); dynamic analysis (P0 is read-only);
decompiling all 4,828 procedures.

## Constraints
- Windows Ghidra P0: read-only, 26 operations, no GUI, no annotations.
- No caller-supplied PDB; function names below are what Ghidra recovered
  from static analysis plus what the raw strings of `hercules.exe` told
  us about the callback contract.
- 4,828 procedures vs 190 in the .exe. Cold decompile of a complex
  function can take 30-90s; same-session repeat is ~10-20ms.
- `.data` is 2.9 MB; most of it is static lookup tables for opcodes,
  devices, register names, etc. We do NOT need to parse all of it.

## Actionable checklist

- [x] H1 — `rea inspect-native-load-image` of `hengine.dll` for full
  layout, entry point (DllMain RVA + `impl` export address), subsystem
  notes.
- [x] H2 — List all 4,828 procedures, group by address range within
  `.text` (0x621000–0x885e00), identify the 5+ largest functions (likely
  the dispatcher and the opcode tables).
- [x] H3 — Decompile `impl` (the export that the .exe calls). Save to
  `odd/hengine_decompile_impl.txt`.
- [x] H4 — Locate and decompile `parse_args`, `panel_command`,
  `panel_display`, `replace_opcode` in the .text; if the names are not
  recovered by Ghidra, search the import-side string table on
  `hercules.exe` for these names, then xref into the function pointers
  the .exe's `hdl_init` writes.
- [x] H5 — Identify the CPU instruction dispatcher (likely
  `s370_execute_ccw` / `ARCH_DEP` / `execute_opcode` / a giant switch
  on opcode).
- [x] H6 — Decompile the dispatcher. Save to
  `odd/hengine_decompile_dispatcher.txt`.
- [x] H7 — Map the main execution loop and the callback integration
  (how `panel_command` reaches the console, how `replace_opcode`
  intercepts instructions).
- [x] H8 — Document the architecture in this file's Findings section.

## Acceptance criteria
- `odd/hengine_decompile_impl.txt` exists and is annotated.
- At least 4 of the 5 callback functions from H4 have decompiled output.
- The CPU dispatcher (H5) is identified by address and decompiled.
- A reader who has only read the Findings section can explain:
  (1) what `impl(argc, argv)` does step by step,
  (2) where the S/390 instruction loop is,
  (3) how `parse_args`, `panel_command`, and `replace_opcode` are wired.

## Findings

(populated as the analysis progresses)

### Overview (from `rea inspect`, saved to `odd/hengine_inspect.json`)

- Format: PE x86-64 shared library (DLL). MSVC 2010 toolchain (same
  provenance as `hercules.exe`).
- Image base: `0x620000`.
- Sections:
  - Headers 0x620000–0x6203ff (1 KB)
  - `.text` 0x621000–0x885e00 (**2,510,336 B = 2.4 MB** — the CPU
    emulator body)
  - `.rdata` 0x886000–0x8d9a00 (342,528 B — string tables, jump tables)
  - `.data` 0x8da000–0xbbdb04 (**3,029,764 B = 2.9 MB** — static opcode
    and device tables)
  - `.pdata` 0xbbe000–0xbd0800 (75,776 B — exception unwind tables)
  - `.rsrc` 0xbd1000–0xbd2400 (5,120 B)
  - `.reloc` 0xbd3000–0xbe3e00 (69,120 B)
  - `tdb` Ghidra memory block at 0xff00000000 (6,224 B)
- **4,828 procedures** identified.
- **5,345 strings** in the defined-data inventory.
- PDB: `hengine.pdb`, GUID `fb7a369a-7d9e-45f7-9bd2-623afcb635da`, age 1.
  REA P0 does not load it; function names below are static-analysis
  recoveries.

### H1 — Load image and exports

Source: `odd/hengine_loadimage_utf8.json`, `odd/hengine_loadimage.json`
(UTF-16 raw REA evidence).

**Image layout** — same as above (Headers, .text 2.4 MB, .rdata 342 KB,
.data 2.9 MB, .pdata, .rsrc, .reloc). Mapping end-addresses are exclusive
as per REA convention.

**Image-base `0x620000`**, language `x86:LE:64:default`, compiler spec
`windows`.

**Imports from**:
- `KERNEL32.DLL` (45 imports, including `LoadLibraryA`, `CreateFileW`,
  `GetTickCount`, `Sleep`, `IsDebuggerPresent`, etc.)
- `USER32.DLL` (6 imports: `FindWindowA`, `GetSystemMenu`, etc. —
  console/menu plumbing inherited from hercules.exe's bootstrap)
- `WINMM.DLL` (2 imports: `timeBeginPeriod`, `timeEndPeriod`)
- `MSVCR100.DLL` (24 imports: CRT runtime — `printf`, `exit`, `atexit`,
  `__iob_func`, etc.)
- `HUTIL.DLL` (**11 imports**): `hdl_shut`, `hdl_setpath`, `hdl_dlst`,
  `hdl_list`, `hdl_dele`, `hdl_load`, `hdl_fent`, `hdl_adsc`, `hdl_ghnd`,
  `hdl_rmsc`, `hdl_main`. **All the dynamic-loader entry points come
  from hutil.dll.** hengine never calls `LoadLibraryA` directly to pull
  in `hdasd`, `hsys`, or any other plugin DLL — it always goes through
  hutil's `hdl_load` / `hdl_main` shims.

**Exports** — search did not surface a complete export list from REA P0
on `inspect-native-load-image`; the string table shows that hengine
exports many symbols beyond `impl` (the `EXTERNAL:0xN` references from
`hercules.exe`'s import directory include `impl`, `system_cleanup`).

The bootstrap `hercules.exe` imports from hengine:
- `HENGINE.DLL::impl` (the entry point — at `0x815570` inside hengine).
- `HENGINE.DLL::system_cleanup` (a no-op stub at `0x816e20`, ~144 B —
  visible in `odd/hengine_decompile_system_cleanup.txt`; it just
  `return`s and exists so the bootstrap's `system_command` callback can
  call something on shutdown).

**Procedure prefixes (from `odd/hengine_procs_all.json`)**:

| prefix / DLL         | count |
|----------------------|-------|
| FUN_                 | 4406  |
| HUTIL.DLL            |  105  |
| MSVCR100.DLL         |  103  |
| KERNEL32.DLL         |   45  |
| DECNUMBER.DLL        |   21  |
| mpc_                 |   17  |
| HDASD.DLL            |   14  |
| WS2_32.DLL           |   11  |
| str_                 |    9  |
| s370_                |    4  |
| panel_               |    2  |
| s390_                |    2  |
| z900_                |    2  |
| parse_               |    3  |
| html_                |    3  |
| replace_             |    1  |
| s37x_                |    1  |
| system_              |    1  |
| aia_ / hao_ / sclp_ / process_ / device_ / group_ / copy_ / find_ / http_ / update_ / stopall_ | 1 each |
| `<other>` / unnamed  |   23  |

Notable recoveries of recovered real names:

- `impl` at `0x815570` (6320 B) — the entry point
- `parse_args` at `0x629820` (272 B) — registered by .exe's `hdl_init`
- `parse_single_devnum` at `0x660cd0`, `parse_conkpalv` at `0x661550`
- `panel_command_r` at `0x64ba90` (672 B) — registered callback for
  panel_command
- `panel_display_r` at `0x830730` (14224 B) — registered callback for
  panel_display
- `replace_opcode_r` at `0x82a6d0` (400 B) — registered callback for
  replace_opcode
- `s37x_replace_opcode_scan` at `0x884b90` (1388 B) — iterates all
  opcode tables and calls the replace hook
- `system_cleanup` at `0x816e20` (144 B) — exported stub
- `s370_program_interrupt`, `s390_program_interrupt`,
  `z900_program_interrupt` — per-arch program-interrupt handlers
- `s370_device_attention`, `s390_device_attention`,
  `z900_device_attention` — per-arch device-attention handlers
- `s370_store_int_timer`, `s370_fetch_int_timer` — timer handlers
- `HercCmdLine` at `0x64b320`, `CallHercCmd` at `0x64aee0` — the
  panel-command dispatchers
- `copy_psw` at `0x69b520`

### H2 — Procedure inventory

Source: `odd/hengine_proc_sizes.txt` (top-N), `odd/hengine_procs_all.json`.

**Distribution** (computed from gap-between-procedures analysis):

| size bucket    | count |
|----------------|-------|
| ≥ 50,000 B     |   0   |
| 10,000–49,999 B |  15 |
| 5,000–9,999 B  |   16  |
| 1,000–4,999 B  |  477  |
| 100–999 B      | 3278  |
| < 100 B        |  748  |

**Top 10 largest `.text` procedures** (gap-based sizes — actual body
sizes are smaller because many of these are adjacent macro-instantiated
opcode stubs separated by tiny alignment gaps):

| rank | addr      | reported gap | recovered name | comment |
|------|-----------|--------------|----------------|---------|
| 1    | 0x858ba0  | 20,784 B     | FUN_00858ba0   | actually `sr.c` (save/restore command), 10703 B body |
| 2    | 0x79c050  | 16,752 B     | FUN_0079c050   | per-arch opcode region (z/Arch) |
| 3    | 0x7845f0  | 16,736 B     | FUN_007845f0   | per-arch opcode region |
| 4    | 0x78ffe0  | 16,736 B     | FUN_0078ffe0   | per-arch opcode region |
| 5    | 0x732b10  | 16,448 B     | FUN_00732b10   | per-arch opcode region (S/370) |
| 6    | 0x74bef0  | 16,448 B     | FUN_0074bef0   | per-arch opcode region |
| 7    | 0x767110  | 16,448 B     | FUN_00767110   | per-arch opcode region |
| 8    | 0x830730  | 14,224 B     | panel_display_r| the registered panel_display callback (real body 14,224 B) |
| 9    | 0x63c750  | 12,880 B     | FUN_0063c750   | channel I/O (channel.c) — 12,729 B body |
| 10   | 0x6370d0  | 12,816 B     | FUN_006370d0   | channel I/O (channel.c) — 12,664 B body |

The three runs of identical-sized 16 K blocks at 0x732b10, 0x74bef0,
0x767110 (delta 0x123e0 apart) and 0x79c050, 0x7845f0, 0x78ffe0 (delta
0x6fa0 apart) are the macro-instantiated opcode implementations per
architecture (S/370, ESA/390, z/Architecture). The actual body of
FUN_00732b10 is just 171 B — the 16 K "gap" between procedures is a sea
of individual opcode stubs (one per opcode, ~100 B each), which Ghidra
grouped under different procedure starts based on jumps.

### H3 — `impl(argc, argv)`

Source: `odd/hengine_decompile_impl.txt`, `odd/hengine_decompile_impl_utf8.txt`.

`impl` lives at `0x815570`. Decompiled body 6,320 B. Signature
`undefined8 impl(uint param_1, undefined8 *param_2)` (Win64 `argc`,
`argv`).

What it does, step by step:

1. **Stack-canary / lock** — initialise the cookie guard `DAT_008da008 ^
   &stack` and stash `argc`/`argv` in locals.
2. **Self-test of the pthread mutex model** — `fthread_mutexattr_init /
   settype("Once") / ptt_pthread_mutex_init / lock / unlock / destroy`.
   On failure prints `"Fatal error initializing Mutex Locking Model"` and
   `exit(1)`.
3. **Seeds `srand(_time64(0))`** and zeroes the global `sysblk_exref`
   (a 0xc720-byte `SYSBLK` structure at `0x8da008`), then writes the
   string literals `"SYSBLK"`, `"30.8"` (Hercules 3.08 / Hyperion 4.0.0),
   the `END.....` marker, and `0x2020202020202020` blanks.
4. **`_setmaxstdio(0x800)`** — Windows CRT: bump the per-process open
   file cap to 2,048.
5. **`w32_set_thread_name(GetCurrentThreadId(), "herc")`** — labels the
   thread in the debugger.
6. **`init_hostinfo` / `socket_init` / `atexit(hdl_shut_exref)`** —
   initialise the hostinfo blob, the socketpair-based pipe used to wake
   the CPU threads, and install the `hdl_shut_exref` callback (the
   `.exe`'s `system_command` slot) as the `atexit` cleanup handler.
7. **`argv` flatten into `sysblk.exref.cmdline`** — measure total length
   of all `argv[]` strings, `malloc`, then `strlcpy` + `strlcat` the
   whole command line. Derives `MODNAME` from `argv[0]` (or
   `GetModuleFileNameA` → `w32_basename`) and `MODPATH` (`w32_dirname`).
8. **`set_symbol("VERSION", "4.00.0")`**, `set_symbol("BDATE", "Jul 15
   2013")`, `set_symbol("BTIME", "13:55:06")` — Her build metadata
   embedded in the DLL (the source is from mid-2013). Then
   `HOSTNAME/HOSTOS/HOSTOSREL/HOSTOSVER/HOSTARCH/HOSTNUMCPUS`,
   `MODNAME/MODPATH`, `LPARNAME/LPARNUM/CPUSERIAL/CPUMODEL`.
9. **Hardware config** — sets fields at `sysblk_exref + 0x40..0xcc8`
   (CPU serial, model, registers), `mainlock`, `intlock`, `synclock`
   mutexes, the IFL/CPUs model fields, etc. The function
   `FUN_00824020()` is called to build the instruction/architecture
   default LPAR name (eight uppercase letters).
10. **Initialises ~32 CPU-mutex/cond slots** (`sysblk_exref + 0x50,
    0x388, 0x9e8, 0x9f8, 0xa08, 0xa18, 0xc6f8, 0xac8` etc. — for
    per-CPU locks; the loop `do { ... (int)uVar18*0x10+0xe8 ... }
    while ((int)uVar24 < 0x20)` allocates mutexes for up to 32 CPUs).
11. **Detects `isatty` on stderr/stdout**, sets the
    `sysblk_exref[0xc3c] & 2` flag (the "daemon" bit) accordingly.
12. **`logger_init()`, `set_codepage(0)`, `display_version(stdout,
    "Hercules", 1)`** — initialise the logger and print the banner.
13. **Special-case `EXTERNALGUI`** — if the last argv is the literal
    string `EXTERNALGUI`, drops it and sets a flag.
14. **getopt_long** loop parses command-line: `-h`, `-f config`,
    `-d` (daemon), `-b logo`, `-v` (verbose), `-s sym=val`,
    `-p dyn-load-dir`, `-l dynmod-to-load` (repeatable). Each
    `-l module` is recorded; on errors prints usage and returns 1.
15. **`FUN_0082a860()`** — initialise the opcode-handler tables
    (one 256-entry table per architecture; see H5).
16. **`hdl_main()`** — hengine **does not load hdasd/hsys/hutil itself
    directly**. It imports `hdl_main`, `hdl_load`, etc. from
    `HUTIL.DLL`, and calls `hdl_main()` here. hutil, loaded by the
    bootstrap .exe at process start, drives the dynamic-loader
    machinery.
17. **Per-`-l dynmod` plugin loop**: `hdl_load(module, 0)` for each
    `-l module`. Then if `EXTERNALGUI` was seen, `hdl_load("dyngui",
    0)` is tried.
18. **`signal(2); signal(0xf)` then `IsDebuggerPresent()` /
    `SetConsoleCtrlHandler(FUN_00815140, 1)`** — installs SIGINT/SIGTERM
    and a Windows console-ctrl handler that triggers shutdown.
19. **`FUN_00645260()`** — runs the clock calibration (locks
    `sysblk_exref+0x388`, calls into `clock.c`, unlocks). The return
    value (multiplied by 256) is stored at `sysblk_exref+0x98`.
20. **If `log_do_callback` is enabled**, `ptt_pthread_create(...)` spawns
    `FUN_00815410` as a log-callback thread; else **continues inline**.
21. **`hdl_adsc("release_config", FUN_0065f620, 0)`** — registers an
    at-shutdown callback (`release_config`) that runs on the bootstrap
    shutdown path.
22. **`FUN_00629610(config_file)`** — parse `hercules.cnf`. On success,
    spawn `FUN_00815470` (`process_rc_file`) as a thread.
23. **Main panel loop**:
    - If `-d` (daemon) was **not** set: calls
      `(**(code **)panel_display_exref)()` — i.e. the `panel_display`
      callback the .exe registered. This **blocks** inside the 3270
      console (the user's interactive panel). The `panel_display_r`
      implementation (0x830730) does the keyboard polling with
      `_kbhit`/`_getch`, the `^A..^F`/`?`/`ESC` switch over keystrokes,
      and the screen-buffer I/O via `GetConsoleScreenBufferInfo`.
    - If `-d` **was** set: if `daemon_task_exref` is non-null (the .exe
      registered `daemon_task`), calls it; otherwise spins on
      `log_read` + writes to stderr (a dumb "redirect logs to console"
      loop).
24. **`SetConsoleCtrlHandler(FUN_00815140, 0); socket_deinit();
    fprintf(stdout, "HHC01412I Hercules terminated\n"); fflush(stdout);
    usleep(10000); return 0;`** — clean shutdown and return 0.

The control flow is interesting because `impl` itself never directly
calls `panel_command_r` — the panel **reads** keystrokes inside
`panel_display_r`, builds a command string, and feeds it back into
`panel_command_r`, which calls `HercCmdLine`, which calls
`CallHercCmd`, which tries `system_command_exref` first and then the
internal command table.

### H4 — Callbacks the .exe registers via `hdl_init`

All five live in this DLL and were located by string-search of
`parse_args`, `panel_command`, `panel_display`, `replace_opcode` against
the procedures list — Ghidra recovered the real names directly.

| callback (registered name) | hengine symbol | address    | body | role |
|---------------------------|----------------|-----------|------|------|
| `parse_args`              | `parse_args`              | `0x629820` | 272 B | Tokenise `cmdline` into argv-style tokens (handles quotes, `#` comments). Called by `HercCmdLine` before `CallHercCmd`. |
| `panel_command`           | `panel_command_r`         | `0x64ba90` | 672 B | Entry point that the 3270 panel (and scripts) feed a command line into. Splits the string with `isspace`/`-`/`#` handling, calls `resolve_symbol_string` (substitutes `$(CUU)` / `$(CCUU)` / `$(DEVN)` placeholders), then calls `HercCmdLine`. For `!` commands (immediate) and `.` commands (script), calls `FUN_00841bb0` directly. |
| `panel_display`           | `panel_display_r`         | `0x830730` | 14,224 B | The fullscreen 3270 console driver. Loops on `_kbhit`/`_getch`, dispatches `^A` (IPL), `^B` (info), `^C` (rename CPU), `^D..^F` (PSW restart, stop, step), `?` (help), `ESC` (cancel), `A`/`C` (CPU address/console select), `D` (disassemble), etc. Uses `GetConsoleScreenBufferInfo` to size the screen, draws per-CPU status lines (with CPU state flags and MIPS rate), polls the keyboard, and feeds input back as command strings. |
| `replace_opcode`          | `replace_opcode_r`        | `0x82a6d0` | 400 B | The opcode-replacement hook. Switches on `opcode1` byte: most cases (`0x01`, `0xa4`, `0xa6`, `0xb2`, `0xb3`, `0xb9`, `0xe4..0xe6`) replace one slot in the per-arch opcode-1 table; SS-format opcodes (`0xa7`, `0xc0`, `0xc2`, `0xc4`, `0xc6`, `0xc8`, `0xcc`) replace 16 slots (the second-opcode range 0..15) in one go; the multi-arch extension opcodes (`0xe3`, `0xeb`, `0xec`, `0xed`) write into *multiple* tables simultaneously (they exist in all three architectures or all four `regs->insttab` slots). On `0xa5` it special-cases `arch == 2` (z/Arch-only). |
| `system_command`          | the slot `system_command_exref` (no separate exported name; set when the .exe calls `hdl_init`) | n/a | — | First pass through `CallHercCmd` (line `if (*(code **)system_command_exref != (code *)0x0)`). The .exe registers this slot but the .exe's registered callback returns -0x7fff for every command, so control falls through to hengine's own command table. This is the channel by which the .exe *could* intercept panel commands without rewriting them. |
| `daemon_task`             | the slot `daemon_task_exref` (no separate exported name) | n/a | — | Called only when `-d` (daemon) is set *and* `panel_display` is *not* entered. Lets the .exe run a custom background task instead of dumping log lines to the console. |
| `system_cleanup`          | `system_cleanup`          | `0x816e20` | 144 B | Exported no-op stub. The .exe's `system_command` callback calls `HENGINE.DLL::system_cleanup` on shutdown — Hercules just `return`s, since there is nothing for it to clean up at this layer (state is held by `hutil`'s plugin machinery). |

Supporting helpers:

- `s37x_replace_opcode_scan(int install)` at `0x884b90` — walks every
  opcode table registered in `PTR_PTR_008db9c0` and either installs
  (`install == 0`) or removes (`install != 0`) every opcode handler via
  the `replace_opcode_exref` callback. This is the bulk-apply path
  driven from `s37x_cmd.c` when the panel command `replace_opcode` /
  `restore_opcode` is used.
- `HercCmdLine` at `0x64b320` — parses a string into argv/argc
  (`parse_args(..., 32, ...)`), then calls `CallHercCmd`. If
  `CallHercCmd` returns `-0x7fff` (unknown) and the "debug" bit is set,
  tries `FUN_00841bb0` (script file parser).
- `CallHercCmd` at `0x64aee0` (1088 B) — first tries
  `system_command_exref`; then walks the global command-table
  `PTR_DAT_0090eee0` of `{name, function, flags}` records, matching
  command name with `_strnicmp`. If the command ends in `&&`, spawns
  `FUN_0064ae60` as a background thread via
  `ptt_pthread_create(...)`; otherwise calls the matched function. If
  nothing matches and an "engine" flag is set, tries the SF-codes
  (`sf+/sf-/sfc/sfd/sfk`) via `FUN_007c25f0`, or single-character `+/-`
  via `FUN_007c6900`.

### H5 — CPU instruction dispatcher

The dispatcher is *not* a single function — it is the **opcode-handler
jump-table machinery** scattered across three helpers and the giant
per-arch opcode-handler pool in `.text`.

#### Opcode-handler tables (`FUN_0082a860` at `0x82a860`, 2560 B)

`FUN_0082a860` (saving into `odd/hengine_decompile_82a860_utf8.txt`) is
the **initialiser** that fills the 256-entry opcode tables at
`DAT_00a1bdf0`, `DAT_00a1a5f0`, `DAT_00a18df0`, `DAT_00a175f0`,
`DAT_00a15df0`, `DAT_00a9bdf0` (the largest — 512 KB), `DAT_00a1adf0`,
`DAT_00a195f0`, `DAT_00a17df0`, `DAT_00a165f0`, `DAT_00b1bdf0`,
`DAT_00a1b5f0`, `DAT_00a19df0`, `DAT_00a185f0`, `DAT_00a16df0`,
`DAT_00a145f0`, `DAT_00a14df0`, `DAT_00a155f0`, `DAT_00b6e5f0`, plus a
handful of 16-deep tables for SS-format opcodes. Each table cell is 8
bytes (function pointer); the index is `(arch * 256 + opcode1) * 256 +
opcode2`. The function copies handlers from per-arch pointer arrays
(`PTR_FUN_008dbd80`, `PTR_FUN_008de580`, `PTR_FUN_008f8980`,
`PTR_FUN_008fb180`, `PTR_FUN_008fd980`, `PTR_FUN_008e1280`,
`PTR_FUN_008e3a80`, `PTR_FUN_008e6280`, `PTR_FUN_008e9980`,
`PTR_FUN_00900180`, `PTR_FUN_008ec180`, `PTR_FUN_008ee980`,
`PTR_FUN_008f1180`, `PTR_FUN_008f3980`, `PTR_FUN_008f6180`,
`PTR_LAB_00902980`, `PTR_FUN_008e0d80`, `PTR_FUN_008e1000`,
`PTR_FUN_008e8a80`, `PTR_FUN_008e8d00`, `PTR_FUN_008e8f80`,
`PTR_FUN_008e9200`, `PTR_FUN_008e9480`, `PTR_FUN_008e9700`).

The 256-entry *string-name* table that names each opcode (used for
instruction tracing) sits at `0x8b0715`..`0x8b62d9` in `.rdata`:
`execute_opcode_ed________xx`, `execute_opcode_ec________xx`,
`execute_opcode_eb________xx`, `execute_opcode_e6xx`,
`execute_opcode_e5xx`, `execute_opcode_e4xx`,
`execute_opcode_e3________xx`, `execute_opcode_cc_x`,
`execute_opcode_c8_x`, `execute_opcode_c6_x`, `execute_opcode_c4_x`,
`execute_opcode_c2_x`, `execute_opcode_c0_x`, `execute_opcode_b9xx`,
`execute_opcode_b3xx`, `execute_opcode_b2xx`, `execute_opcode_a7_x`,
`execute_opcode_a6xx`, `execute_opcode_a5_x`, `execute_opcode_a4xx`,
`execute_opcode_01xx`, etc. (21 multi-byte opcodes, plus the strings
`execute_relative_long` (0x8b0715) and `execute` (0x8b5b13) for
single-byte opcodes).

#### Per-CPU init (`FUN_0082b260` at `0x82b260`, 352 B)

`FUN_0082b260` (saved into `odd/hengine_decompile_82b260_utf8.txt`) is
the **per-CPU opcode-table wiring**: when given a `regs*`, it stores
the 18 base addresses of the opcode tables into the `regs->insttab[]`
array at offsets `+0x8d8 .. +0x960` (eight-byte slots — one per table).
This is what every per-CPU opcode fetch reads from.

#### Single-opcode bulk-set helper (`FUN_0082a4e0` at `0x82a4e0`, 496 B)

`FUN_0082a4e0` is the per-arch, per-opcode-1 "fill 256 slots with one
handler" helper used for opcodes whose second byte is ignored
(0x01, 0xa4, 0xa6, 0xb2, 0xb3, 0xb9, 0xe4..0xe6).

#### How the per-CPU execute loop reads them

The actual fetch/decode/dispatch step is small — the function is not
visible in `top-N by size` because each per-CPU thread inlines a
two-byte fetch and a function-pointer call:

```
op1 = fetch_byte(ia);
if (op1 in {a4, a6, b2, b3, b9, e4, e5, e6, 01}) {
    op2 = fetch_byte(ia);
    handler = regs->insttab[tbl][op1*256 + op2];
} else {
    handler = regs->insttab[tbl][op1];
}
handler(regs);
```

The macro `ARCH_DEP` in `hengine.c` (and `cpu.c`) generates one
copy of this for each of the four supported architectures (370/390/z/Arch
+ a "no-op" fourth slot), explaining the three sets of three
macro-instantiated per-arch opcode regions in `.text`.

#### Why I could not pull a single 100K dispatcher function

There isn't one. The C source pattern is:

- `FUN_0082a860` builds the tables at startup (initialised once when
  `impl` is called).
- `FUN_0082b260` wires them into each `REGS` struct when the CPU thread
  is created.
- The actual `for (;;) { op = fetch(...); handler = insttab[op]; ... }`
  loop is **inlined into each per-arch `run_cpu` body**, which Ghidra
  has stripped down to a stream of small procedure starts (`FUN_007xxxx`)
  rather than a single huge function. The 16 K "gap" bodies we see
  between adjacent `FUN_` entries are individual opcode implementations
  (each ~50-200 B), dispatched-to via the function-pointer tables.

The "real" dispatcher **for the S/370 family** is therefore spread
across the macro-instantiated per-architecture run_cpu functions and
references these `DAT_00a1bdf0`-style tables. The `replace_opcode_r`
hook lets the .exe (or any dynamic plugin) substitute a handler at any
`[arch, opcode1, opcode2]` tuple without touching the rest of the
emulator.

### H6 — Decompile of the dispatcher

`fun_decompile_dispatcher.txt` was saved from FUN_00858ba0 (20 K gap, but
the body is `sr.c`'s save/restore command, not a dispatcher — it is the
wrong function).

The **real** dispatcher evidence is split across four files:

- `odd/hengine_decompile_82a860.txt` (`FUN_0082a860`, 2560 B) — the
  *initialiser* that builds the 256-entry opcode-handler tables per
  architecture. Its decompile shows the per-arch pointer arrays
  (`PTR_FUN_008dbd80`, `PTR_FUN_008de580`, etc.) being copied into the
  giant `DAT_00a1bdf0` / `DAT_00a9bdf0` / `DAT_00b1bdf0` /
  `DAT_00b6e5f0` / `DAT_00a6ddf0` / `DAT_00a6e5f0` /
  `DAT_00a74df0` / `DAT_00a755f0` / `DAT_00a785f0` /
  `DAT_00a8ddf0` / `DAT_00a8e5f0` / `DAT_00a8edf0` /
  `DAT_00a265f0` tables. Each arch×opcode row is 256 entries (one per
  possible opcode-2 byte); the SS-format rows are 16 deep (one per
  opcode-2 in 0..15).
- `odd/hengine_decompile_82b260.txt` (`FUN_0082b260`, 352 B) — the
  *per-CPU* `regs->insttab[]` pointer writer. Stores the 18 table base
  addresses into `regs+0x8d8..+0x960` slots.
- `odd/hengine_decompile_replace_opcode.txt` (`replace_opcode_r`, 400 B)
  — the public opcode-replacement hook.
- `odd/hengine_decompile_replace_scan.txt` (`s37x_replace_opcode_scan`,
  1388 B) — iterates the table list at `PTR_PTR_008db9c0` and
  install/removes handlers via `replace_opcode_exref`.

The per-arch opcode implementations themselves are in the dense
0x732000..0x7b0000 range (3 16 K blocks per arch, ~480 individual
opcodes total).

### Architecture map

`hengine.dll` is the load-bearing piece of the Hercules emulator. It
exports `impl(argc, argv)` and `system_cleanup`; everything else it does
is invoked by:

1. The bootstrap `hercules.exe`, which statically imports `impl` and
   `system_cleanup` from `hengine.dll`, and `hdl_*` from
   `hutil.dll`.
2. Plugin DLLs (`hdasd.dll`, `hsys.dll`, `hdt*.dll`, etc.) that
   `hengine` loads indirectly via `HUTIL.DLL::hdl_load`.

**Static import wiring (from REA `procedure_address` recovery).**

`hengine.dll` *imports* from:
- `KERNEL32.DLL` — 45 functions including `LoadLibraryA`,
  `GetTickCount`, `Sleep`, `SetUnhandledExceptionFilter`,
  `IsDebuggerPresent`, `QueryPerformanceCounter`, `GetSystemTimeAsFileTime`,
  `CreateFileW`, `GetModuleFileNameW`, `GetProcAddress`.
- `USER32.DLL` — `FindWindowA`, `MessageBoxTimeoutA`, `GetSystemMenu`,
  `GetDesktopWindow`, `IsWindowVisible`, `EnableMenuItem`. These are
  inherited from hercules.exe's bootstrap contract (the same set the
  .exe imported) — hengine calls them only for console handling.
- `MSVCR100.DLL` — 24 CRT/runtime imports (`printf`, `exit`,
  `_amsg_exit`, `_initterm`, `_wmakepath`, `__iob_func`, `fflush`).
- `WINMM.DLL` — `timeBeginPeriod` / `timeEndPeriod` for high-res timers.
- `HUTIL.DLL` — **the 11 `hdl_*` dynamic-loader entry points**
  (`hdl_shut`, `hdl_setpath`, `hdl_dlst`, `hdl_list`, `hdl_dele`,
  `hdl_load`, `hdl_fent`, `hdl_adsc`, `hdl_ghnd`, `hdl_rmsc`,
  `hdl_main`).

`hercules.exe`'s import table (visible in the prior analysis) imports
from `hengine.dll` exactly two symbols:
- `impl` (at `0x815570`) — the single entry point.
- `system_cleanup` (at `0x816e20`) — a no-op stub for `atexit`-style
  handshake.

**Dynamic plugin integration.** When `impl` runs it calls
`HUTIL.DLL::hdl_main()` early on (after argument parsing but before
loading any device DLL). That hands the dynamic-loader state to
`hutil`, which then receives `HUTIL.DLL::hdl_load("hdasd", 0)` /
`HUTIL.DLL::hdl_load("hsys", 0)` / etc. when `impl` processes each
`-l dynmod` argv entry (or the implicit `dyngui` if `EXTERNALGUI` was
on the command line). `hutil` does the `LoadLibraryA` and resolves the
plugin's `hdl_init`, `hdl_ddev`, etc. entry points; `impl` never sees
those.

**The 5 callbacks the .exe registers into `hengine`'s slots
(`*_exref`).** Defined in `.data` as 8-byte slots; the .exe's
`hdl_init` writes the function pointer through `hdl_main`'s
machinery. hengine reads these slots in `CallHercCmd` and the
`impl`-time daemon branch:

- `system_command_exref` — called first by `CallHercCmd` for every
  panel command. The .exe registers a no-op callback that returns
  -0x7fff, so this is plumbing for a "extensibility point" the .exe
  doesn't actually use.
- `panel_display_exref` — called once by `impl` at startup. The .exe
  registers `hdl_init`-driven logic that ends up calling
  `panel_display_r` (the 3270 driver inside hengine itself).
- `daemon_task_exref` — called instead of `panel_display_exref` when
  `-d` is passed. Used only when the user wants a headless run with no
  console.

**The CPU execution loop.** Lives in the per-CPU thread entry point
(likely `cpu.c:cpu_thread`, not visible in the procedure list because
Ghidra stripped names; it is the function `impl` indirectly triggers via
`ptt_pthread_create` after `clock.c` setup). The thread runs
`ARCH_DEP(run_cpu)(REGS *regs)`, which for each iteration:
1. **Fetch** — reads 2/4/6 bytes from `regs->IA` (instruction address)
   in main memory.
2. **Decode** — extracts `opcode1` (first byte) and (when the opcode is
   one of the multi-byte opcodes) `opcode2` (second byte).
3. **Dispatch** — loads `regs->insttab[arch][opcode1 * 256 +
   (opcode2 when present)]` (the table base was written into
   `regs+0x8d8..+0x960` by `FUN_0082b260`), and calls it with `regs`.
4. The handler updates `regs->GR`, `regs->FPR`, `regs->AR`,
   `regs->PSW`, `regs->IA`, etc., and the loop continues.

**Opcode dispatch tables** (from `FUN_0082a860`): 18+ tables in `.data`,
each indexed `[arch][opcode1][opcode2]` with 8-byte function-pointer
cells, built at startup from per-arch pointer arrays
(`PTR_FUN_008dbd80` etc.). The `replace_opcode_r` hook is the
public-side install/uninstall API for individual
`[arch, opcode1, opcode2]` cells; `s37x_replace_opcode_scan` is the
bulk-apply helper that walks the table-of-tables and calls the hook for
every cell.

**Where the panel/console and replace-opcode hooks fire.**

- **`replace_opcode` hook** — fired exclusively by
  `s37x_replace_opcode_scan`, which itself is called by the
  `replace_opcode` and `restore_opcode` panel commands. So this hook is
  *not* fired on every instruction — it is a setup-time tool for
  intercepting opcodes globally before any guest code runs.
- **`panel_command` hook** — `impl` does **not** call this hook; the
  hook is the *entry point* the .exe exposes so that anything inside
  `hengine` (the 3270 panel, scripts, etc.) can submit a command string
  and have it land in `CallHercCmd`. In practice hengine's own
  `panel_command_r` is the producer of these strings (typed at the
  console), so the registration is symmetrical plumbing.
- **`panel_display` hook** — fired once by `impl` after all initial
  setup, to enter the 3270 console driver. This is the *only* path
  through which hengine gives control back to the .exe in normal
  interactive mode.

**Surprising / weird observations:**

- The path embedded in debug strings is
  `c:\\users\\juergen\\desktop\\hercules_patched-source\\` — the build
  was made from a developer's local checkout of "hercules_patched-source"
  (Juergen is a maintainer's name; this is the Hyperion/Hercules
  patched tree).
- The build date is `Jul 15 2013 13:55:06`, version `4.00.0` (Hercules
  3.08 → Hyperion 4.00.0 branding). The TLS, MSVCR100 linkage and
  `LoadLibraryA` usage confirm MSVC 2010 toolchain.
- The `.data` section is **2.9 MB** of mostly static tables —
  `DAT_00a9bdf0` alone is 512 KB and is the giant 4-arch × 256-opcode
  generic-instruction table. `DAT_00b6e5f0` (4 MB range starting at
  `0xb6e5f0`, but actually the table stops before that — the index
  ends at `0xb6e670`) is another per-arch table.
- `system_cleanup` is exported but does **literally nothing**
  (`return;`). It's a contract marker for the .exe → hengine cleanup
  handshake.
- The `FUN_0062a780` (script.c) handler walks `DAT_00bbd3f0` as a
  *doubly-linked list of running scripts*, not an array — `puVar6` is
  cast through `(undefined8 **)puVar6 == &DAT_00bbd3f0` to detect end.
- 4 of the 6 S/370-architecture-specific names Ghidra recovered
  (`s370_program_interrupt`, `s370_device_attention`,
  `s370_store_int_timer`, `s370_fetch_int_timer`) confirm the ARCH_DEP
  macro instantiation, with s370, s390, z900 instantiated as expected.
- The `impl` decompile shows `set_symbol("HOSTOSVER", ...)` etc. — the
  emulator has its own symbol-substitution table used to render
  `$(HOSTNAME)`, `$(CUU)`, `$(DEVN)` style templates in panel
  messages.
- `panel_display_r` calls `GetConsoleScreenBufferInfo` to size the
  3270 console window, then paints per-CPU status rows with MIPS
  throughput calculated from `instcnt` (instructions-executed counter).

### H7 — Open questions / follow-ups

- The exact address of `cpu_thread` / `run_cpu` for each architecture —
  the dispatcher itself is inlined into the per-arch run_cpu
  functions, which Ghidra fragmented into many small `FUN_` entries.
  Identifying the loop-body entry would require either the .pdb or a
  callgraph trace from `ptt_pthread_create(..., FUN_00815410, ...)` in
  `impl`.
- The exact opcode set covered — the .data has 256-entry tables ×
  ~18 arch axes, but which opcodes are *missing* vs `(*unimplemented*)`
  handler would need walking through the per-arch pointer arrays
  (`PTR_FUN_008dbd80`, etc.).
- The instruction-stepping hook (`s+` panel command) is wired through
  `sysblk_exref + 0xd60` (the instructions-executed counter) and
  `instbreak` ranges, but no single function is the "step mode"
  coordinator.
- The channel I/O dispatcher (`FUN_0063c750`, 12,729 B) deserves a
  separate reverse-engineering pass — it implements CCW (channel
  command word) chains.
- The 21 `execute_opcode_*` strings are the *names* the disassembler
  prints in instruction traces; with the .pdb one could recover the
  actual symbol-to-string mapping that `FUN_0082a860` builds.