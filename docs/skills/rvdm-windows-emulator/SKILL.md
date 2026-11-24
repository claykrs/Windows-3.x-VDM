---
name: rvdm-windows-emulator
description: Work on RVDM, the Luau 8086/286 PC and Windows 3.0a/3.1 emulator that runs the genuine WIN.COM -> KERNEL -> USER/GDI -> Program Manager boot inside a Roblox window. Use when the task mentions RVDM, "Windows 3.0 in Roblox", "the Windows emulator", WIN.COM/KERNEL/USER/GDI, Program Manager, SETUP.INF app compatibility, Tetris 2.0, VGA mode 12h, EditableImage/VgaSink, app_harness, WinBoot, check.lua, pack_winboot, studio_deploy, Vdm.rbxmx, a guest CS:IP fault, or planning Windows 3.1 Standard mode (286 protected mode, DOSX/KRNL286, XMS/EMS). Trigger even for casual references to "the emulator" in this repo.
---

# RVDM — Windows 3.0a in a Roblox window

RVDM is an 8086 real-mode PC written in Luau. It boots the **real** Microsoft
Windows 3.0a binaries: `WIN.COM` validates DOS 5.0 / SFT / LoL / the MCB arena,
EXECs `KERNEL.EXE`, loads SYSTEM/KEYBOARD/MOUSE/DISPLAY/VGA drivers and fonts,
then real `GDI.EXE` + `USER.EXE`, and renders the real Program Manager at
640x480 in an emulated VGA framebuffer. No screen is mocked and no app output is
hardcoded.

Repo root is the working directory. Current branch name varies by worktree;
the public release line is `main`.

## Verified state (2026-11-03)

- Real `WIN.COM -> KERNEL -> drivers/fonts -> GDI/USER -> Program Manager`
  reaches the 640x480 desktop with Main/Accessories/Games groups. **Use
  `timerInterval = 55_000`**; 25k is diagnostic only and trips KERNEL's
  critical-section reentry guard (`fatal 0x140`).
- **20/20 SETUP.INF applications launch and render** with real guest code (no
  stubbed app output): PROGMAN, WINFILE, WRITE, PBRUSH, NOTEPAD, CARDFILE,
  CALENDAR, CALC, CLOCK, REVERSI, CONTROL, TASKMAN, WINVER, CLIPBRD, PIFEDIT,
  RECORDER, PRINTMAN, SOL, TERMINAL, MSDOS.
- **Tetris 2.0 is playable**: `TETRIS.EXE` + `ABOUTTET.DLL`, opening
  `SYSTEM\WIN87EM.DLL`, `TETRIS.INI`, `TETRIS.HST`; Game > New starts a level
  and falling/stacked pieces render in mode 12h. `Score:`/`Level:`/`Lines:`
  draw red digits at x≈41 but their opaque black text backgrounds start at
  x≈51 (one character cell right); board/pieces are unaffected.
- **PC speaker path**: PIT channel 2 (0x43/0x42) and port 0x61 gate bits 0+1
  feed `Machine:speakerState()`; the client retriggers a short optional Roblox
  beep. Tetris itself only writes 0x61 bit 7 (A20), so its sound is not wired.
- **667 assertions** is the current test count:
  `lune run tools/run.lua` prints `passed assertions: 667` and
  `ALL TESTS PASSED`. 3.0a CALC was re-booted through Program Manager after the
  R7 CPU/XMS changes (303,069 non-black px at 640x480).
- **Windows 3.1 (R7, in progress):** with `cpuLevel="286"` and 4 MiB RAM, real
  `WIN.COM`/`WIN.CNF` passes the HIMEM/CPU probes, runs WSWAP, EXECs and
  EXEPACK-unpacks `SYSTEM\DOSX.EXE`, builds/copies its GDT, enters PM at
  `0078:0B0E`, runs `LLDT/LTR`, IRETs to ring 3 (`0x5B:0xB51`), calls the 0xCB
  gate into ring 0 at `0078:0C5D`; the all-zero LIDT selects the compact
  callback IDT at 0x110470/0x3F and INT3 enters the `0078:0C63` switch
  helper. The helper clears CR0.PE and `LJMP 3838:0C7D` reloads real CS;
  4M/8M runs complete with no fault (4M PC=`3838:1C21`, 8M PC=`3838:34C2`,
  PE=0). At 64M it is still in the loader's KRNL286/KRNL386 path-search loop
  (`3838:1C7F`); AH=43 finds `C:\WINDOWS\SYSTEM\krnl286.exe`, but the switch
  helper's second near RET returns to `3838:0078` (INT3 saved CS popped as
  IP). The real 286 callback frame is on the SS=004B stack at SP~0x00F2
  (`[0x134]=2`, `[0x2F5A]=0`), not the DS:0x0F0 copy; `0053:0FE3` switches to
  SP=0x42B0 and enters `005B:0340` with PE=1, so its ES=0 access faults.
  Forcing PE=0/SS=004B/SP=0x00F2 at `0340` makes the guest exit at step
  75,238 (no KRNL286), so `0340` is PM code and the guest setup is
  inconsistent with PM null-selector semantics. Disassembly: `0B9A` pushes
  the outer 0C13 frame on SS=004B; `148F` starts a nested 0x42B0 stack and
  never uses it. GDT dumps at `148F`/`0340`/`0367`: `GDTR=0x110800/0x011F`,
  `GDT[0]=0000 0000 0000 0000`, `GDT[0x18]=FFFF 0000 F200 0000`; no
  `B8 18 00`/`8E C0 18` patch. GDT[0] is correctly null. The 286 reset path
  is now implemented: zero LIDT -> triple fault, CMOS 09h SHUT9 / 0Ah SHUTA,
  MOV CR0/DR gated to 386. DOSX EXECs **KRNL286.EXE**. VERR/VERW semantics
  were also fixed (`0F 00 /4,/5`): DOSX's API 0x0A alias creation now
  succeeds, KRNL286's `CS:0x30` becomes `02E7` and `CS:0x32` becomes `009B`,
  and the old `02EF:1CFE` DS=0 fault is gone. The DOSX callback frame is now
  green: outer-privilege `RETF` restores `027F:01F8` before `148F`, the
  16-bit call-gate frame is IP/CS/oldSP/oldSS/params (no FLAGS), and the
  `14E1` epilogue IRETs to KRNL286 at `02EF:9A19`. Next first fault is
  `02EF:728C` (`#GP: es selector FB00`, PE=1) from `MOV ES,[BP-4]` with
  `[BP-4]=FB00`. `--cpu 386`
  is a separate WIN386 enhanced-mode branch: it EXECs WIN386.EXE and first
  faults at `1110:5A66` (unhandled INT 05); `--cpu 386 --force286` faults at
  `0000:0085`. It is
  not the KRNL386 standard-mode target.
- Known limits: 640K real-mode wall (WRITE's 79 segments need demand loading);
  XMS exists on 286+ but no EMS; no DOS `COMMAND.COM`; `AH=4B AL=3` overlays
  unimplemented; fixed file attributes/timestamps; cosmetic icon-plane colour,
  group-label spacing and Tetris value-background offsets; no Sound Blaster/
  AdLib, printer/serial or installer backend; instruction-counted timer, not
  wall-clock PIT. 3.1 has descriptor translation, ring 3, a ring-3→ring-0
  call gate/TSS switch and PM IDT delivery, but no PM→real-mode switch-back.

## File map

| Path | Purpose |
| --- | --- |
| `core/Cpu.lua` | 8086 real-mode CPU, flags, interrupts, HLT/STI/POPF/IRET shadow |
| `core/Memory.lua` | 1 MB address space, A0000 VGA aperture wiring |
| `core/Vfs.lua` | In-memory DOS filesystem and path handling |
| `core/Bios.lua` | INT 10h/16h/9/8 glue, console text |
| `core/Dos.lua` | INT 21h subset, PSP, MCB arena, SFT/LoL, DTA/FindFirst, EXEC |
| `core/Xms.lua` | XMS 3.0 driver: INT 2Fh 4300/4310, A20, HMA, EMBs, 0Bh move |
| `core/Executables.lua` | COM/MZ/NE/bound-NE loaders, PSP, relocations, env block |
| `core/Machine.lua` | Wiring, `Machine.new(deps)`, run loop, PIC, keyboard, mouse, timer |
| `core/Vga.lua` | Mode 12h/13h/text, planar/linear render, palette, dirty rects |
| `core/TextScreen.lua` | 80x25 text sink |
| `core/init.lua` | Roblox-facing module index (not part of the strict core gate) |
| `fixtures/` | Generated apps, `Kernel16`, `TestApps`, `WinBoot*.lua` (ignored) |
| `roblox/ui/` | `Theme`, `Cleaner`, `State`, `Components`, `Window`, `init` (VdmUi) |
| `roblox/client/` | `Emulator.client.lua`, `ScreenSink`, `VgaSink`, `KeyboardMap` |
| `tests/` | `CpuTests`, `PmCpuTests`, `XmsTests`, `MachineTests`, `DosTests`, `GroupFileTests` |
| `tools/check.lua` | Format/lint/typecheck/test gate |
| `tools/app_harness.lua` | Boot, app matrix, traces, PNG screenshots |
| `tools/install.lua` | SETUP.INF staging, INI writers, group generation |
| `tools/pack_winboot.lua` | Packs staged media into `fixtures/WinBoot*.lua` |
| `tools/build_rbxmx.lua` | Builds importable `Vdm.rbxmx` |
| `tools/studio_deploy.lua` | Builds `execute_luau` deploy JSON |
| `media/win30/` | Your Windows media: `files/`, `staged/`, `staged/<app>/` (ignored) |
| `docs/APP_COMPAT.md` | App matrix and third-party eligibility evidence |
| `docs/PHOTOSHOP.md` | 3.1/Photoshop feasibility research |

Generated/ignored: `Vdm.rbxmx`, `fixtures/WinBoot*.lua`, `tools/deploy_args.json`,
`tools/out/`, `tools/bin/`, `media/`, `tools/memdump.bin`.

## Hard rules

1. **`core/` modules are environment-pure** (the Roblox-facing `core/init.lua`
   index is the one exception and requires child modules). No `game`/`workspace`,
   no `print`/`warn`, no filesystem. Dependencies arrive via `Machine.new(deps)`;
   diagnostics go through `machine:log()` (appended to `machine.diagnostics`,
   optionally forwarded to `deps.logger`).
2. **`--!strict` in `core/`.** Annotate public APIs and injected dependency
   shapes. `any` is allowed only at the dependency table, the CPU opcode
   dispatch table, and VFS nodes at the Roblox boundary. Roblox UI/tools are
   `--!nonstrict` because the standalone analyzer lacks Roblox types, but their
   public APIs are still annotated.
3. **Luau has no native bitwise operators.** `& | ~ << >>` do not parse. Use
   `bit32` via module-local aliases:
   `const band, bor, lshift, rshift = bit32.band, ...`.
4. **`const` is the default** for bindings that never change; `local` only when
   reassigned. Constants are `SCREAMING_SNAKE_CASE`.
5. **Naming:** modules/types `PascalCase`; functions/methods/locals `camelCase`;
   module files `PascalCase.lua`; tools `snake_case.lua`; Roblox entry points
   `Name.client.lua`; tests `PascalCaseTests.lua`. `.lua` everywhere.
6. **Roblox work is client-side.** Server is only for future media/HTTP.
   Roblox modules load through service roots and index modules
   (`require(ReplicatedStorage:WaitForChild("Vdm"))`, `VdmUi`, `VdmFixtures`);
   string-path requires (`./`, `@self`) are unavailable. Sibling requires inside
   one UI folder are allowed.
7. **Every change must leave the gate green.** UI work gets an independent QA
   pass. A style commit must change no behaviour.

## Build, boot, deploy

Run from the repo root. If Lune is not on `PATH`, use `./tools/bin/lune.exe`
(PowerShell: `.\tools\bin\lune.exe`).

```powershell
# Full gate: stylua --check, selene (luau), selene (roblox), luau-analyze strict, tests
lune run tools/check.lua
# Media pipeline (media is NOT in git; bring your own Windows 3.0a disks)
lune run tools/extract.lua      # .IMG FAT12 -> media/win30/files
lune run tools/stage.lua        # SZDD -> media/win30/staged
lune run tools/pack_winboot.lua # staged + INI rules -> fixtures/WinBoot*.lua
lune run tools/build_rbxmx.lua  # core/ui/fixtures/client -> Vdm.rbxmx
```

`extract.lua` expects `media/win30/Microsoft Windows 3.0a (5.25 1.2MB)`.
`pack_winboot.lua` reuses `Install.writeSystemIni`; keep that coupling or the
Studio boot gets an empty shell / NETWORK.DRV fallback.

Import `Vdm.rbxmx` into Studio, enable **Game Settings -> Security -> Allow
Mesh / Image APIs**, and set the `ReplicatedStorage` attribute
`VdmBootWindows = true`. Without it the client runs the bundled NE4 fixture.

### Harness boot

```powershell
# Plain WIN.COM boot to Program Manager
lune run tools/app_harness.lua --timer 55000 --steps 20000000 --shot tools/out/pm
# One app on WIN.COM's command line (same as WIN CALC.EXE)
lune run tools/app_harness.lua boot CALC --timer 55000 --steps 8000000 --shot tools/out/calc
# App queued through WIN.INI [windows] run=
lune run tools/app_harness.lua boot CALC --via ini --timer 55000 --steps 8000000 --shot tools/out/calc-ini
# Whole matrix (expensive; only for a deliberate compat refresh)
lune run tools/app_harness.lua boot all --via ini --timer 55000 --steps 5000000
# Static NE load against real KERNEL/GDI/USER; header facts; staging audit
lune run tools/app_harness.lua static all
lune run tools/app_harness.lua list
lune run tools/app_harness.lua audit
```

Options: `--steps N`, `--slice N`, `--hot N`, `--via cmdline|ini`,
`--cmdline TEXT`, `--app-dir DIR`, `--keys 1C,1C`, `--key-at N`,
`--key-gap N`, `--timer N`, `--shot BASE`, `--shots`, `--no-shot`.
`--keys` values are **hex set-1 scan codes** (`1C` = Enter). The harness parses
the default timer as 25_000 even though boots need 55_000: **always pass
`--timer 55000`** for guest code. Screenshots go to `tools/out/` (ignored), named
`<base>-<app>.png` or `<base>-win.png`.

### Windows 3.1 probe (R7)

```powershell
lune run media/win31/probe31.lua --steps 400000
# optional: --cpu 8086|286|386 --trace 1
```

It seeds `media/win31/install/WINDOWS`, defaults to `cpuLevel=286` and 4 MiB,
and boots the real 3.1 `WIN.COM`. Expected current result: DOSX enters PM,
IRETs to ring 3 at `0x5B:0xB51`, calls the 0xCB gate into ring 0 at
`0078:0C5D`; the 286 zero LIDT loads IDTR=0/0 and INT3 triple-faults. The
CMOS 09h SHUT9 path restores BDA `0040:0069/0067` SS:SP, pops DS/ES/PUSHAW,
and `RETF 2` resumes real-mode `3838:0C13`. DOSX then EXECs
**`C:\WINDOWS\SYSTEM\KRNL286.EXE` (71,730 bytes)**. VERR/VERW (`0F 00
/4,/5`) are implemented correctly, so DOSX's alias creation succeeds and
KRNL286's module header is initialized (`CS:0x30=02E7`, `CS:0x32=009B`).
The DOSX callback frame is also fixed: outer-privilege `RETF` restores
`027F:01F8`, the call-gate frame is IP/CS/oldSP/oldSS/params (no FLAGS), and
the `14E1` epilogue IRETs to KRNL286 at `02EF:9A19`. At 4M steps the next
fault is `02EF:728C`:
`#GP: es selector FB00: absent or outside GDT limit`, PE=1, CS=02EF base
`0x8FDB0`, DS=02EF, ES=03F7, SS=027F, SP=01B0, AX=FB00, BX=02EF, CX=B6CB,
SI=0040, DI=B6CB, BP=01CC; last PC `0053:2197`. The faulting instruction is
`MOV ES,[BP-4]` at `02EF:7289` with `[BP-4]=FB00`.
`--cpu 386` is a separate WIN386 enhanced-mode branch (EXECs WIN386.EXE,
first fault `1110:5A66` unhandled INT 05), not the R7 KRNL386 target.
`media/` is ignored; do not commit it.

### Studio MCP deploy

```powershell
lune run tools/studio_deploy.lua reinit      # after editing core/init.lua
lune run tools/studio_deploy.lua core        # Vdm -> ReplicatedStorage
lune run tools/studio_deploy.lua ui          # VdmUi
lune run tools/studio_deploy.lua fixtures    # VdmFixtures
lune run tools/studio_deploy.lua client      # VdmClient -> StarterPlayerScripts
lune run tools/studio_deploy.lua server      # VdmServer -> ServerScriptService
lune run tools/studio_deploy.lua single Machine
node tools/mcp.mjs callfile execute_luau tools/deploy_args.json
```

**Payload rule:** `execute_luau` double-decodes escapes, so the generated code
must contain **zero backslashes**. `studio_deploy.lua` base64-encodes every
source and asserts no `\` exists. Never hand-write Windows paths into an
`execute_luau` payload; use `callfile` with the generated JSON. The `core` chunk
updates child ModuleScripts but **not** the `Vdm` root's `init.lua` Source — run
`reinit` and redeploy after editing `core/init.lua`.

## Third-party 16-bit EXE workflow

1. **Triage eligibility** with `app_harness list` (or read the NE header):
   `0Ch` bit 3 (`NE_FFLAGS_PROTMODE`) clear, `3Eh` expected Windows version
   `<= 3.0`, `36h` target OS `02h`, CPU bits 4/5/6 absent or 8086. Bit 3 set =
   Standard/386 only; 3.1-only apps cannot run under 3.0a in any mode.
2. **Stage the package flat** under `media/win30/staged/<app>/`: EXE, DLLs,
   INI/HST/HLP/DOC, all dependencies. `tools/stage.lua` is only for SZDD Windows
   media; do not run it on a third-party EXE. `--app-dir` reads top-level files
   only, so keep the folder flat.
3. **Boot it** with `--app-dir`; the harness copies every file to `C:\WINDOWS`
   and every `.DLL` also to `C:\WINDOWS\SYSTEM`. `--via ini` sets
   `[windows] run=C:\WINDOWS\<APP>.EXE`; omit it to use WIN.COM's command tail.
4. **Drive dialogs** with `--keys`/`--key-at` (make/break set-1 codes; `1C` =
   Enter). Pick the step from the report, not by repeated guessing.
5. **Capture** with `--shot tools/out/<name>`; `recent opens` must show the EXE
   and every DLL. A missing DLL is a failed `AH=3D` (`CF=1` in last DOS calls).
6. **Tetris example** (files already under `media/win30/staged/tetris/`):

```powershell
lune run tools/app_harness.lua boot TETRIS --via ini --timer 55000 `
  --steps 20000000 --app-dir media/win30/staged/tetris `
  --shot tools/out/tetris
# Title screen/dialog needs Enter; adjust --key-at from the first report
lune run tools/app_harness.lua boot TETRIS --via ini --timer 55000 `
  --steps 22000000 --app-dir media/win30/staged/tetris `
  --keys 1C --key-at 12000000 --shot tools/out/tetris-play
```

Expected Tetris trace: `TETRIS.EXE`, `ABOUTTET.DLL`,
`SYSTEM\WIN87EM.DLL`, `TETRIS.INI`, `TETRIS.HST`; mode 12h planar output.
For a Studio bundle, add the app's files to `pack_winboot.lua`'s optional list
(`TETRIS.EXE` etc. are auto-included only from the staged root) — verify the
pack list before assuming a subfolder is bundled.

## Debugging playbook

1. **Reproduce one app** with `boot <APP> --timer 55000`; never start with
   `boot all`. Budget just enough: 4M plain, 8-20M with apps, 20-25M Tetris.
2. **Read the verdict:** `APP EXEC REACHED` = real `AH=4Bh`; `BLOCKED ON
   KEYBOARD` = INT 16h wait; `EXITED` = DOS terminate; `spin`/`hot loop` =
   scheduler/driver loop; `WILD JUMP` = bad pointer/relocation; `BUDGET
   EXHAUSTED` = often healthy idle Windows. KERNEL's `WinExec`/`LoadModule` path
   does not use `AH=4Bh`, so the verdict may still say "before app EXEC" while
   `recent opens` proves the app loaded (`result.opened` exists but is not
   printed — verify if you extend the report).
3. **Trace files/DLLs:** `AH=3D` + `CF=1` is the missing file; `AH=4B` is a real
   EXEC; `EXEC targets` shows the command tail; `INT 21h calls` lists counts by
   AH; `INT 80h`/`INT 2Fh` show Win16/DOS multiplexer traffic.
4. **Locate a spin** with `hot spots`/`final spin`; `code at stop` prints 16
   bytes at `CS:IP` — disassemble before changing anything. `--hot N` controls
   PC count. Scratch probes (`probe_next_dswatch.lua` for KERNEL's DS cache word
   `1111:02DA`, `probe_int2f.lua`, `probe_boot.lua`) are git-ignored and may be
   stale; read before running.
5. **Static check:** `app_harness static all` and `tools/load_real.lua` prove NE
   parsing/imports without executing app code. WRITE's 79 segments are the known
   eager-loader limit, not an app bug.
6. **Blank/incorrect screen:** print `mode`, `kind`, `width x height`,
   `non-black px`, `colours`. Text uses `ScreenSink`; graphics use
   `VgaSink`/`EditableImage`. In Studio check **Allow Mesh / Image APIs**, else
   the sink falls back to a 32-column (~24-row) grid. `unhandled INT 10h AH=11`
   is benign for Tetris unless a later failure points at it.

## Known fixes and gotchas

| Symptom / rule | Cause and fix |
| --- | --- |
| KERNEL `fatal 0x140`, CALC "System Error" | 25k PIT fires too fast and trips critical-section reentry. Use `--timer 55000` (`config.timerInterval` defaults to 55_000; harness parser default is 25_000). |
| MS-DOS Executive/File Manager missing or bogus filenames | FindFirst DTA layout: attribute at `15h`, size at `1Ah`, name at `1Eh`; volume-only searches must not return normal files. |
| MCB corruption / `AH=48` overlap | First-fit MCB chain with split/merge/resize; one-paragraph MCB gaps; invariant `next.start == prev.start + prev.size + 1`; zero-size allocations succeed at `arenaTop`. EXEC marks PSP + image owned. `dosBrk` is gone. |
| Bound KERNEL/GDI faults, overwritten stack | MZ stub maps the whole file at `CS-0x20` and jumps to the NE entry; `AH=4B` applies NE relocations in place before the stub runs. Load high (`imageBase = pspSeg + programParas - imageParas`) and reserve a second image-sized area + `0x1000` paragraphs. Do not reintroduce the eager `relocateBoundNE` pass. |
| SYSTEM.INI lookups silently revert to defaults (NETWORK.DRV) | `WIN.COM` needs `windir=C:\WINDOWS\` with trailing slash; child environments must get `C:\WINDOWS` **without** it, because KERNEL appends its own. Double slash breaks every profile lookup. `PATH` must include `C:\WINDOWS\SYSTEM` (WIN87EM.DLL). |
| KERNEL never starts the shell / SFT not found | DOS data at segment `0x0060`: 59-byte SFT entries, three `CON` names at entry+`1E`, list of lists at `AH=52` -> `BX = LoL+2` (`[BX-2]` MCB, `[BX+4]` SFT, `[BX+22h]` NUL). `AH=44` must classify `CON` as a character device. |
| GDI HDC becomes null after timer interrupt | BIOS INT 8 EOI stub must `PUSH AX` / `MOV AL,20h; OUT 20h,AL` / `POP AX` / `IRET`. Clobbering AX corrupts live caller results. |
| `CMP` gives wrong flags / clobbers a register | Group 1 `/7` CMP must produce subtraction flags (not XOR); `CMP r8,r/m8` and `0x39` family must not write back. Signed Jcc compares `SF ~= 0` vs `OF ~= 0` as booleans, never masks `0x80`/`0x800`. |
| Guest freezes at idle | HLT is an idle wait, not an exit. `Machine.run` wakes on the next PIT tick; the harness stops only on keyboard wait or DOS exit. The client keeps calling `run` while halted. |
| Text appears but app never finishes | DOS/BIOS handler CF/ZF must reach the guest. Dispatch inline while the vector still points at the emulator stub; don't let the stub's IRET restore pre-call flags. |
| CALENDAR/REVERSI fail on VGA.DRV resources >64K | A child PSP must not close inherited JFT handles still owned by KERNEL; `AH=3E` keeps the owner's handle. |
| CLOCK never advances | `INT 21h AH=2C` must advance from the BDA tick, not stay frozen at noon. |
| WM_TIMER apps freeze / Tetris board stays blank | Maskable IRQs must honour IF, and `Cpu.interrupt`'s chained-stub write-back must preserve the caller's IF. Otherwise an INT 2Fh/28h chain leaves Windows idling with IF=0 and no timer messages reach the app. |
| Two cursors in Studio | `MouseIconEnabled=false` does not hide Studio's OS arrow. Poll `GetMouseLocation` minus `GetGuiInset`, hide for the whole VDM window, and in Studio capture with `MouseBehavior.LockCurrentPosition` + `GetMouseDelta`; PrintWindow shows the guest cursor only. |
| PC speaker silent / false beeps | PIT channel 2 divisor comes through 0x43 then 0x42; 0x61 bits 0+1 gate it. Tetris writes 0x61 bit 7 (A20) only, so do not treat every 0x61 write as sound. |
| Tetris score boxes empty | The red digits (index 12) are at x≈41 and the opaque black text backgrounds at x≈51, one character cell right. VGA.DRV fill PCs 0D87:1AE5/1DF7 write the background after the glyphs; this is a GDI text-alignment/background-rect or child-window paint-order issue, not black-on-black text or an EGA palette swap. |
| WRITE "Insufficient memory" false alarm | `AH=47` must return `AX=0x0100` (AH=1, AL=0); leaving AL as the caller's `'A'` breaks its NUL scan. |
| VGA repaints are slow | Use `Vga:consumeDirty()` + `snapshotRegionRGBA` + `VgaSink:UpdateRegionRGBA`; a full 640x480 RGBA upload is 1,228,800 bytes. |
| `WritePixelsBuffer` silently fails | Its buffer length must equal `regionWidth * regionHeight * 4` exactly; `VgaSink` resizes `regionBuffer` on any mismatch. |
| Studio boot empty shell / group icons "Cannot find file" | `pack_winboot` must use `Install.writeSystemIni`; include `PROGMAN.EXE` (WinBootApps) and every group target (`WinBootBig`), or KERNEL exits after USER / icons cannot resolve. |
| Studio `core` deploy misses `Vdm` root source | `execute_luau` chunk updates children only; run `studio_deploy.lua reinit`, then redeploy the tree. |
| DOSX GDT is all zeros / garbage | `PUSH imm8` must sign-extend only 0x80..0xFF; adding 0xFF00 to every byte corrupts the GDT builder's offsets. Also force A20 on during XMS 0Bh moves; DOSX copies its GDT into an EMB while the guest gate is off. |
| PM `#GP: CS selector ... is not a code segment (access E4)` | `E4` is a present 286 call gate (type 4); use `Cpu:farCall`, not `loadSeg`. DOSX 0xCB targets `0078:0C5D` with 0 params and TSS SS0=0x68/SP0=0x30A8. |
| PM `#GP: protected-mode interrupt 03 ... requires an IDT handler` | Historical. PM IDT delivery is implemented. The gate target's `LIDT [DS:0x2A31]` operand is all-zero (uninitialised copy); select the compact 8-entry IDT at liveBase+0x470 (0x110470/0x3F) and patch vector 3 to `0078:0C63`. A later zero LIDT keeps the compact table. |
| PM `#GP: es selector 3838 ...` / `ds selector 0C63 ...` | Real-mode paragraph values used by DOSX's callback stub; do not special-case them. `0078:0FE3` is not the switch helper: it ends in `POP DS`, popping the INT3 frame's saved IP (`0x0C63`, a code offset, not a selector); the helper is `0078:0C63`, which clears CR0.PE and `LJMP 3838:0C7D`. |
| 64M probe still in DOSX real-mode loader, no fault | KRNL286 path search loops: `3838:0098` -> `3838:1C0C`; AH=43 finds `C:\WINDOWS\SYSTEM\krnl286.exe`, AH=4A resizes, `LJMP 0053:0BF` runs the PM callback, and the switch helper's second near RET at `3838:0C86` pops INT3 saved CS `0x0078` as IP. Stack at SP=0x3098: `[0C63, 0078, 0046, 0C05, 005B, 0046, 3068, 004B]`; push32/pop32 is balanced. The real callback frame at DS:0x0F0 is `3838:0C13`, not `0x7C`; diagnostic patch to 0C13 continues, 0C7C exits at 75k. |
| `#GP: es selector 0000 offset 0246` at `005B:036F` | Diagnostic with compact vector 3 restored to `0053:0FE3`: `MOV AX,ES:[BX+2]` at `005B:036B` reads IVT INT 91 (BX=0244) while PE=1, after `0053:14DC LJMP 005B:0340`. The callback body expects real mode; not the committed path. |
| Handoff frames at the 0C63 helper | `005B:0C00` call-gate stack is `[0C05,005B,oldSP,oldSS]` (286 call gates push no FLAGS); the `0070` dispatcher's ring0->ring3 `RETF` frame is `[0E63,0053,SP=01F8,SS=027F]`, so `148F` runs on `027F:01F6`, not `0068:30A0`. `0053:0FE3` INT3 stack `[0C63,0078,0046,0C05,005B,0046,oldSP,004B]`. First pass `[0x134]=2`, `[0x2F5A]=0`: `005B:0B9A` pushes outer `0C13/3838/0046` on SS=004B at SP=0x00F2; `0053:148F` sets SP=`[0x100]`=0x42B0, subtracts `[0x2F6F]`, and jumps `005B:0340` with PE=1. `0340` is PM code (`CALL 0B61` PM gate). GDT at `148F`/`0340`/`0367`: `GDTR=0x110800/0x011F`, `GDT[0]=0000 0000 0000 0000`, `GDT[0x18]=FFFF 0000 F200 0000`; no `B8 18 00`/`8E C0 18` patch. GDT[0] is correctly null. Forcing PE=0/SS=004B/SP=0x00F2 exits at step 75,238 (no KRNL286). |
| `--cpu 386` diagnostic | `WIN.CNF` EXECs WIN386.EXE (544,789 bytes), not DOSX/KRNL386. First fault `1110:5A66`: unhandled INT 05, zero IVT, CR0=0, CS=`1110` base 0x11100, IP in ASCII data; DS/SS=`142E`, ES=0. `--cpu 386 --force286` loads DOSX but faults with unhandled INT3 at `0000:0085`. This is WIN386 enhanced mode, not the R7 KRNL386 target. |

### CPU/DOS indexing facts

- `r[1..8] = AX CX DX BX SP BP SI DI`; `r[5]` is SP. `cpu:wr(3)=BX`,
  `wr(4)=SP`; `cpu:wb(0..7) = AL CL DL BL AH CH DH BH`, so AH is `wb(4)`.
- Pascal first arg at `SS:SP+6`; far pointer = offset then segment;
  `GlobalAlloc` reads `(flags, sizeHigh, sizeLow)`.
- Never fire INT 8 inside `0xF100`; DOS/BIOS CF must survive the stub.
- PM IDT gate: offset low at +0, selector +2, param count/reserved +4, access
  +5 (type 6/7/E/F; present 0x80; DPL bits 5-6), offset high +6. DOSX vector 3
  is at IDT 0x110000+0x18: offset 0x1139, selector 0x70, access 0xE6.

## Roblox host behavior

- **Window:** guest 640x480; `fitWindow` picks integer scale 1-3 when it fits,
  else fractional, plus title/status bars; opaque black desktop; scriptable camera.
- **Scene cleanup:** disable all CoreGui types (repeat 12 x 0.5s because CoreGui
  initializes late), topbar/chat/reset off, destroy SpawnLocation/Baseplate and
  the local character plus every `CharacterAdded`; `ScreenGui.ResetOnSpawn = false`.
- **Keyboard:** KeyCode -> PC/XT set-1 make/break via `KeyboardMap` -> 8042 port
  `0x60` -> IRQ1. `InputBegan` ignores Roblox's `_processed` flag so **O** (emotes
  menu) still reaches the guest. Release on `InputEnded`/`WindowFocusReleased`/
  close. Repeat: 0.45s delay, 0.05s interval (~20 cps), not for modifiers/locks.
- **Mouse:** PS/2 INT 15h/C2xx + IRQ12/C207. MOUSE.DRV moves two pixels per
  count, so `setMouse` sends half-counts with a remainder; flip Y once.
- **Anchor:** `syncMouse` clears pending motion/buttons, sends eight
  `(-127,+127)` sync packets to clamp at (0,0), then applies the target delta.
  Re-anchor on entry/click/0.3s stillness; suppress video 50ms.
- **Packets:** coalesce only same-button, non-sync movement within ±127; never
  across a sync packet; queue cap 64, drop oldest.
- **Click anchor:** MouseButton1/2 `InputBegan` forces the anchor before the
  press. Hide the host arrow over the framebuffer; restore on close.
- **Performance:** Heartbeat targets 4ms, 12k-80k instructions/frame; mouse
  pumps 1,500 instructions every 8ms. Render only the dirty rectangle; recreate
  `EditableImage` on mode change.
- **Permissions/fallback:** **Allow Mesh / Image APIs** is required; failure
  falls back to a 32-column (~24-row) Frame grid, then a labelled placeholder.
  Text mode uses `ScreenSink`; `VgaSink` is fixed-size.

## Git and release

- Public repo: `https://github.com/claykrs/Windows-3.x-VDM` (`origin`).
- The release line is a **single squashed commit** on local `main` (current:
  `d328632 windows 3.0a in roblox`). The local tag **`backup-before-squash`**
  (`880e04c`) preserves the previous 94-commit history. `origin/main` may lag
  behind the squashed local line (it pointed at `f17a233` when this was written);
  verify with `git log` before publishing. Never force-push without a fresh
  backup tag.
- Commit messages are natural, lowercase summaries (for example
  `host window and renderer cleanup`, `windows 3.0a in roblox`), not
  Conventional Commits. Keep functional and style commits separate; a style
  commit must be behaviour-neutral and `tools/check.lua` green.
- **Never commit media.** `media/`, `fixtures/WinBoot*.lua`, `Vdm.rbxmx`,
  `tools/deploy_args.json`, `tools/bin/`, and `tools/out/` are ignored.
- GitHub Release assets: the built Roblox model as **`Vdm.rbxm`**, a demo place,
  and the version in the release title/notes. `tools/build_rbxmx.lua` currently
  emits `Vdm.rbxmx`; verify the release packaging/rename step before uploading
  so the asset name matches the published convention.

## Windows 3.1 roadmap (Standard mode first)

Do **not** start with 386 Enhanced mode. Windows 3.1 Standard mode is the
practical next generation and enough for Photoshop 2.5 (`docs/PHOTOSHOP.md`).
Keep 3.0a real mode as the regression baseline.

1. **286 protected mode:** GDT/IDT/LDT, descriptors/limits/selectors, privilege
   levels, call gates, TSS, ring transitions, `#GP/#PF/#UD`, real<->PM, A20; add
   the 386 subset DOSX/KRNL286 actually uses (`0x66/0x67`, 32-bit GPRs, FS/GS,
   MOVZX/MOVSX, BSF/BSR, BT*, SHLD/SHRD, SETcc, XADD, system) — verify the subset
   before building a full 386 core. **R7 pass 1:** execution levels, A20/XMS,
   0F system subset and the DOSX handoff are done. **R7 pass 2:** descriptor
   caches/`loadSeg`, PM far jump and the ring-3 handoff are done. **R7 pass 3:**
   call gate 0xCB + TSS ring-3→ring-0 stack switch + outer IRET are done.
   **R7 pass 4:** PM IDT delivery for INT3 works. **R7 pass 5:** PE-transition
   support/tests added. **R7 pass 6:** the compact real-callback IDT
   (0x110470/0x3F) is selected and vector 3 points at `0078:0C63`.
   **R7 pass 7:** the switch helper clears CR0.PE and `LJMP 3838:0C7D`
   reloads real CS. **R7 pass 8:** 4M/8M clean; 64M still in the KRNL286
   path-search loop. **R7 pass 9:** the frame at `3838:0C86` is
   `[0C63,0078,0046,0C05,005B,0046,3068,004B]`; push/pop is balanced and the
   second near RET pops saved CS 0x0078 as IP. The real callback frame is
   `3838:0C13` at DS:0x0F0, not 0x7C. **R7 pass 10:** handoff trace shows
   the call-gate/INT3 frames are correct; `0053:0FE3` leaves PE=1 before
   `005B:0340` (ES=0 fault), and the `0C63` helper uses the INT3 frame.
   **R7 pass 11:** `[0x134]=2` selects the 286 callback path; `0B9A` builds
   `0C13/3838/0046` on the SS=004B stack at SP=0x00F2, but `0053:0FE3`
   switches to SP=0x42B0 and re-enters `0340` with PE=1. The contract is the
   SS=004B frame (return to `0B85`), not the DS:0x0F0 copy. **R7 pass 12:**
   forcing PE=0/SS=004B/SP=0x00F2 at `0340` makes the guest exit at step
   75,238 (no KRNL286), so `0340` is PM code; the guest setup is inconsistent
   with PM null-selector semantics. **R7 pass 13:** disassembly confirms
   `0B9A` pushes the outer 0C13 frame on SS=004B, `148F` starts a nested
   0x42B0 stack and never uses it, and GDT[0] is null; selector 0x18 is the
   only real-mode alias. **R7 pass 14:** GDT dumps at `148F`/`0340`/`0367`
   are identical: `GDTR=0x110800/0x011F`, `GDT[0]=0000 0000 0000 0000`,
   `GDT[0x18]=FFFF 0000 F200 0000`. No `B8 18 00`/`8E C0 18` patch exists;
   GDT[0] is correctly null. Next: why the real-mode handler copy is invoked
   in PM. **R7 pass 15:** `--cpu 386` EXECs WIN386.EXE (not DOSX/KRNL386) and
   first faults at `1110:5A66` (unhandled INT 05, zero IVT, IP in ASCII
   data); `--cpu 386 --force286` faults with unhandled INT3 at `0000:0085`.
   **R7 pass 16:** 286 reset path implemented: zero LIDT -> triple
   fault/reset, CMOS 09h SHUT9 (SS:SP/BDA, POP DS/ES/POPA/RETF 2, A20 off),
   0Ah SHUTA (BDA CS:IP, A20 preserved), MOV CR0/DR gated to 386. DOSX EXECs
   KRNL286.EXE (71,730 bytes). **R7 pass 17:** VERR/VERW fixed; DOSX's API
   0x0A alias creation succeeds, KRNL286's `CS:0x30=02E7` and `CS:0x32=009B`
   are initialized, and the old `02EF:1CFE` DS=0 fault is gone. **R7 pass
   18:** outer-privilege `RETF`/`RETF imm16` implemented; the `0070`
   dispatcher's ring0->ring3 frame now restores `027F:01F8` before `148F`,
   and the 16-bit call-gate frame is IP/CS/oldSP/oldSS/params (no FLAGS).
   The `14E1` epilogue IRETs to KRNL286 at `02EF:9A19`. Next fault
   `02EF:728C` (`#GP: es selector FB00`, PE=1) from `MOV ES,[BP-4]` with
   `[BP-4]=FB00`.
   The 386 branch is WIN386 enhanced mode, not the R7 KRNL386 target.
2. **DOS extender + kernel:** real `DOSX.EXE` + `KRNL286.EXE` -> USER/GDI 3.1;
   SHELL/COMMDLG/TOOLHELP (not in 3.0a), WIN87EM, VGA/MOUSE/KEYBOARD drivers,
   3.1 SETUP.INF profile.
3. **Memory:** XMS/HIMEM/A20, EMS 4.0 (LIM), selector global heap, per-instance
   DGROUP, discardable/demand segments, multi-MB swap VFS. `INT 67h` currently
   reports "not installed"; no XMS.
4. **Loader:** keep NE header/entry/import parsing; rebuild selector fixups,
   per-instance DGROUP and demand loading. Current eager loader is 640K-limited.
5. **Interrupts/timer/PIC:** rebuild IDT delivery, ring transitions and fault
   frames; keep the 8086 shadow/flag lessons.
6. **Audio/peripherals:** SOUND.DRV/COMM.DRV are packed but no audio/serial/
   printer backend is verified; add Sound Blaster/AdLib-class audio, UART/COMM,
   printer and joystick after Standard mode is stable (mark untested).

**Reuse:** 8086 semantics/flags, `Memory`, `Vfs`, VGA/planar/dirty rects, DOS
file/handle/console, 8042/PS2 input, Roblox window/sink, NE header parsing,
`app_harness` methodology.

**Rebuild:** CPU protected state and exceptions, interrupt delivery, segment
limits/translation, XMS/EMS/selector heap, NE segment allocation/fixups/demand
loading, PM EXEC/PSP, DOS extender interface, driver/device model, PM timer/PIC.
386 Enhanced mode (paging, V86, VMM/VxD, DPMI) is later.

## Cost control

- Prefer `app_harness boot <APP>` over a Studio boot or the whole matrix; one
  app, one question, `--steps` just large enough.
- Reuse `tools/out/*.png`/`*.log` and `docs/screenshots/*`; don't regenerate
  evidence a report or source already answers.
- `grep` before `read`, use `offset`/`limit`; read `HANDOFF.md` sections 3-6
  first. Run `tools/run.lua` for tests, the full `check.lua` only before commit.
- Skip `pack_winboot` unless staged media/INI/group generation changed; skip
  Studio deploy unless core/client/UI changed. Keep subagent tasks bounded:
  explicit files, one hypothesis, one command, a written expected result.
