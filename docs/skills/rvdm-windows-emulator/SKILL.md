---
name: rvdm-windows-emulator
description: Work on RVDM, the Luau 8086 PC and Windows 3.0a real-mode emulator that runs the genuine WIN.COM -> KERNEL -> USER/GDI -> Program Manager boot inside a Roblox window. Use when the task mentions RVDM, "Windows 3.0 in Roblox", "the Windows emulator", WIN.COM/KERNEL/USER/GDI, Program Manager, SETUP.INF app compatibility, Tetris 2.0, VGA mode 12h, EditableImage/VgaSink, app_harness, WinBoot, check.lua, pack_winboot, studio_deploy, Vdm.rbxmx, a guest CS:IP fault, or planning Windows 3.1 Standard mode (286 protected mode, DOSX/KRNL286, XMS/EMS). Trigger even for casual references to "the emulator" in this repo.
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
- **Tetris 2.0 runs**: `TETRIS.EXE` + `ABOUTTET.DLL`, opening
  `SYSTEM\WIN87EM.DLL`, `TETRIS.INI`, `TETRIS.HST`; mode 12h output.
- **459 assertions** is the current test count:
  `lune run tools/run.lua` prints `passed assertions: 459` and
  `ALL TESTS PASSED`. HANDOFF/README say 430; that number is stale.
- Known limits: 640K real-mode wall (WRITE's 79 segments need demand loading);
  no EMS/XMS; no DOS `COMMAND.COM`; `AH=4B AL=3` overlays unimplemented;
  fixed file attributes/timestamps; cosmetic icon-plane colour and group-label
  spacing issues; instruction-counted timer, not wall-clock PIT.

## File map

| Path | Purpose |
| --- | --- |
| `core/Cpu.lua` | 8086 real-mode CPU, flags, interrupts, HLT/STI/POPF/IRET shadow |
| `core/Memory.lua` | 1 MB address space, A0000 VGA aperture wiring |
| `core/Vfs.lua` | In-memory DOS filesystem and path handling |
| `core/Bios.lua` | INT 10h/16h/9/8 glue, console text |
| `core/Dos.lua` | INT 21h subset, PSP, MCB arena, SFT/LoL, DTA/FindFirst, EXEC |
| `core/Executables.lua` | COM/MZ/NE/bound-NE loaders, PSP, relocations, env block |
| `core/Machine.lua` | Wiring, `Machine.new(deps)`, run loop, PIC, keyboard, mouse, timer |
| `core/Vga.lua` | Mode 12h/13h/text, planar/linear render, palette, dirty rects |
| `core/TextScreen.lua` | 80x25 text sink |
| `core/init.lua` | Roblox-facing module index (not part of the strict core gate) |
| `fixtures/` | Generated apps, `Kernel16`, `TestApps`, `WinBoot*.lua` (ignored) |
| `roblox/ui/` | `Theme`, `Cleaner`, `State`, `Components`, `Window`, `init` (VdmUi) |
| `roblox/client/` | `Emulator.client.lua`, `ScreenSink`, `VgaSink`, `KeyboardMap` |
| `tests/` | `CpuTests`, `MachineTests`, `DosTests`, `GroupFileTests` |
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
| WRITE "Insufficient memory" false alarm | `AH=47` must return `AX=0x0100` (AH=1, AL=0); leaving AL as the caller's `'A'` breaks its NUL scan. |
| VGA repaints are slow | Use `Vga:consumeDirty()` + `snapshotRegionRGBA` + `VgaSink:UpdateRegionRGBA`; a full 640x480 RGBA upload is 1,228,800 bytes. |
| `WritePixelsBuffer` silently fails | Its buffer length must equal `regionWidth * regionHeight * 4` exactly; `VgaSink` resizes `regionBuffer` on any mismatch. |
| Studio boot empty shell / group icons "Cannot find file" | `pack_winboot` must use `Install.writeSystemIni`; include `PROGMAN.EXE` (WinBootApps) and every group target (`WinBootBig`), or KERNEL exits after USER / icons cannot resolve. |
| Studio `core` deploy misses `Vdm` root source | `execute_luau` chunk updates children only; run `studio_deploy.lua reinit`, then redeploy the tree. |

### CPU/DOS indexing facts

- `r[1..8] = AX CX DX BX SP BP SI DI`; `r[5]` is SP. `cpu:wr(3)=BX`,
  `wr(4)=SP`; `cpu:wb(0..7) = AL CL DL BL AH CH DH BH`, so AH is `wb(4)`.
- Pascal first arg at `SS:SP+6`; far pointer = offset then segment;
  `GlobalAlloc` reads `(flags, sizeHigh, sizeLow)`.
- Never fire INT 8 inside `0xF100`; DOS/BIOS CF must survive the stub.

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
   before building a full 386 core.
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
