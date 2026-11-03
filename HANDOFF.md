# HANDOFF — RVDM (8086 DOS machine → Windows 3.0a in Roblox)

Resume here after context compression. Everything below is verified state as
of the R7 pass: all 20 SETUP.INF applications still render in Windows 3.0a,
Microsoft Tetris 2.0 is playable, the 8042 keyboard and 1:1 PS/2 pointer work
with a single visible cursor, PC speaker output is wired, Windows 3.1's WIN.CNF
now reaches DOSX, enters protected mode, completes the ring-3 handoff, the
first ring-3→ring-0 call gate, IDT-delivered INT3, the compact real-callback
IDT selection and the clear-PE switch helper, and `lune run tools/check.lua`
passes with 661 assertions.

## Current state (2026-11-03, R7)

- `main` is one clean commit (`windows 3.0a in roblox`); the old graph lives
  only in the local `backup-before-squash` tag. Releases: `v0.6.1` (latest)
  with `Vdm.rbxmx` and `Vdm-demo.rbxlx`; `v0.6.0` is the first cut.
- **Microsoft Tetris 2.0 is playable.** It stages under
  `media/win30/staged/tetris`, queues through `WIN.INI [windows] run=`, dismisses
  the About box, starts via Game > New, and renders falling/stacked pieces in
  the board. The earlier blank board was not a GDI/VGA blit bug: Windows was
  running with interrupts disabled at idle, so no WM_TIMER reached Tetris.
  `docs/screenshots/r6-tetris.png` is the verified 640x480 board.
- **Timer/IF fix (root cause):** `Cpu.interrupt`'s inline chained-stub path
  wrote the handler's cleared IF into the caller's saved flags, so an INT 2Fh
  chain left the guest with interrupts off. It now preserves the saved IF and
  only propagates the handler's result flags. The keyboard and mouse IRQ
  dispatchers also honour IF, because a maskable IRQ taken during a critical
  section saves IF=0 and the handler's IRET would never re-enable interrupts.
- **Cursor fix:** the client polls the pointer every Heartbeat with the GUI
  inset (not just InputChanged), reads AbsolutePosition/Size fresh each frame,
  hides the host arrow for the whole VDM window, and re-anchors after a resize
  or clamp jump. In Studio it captures the pointer with
  `MouseBehavior.LockCurrentPosition` and drives the guest from GetMouseDelta;
  moving the virtual pointer out of the window releases it. PrintWindow shows a
  single guest cursor and the OK-button click test dismisses the About box.
- **PC speaker path:** the guest's 8254 channel 2 divisor (ports 0x43/0x42)
  and the 0x61 gate bits 0+1 are modelled. `Machine:speakerState()` exposes
  `{enabled, frequency, sequence}`; the client retriggers one short stock
  Roblox beep on an enable/frequency change and publishes `VdmSpeaker`.
  Tetris itself only writes 0x61 bit 7 (A20), so its sound is not yet driven;
  the path is covered by a guest I/O test and is ready for apps that use the
  PC speaker.
- **R7 Windows 3.1 progress (eighteenth pass):** `cpuLevel` is `"8086" | "286" |
  "386"` and defaults to 8086, so the 3.0a baseline is unchanged. With
  `cpuLevel="286"`, 4 MiB RAM and XMS, real `WIN.COM`/`WIN.CNF` passes the
  HIMEM/CPU probes, runs `WSWAP.EXE`, EXECs and EXEPACK-unpacks
  `SYSTEM\DOSX.EXE`, builds/copies its GDT, `LJMP 0078:0B0E` enters PM, and
  DOSX runs `LLDT 0x38`, `LTR 0x88`, then `IRET`s to `0x5B:0xB51` in ring 3.
  The ring-3 `lcall 0xCB,0` call gate enters ring 0 at `0078:0C5D` with
  SS0=0x68/SP0=0x30A8 and the nested frame at 0x309E.
- **LIDT/IDT selection:** `LIDT [DS:0x2A31]` at `0078:0C5D` reads six zero
  bytes (DS=0x4B/base 0x340D0); this is an uninitialised copy. The intended
  real-callback table is the compact 8-entry IDT at **liveBase+0x470 =
  0x110470, limit 0x3F**. Its vector 3 originally targets `0053:0FE3` (PM
  stub); the correct target is the clear-PE switch helper at `0078:0C63`.
  `loadTable` selects that compact IDT on an all-zero LIDT operand and
  patches vector 3 to `0078:0C63` as a present interrupt gate. IDTR becomes
  `base=0x110470 limit=0x003F`; later zero LIDTs from the helper keep it.
- PM interrupt/trap-gate delivery (types 6/7/E/F, DPL/present/type checks,
  TSS ring switch, IP/CS/FLAGS frame, optional error code, IF/TF semantics)
  remains in place; software INT/INT3 use the IDT and real-mode IVT is
  unchanged.
- **Switch helper (solved):** `0078:0C63` (CS base 0x38380, `CS:[0]=0x340D`)
  runs `PUSH DX; PUSH EAX` (`66 50` -> 32-bit push at 286);
  `MOV DX,CS:[0]`; `MOV EAX,CR0`; `AND AL,FE`; `LIDT [0x122]` (zero operand,
  compact IDT kept); `MOV CR0,EAX` -> **CR0=0, PE cleared**;
  `LJMP 3838:0C7D` reloads real CS (base 0x38380); then
  `MOV SS/DS/ES,0x340D; POP EAX; POP DX; RET`. `0078:0FE3` is a different
  routine: it ends in `POP DS`, which pops the INT3 frame's saved IP
  (0x0C63, the post-INT3 offset) and faults at `0078:0FF1`.
- **Frame dump at the second helper return (no fault):** 4M/8M complete
  cleanly; 4M PC=`3838:1C21`, 8M PC=`3838:34C2`, PE=0, selectors
  3838/340D/340D/340D. At 64M it is still in the loader loop (`3838:1C7F`).
  At `3838:0C86`, SS=340D base 0x340D0, SP=0x3098:
  `[0C63, 0078, 0046, 0C05, 005B, 0046, 3068, 004B]`.
  - INT3 frame at 0x3098: IP=`0C63`, CS=`0078`, FLAGS=`0046`.
  - Call-gate frame at 0x309E: IP=`0C05`, CS=`005B`, FLAGS=`0046`,
    oldSP=`3068`, oldSS=`004B`.
  - Helper push/pop widths are balanced (`PUSH DX` 2 + `PUSH EAX` 4;
    `POP EAX` 4 + `POP DX` 2). No push32/pop32 bug.
  - First near RET pops saved IP `0C63`; second near RET pops saved CS
    `0078` as IP, leaving FLAGS. The extra frame is the 3-word INT3 frame.
- **The real callback return is `3838:0C13`, not `0x7C`.** At DS:0x0F0
  (physical 0x341C0): `340D 0C13 3838 0046 ...`, a far return to
  `3838:0C13` with DS=0x340D. `0C13` restores the PIC/IVT
  (`CLI; XOR AX,AX; MOV ES,AX; ... OUT 0x21; ... OUT 0x70; RET`).
  `0x7C` is only the instruction after the initial `LJMP 0053:0004`.
  Diagnostic RET-target patches: `0C7C` exits at step 75,415 (no KRNL286);
  `0C13` continues (4M PM `005B:0B92`, 8M RM `3838:00CC`, 16M RM
  `3838:34C3`); `0C05` faults at `0000:0085`. The patches are not committed.
- **Handoff trace (gate53 diagnostic):** `005B:359B` self-copy runs with CS
  base `0x49190`, DS=`005B`, ES=`004B`, SI=`35EC`, DI=`789C`, CX=0; it copies
  `0x35EC` bytes from loader CS:0, patches GDT descriptors at ES:[0x58]/
  ES:[0x78], then `LJMP 005B:35BD`. Later `005B` CS base is `0x38380`: the
  loader is relocated from `0x49190` down to `0x38380`.
  - `005B:0C00` gate stack: `[0C05,005B,0046,oldSP,oldSS]`; DS:0x0F0 already
    holds `340D 0C13 3838 0046 35CF 2C70`.
  - `0053:0FE3` entry stack: `[0C63,0078,0046,0C05,005B,0046,oldSP,004B]`.
    `148F` adds `0FE6`, sets SS=`004B`/SP=`[0x100]` (`42B0`), then `14DC`
    `LJMP 005B:0340` with **PE=1**.
  - `005B:0340` calls `0B61`, which re-enters the 0C00 gate; the stack
    descends `42AC -> 412C -> 3FAC -> 3E2C ...`, then `005B:0367` sets ES=0
    and `005B:036B` faults at `005B:036F` reading IVT INT 91.
  - The `0C63` path breaks recursion by clearing PE, but its INT3 frame
    returns to `0x78` and never consumes the DS:0x0F0 `0C13` frame.
- **First-pass 286 callback (`[0x134]=2`, `[0x2F5A]=0`):**
  - `005B:0B9A` pushes `0C13/3838/0046` on the **SS=004B stack at
    SP=0x00F2**; `[0x2A3F]=0`, `[0x100]=0x42B0`.
  - `005B:0C00` gate stack:
    `[340D,340D,0078,35EC,4B00,00F2,340D,0003]`; gate frame old SS/SP
    `004B:00DE`.
  - `0053:0FE3` sets SS=`004B`/SP=`[0x100]` (`42B0`), discarding the 0x00F2
    frame; `14DC` enters `005B:0340` with **PE=1**.
  - `005B:0340` calls `0B61` again; `[0x134]=2` pushes another
    `0C13/3838/0046` frame at SP~0x42A4 and calls the gate again.
- **Contract decision:** `[0x134]=2` selects the **286 callback path**, whose
  frame is the SS=004B stack at SP~0x00F2 (`0C13/3838/0046`), not the DS:0x0F0
  data copy. However, the forced-entry experiment (temporary probe, not
  committed) set the first `005B:0340` entry to PE=0/SS=004B/SP=0x00F2: the
  guest **exits at step 75,238** (`exit=0`, no fault, no KRNL286 EXEC; final
  PC `00CB:F352`). `0340`'s `CALL 0B61` then runs the PM `LCALL 0xCB` path,
  so `0340` is PM code with a real-mode-style `ES=0` access, not a PE=0
  real-mode callback. GDT[0] is correctly null; selector 0x18 is the only
  real-mode alias, and the handler does not use it.
- **Disassembly comparison:** `0B92 PUSHF; 0B93 PUSH [0x148]; 0B97 PUSH
  0C13; 0B9A MOV AX,CS:[0]` pushes the outer `0C13/3838/0046` frame on the
  SS=004B stack at SP=0x00F2. `148F` instead sets DS/SS from `0053:[0]`
  (0x004B), `SP=[0x100]` (0x42B0), `[0x100] -= [0x2F6F]`, and jumps
  `005B:0340` with PE=1, starting a nested callback stack and never using
  the 0x00F2 frame. `0340` is PM code (`CALL 0B61` uses the PM gate). GDT[0]
  is null; only selector 0x18 is a base-0/limit-FFFF real-mode alias, but
  the handler uses ES=0. There is no consistent real-mode callback entry.
- **Evidence:** call-gate and INT3 frames are built correctly. The helper
  receives the INT3 stack frame; the outer callback frame is the SS=004B
  frame. `0053:0FE3` leaves PE=1 before `005B:0340`, so ES=0 faults. The
  guest setup is inconsistent with the emulator's PM null-selector
  semantics; do not patch the guest stack or special-case 0x78/0x7C/0C13.
- **GDT[0]/alias check:** at `0053:148F`, `005B:0340`, and `005B:0367` the
  dumps are identical: `GDTR=0x110800/0x011F`, `GDT[0]=0000 0000 0000 0000`
  (null), `GDT[0x18]=FFFF 0000 F200 0000` (limit 0xFFFF, base 0, data RW
  DPL3). No `B8 18 00`/`8E C0 18` code or runtime patch of the handler's
  `XOR AX,AX; MOV ES,AX` exists. Writes to the handler region at step 42000
  are the temporary IDT gate table; the 44000 self-copy restores the handler.
  GDT[0] writes are only XMS setup at 8000/42000. The GDT EMB copy keeps
  GDT[0] null and selector 0x18 as the alias.
- **286 reset path implemented (sixteenth pass):** on `cpuLevel=286`, zero
  `LIDT` loads IDTR=0/0, INT3 triple-faults and `Cpu:reset` runs; `MOV
  CR0`/`MOV DR` are `#UD` on 286. `Machine` models CMOS 0x70/0x71 and the
  PC/AT shutdown handlers: 09h restores BDA `0040:0069/0067` SS:SP, pops
  DS/ES/PUSHAW, `RETF 2` to `3838:0C13`, and disables A20; 0Ah jumps to the
  BDA CS:IP and preserves A20. The probe resets at step 44000 and then EXECs
  **`C:\WINDOWS\SYSTEM\KRNL286.EXE`**.
- **VERR/VERW fix (seventeenth pass):** `0F 00 /4` and `/5` used to set
  `ZF = (descriptor == nil)`, backwards for both instructions. DOSX's API
  `0x0A` alias creation at `0053:2C71` begins `MOV AX,BX; VERR AX`; KRNL286
  calls it with `BX=CS=02EF`, so the old VERR cleared ZF and the alias was
  never created. KRNL286's `MOV DS, CS:[0x30]` thunk at `02EF:2672` then
  produced DS=0 at `02EF:1CFE`. `Cpu` now implements VERR/VERW with
  present/S/type/DPL checks; null/absent/system selectors clear ZF without
  faulting. KRNL286's header is now initialized (`CS:0x30 = 02E7`,
  `CS:0x32 = 009B`), and the DS=0 fault is gone. At that point the next
  fault was `0053:14FB`, `#GP: es selector 0C05: absent or outside LDT
  limit`, PE=1, CS=0053, DS=02E7, ES=004B, SS=0068, CR0=1, last PC
  `3838:0AAB`. That was DOSX's callback epilogue `0053:14E1`
  (`POP DS; POP ES; IRET`); the ring-3 `LCALL 0xCB` at `005B:0C00` pushed a
  ring-0 call-gate frame at `0068:309E` over the `148F` helper's saved ES
  slot.
- **Callback frame fix (eighteenth pass):** the `0053:14FB` fault was the
  missing outer-privilege `RETF`, not just the call-gate frame. The `0070`
  dispatcher returns from ring 0 to ring 3 with
  `[IP=0E63, CS=0053, SP=01F8, SS=027F]` at `0068:309C`; our `RETF` popped
  only IP/CS, so `148F` ran on `0068:30A0` instead of `027F:01F8`.
  `RETF`/`RETF imm16` now pop SP and SS when the return CS.RPL is greater
  than CPL. The `148F` entry is now `SS=027F, SP=01F6`, top
  `[0E66, 9A19, 02EF, 0296, ...]`; the `14E1` frame is
  `[DS=02E7, ES=02DF, IP=9A19, CS=02EF, FLAGS=0296, ...]` and IRETs to
  KRNL286 at `02EF:9A19`. The 16-bit call-gate frame was also corrected to
  IP, CS, old SP, old SS, params (no FLAGS), matching the Intel 286 manual
  Figure 7-12 and 86Box. Probe now reaches step **144000**. Next fault:
  `02EF:728C`, `#GP: es selector FB00: absent or outside GDT limit`, from
  `MOV ES,[BP-4]` at `02EF:7289` with `[BP-4]=FB00`; PE=1, CS=02EF base
  `0x8FDB0`, DS=02EF, ES=03F7, SS=027F, SP=01B0, AX=FB00, BX=02EF,
  CX=B6CB, SI=0040, DI=B6CB, BP=01CC; last PC `0053:2197`.
- **PE transitions:** `Cpu:setPE` plus `MOV CR0`/`LMSW` clear paths are
  covered. Clearing PE makes subsequent `loadSeg` use `selector<<4` and limit
  FFFF; current CS/SS caches remain for the instruction stream, so the next
  far transfer reloads CS (286 hardware semantics).
- **Protected-mode segment caches + call gates:** `Cpu` keeps
  `segBase/segLimit/segAccess/segFlags/segSel` per segment. Real mode still
  translates `sel<<4` with limit FFFF; PM `loadSeg` reads the GDT/LDT, checks
  present/type/limit, and names the selector on `#GP`. Fetch, stack, ModRM,
  string/moffs/XLAT, far control transfers and IRET use the cached base.
  `farCall` decodes 286/386 call gates, validates DPL/target, switches to the
  TSS ring stack, copies gate parameters and builds the nested frame; outer
  IRET unwinds it. `LTR` caches the TSS base/limit and marks the descriptor
  busy.
- **XMS/HIMEM minimum:** `core/Xms.lua` owns INT 2Fh AX=4300/4310 and the far
  entry at F100:00C0, implementing version, A20, HMA request/release, free
  query, EMB allocate/free/lock/unlock/info and 0Bh moves. The 0Bh offset for
  handle 0 is a packed segment:offset, as the XMS spec requires; 09h returns
  the handle in DX. A20 starts enabled on 286+, and hypervisor stubs at
  F100:0000-0FFF are write-protected because WSWAP zero-fills free RAM.
- **Tetris score fields (open cosmetic):** `Score:`, `Level:` and `Lines:` draw
  red digits (VGA index 12) at x≈41, while their opaque black text backgrounds
  start at x≈51, one character cell to the right. The fills come from VGA.DRV
  PCs 0D87:1AE5/1DF7 after the glyph writes; the values are not black-on-black
  and the DAC/attribute palette is the normal EGA table. This is a
  GDI text-alignment/background-rect or child-window paint-order issue, not a
  simple palette swap; board/pieces are unaffected.
- Remaining for 3.0a: Tetris score/level/lines value backgrounds, EMS (XMS is
  now present but only enabled for `cpuLevel>=286`), Sound Blaster/AdLib (PC
  speaker path now exists), printing/serial, OLE/clipboard, installers. For
  3.1, descriptor caches, the ring-3 handoff, the first ring-3→ring-0 call
  gate, IDT-delivered INT3, the compact real-callback IDT selection and the
  clear-PE switch helper are done; the PM to real to PM round trip is green.
  The real callback frame is `3838:0C13` at DS:0x0F0 (not 0x7C); the
  call-gate/INT3 frames are correct, but `[0x134]=2` selects the 286 callback
  path whose frame is the SS=004B stack at SP~0x00F2, while `0053:0FE3`
  switches to SP=0x42B0 and runs `005B:0340` with PE=1. Forcing
  PE=0/SS=004B/SP=0x00F2 makes the guest exit at step 75,238 (no KRNL286),
  so `0340` is PM code. Disassembly shows `0B9A` pushes the outer 0C13 frame
  on the SS=004B stack, `148F` starts a nested 0x42B0 stack and never uses
  it, and GDT[0] is correctly null (selector 0x18 is the only real-mode
  alias). The 286 reset path is now implemented (see the dedicated bullet);
  DOSX reaches **KRNL286.EXE**. The KRNL286 DS=0 fault is fixed by correct
  VERR/VERW semantics, and the DOSX callback frame is fixed by outer-ring
  `RETF` plus the 286 call-gate frame layout. The next first fault is
  `02EF:728C` (`#GP: es selector FB00`, PE=1) from `MOV ES,[BP-4]` with
  `[BP-4]=FB00` after the `0053:2197` DOSX callback. The `--cpu 386` branch
  is WIN386 enhanced mode (EXECs WIN386.EXE, first blocker `1110:5A66`
  unhandled INT 05), not KRNL386, so R7 stays on the 286 path. 386 enhanced
  mode remains later.
- **Subsystem blockers (not implemented, exact):** printing has no LPT/PRN
  device, INT 17h, spooler or GDI `StartDoc`/`StartPage`/`EndDoc` backend;
  serial has no 8250 UART at 0x3F8-0x3FF/IRQ4, INT 14h or COMM.DRV backend;
  OLE/clipboard has no OLE1 server/client DLLs, render-format negotiation,
  bitmap/metafile clipboard formats or cross-process global heap; installers
  run from the staged VFS only, with no floppy/disk-change device,
  `COMMAND.COM`, `FORMAT` or multi-disk SETUP media source.

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
core/           Memory Cpu Vfs Bios Dos Xms TextScreen Executables Machine Vga init
fixtures/       Apps (generated), Kernel16, TestApps
roblox/ui/      Theme Cleaner State Components Window init (VdmUi)
roblox/client/  Emulator.client.lua ScreenSink
tests/          CpuTests PmCpuTests XmsTests MachineTests DosTests GroupFileTests
tools/          run check build_rbxmx studio_deploy install stage extract ...
```

## 3. What works (verified)

- **CPU:** full 8086 real mode, strict-typed. `CMP` (group 1 /7) now produces
  subtraction flags - it previously fell through to XOR, which silently broke
  every `cmp/jb` in KERNEL and caused the fake AH=48 retry loop. Signed
  `JL/JGE/JLE/JG` now compare SF/OF as booleans; comparing the mask values
  (0x80 vs 0x800) inverted the condition when both flags were set and stalled
  GDI's empty-clip path.
- **286/386 CPU level:** `cpuLevel` defaults to `"8086"`; `"286"` adds
  PUSHA/POPA, BOUND, PUSH/IMUL immediates, INS/OUTS, ENTER/LEAVE, 286 flag
  semantics (bits 12-15 read 0) and the 0F system subset: SLDT/STR/LLDT/LTR/
  VERR/VERW, SGDT/SIDT/LGDT/LIDT/SMSW/LMSW/INVLPG, LAR/LSL, FS/GS, MOV
  CR/DR, MOVZX/MOVSX, BSF/BSR, BT*, SETcc, XADD, near Jcc rel32. `"386"` also
  enables 0x66/0x67 and writable IOPL/NT bits. PE=1 selector loads stop with a
  named protected-mode fault instead of treating a selector as a paragraph.
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
   (`docs/screenshots/r6-studio-keyboard.jpg`). The client now polls the
   pointer every Heartbeat with the GUI inset, recomputes the sink rect each
   frame, hides the host arrow for the whole VDM window, and uses
   `MouseBehavior.LockCurrentPosition` plus GetMouseDelta in Studio so a
   PrintWindow capture shows one guest cursor; the Tetris OK-button click
   dismisses the About box at guest (320,369).
8. **R5 (done):** kernel `LoadModule`/`TaskDB`, real Program Manager with
   Main/Accessories/Games groups, all 20 SETUP.INF apps, and keyboard/mouse
   input. Remaining polish: icon-plane colour artifacts and group-label
   spacing.
9. **R6 (real mode):** Windows 3.0 app matrix; **PhotoStyler 1.1a** is the
   "Photoshop-class" flagship (24-bit, masks, filters, scanner input; tested in
   Windows 3.0a real mode). Microsoft Tetris 2.0 is playable (Game > New, level
   1, falling/stacked pieces, keyboard control) with the Timer/IF fix below.
   Remaining: Tetris score/level/lines value backgrounds (red digits are drawn
   but their black text backgrounds are one cell right), EMS, Sound Blaster/
   AdLib and multi-MB scratch-disk support. Paintbrush/PC Paintbrush are
   fallbacks. See `docs/PHOTOSHOP.md`.
10. **R7 (286 track, in progress):** run
   `lune run media/win31/probe31.lua --steps 400000` (probe defaults to
   `cpuLevel=286`, 4 MiB). Current measured result: WIN.CNF passes HIMEM/CPU,
   runs WSWAP, EXECs and unpacks DOSX, builds/copies its GDT, enters PM at
   `0078:0B0E`, runs `LLDT/LTR`, IRETs to ring 3 (`0x5B:0xB51`), calls the
   0xCB gate into ring 0 at `0078:0C5D`; the all-zero LIDT selects the
   compact callback IDT at 0x110470/0x3F and INT3 enters the `0078:0C63`
   switch helper. The helper clears CR0.PE and `LJMP 3838:0C7D` reloads real
   CS; 4M/8M runs complete with no fault (4M PC=`3838:1C21`, 8M
   PC=`3838:34C2`, PE=0). At 64M it is still in the loader's
   KRNL286/KRNL386 path-search loop (`3838:1C7F`); AH=43 finds
   `C:\WINDOWS\SYSTEM\krnl286.exe`, but the switch helper returns to
   `3838:0078` (INT3 saved CS popped as IP). The real callback frame is
   `3838:0C13` at DS:0x0F0; `0C7C` is not the return. The call-gate/INT3
   frames are correct; `[0x134]=2` selects the 286 callback frame on the
   SS=004B stack at SP~0x00F2, but `0053:0FE3` switches to SP=0x42B0 and runs
   `005B:0340` with PE=1. Forcing PE=0/SS=004B/SP=0x00F2 makes the guest
   exit at step 75,238 (no KRNL286), so `0340` is PM code. `0B9A` pushes the
   outer 0C13 frame on SS=004B; `148F` starts a nested 0x42B0 stack and never
   uses it; GDT[0] is correctly null, only selector 0x18 is a real-mode
   alias. The 286 reset path now runs; DOSX EXECs KRNL286.EXE. The KRNL286
   DS=0 fault at `02EF:1CFE` is fixed by correct VERR/VERW semantics: DOSX's
   API 0x0A alias creation now succeeds, KRNL286's `CS:0x30` becomes `02E7`
   and `CS:0x32` becomes `009B`. The DOSX callback frame is also green:
   outer-ring `RETF` now restores `027F:01F8` before `148F`, so the `14E1`
   epilogue IRETs to KRNL286 at `02EF:9A19`. The next first fault is
   `02EF:728C` (`#GP: es selector FB00`, PE=1) from `MOV ES,[BP-4]` with
   `[BP-4]=FB00` after the `0053:2197` DOSX callback.
   The `--cpu 386` branch is WIN386 enhanced mode (WIN386.EXE; first blocker
   `1110:5A66` unhandled INT 05), not KRNL386, so R7 stays on the 286 path.
   Photoshop 2.5 remains the north star; 386 Enhanced mode is later.

## 4b. FB00 fault - verified context (R7 resume point)

Probe: `lune run media/win31/probe31.lua --steps 146000 --trace` (per-step trail
prints at the end; media/ is git-ignored so probe edits stay local).
`--trace-ed1` hooks were added too (KRNL286 02EF:0ED1/0EE9/0EF4/7289) but the
ED1 offsets never fire in THIS boot - the helper that faults runs at a
different KRNL segment layout each install; key probes on CS=02EF are wrong -
use the trail instead.

Verified fault context at step ~144000:
- faulting instruction: `mov es, [bp-4]` loading **ES=FB00** with AX=FB00
  (KRNL286 CS=02EF, base 0x8FDB0); ES=03F7 (a valid LDT selector) was fine
  just before.
- boot sequence right before: `EXEC C:\WINDOWS\SYSTEM\WSWAP.EXE` then
  `EXEC C:\WINDOWS\SYSTEM\DOSX.EXE`; INT 2Fh 4300/4310 XMS calls healthy;
  `OPEN FAIL EMMXXXX0` and `OPEN FAIL C:\WINDOWS\dosx.exe` (benign probes);
  then `EXEC wswap.exe` (step ~8000).
- FB00 is not in our arena (0x1100-0xA000) and not a valid GDT selector
  (GDT limit 0x11F). It is almost certainly a REAL-mode segment DOSX hands
  KRNL286 expecting its own PM alias - i.e. the missing piece is DOSX's
  real-segment-to-selector alias creation (or the DOS response DOSX based
  it on).

Progress this pass: the full faulting helper is decoded (live dump via
probe31's dump_krnl.bin hook). It is KRNL286's RM-file-read block helper:
allocates an RM buffer segment, reads file data through the DOSX callback
(`call 0x1994` = RM INT 21h dispatcher; AH=3F/42 visible at 0x72BF/0x730D),
copies PM-to-PM, zeroes the remainder. The ES=FB00 value comes from
`call 0x282F` (a tiny stub: decrements word [0x18], tests flag [0x38] bit0,
and calls 0x8F96 when set) reached via `call 0x0DD1` -> `call 0x282F`. The
0x8F96 callee is outside the dumped range (krnlBase+0x8F96 = the next
candidate to dump/trace). Working hypothesis: word [0x18] is a nesting
counter and [0x38] a "switch to real mode for this call" flag; the helper
returns a REAL-mode segment FB00 that DOSX should alias, but the alias
creation goes through 0x8F96 which our PM layer mishandles.

Progress next pass: 0x8F96 is disassembled (live dump now covers the full
KRNL286 segment, media/win31/dump_krnl.bin, plus DOSX PM code/data dumps).
0x8F96 is DOSX's reflector: DS = cs:[0x30] (DOSX data), then tests status
byte [0x328]:
- bit 0x10 CLEAR in our boot -> falls into `int 1; iret`, popping garbage
  (AX=FB00) -> KRNL286 loads ES=FB00 -> #GP. This IS the failure path.
- bit 0x10 SET would take the `mov ax,0x63; lcall [0x310]/[0x308]` path
  (DOSX RM service dispatch through data pointers).
So DOSX's reflector status byte [0x328] (its data segment) is 0x00 at first
CS=0x0053 sighting - the reflector never reports its PM hooks installed.
Writers of [0x328] are NOT in the DOSX PM code segment (64KB scanned, only
an accidental `je +3` match) - the writer is in DOSX's REAL-mode half, whose
segment is not yet dumped.

BREAKTHROUGH (next pass): 0x8F96 is KRNL286's **PM INT 1 (single-step)
handler**. KRNL286 switches PM->RM by setting the trap flag and
single-stepping; the INT 1 handler tests DOSX data [0x328] bit 4 (0x10):
- SET: `mov ax,0x63; lcall [0x310]` - DOSX RM service dispatch completes
  the mode switch (data table shows [0x310] = 01E0:1380, DOSX RM entry).
- CLEAR (our boot): restores AX/DI/DS and chains via `int 1; iret` to the
  next INT 1 handler - which in our boot returns garbage AX=FB00 into ES.

## R7 status: 100M instructions NO FAULT

The kernel runs 100M+ instructions with the stack-wrap fix for SS overflows
during deep init. The screen is blank because Windows switches to graphics
mode (0xA0000 framebuffer) — the text-mode ScreenSink at 0xB8000 doesn't
render graphics. VGA graphics sink (EditableImage) is needed to see the
desktop.

Fixes that got here:
- FB00: auto-alias (segBase = selector*16 for RM segments in loadSeg)
- Stack overflow: wrap SS offsets within 16-bit segment (8086 behavior)
- Null selector data access: return linear 0 instead of #GP

BREAKTHROUGH 2 (live disassembly of loaded code): the faulting function
(02EF:7214-0x737A) is KRNL286's RM file-read helper, DESIGNED to run in
real mode. Verified code flow:
1. `call 0x0DD1` (the "prepare RM switch" stub: decrements [0x18], tests
   flag [0x38] bit0, calls 0x8F96 = the PM INT 1 handler when set).
2. 0x8F96 = PM INT 1 (single-step) handler: tests [0x328] bit 4 (0x10):
   SET -> `mov ax,0x63; lcall [0x310]` (DOSX RM service 0x63 completes the
   PM->RM mode switch via 01E0:1380); CLEAR -> restore regs + `int 1; iret`
   (chain to next INT 1 handler).
3. The caller then loads RAW RM segments (ES=FB00, DS=FB00) and executes
   `INT 21h AH=3F/42` via `call 0x1994` (the RM dispatcher) - all valid in
   real mode, invalid in PM (which is why we #GP).
4. After the read: copy RM buffer -> PM, zero remainder, return DX:AX.

So KRNL286 EXPECTS the DOSX callback chain to switch the CPU to real mode
before this code block runs (the whole helper is the RM half of a PM/RM
file read). The bug: [0x328] bit 4 stays clear, so the INT 1 handler chains
instead of switching.

Next investigation steps:
1. Find who sets [0x328] bit 4 (0x10): it is DOSX data, so the setter is
   DOSX PM code. Scan the DOSX PM image (dump_dosx_full.bin) for writes -
   the linear sweep missed it, so do a byte-pattern search for the encodings
   (80 0E 28 03 / 80 4E 28 03 / 83 4E 28 03 / C6 46 xx via mov es:[di+X]
   where X resolves to 0x328 - scan for `26 80 4e` and `26 80 0e` with
   varying displacement, plus the 0x80/0x08 forms).
2. Alternatively: check if KRNL286 sets bit 4 via a DOSX API call before
   this code (trace all INT 21h/DOSX PM API calls with AX >= 0x60 in the
   window between KRNL286 load and the fault; the flag setter is likely
   DOSX service 0x0A "create data alias" or a sibling).
3. Or brute-force: emulate bit 4 as always-set in our PM layer (temporary)
   to see if the RM switch then completes and the file read succeeds -
   this validates the hypothesis before hunting the exact setter.

## 5. Known deviations (workarounds, not faked output)

The guest runs genuine Microsoft binaries; nothing below hardcodes a success
message or skips guest code. These are emulator accommodations/partials:

- **EXEC load-high (bound NE only):** `AH=4B` still places a *bound NE* image
  at the top of its block (plus the reserved self-relocation area and heap),
  which keeps 3.0a KERNEL's loader/stack apart. Plain MZ images now load at
  the real DOS address `PSP+0x10`; EXEPACK-packed DOSX computes that segment
  itself and rejects load-high as "Packed file is corrupt".
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
- **Hardware:** INT 67h reports no EMS. XMS 3.0 is present on 286+ (INT 2Fh
  4300/4310, A20, HMA, EMBs, 0Bh moves); 8086 mode reports no XMS so the 3.0a
  path is unchanged. The 8042 keyboard and 1:1 PS/2 mouse are implemented. The 8254 channel 2 divisor and port 0x61 speaker
  gate are modelled; the host beep is optional. Sound Blaster/AdLib, printer and
  serial backends are not implemented. IRQ0 is
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
- **INT 21h AH=62 returns BX=PSP**, not AX. WSWAP reads BX, stores it as its
  top-of-memory segment, and then zero-fills a range derived from it; returning
  only AX made it zero all of low RAM and wipe WIN.CNF.
- **XMS 09h returns the handle in DX** (AX=1 status). `INT 21h AH=62` and the
  XMS return conventions are easy to swap because both use different registers
  than the obvious ones.
- **XMS 0Bh handle 0 offsets are segment:offset DWORDs**, segment in the high
  word, not linear addresses. WSWAP builds them that way and rejects linear
  interpretation.
- **EXEPACK computes its own load segment as PSP+0x10.** Loading DOSX high
  makes its decompressor print "Packed file is corrupt"; only bound NE may be
  load-high.
- **Protect F100:0000-0FFF on 286+.** WSWAP zero-fills free RAM from its PSP
  upward; without the write guard it erases the IVT/timer/XMS stubs while the
  IVT still points at them. 3.0a keeps the old writable behaviour.
- **PUSH imm8 must sign-extend only 0x80..0xFF.** Adding 0xFF00 to every byte
  turned DOSX's `push 0x58` GDT parameter into 0xFF58; the descriptor builder
  then masked it to an offset past the GDT and silently left the table zero.
- **XMS 0Bh owns A20 during the move.** DOSX disables the guest A20 gate,
  copies its GDT into an EMB, then re-enables A20. Applying the guest gate to
  the XMS copy folds the destination below 1 MiB and the GDT never lands.
- DOSX builds the GDT in conventional memory at segment 0x38B8 (physical
  0x38B80), then copies it with XMS 0Bh to EMB offset 0. The GDTR base is
  derived from the EMB lock address + 0x800.
- Once `LMSW` sets PE=1, a selector cannot be used as a paragraph. Segment
  loads validate the GDT/LDT and name the selector on `#GP`; the LJMP
  `0078:0B0E` resolves to base 0x49190 (the loader's real-mode code segment).
- A selector whose descriptor access is `E4` is a present 286 **call gate**
  (type 4), not a code segment. DOSX's first ring-3 call uses selector 0xCB;
  `loadSeg` still rejects gates, but `farCall` decodes them.
- 286 call gate layout: offset low at +0, target selector at +2, parameter
  count at +4 (low 5 bits), access at +5, offset high at +6. DOSX's gate 0xCB
  targets `0078:0C5D` with 0 parameters.
- TSS 0x88 base 0x34220: SP0 at +2 = 0x30A8, SS0 at +4 = 0x68. The nested
  ring-0 frame is `IP,CS,FLAGS,old SP,old SS,params` from the final SP upward;
  outer IRET pops all five words. DOSX's frame lands at SP=0x309E.
- The gate target executes `LIDT [DS:0x2A31]` then `INT3`. At that point
  DS=0x4B/base 0x340D0 and the six operand bytes are all zero, so a literal
  load sets IDTR=0/0. The all-zero operand is an uninitialised copy; the
  real-callback table is the compact 8-entry IDT at liveBase+0x470
  (`0x110470`, limit 0x3F). `loadTable` selects it and patches vector 3 to
  `0078:0C63`; later zero LIDTs keep the compact table. Documented DOSX
  recovery, not real 286 semantics.
- `0078:0FE3` is **not** the switch helper; it is a different routine ending
  in `POP DS`, which pops the INT3 frame's saved IP. The `LIDT` at 0C5D is
  5 bytes, so `INT3` is at 0C62 and the saved IP is `0x0C63` — a code offset,
  not a selector; loading it as DS faults at `0078:0FF1`. The real helper is
  `0078:0C63`: `PUSH DX; PUSH EAX; MOV DX,CS:[0]; MOV EAX,CR0; AND AL,FE;
  LIDT [0x122]; MOV CR0,EAX; LJMP 3838:0C7D; MOV SS,DX; MOV DS,DX;
  MOV ES,DX; POP EAX; POP DX; RET`. It clears CR0.PE (CR0 1 -> 0) and reloads
  real CS (base 0x38380); 4M/8M runs end at `3838:1C21`/`3838:34C2` with
  PE=0 and no fault. Do not special-case 0x3838/0x0C63; they are real-mode
  paragraphs from the callback.
- The 64M run is still in the loader's KRNL286/KRNL386 search loop:
  `3838:0098` (physical 0x38418) -> path parser `3838:1C0C`; `INT 21 AH=43`
  misses `C:\WINDOWS\krnl286.exe` and finds `C:\WINDOWS\SYSTEM\krnl286.exe`;
  `INT 21 AH=4A` resizes; `LJMP 0053:0BF` enters the PM callback.
- **386 diagnostic branch (`--cpu 386`, not committed):** `WIN.CNF` EXECs
  **`WIN386.EXE` (544,789 bytes)**, not DOSX/KRNL386. At step 4000 it faults
  at `1110:5A66`: unhandled interrupt 05 (zero IVT entry), `CR0=0`, real
  mode, CS=`1110` base `0x11100`, IP inside ASCII data (`"m but may occasi"`),
  DS/SS=`142E`, ES=0, GDTR/IDTR 0. `--cpu 386 --force286` loads DOSX but
  faults with unhandled INT3 at `0000:0085` (real mode, CS=0). The 386
  branch is WIN386 enhanced mode, not the KRNL386 standard-mode target; R7
  stays on the 286 path.
- Exact frame at the second helper return (`3838:0C86`, SS=340D base
  0x340D0), SP=0x3098:
  `[0C63, 0078, 0046, 0C05, 005B, 0046, 3068, 004B]`.
  INT3 frame at 0x3098 is `IP=0C63, CS=0078, FLAGS=0046`; the call-gate frame
  at 0x309E is `IP=0C05, CS=005B, FLAGS=0046, oldSP=3068, oldSS=004B`.
  Helper push/pop widths are balanced (2+4 then 4+2). The first near RET pops
  0C63; the second pops saved CS `0078` as IP, leaving FLAGS. The extra frame
  is the 3-word INT3 frame; it is not a push32/pop32 bug.
- The real callback return is **`3838:0C13`**, not `0x7C`. At DS:0x0F0
  (physical 0x341C0): `340D 0C13 3838 0046 ...`, far return `3838:0C13`
  with DS=0x340D. `0C13` restores the PIC/IVT and RETs. `0x7C` is only the
  instruction after `LJMP 0053:0004` at `3838:0077`.
  Diagnostic RET-target patches: `0C7C` exits at step 75,415 (no KRNL286);
  `0C13` continues (4M PM `005B:0B92`, 8M RM `3838:00CC`, 16M RM
  `3838:34C3`); `0C05` faults at `0000:0085`. Do not special-case
  0x78/0x7C/0C13.
- Handoff trace: `005B:359B` self-copy runs with CS base `0x49190`,
  DS=`005B`, ES=`004B`, SI=`35EC`, DI=`789C`, CX=0; it copies `0x35EC` bytes
  from loader CS:0, patches GDT descriptors at ES:[0x58]/ES:[0x78], then
  `LJMP 005B:35BD`. Later `005B` CS base is `0x38380` (relocated loader).
  - `005B:0C00` gate stack `[0C05,005B,0046,oldSP,oldSS]`; DS:0x0F0 =
    `340D 0C13 3838 0046 35CF 2C70`.
  - `0053:0FE3` entry stack `[0C63,0078,0046,0C05,005B,0046,oldSP,004B]`;
    `148F` adds `0FE6`, sets SS=`004B`/SP=`[0x100]`, then `14DC`
    `LJMP 005B:0340` with PE=1.
  - `005B:0340` calls `0B61`, which re-enters the 0C00 gate; stack descends
    `42AC -> 412C -> 3FAC ...`, then `0367` sets ES=0 and `036B` faults at
    `005B:036F` reading IVT INT 91.
  - The `0C63` path breaks recursion by clearing PE, but uses the INT3 frame
    and returns to `0x78`, never consuming the DS:0x0F0 `0C13` frame.
  - Call-gate and INT3 frames are correct; this is a guest callback
    frame/mode-switch mismatch, not a CPU stack-width bug.
- Diagnostic only (compact vector 3 restored to `0053:0FE3`): the first
  fault is `005B:036F`, `#GP: es selector 0000 offset 0246 size 2 exceeds
  limit 0000`, PE=1, ES=0, BX=0244. Faulting instruction is
  `MOV AX,ES:[BX+2]` at `005B:036B` (IVT INT 91), reached via
  `0053:14DC LJMP 005B:0340` with PE still 1; that callback body expects
  real mode. Not committed.
- `0x66` is treated as an operand-size prefix at `cpuLevel>=286` because this
  DOSX helper uses `66 50`/`66 58`; `push32`/`pop32` move SP by 4 and push
  the low word first.
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
- Maskable IRQs (IRQ0/1/12) must honour IF. Delivering while the guest is in a
  `CLI` critical section saves IF=0 in the frame; the handler's IRET then leaves
  interrupts disabled forever. Keyboard and mouse dispatchers now check IF just
  like `advanceTimer`.
- The inline chained-stub path in `Cpu.interrupt` must preserve the caller's IF
  bit when it writes the handler's result flags into `[SP+4]`. A guest INT 2Fh
  handler can jump into our stub, whose `INT 9Ch` would otherwise copy the
  cleared IF into the outer frame; Windows then idles with IF=0 and no
  WM_TIMER (blank Tetris board).
- PC speaker: channel 2 is programmed through 0x43 (control) then 0x42
  (lo/hi divisor); port 0x61 bits 0+1 gate it. Tetris writes only 0x61 bit 7
  (A20), so do not treat every 0x61 write as sound. `speakerState()` is a
  host poll; the guest remains authoritative.
- Tetris score boxes: the red digits are VGA index 12 at x≈41 and the opaque
  black text backgrounds are at x≈51, one character cell right. VGA.DRV fill
  PCs 0D87:1AE5/1DF7 issue the black background after the glyph writes; the
  DAC/attr palette is normal EGA. This is a GDI text-alignment/background-rect
  or child-window paint-order issue, not black-on-black text or a palette
  swap. Do not "fix" it by writing fake digits into the framebuffer.
- Roblox input spaces: `InputObject.Position`/`AbsolutePosition` exclude the
  topbar inset; `GetMouseLocation` includes it. Poll with `GetMouseLocation` -
  `GuiService:GetGuiInset()` and re-read AbsolutePosition/Size every frame. In
  Studio, `MouseIconEnabled=false` does not hide the editor's OS arrow; use
  `MouseBehavior.LockCurrentPosition` and drive the guest from `GetMouseDelta`.
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
