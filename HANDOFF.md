# HANDOFF — RVDM (8086 DOS machine → Windows 3.0a in Roblox)

Resume here after context compression. Everything below is verified state as
of the R5 Program Manager pass: all 20 SETUP.INF applications render, the 8042
keyboard and 1:1 PS/2 pointer work, and `lune run tools/check.lua` passes with
430 assertions.

## 0. Hard rules

1. **Luau has no native bitwise operators** (`& | ~ << >>` do not parse).
   Use `bit32` with local aliases (`const band, bor, lshift, rshift = ...`).
   Verified against `luau-compile` and Lune 0.11.1.
2. **`const` is available** (Luau 0.711+) and is the default for bindings that
   are never reassigned. `local` only when the binding changes.
3. **Core is environment-pure** (`core/`): no `require`, no `game`, no
   `print`/`warn`, no filesystem. Dependencies arrive via `Machine.new(deps)`.
   Host diagnostics go through `machine:log()` (→ `machine.diagnostics`).
4. **Naming:** modules/types `PascalCase`, functions/methods/locals
   `camelCase`, constants `SCREAMING_SNAKE_CASE`, module files
   `PascalCase.lua`, tools `snake_case.lua`, Roblox entry points
   `Name.client.lua`, tests `PascalCaseTests.lua`.
5. **Types:** `--!strict` in `core/` (typed public APIs everywhere). Roblox
   UI and tools are `--!nonstrict` because `luau-analyze` has no Roblox type
   definitions; their public APIs are still annotated.
6. Roblox work runs **client-side**; server only for future media/HttpService.
7. UI work gets an independent agent QA pass before shipping.
8. A style commit must leave `tools/check.lua` green and change no behaviour.

## 1. Environment

- Repo at `irl/RVDM` (git). Lune 0.11.1 at `tools/bin/lune.exe`.
- Toolchain: `tools/bin/stylua.exe` 2.6.0, `selene.exe` 0.32.0,
  `luau-analyze.exe`/`luau-compile.exe` 0.745. `rokit.toml` pins them for CI.
- Run gates: `lune run tools/check.lua`
  (format → lint luau → lint roblox → strict typecheck → tests).
- Windows 3.0a media staged under `media/win30/` (git-ignored; WinWorld 3.0a
  5.25" 1.2MB, SZDD-decompressed). Not committed.
- Studio MCP bridge: `node tools/mcp.mjs call <tool> <json>` /
  `callfile <tool> <argsFile>`. **execute_luau payloads must contain NO
  backslashes**; sources go base64 via `tools/studio_deploy.lua`.

## 2. Layout

```
core/           Memory Cpu Vfs Bios Dos TextScreen Executables Machine Vga init
fixtures/       Apps (generated), Kernel16, TestApps
roblox/ui/      Theme Cleaner State Components Window init (VdmUi)
roblox/client/  Emulator.client.lua ScreenSink
tests/          CpuTests MachineTests
tools/          run check build_rbxmx studio_deploy install stage extract ...
```

## 3. What works (verified)

- **CPU:** full 8086 real mode, strict-typed. `CMP` (group 1 /7) now produces
  subtraction flags - it previously fell through to XOR, which silently broke
  every `cmp/jb` in KERNEL and caused the fake AH=48 retry loop. Signed
  `JL/JGE/JLE/JG` now compare SF/OF as booleans; comparing the mask values
  (0x80 vs 0x800) inverted the condition when both flags were set and stalled
  GDI's empty-clip path.
- **DOS arena:** first-fit MCB chain with split/merge/resize, 1-paragraph MCB
  gaps, zero-size allocations succeed at `arenaTop`. `dosBrk` is gone.
- **DOS data area** at segment `0x0060`: 59-byte SFT with three `CON` entries
  (stdin/out/err), list of lists at `AH=52` → `BX = LoL+2`, one DPB, a CON
  device header, InDOS byte. Windows locates the SFT by finding three equally
  spaced `CON ` names.
- **NE loader:** real KERNEL/GDI/USER + 6 drivers load (`tools/load_real.lua`,
  9 modules, imports resolved). Iterated segments, chained fixups, entry
  tables, import-by-name/ordinal, and resident + non-resident export names are
  handled (CALC/PBRUSH static loads pass; commit `e1decc0`). WRITE's 79
  segments still need demand loading.
- **App staging/harness:** `tools/install.lua` stages 164 VFS files including
  `[shell]`/`[win.apps]`, fonts, generated program groups and shell settings;
  `tools/app_harness.lua` boots the real media, statically NE-loads every
  built-in, traces DOS/INT 2F and writes PNG screenshots. **All 20 SETUP.INF
  applications** launch and render, including Solitaire, Terminal,
  Clipboard, PIF Editor, Recorder, Print Manager and MS-DOS Executive. Its
  file list and File Manager's tree both use the real DOS FindFirst DTA
  layout (attr at 15h, size at 1Ah, name at 1Eh). Matrix + screenshots:
  `docs/APP_COMPAT.md`.
- **Bound MZ+NE EXEC:** `KERNEL.EXE` is mapped flat by the MZ stub at
  `loadSeg - cparhdr`; `Dos.FN[0x4B]` now applies the NE relocations in place
  before the stub jumps to the entry point.
- **WIN.COM boot → Program Manager:** with `timerInterval=55_000`, `WIN.COM`
  shrinks itself (AH=4A), EXECs KERNEL, validates DOS 5.0 / SFT / LoL /
  arena, self-relocates, loads SYSTEM.DRV/KEYBOARD.DRV/MOUSE.DRV,
  DISPLAY.DRV/VGA.DRV and the VGA fonts, loads real GDI.EXE and USER.EXE,
  reads SYSTEM.INI/WIN.INI/PROGMAN.INI, loads the `[boot] shell` and renders
  the real Program Manager window (640x480, File/Options/Window/Help).
  `tools/out/clean55k-win.png` is the verified Lune screenshot.
- **Environment:** WIN.COM keeps `windir=C:\WINDOWS\` (it joins KERNEL.EXE
  directly), but children inherit `windir=C:\WINDOWS` without the trailing
  separator; KERNEL's profile code appends its own, so the old double
  backslash silently made SYSTEM.INI lookups fall back to defaults. `PATH`
  is `C:\WINDOWS;C:\WINDOWS\SYSTEM`, so WIN87EM.DLL and other SYSTEM DLLs
  resolve.
- **Timer/PIC:** the 8259A in-service bit, OCW2 EOI, OCW1 mask and the 8086
  one-instruction STI/POPF/IRET shadow are modelled. The BIOS EOI stub
  preserves AX; `MOV AL,20h` alone silently corrupted GDI HDCs. The
  diagnostic 25k PIT fires faster than real 18.2 Hz and trips KERNEL's
  reentrancy guards (`fatal 0x140`); guest boots must use 55k.
  `app_harness --timer N` selects the interval.
- **Input:** an 8042-style keyboard controller latches set-1 make/break codes
  on port 0x60, reports OBF on 0x64, and raises IRQ1. BIOS INT 9 acknowledges
  the PIC and returns the latched byte for chained handlers; KEYBOARD.DRV does
  the actual translation. The Roblox client maps KeyCodes to scan codes, sends
  releases, repeats held keys at 20 cps, and releases everything on focus loss.
  MOUSE.DRV's PS/2 path moves two screen pixels per count, so `setMouse` sends
  half-counts with a remainder to keep the guest cursor under the host pointer.
- **Harness:** `app_harness` no longer treats HLT as "exited"; it resumes
  idle Windows loops on the next PIT tick and only stops on a keyboard wait
  or a DOS exit.
- **INT flags:** DOS/BIOS handler CF/ZF now reach the guest (inline dispatch
  while a vector still points at the emulator stub), so `jc/jnc` after INT 21h
  is trustworthy.
- **Bound NE low area:** EXEC reserves the image plus a second image-sized area
  plus 0x1000 paragraphs below it. KERNEL's self-relocation segments, local
  heap and stack no longer collide (the old overlap made a KEYBOARD.DRV read
  overwrite the stack and AnsiUpper's own code).
- **Bound NE:** the MZ image is loaded high in the EXEC block
  (`imageBase = pspSeg + programParas - imageParas`) and the eager
  `relocateBoundNE` pass is gone; KERNEL's own chained-fixup pass runs with
  intact chains.
- **DOS EXEC layout:** `AH=4B` now allocates a fresh 0x40-paragraph
  environment block and a fresh program block (PSP + actual image), sets MCB
  owner = child PSP, sets `PSP:2` to the top of the program block, copies the
  parent environment, and relocates a bound NE at `pspSeg + 0x10`.
- **INT 67h:** EMM is reported as "not installed" (`AH=84h; IRET`).
- **CPU:** `CMP r8,r/m8` and `CMP r16,r/m16` (0x38/0x39 family) no longer write
  the result back to the destination register. This clobber was corrupting
  KERNEL's path parser character by character.
- **Environment trailer:** the PSP environment ends with `00 00`, a word count
  (1), and the program's full path. KERNEL opens that path after the double
  NUL; without it it tried to open the string `dir=`.
- **EXEC arena reservation:** `AH=4B` now marks the PSP + loaded image as owned
  in the MCB arena. Previously KERNEL's first `AH=48` returned 0x1100, which
  overlapped its own code segment at 0x1124.
- **DOS:** `AH=43` (get/set attributes) and `AH=57` (file date/time) added.
- **VGA:** `core/Vga.lua` implements mode 12h (640x480x16 planar), mode 13h,
  text-mode fallback, write modes 0/1/2, read map select, DAC/palette, dirty
  rectangles, and RGBA snapshots. It is wired into `Memory` (A0000 aperture),
  CPU ports `0x3B0..0x3DF`, `Bios` INT 10h (mode set/get, display combination),
  and the client `VgaSink` (`EditableImage`). Studio-verified: `mode=12
  size=640x480 BDA=12/80` and the 16-colour test pattern renders in the
  Roblox window.
- **Roblox:** Vdm + VdmUi + VdmFixtures client-side; NE4 renders in a themed
  window; keyboard sends 8042 set-1 make/break scan codes (with typematic
  repeat); guest faults are caught per frame.
  Studio smoke tested in Place1: NE4 fixture works, and the real
  WIN.COM → KERNEL chain boots in the same window via the generated
  `fixtures/WinBoot*.lua` modules (`ReplicatedStorage` attribute
  `VdmBootWindows`). Lune boots to Program Manager at 55k; Studio does too.
  The generated WinBoot set includes `PROGMAN.EXE`, `PROGMAN.INI` and the
  generated `MAIN.GRP`/`ACCESSOR.GRP`/`GAMES.GRP` (`WinBootGroups`), and
  reuses `Install.writeSystemIni`, so shell/group/network settings match
  Lune. Place B (placeId 111091505099004) renders Program Manager with the
  Main group and minimized Accessories/Games at ~39M steps
  (`docs/screenshots/r7-studio-program-manager.jpg`); the generated
  `WinBootBig` bundle now carries every built-in app executable, so group
  icons resolve instead of reporting "Cannot find file". The client requires
  `VdmUi.Cleaner`/`VdmUi.Window` directly; requiring `VdmUi` first and then a
  child trips Roblox's "tables cannot be cyclic" check.
  **New Studio places need `Game Settings > Security > Allow Mesh / Image
  APIs` enabled** or `EditableImage` creation fails and VgaSink falls back to
  its coarse 32x24 frame grid. Place B has that setting plus
  `Allow HTTP Requests` enabled.
- **GUI rendering:** the VGA framebuffer → `EditableImage` sink is
  authoritative. A native 1:1 ScreenGui mapping was prototyped and rejected:
  USER/GDI paint into device contexts, and owner-draw/custom controls/bitmap
  fonts/clipping/BitBlt cannot map without reimplementing the GUI. See
  `roblox/gui/FEASIBILITY.md`; `Win3Skin` is for an optional emulator host
  skin only, never guest UI.
- **Fixture GlobalAlloc** now reads `(flags, sizeHigh, sizeLow)` correctly
  (was allocating one paragraph by accident).

## 4. Resume steps

1. **No current boot blocker.** The plain 55k boot reaches Program Manager
   with no fault, idle in KERNEL/USER (`1111:19E5` / `24F3:4A6E`), and renders
   the complete Main, Accessories and Games groups
   (`docs/screenshots/r5-progman-groups.jpg`). Place B reaches the same state
   around 39M steps (`docs/screenshots/r7-studio-program-manager.jpg`), and
   all 20 SETUP.INF apps render through the harness.
   The earlier `1111:007B` fault was an intermediate group-WIP/timing state
   and does not reproduce on either the current 164-file install or HEAD's
   161-file install. Its mechanism, if it recurs, is KERNEL's INT 21h DS cache
   word `1111:02DA` becoming zero: `19DF` loads DS=0, the dispatch table
   read yields a zero handler, and `ret` lands at `1111:0000`; use
   `tools/probe_next_dswatch.lua` to name the writer.
   **Resolved red herring:** the old GDI `0000:2B4E`/`ADDATOM` fault was a
   null HDC caused by the BIOS timer stub's `MOV AL,20h` clobbering AX; the
   guest loader resolved `KERNEL.ADDATOM` correctly. See commit `da4c1a2`.
2. **Timer-rate sensitivity.** `timerInterval=25_000` trips KERNEL's
   critical-section reentry guard (`fatal 0x140`, `1111:64D6`); CALC then
   shows "System Error — Terminating current application". Use
   `--timer 55000` for every guest-code run and treat 25k results as
   diagnostic only.
3. **CALC (works).** `PATH` includes `C:\WINDOWS\SYSTEM`, so `WIN87EM.DLL`
   opens instead of "Change Disk". After the timer EOI and signed-Jcc fixes,
   CALC loads, runs and paints its complete Calculator window
   (`tools/out/raster-jccfix-calc.png`). The only cosmetic issue is a few
   green stripes in the leftmost button icons; investigate the embedded icon
   planes if it matters.
4. **Program groups (works).** `tools/install.lua` + `tools/win_group.lua`
   generate `MAIN.GRP`/`ACCESSOR.GRP`/`GAMES.GRP` from SETUP.INF, embed real
   NE icons and list the full `C:\WINDOWS\*.GRP` paths in `PROGMAN.INI`. The
   164-file install opens/reads all three group files and Program Manager
   draws Main (File Manager, Control Panel, Print Manager, Clipboard, Setup,
   Read Me) with Accessories/Games minimized.
5. **WRITE (works).** The "Insufficient memory" dialog was a false report:
   `INT 21h AH=47` returned with `AL` still `'A'` from the caller, WRITE's path
   helper scans for the NUL terminator using `AL`, wrapped the segment and took
   its startup-error path. DOS returns `AX=0x0100` (AH=1, AL=0); fixed in
   `core/Dos.lua`. WRITE now renders its full window
   (`tools/out/write-fix-write.png`). The heap was never exhausted (~375 KB
   free), so the AH=4B reservation is not the problem. The host static loader
   still cannot eagerly map WRITE's 79 segments; the live KERNEL path
   demand-loads only the preloaded ones.
6. **CALENDAR / REVERSI / CLOCK (work).** CALENDAR/REVERSI were failing on
   `USER.LoadBitmap`/`LoadCursor` for VGA.DRV resources above 64K: a child PSP
   closed inherited JFT handles that KERNEL still owned. `AH=3E` now keeps the
   owner's handle when a different PSP closes the shared entry. CLOCK spun in
   its wait-for-second-change loop because `INT 21h AH=2C` was frozen at noon;
   it now advances from the BDA tick. All three render at 20M steps.
7. **Mouse/keyboard (done).** PS/2 INT 15h/C2xx, IRQ12/C207 delivery and the
   Roblox pointer mapping are complete. MOUSE.DRV moves two pixels per PS/2
   count, so `Machine.setMouse` sends half-counts with a remainder and tracks
   the host pointer 1:1. The 8042 keyboard controller latches port 0x60
   make/break codes, raises IRQ1, and chains to a real BIOS INT 9 stub.
   Verified in Lune: Program Manager File menu via mouse, Notepad
   `hello world` + `Hello, World!` via keyboard, Shift, typematic repeat,
   Alt+F menu, and Calculator `1 + 2 = 3` via keyboard. Studio Play also
   opens the Program Manager File menu from host Alt+F
   (`docs/screenshots/r6-studio-keyboard.jpg`).
8. **R5 (done):** kernel `LoadModule`/`TaskDB`, real Program Manager with
   Main/Accessories/Games groups, all 20 SETUP.INF apps, and keyboard/mouse
   input. Remaining polish: icon-plane colour artifacts and group-label
   spacing.
9. **R6 (real mode):** Windows 3.0 app matrix; **PhotoStyler 1.1a** is the
   "Photoshop-class" flagship (24-bit, masks, filters, scanner input; tested in
   Windows 3.0a real mode). Add EMS, mouse and multi-MB scratch-disk support.
   Paintbrush/PC Paintbrush are fallbacks. See `docs/PHOTOSHOP.md`.
10. **R7+ (separate track):** 386 ISA + 286 protected mode + Windows 3.1
   **Standard mode** (DOSX/KRNL286, XMS, WIN87EM) if the project leaves real
   mode. Photoshop 2.5 is the north star; it is a 16-bit NE app that works in
   3.1 Standard mode. 386 Enhanced mode (paging/V86/VMM/VxD) is later.

## 5. Known deviations (workarounds, not faked output)

The guest runs genuine Microsoft binaries; nothing below hardcodes a success
message or skips guest code. These are emulator accommodations/partials:

- **EXEC load-high:** `AH=4B` reserves the image, a second image-sized low
  area for a bound NE's self-relocated segments, and `0x1000` paragraphs of
  heap, then places the MZ image at the top. Real DOS loads at PSP+0x10 and
  gives the program the largest block; this workaround keeps KERNEL's
  self-loader, stack and heap apart. It should be replaced with a faithful
  layout once the kernel's memory model is understood.
- **File attributes/timestamps:** `AH=43` reports archive/directory
  attributes; `AH=57` returns a fixed 1990-01-01 12:00. No real attribute or
  timestamp model yet.
- **VFS:** a partial `SETUP.INF` install, not a full Windows setup. Missing
  files surface as real DOS errors.
- **Studio boot bundle:** `tools/pack_winboot.lua` packs WIN.COM/KERNEL,
  drivers/fonts, the generated groups and all 20 built-in app executables into
  `fixtures/WinBoot*.lua` (git-ignored). It also carries SETUP.EXE/SETUP.INF,
  README.TXT, WINVER.EXE, DIGITAL.FON and CONTROL.INI so the non-DOS Main-group
  items resolve. `COMMAND.COM` is not on the Windows media, so the DOS Prompt
  item still reports "Cannot find file" by design.
- **Display:** text mode uses the text sink; graphics modes switch the client to
  `VgaSink`/`EditableImage`. VGA.DRV paints the real Program Manager desktop in
  Lune (`tools/out/clean55k-win.png`) and Studio
  (`docs/screenshots/r7-studio-program-manager.jpg`). NE4/KERNEL output is real
  guest output, not a mock.
- **Hardware:** INT 67h reports no EMS; no XMS yet. The 8042 keyboard and 1:1
  PS/2 mouse are implemented. IRQ0 is
  instruction-counted (`config.timerInterval`, default 55k ≈ 18.2 Hz at ~1M
  instr/sec), not wall-clock PIT timing. The app harness's old 25k default is
  diagnostic only and trips KERNEL's reentrancy guards; use `--timer 55000`.
- **DOS:** `AH=4B` AL=3 overlays and some lesser INT 21h calls are still
  unimplemented and fail loudly.
- The old `C:\WINDOWSKERNEL.EXE` duplicate path workaround is gone. WIN.COM
  needs the trailing `windir` separator; child environments are normalized to
  drop it before KERNEL's profile code appends its own.

## 6. Lessons (do not re-learn)

- Register table `r[1..8] = AX CX DX BX SP BP SI DI`; **`r[5]` is SP**;
  `cpu:wr(n)` is 0-indexed (`wr(3)=BX`, `wr(4)=SP`); `cpu:wb(n)` is
  `AL CL DL BL AH CH DH BH`, so AH is `wb(4)`, not `wb(1)`.
- Signed Jcc compares `SF ~= 0` vs `OF ~= 0`, never `band(flags,SF)` vs
  `band(flags,OF)`: the mask values 0x80 and 0x800 are unequal even when both
  flags are set.
- INT 21/10/16 handler flags must reach the guest. The emulated IVT stubs
  dispatch inline while they still point at the stub; never let the stub's
  IRET restore the pre-call flags (DOS reports errors via CF).
- Studio: the `core` deploy chunk updates child ModuleScripts but not the
  `Vdm` root's `init.lua` Source; run `studio_deploy.lua reinit` after editing
  `core/init.lua`, then redeploy the tree.
- DOS AH=47h returns cwd WITHOUT drive, WITH trailing backslash.
- WIN.COM scans the environment for lowercase `windir=` and joins the value
  directly with `kernel.exe` — the value needs the trailing backslash.
  Children (KERNEL and below) must get it WITHOUT the slash: KERNEL's profile
  code appends its own, and a doubled slash silently reverts every
  SYSTEM.INI lookup to defaults.
- `PATH` must include `C:\WINDOWS\SYSTEM`; the real-mode loader finds
  WIN87EM.DLL and friends through it.
- INT 8 (IRQ0) must never fire inside the `0xF100` stub region.
- The BIOS INT 8 EOI stub must preserve AX (push/pop). The guest KERNEL ISR
  chains to it with live caller results; clobbering AL turned a valid GDI HDC
  into a null handle and produced a misleading `0000:842C` fault.
- HLT is an idle wait, not an exit. A harness that stops on `cpu.halted` will
  freeze Windows at its idle loop; `run()` wakes it on the next PIT tick.
- `timerInterval=25_000` is a diagnostic accelerator, not a faithful PIT:
  it fires early enough to hit KERNEL's critical-section reentry guard
  (fatal 0x140). Guest-code runs use 55k.
- Windows-internal INT 21h probes (`AH >= B0`) fail gracefully; never abort.
- MCB chain invariant: `next.start == prev.start + prev.size + 1`; allocations
  split with a one-paragraph MCB gap.
- SFT entry stride is 59 bytes; the `CON` name sits at entry+0x1E; AH=52's
  pointer is the first-DPB field (`[BX-2]` MCB, `[BX+4]` SFT, `[BX+22h]` NUL).
- Bound NE: the MZ stub maps the whole file at `CS-0x20` and jumps to the NE
  entry; relocations are the loader's job.
- Pascal argument convention: first argument at `SS:SP+6`; a far pointer word
  order is offset then segment; `GlobalAlloc` reads flags, sizeHigh, sizeLow.
- Lune: `process.exec(program, params, options)`; `process.args` is a table.
- Lune heredocs via bash mangle backslashes — use the Write tool.
- Studio: string-path requires (`./`, `@self`) disabled in this build; use
  service roots and index modules. `SurfaceGui.AlwaysOnSurface` no longer
  exists. `get_console_output` can lag — verify with fresh probes.
- `EditableImage:WritePixelsBuffer` requires the buffer length to be exactly
  `regionWidth * regionHeight * 4`. Reusing a larger dirty-region buffer
  silently fails; VgaSink resizes on any length mismatch.
- `tools/pack_winboot.lua` must use the same INI rules as
  `Install.writeSystemIni`; otherwise the Studio boot has an empty shell or
  the NETWORK.DRV fallback. It now calls the install helper through a tiny
  fake VFS. Include `PROGMAN.EXE` (WinBootApps) or KERNEL exits after USER.
- The Studio boot also needs every group target in the VFS. `WinBootBig`
  carries CALC, WINFILE, NOTEPAD, MSDOS and the rest of the built-in fleet;
  packing only PROGMAN.EXE makes every group icon report "Cannot find file".

## 7. Style/tooling

- `STYLE.md` is the contract; `stylua.toml`, `selene.toml`,
  `selene_roblox.toml`, `rokit.toml` enforce it.
- `lune run tools/check.lua` runs every gate locally and in CI
  (`.github/workflows/ci.yml`).
- Generated artifacts are ignored: `Vdm.rbxmx`, `tools/deploy_args.json`,
  `tools/memdump.bin`, `media/`, `tools/bin/`.
