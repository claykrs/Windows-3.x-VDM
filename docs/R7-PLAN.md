# R7 plan — Windows 3.1 Standard mode (286 protected mode)

Research/prep note. Current release is still the 3.0a real-mode baseline; this
document records what was verified against real Windows 3.1 media and the
shortest credible path to `WIN.COM -> DOSX -> KRNL286 -> USER/GDI`.

## Implementation status (2026-11-03, first R7 pass)

Done through the eighteenth R7 pass (667 assertions, gate green, 3.0a CALC
boot re-verified at 303,069 non-black px):

- `cpuLevel = "8086" | "286" | "386"`, default `"8086"`; 286 selects the
  186/286 opcodes (PUSHA/POPA, BOUND, PUSH/IMUL imm, INS/OUTS, ENTER/LEAVE),
  286 real-mode flag bits and the 0F system subset (SMSW/LMSW/LGDT/LIDT,
  SGDT/SIDT, SLDT/STR/LLDT/LTR/VERR/VERW, LAR/LSL, MOV CR/DR, MOVZX/MOVSX,
  BSF/BSR, BT*, SETcc, XADD, Jcc rel32). 386 adds 0x66/0x67 and writable
  IOPL/NT; full 32-bit ALU/addressing is still pending.
- `Cpu` now has per-segment descriptor caches (`segBase/segLimit/segAccess/
  segFlags/segSel`) and `loadSeg`/`linear`. Real mode still uses
  `selector<<4` and limit FFFF; PM validates GDT/LDT present/type/limit and
  names the selector on `#GP`. Fetch, stack, ModRM, string ops, moffs, XLAT,
  far call/jump/return and IRET use the cached base. A basic same/outer-ring
  IRET is implemented for DOSX's ring-3 handoff.
- `core/Xms.lua`: INT 2Fh 4300/4310, far entry F100:00C0, version 3.0, A20,
  HMA request/release, free query, EMB allocate/free/lock/unlock/info, 0Bh
  move with segment:offset handle-0 semantics. A20 defaults on for 286+; 0Bh
  temporarily owns A20 so a guest copy into an EMB is not folded while the
  guest gate is off.
- `Memory`: configurable power-of-two size (1 MiB default, 4 MiB for 3.1),
  A20 fold, and a write-protected F100:0000-0FFF hypervisor stub range.
- DOS: `AH=38` country info, `AH=29` FCB filename parse, `AH=2B` set date,
  `AH=62` now returns BX=PSP, `INT 15h AH=88`; EXEC releases prior XMS blocks
  and loads plain MZ at PSP+0x10 while keeping bound NE load-high.
- WIN.CNF path: HIMEM/CPU pass -> WSWAP runs -> `SYSTEM\DOSX.EXE` EXECs and
  EXEPACK-unpacks -> DOSX checks XMS -> builds a GDT in conventional memory
  and copies it into an EMB via XMS 0Bh -> `SMSW; LGDT; LIDT; LMSW` ->
  `LJMP 0078:0B0E` succeeds (selector base 0x49190) -> DOSX runs PM setup,
  `LLDT 0x38`, `LTR 0x88`, `IRET` to `0x5B:0xB51` (ring 3).
- Call gate 0xCB (`E4`, target `0078:0C5D`, 0 params) performs the
  ring-3→ring-0 transition through the 0x88 TSS: SS0=0x68, SP0=0x30A8,
  frame at 0x309E with IP/CS/FLAGS/old SP/old SS.
- `LIDT [DS:0x2A31]` operand verified: at `0078:0C5D` DS=0x4B (base
  0x340D0), the six operand bytes are `00 00 00 00 00 00`, so an unfixed
  LIDT would set IDTR to base=0/limit=0. The live IDT before the target is
  `base=0x110000 limit=0x7FF`; vector 3 is a present DPL3 interrupt gate at
  `0070:1139`.
- PM IDT delivery is implemented: gate types 6/7/E/F, present/type/DPL
  checks, target selector/offset, TSS ring stack switch for inner-ring
  targets, 16-bit IP/CS/FLAGS frame, optional error code, IF clear for
  interrupt gates, TF clear for both. Software `INT n`/`INT3` use the IDT in
  PM; real-mode IVT/stub behaviour is unchanged. The old full-IDT path
  (`0070:1139`, linear 0x111A59) and its real-mode-stub fault at
  `0053:1E4D` are historical.
- IDT investigation result: the zero `LIDT [DS:0x2A31]` operand is an
  uninitialised 6-byte copy. The intended real-callback table is the compact
  8-entry IDT at **liveBase+0x470 = 0x110470, limit 0x3F**. Its vector 3 gate
  initially targets `0053:0FE3` (a PM stub); the correct target is the
  clear-PE switch helper at **`0078:0C63`**. The emulator selects that compact
  IDT when LIDT sees an all-zero operand and patches vector 3 to
  `0078:0C63` with a present interrupt gate. Live IDTR becomes
  `base=0x110470 limit=0x003F`. A later zero LIDT (the helper's real-mode
  reset) keeps the compact table.
- `0078:0FE3` is **not** the switch helper: it is a different routine that
  ends in `POP DS`, popping the INT3 frame's saved IP. The dispatcher's
  `LIDT` is 5 bytes at 0C5D, so `INT3` is at 0C62 and the saved IP is
  **0x0C63** — a code offset, not a selector; loading it as DS faults at
  `0078:0FF1`. `0078:0C63` is the real helper entry.
- Switch-helper trace (`0078:0C63`, CS base 0x38380, `CS:[0]=0x340D`):
  `PUSH DX; PUSH EAX` (`66 50` -> 32-bit push at 286);
  `MOV DX,CS:[0]` -> DX=0x340D; `MOV EAX,CR0` -> 1; `AND AL,FE` -> 0;
  `LIDT [DS:0x122]` (zero operand, compact IDT kept); `MOV CR0,EAX` ->
  **CR0=0, PE cleared**; `LJMP 3838:0C7D` reloads real-mode CS (base
  0x38380); `MOV SS/DX; MOV DS,DX; MOV ES,DX` -> 0x340D; `POP EAX; POP DX;
  RET`. The `0x66` operand-size prefix is now honoured at `cpuLevel>=286`,
  with `push32`/`pop32` implemented for `PUSH/POP r32`.
- New result: **4M and 8M complete with no fault**. 4M PC=`3838:1C21`,
  8M PC=`3838:34C2`, `CR0=00000000`, PE=0,
  CS/DS/ES/SS=3838/340D/340D/340D, `IDTR=0x110470/0x003F`.
- Extended 64M run: still no fault, PC=`3838:1C7F`. The guest is in a DOSX
  real-mode loader loop, not making KRNL286 progress:
  - Loop at `3838:0098` (physical 0x38418) calls the path parser at
    `3838:1C0C`. `INT 21 AH=43` tries `C:\WINDOWS\krnl286.exe` (CF=1,
    not found) then `C:\WINDOWS\SYSTEM\krnl286.exe` (CF=0, found);
    `INT 21 AH=4A` resizes; `LJMP 0053:0BF` enters the PM callback. The
    switch helper clears PE, but its second near `RET` at `3838:0C86`
    returns to `3838:0078` (the INT3 frame's saved CS `0x0078` popped as IP).
    The path search then repeats.
  - The path/attribute service itself works (AH=43 finds the file); the
    blocker is the real-mode callback return frame.
- 386 diagnostic branch (`--cpu 386`, temporary, not committed):
  - `WIN.CNF` EXECs **`WIN386.EXE` (544,789 bytes)**, not DOSX/KRNL386.
  - At step 4000 it faults at `1110:5A66`: unhandled interrupt 05 (zero IVT
    entry). `CR0=0`, real mode, CS=`1110` base `0x11100`, IP points into
    ASCII data (`"m but may occasi"`), DS/SS=`142E`, ES=0, GDTR/IDTR 0.
  - `--cpu 386 --force286` loads DOSX but faults immediately with unhandled
    INT3 at `0000:0085` (real mode, CS=0).
  - The 386 branch is **WIN386 enhanced mode**, not the KRNL386 standard-mode
    target; it hits an immediate 386-only blocker. R7 stays on the 286
    standard-mode/DOSX-KRNL286 path.
- 286 reset implementation (this pass):
  - On `cpuLevel=286`, an all-zero `LIDT` now loads IDTR=0/0; INT3 escalates
    to a triple fault and `Cpu:reset`.
  - `MOV CR0`/`MOV DR` (`0F 20/21/22/23`) are 386-only (`#UD` on 286).
  - `Machine` models CMOS ports 0x70/0x71. Shutdown status 09h uses the PC/AT
    SHUT9 path: restore SS:SP from BDA `0040:0067/0069`, `POP DS; POP ES;
    POPA; RETF 2`, disable A20. Status 0Ah uses SHUTA: jump to the CS:IP at
    `0040:0067`, preserve A20.
  - Probe: reset at step 44000 (`status=09`, BDA SS:SP=`340D:00DE`), then
    **EXEC `C:\WINDOWS\SYSTEM\KRNL286.EXE` (71,730 bytes)**.
  - Tests: 661 assertions; new reset/shutdown/A20/CR0-gating cases.
- VERR/VERW fix (seventeenth pass):
  - `0F 00 /4` and `/5` previously made `ZF = (descriptor == nil)`, so every
    valid selector cleared ZF and every absent descriptor set it. That is
    backwards for both instructions.
  - DOSX's API function `0x0A` (create data alias) starts at `0053:2C71` with
    `MOV AX,BX; VERR AX`; KRNL286 calls it with `BX=CS=02EF`. The old VERR
    returned ZF=0 for that code segment, so DOSX skipped the alias creation
    and KRNL286's `MOV DS, CS:[0x30]` thunk at `02EF:2672` loaded DS=0,
    faulting at `CMP [0x0257],AX` (`02EF:1CFE`).
  - `Cpu` now implements VERR (readable code/data) and VERW (writable data)
    with present/S/type/DPL checks; null, absent, or system selectors clear
    ZF without faulting.
  - Result: KRNL286's module header is initialized: `CS:0x30 = 02E7`
    (autodata/DS selector) and `CS:0x32 = 009B` (LDT alias). The DS=0 fault
    is gone. At that point (before the eighteenth pass) the next fault was
    `0053:14FB`: `#GP: es selector 0C05: absent or outside LDT limit`, PE=1,
    CS=0053, DS=02E7, ES=004B, SS=0068, CR0=1; last PC `3838:0AAB`.
  - That was DOSX's real-mode callback epilogue (`0053:14E1`: `POP DS;
    POP ES; IRET`). The ring-3 `LCALL 0xCB` at `005B:0C00` switched to the
    TSS ring-0 stack (`0068:30A8`) and its call-gate frame overwrote the ES
    slot of the `148F` helper's saved frame, so the epilogue popped `0C05`
    as ES. The eighteenth pass fixes the underlying frame.
  - Tests: 667 assertions; new VERR/VERW case (readable code, execute-only
    code, writable data, code-not-writable, absent, null).
- Callback frame fix (eighteenth pass):
  - The `0053:14FB` fault was **not** the call gate's frame size alone. The
    `0070` dispatcher returns from ring 0 to ring 3 with the frame
    `[IP=0E63, CS=0053, SP=01F8, SS=027F]` at `0068:309C`; our `RETF` popped
    only IP/CS, so `148F` ran on `0068:30A0` instead of `027F:01F8`. Its
    saved ES slot then sat where the later `LCALL 0xCB` ring-0 call-gate
    frame landed.
  - `RETF`/`RETF imm16` now implement the outer-privilege return: when the
    return CS.RPL is greater than the current CPL, they pop SP and SS after
    CS:IP. The `148F` entry is now `SS=027F, SP=01F6`, top
    `[0E66, 9A19, 02EF, 0296, ...]`, and the `14E1` frame is
    `[DS=02E7, ES=02DF, IP=9A19, CS=02EF, FLAGS=0296, ...]`; it IRETs to
    KRNL286 at `02EF:9A19`.
  - The 16-bit call-gate frame was also corrected to the 286 layout:
    IP, CS, old SP, old SS, parameters (no FLAGS). This matches the Intel
    286 manual Figure 7-12 and 86Box; FLAGS belongs only to interrupt gates.
  - Probe now reaches step **144000**. Next fault: `02EF:728C`,
    `#GP: es selector FB00: absent or outside GDT limit`, PE=1, CS=02EF
    base `0x8FDB0`, DS=02EF, ES=03F7, SS=027F, SP=01B0, AX=FB00, BX=02EF,
    CX=B6CB, SI=0040, DI=B6CB, BP=01CC; last PC `0053:2197`. The faulting
    instruction is `MOV ES,[BP-4]` at `02EF:7289` with `[BP-4]=FB00`.
  - Tests: 667 assertions; call-gate frame case updated (no FLAGS) and a
    ring0->ring3 outer `RETF` case added.
- Exact stack dump at the second helper return (`3838:0C86`, SS=340D base
  0x340D0), SP=`3098`:
  `[0C63, 0078, 0046, 0C05, 005B, 0046, 3068, 004B]`.
  - INT3 frame at 0x3098: IP=`0C63`, CS=`0078`, FLAGS=`0046`.
  - Call-gate frame at 0x309E: IP=`0C05`, CS=`005B`, FLAGS=`0046`,
    oldSP=`3068`, oldSS=`004B`.
  - Helper pushes `DX` (2) + `EAX` (4) and pops `EAX` (4) + `DX` (2):
    balanced; there is **no push32/pop32 width error**.
  - First near RET pops saved IP `0C63` (second pass); second near RET pops
    saved CS `0078` as IP, leaving FLAGS. The extra frame is the 3-word INT3
    frame; the helper's near RET cannot skip it.
- The real callback frame is **not 0x7C**. At DS:0x0F0 (physical 0x341C0):
  `340D 0C13 3838 0046 ...` — a far return `3838:0C13` with FLAGS=0x0046
  and DS=0x340D. `0C13` restores the PIC/IVT (`CLI; XOR AX,AX; MOV ES,AX;
  ... OUT 0x21; ... OUT 0x70; RET`). `0x7C` is only the instruction after
  the initial `LJMP 0053:0004` at `3838:0077`.
- Diagnostic patches of the second RET target:
  - `0C7C`: guest exits at step 75,415 (`exit=0`), no KRNL286 EXEC. `0C7C`
    is not the callback return.
  - `0C13`: 4M no fault, PM `005B:0B92`; 8M RM `3838:00CC`; 16M RM
    `3838:34C3`. This matches the real callback frame and keeps DOSX
    running.
  - `0C05`: faults with unhandled INT3 at `0000:0085`.
  These patches are diagnostics only; none are committed.
- Handoff trace (gate53 diagnostic for the original `0053:0FE3` handler):
  - `005B:359B` loader self-copy: CS base `0x49190`, DS=`005B`, ES=`004B`,
    SI=`35EC`, DI=`789C`, CX=0; it copies `0x35EC` bytes from the loader
    CS:0 and patches GDT descriptors at ES:[0x58]/ES:[0x78], then
    `LJMP 005B:35BD`. Later `005B` CS base is `0x38380`: the loader has been
    relocated down from `0x49190` to `0x38380`.
  - `005B:0C00` gate call stack: `[0C05,005B,0046,oldSP,oldSS]`;
    DS:0x0F0 already contains `340D 0C13 3838 0046 35CF 2C70`.
  - `0078:0C5D` LIDT; `0078:0C62` INT3; `0053:0FE3` entry stack:
    `[0C63,0078,0046,0C05,005B,0046,oldSP,004B]`.
  - `0053:148F` adds return `0FE6`, then sets SS=`004B`/SP=`[0x100]`
    (`42B0`); `0053:14DC` does `LJMP 005B:0340` with **PE=1**.
  - `005B:0340` runs `CALL 0B61`; that path calls the 0C00 gate again,
    re-entering `0C5D`/INT3/`0FE3`. The stack descends
    `42AC -> 412C -> 3FAC -> 3E2C -> ...`, then `005B:0367` sets ES=0 and
    `005B:036B` faults reading IVT INT 91 (`005B:036F`).
  - The `0C63` path breaks the recursion by clearing PE, but its INT3 frame
    yields the `0x78` return and never consumes the DS:0x0F0 `0C13` frame.
- First-pass 286 callback trace (`[0x134]=2` selects the `<3` path at
  `005B:0B8B`; `[0x2F5A]=0`):
  - `005B:0B9A` pushes `0C13, 3838, 0046` on the **SS=004B stack at
    SP=0x00F2**; `[0x2A3F]=0`, `[0x100]=0x42B0`.
  - The 005B:0C00 gate stack is
    `[340D,340D,0078,35EC,4B00,00F2,340D,0003]`; the gate frame's old
    SS/SP are `004B:00DE`.
  - `0053:0FE3` then sets SS=`004B`/SP=`[0x100]` (`42B0`), discarding the
    0x00F2 frame, and `14DC` enters `005B:0340` with **PE=1**.
  - `005B:0340` calls `0B61` again; `[0x134]` is still 2, so it pushes
    another `0C13/3838/0046` frame at SP~0x42A4 and calls the gate again.
  - The `0C63` path clears PE but uses the ring0 INT3 frame and returns to
    `0x78`; the 0x00F2 callback frame is never used.
- Contract decision: the guest's own `[0x134]=2` selects the **286
  real-mode callback path**; its return frame is on the **SS=004B stack**
  (`0C13/3838/0046` at SP~0x00F2), not the DS:0x0F0 data copy. The
  `0053:0FE3` dispatcher must enter the callback with PE=0 and that stack
  frame (or return to `0B85`), not switch to SP=0x42B0 and re-enter `0340`.
  The `0C63` helper must consume the 0x00F2 frame, not the INT3 frame.
  Both current paths violate this contract.
- GDT alias check: at `0053:148F`, `005B:0340`, and `005B:0367` the dumps
  are identical:
  - `GDTR=0x110800/0x011F`
  - `GDT[0] = 0000 0000 0000 0000` (null)
  - `GDT[0x18] = FFFF 0000 F200 0000` (limit 0xFFFF, base 0, data RW DPL3 —
    the real-mode alias)
  - No runtime patch of the handler's `XOR AX,AX; MOV ES,AX` to selector
    0x18 exists (no `B8 18 00`/`8E C0 18` code in DOSX). Writes to the
    handler region at step 42000 are the temporary IDT gate table; the 44000
    self-copy restores the handler bytes. GDT[0] writes are only XMS setup
    at 8000/42000.
  - The GDT copy into the EMB preserves GDT[0] as null and keeps selector
    0x18 as the alias. **GDT[0] is correctly null on 286 DOSX**; the guest
    handler's `ES=0` is a real-mode expectation, not a missing GDT[0] alias.
- Disassembly comparison (`005B:0B92-0B9A`, `0053:148F/14DC`):
  - `0B92 PUSHF; 0B93 PUSH [0x148]; 0B97 PUSH 0C13; 0B9A MOV AX,CS:[0]`.
    The `0C13/3838/0046` frame is pushed on the **current SS=004B stack at
    SP=0x00F2**; this is the outer callback return, not the callback stack.
  - `148F`: `CLI/CLD; PUSH DS; MOV DS,CS:[0]` (`0053:[0]=004B`);
    `MOV SS,DS; MOV SP,[0x100]=0x42B0; PUSH AX;
    [0x100] -= [0x2F6F]; ...; LJMP 005B:0340`. It starts a nested callback on
    the dedicated 0x42B0 stack and never consumes the 0x00F2 frame.
  - `14DC LJMP 005B:0340` with **PE=1**. `0340` is PM code: its `CALL 0B61`
    uses the PM gate; `0367` sets `ES=0` for an IVT read.
  - GDT[0] is null; the only writes to 0x110800 are XMS setup at steps
    8000/42000. Selector `0x18` is the base-0/limit-FFFF real-mode alias,
    but the handler uses ES=0.
- Contract: the guest's handler is a **real-mode copy** that expects `ES=0`
  to address the IVT; GDT[0] is correctly null and no selector-0x18 patch is
  present. The 0x42B0 stack is a nested callback stack; the 0x00F2 frame is
  the outer return. There is no consistent PM entry. The guest setup is
  inconsistent with 286 PM null-selector semantics. No fix; stop here.
- Forced-entry experiment (temporary probe, not committed): at the first
  `005B:0340` entry, forced `CR0.PE=0`, `SS=004B`, `SP=0x00F2` (the frame
  built at 0B9A). Result: **guest exits at step 75,238** (`exit=0`), no
  fault, no KRNL286 EXEC; final PC `00CB:F352`, CS=`00CB`, PE=0. The callback
  body's `CALL 0B61` then runs the PM 0B61 path (`LCALL 0xCB`) and exits, so
  `0340` is not a real-mode entry. The forced contract is invalid; `0340` is
  PM code with a real-mode-style `ES=0` IVT access.
- Evidence: the call-gate and INT3 frames are both built correctly; the
  helper receives the INT3 frame, while the real callback frame is a data
  structure at DS:0x0F0. The `0053` dispatcher leaves PE=1 before
  `005B:0340`, so its ES=0 access faults. This is a guest callback
  frame/mode-switch design mismatch, not a CPU stack-width or gate-frame bug.
  Do not special-case 0x78/0x7C/0C13 or patch the guest stack.
- `Cpu:setPE` and `MOV CR0`/`LMSW` PE-clear paths are implemented and tested:
  clearing PE makes subsequent `loadSeg` use `selector<<4` with limit FFFF,
  while current CS/SS caches remain for the instruction stream (286 hardware;
  the next far transfer reloads CS). PM null selectors are also tested:
  loading selector 0 gives base 0/limit 0 and any access faults. New test
  `pm_int3_near_ret_pops_saved_cs` codifies the INT3 frame and the two near
  RETs.

Next exact action: the DOSX callback frame is green. `148F` runs on
`SS=027F, SP=01F6` and the `14E1` epilogue IRETs to KRNL286 at `02EF:9A19`.
The next first fault is `02EF:728C`, `#GP: es selector FB00: absent or
outside GDT limit`, from `MOV ES,[BP-4]` with `[BP-4]=FB00` (AX=FB00), PE=1.
Determine why that KRNL286 helper returns the real-mode segment `FB00` where
a PM selector is expected (it follows the `0053:2197` DOSX callback); fix the
contained CPU/PM or loader behavior, not a guest address.

## Verified media and layout

RTM Windows 3.1 (3.10.103), English, six 3.5" 1.44 MB setup disks:

- `media/win31/rtm/Microsoft Windows 3.1 (3.10.103) (3.5)/.../Disk01..06.img`
- `media/win31/files/` — FAT12 files after unpacking
- `media/win31/staged/` — 467 decompressed files (451 SZDD, 16 verbatim)
- `media/win31/install/WINDOWS/` — expanded install tree used by the probe
  (499 files; `SYSTEM/` plus the root shell/apps)
- helpers: `media/win31/extract31.py`, `stage_install31.py`, `probe31.lua`

Key files after expansion: `WIN.COM` 16,112 (from `WIN.CN_`), `DOSX.EXE`
32,682, `KRNL286.EXE` 71,730, `KRNL386.EXE` 75,490, `USER.EXE` 264,016,
`GDI.EXE` 220,800. `SETUP.INF` reports `Version = "3.1.040"`; the
distribution is 3.10.103.

Differences from the 3.0a pipeline:

| 3.0a | 3.1 |
| --- | --- |
| 5 x 1.2 MB, filenames already final (`WIN.CNF`, `KERNEL.EXE`) | 6 x 1.44 MB, SZDD names compressed (`WIN.CN_`, `KRNL286.EX_`); needs an EXPAND/rename table (`EX_→EXE`, `DL_→DLL`, `DR_→DRV`, `CN_→CNF`, `SR_→SRC`, `FO_→FON/FOT`, …) |
| `WIN.CNF` 3,456, real mode only | `WIN.CNF` 16,112, `/3` `/S`, no real mode ("This version of Windows does not run in real mode") |
| `KERNEL.EXE` real-mode NE | `KRNL286.EXE` + `KRNL386.EXE`, both `NE_FFLAGS_PROTMODE` (flags `0x8009`) |
| no DOS extender | `[winexec] execstd="dosx.exe "`, `execcmd=" krnl286.exe /b /q:"`; `xmsmmgr.exe` is the no-HIMEM fallback |
| no SHELL/COMMDLG/TOOLHELP | `SHELL.DLL`, `COMMDLG.DLL`, `TOOLHELP.DLL`, `DDEML.DLL`, `OLECLI/OLESVR`, `MMSYSTEM.DLL` |
| `SYSTEM.INI` has no taskman/drivers | `[boot] taskman.exe`, `drivers=mmsystem.dll`; larger `[386Enh]` VxD list |

Standard mode is **DOSX + KRNL286**: 16-bit protected mode, 24-bit physical
memory, no paging or V86. Enhanced mode is **WIN386 + KRNL386**: 32-bit
protected mode, paging, V86 and VxD/VMM. `KRNL286` and `KRNL386` are both
PROTMODE NEs; only the former is needed for the first 3.1 milestone.

`KRNL286.EXE` has four segments and uses `LAR` (7), `LSL` (6), `ENTER` (38),
`LEAVE` (132), `BOUND` (1), `MOVZX`, and string I/O. `DOSX.EXE` is packed with
a self-decompressor; after running its unpacker the image contains
`SMSW AX`, `LGDT/LIDT`, `LMSW AX`, `MOV EAX,CR0` / `MOV CR0,EAX`, `66`-prefixed
32-bit operations, `MOVZX`, and `LLDT`/`LTR`/`VERR`/`VERW`. Standard mode is
therefore **not** a pure 286 target: the 386 subset is required from day one.

## First failure against the pre-R7 emulator (historical)

`lune run media/win31/probe31.lua --steps 500000` (staged install in the VFS):

1. **Natural run, 625 instructions, exit 255 (`AX=4CFF`).** `WIN.CNF` probes
   HIMEM with `INT 2Fh AX=4300`; `Machine.int2f` returns `AL=0` (no XMS). It
   prints "Your computer cannot run Windows in either standard or 386 enhanced
   mode" and exits via `AH=4Ch AL=0FFh`. DOSX is never executed. This is the
   first hard failure: Windows 3.1 has no real-mode fallback.
2. **The next CPU-level gate is `WIN.CNF`'s class probe at `1000:30D2`**
   (`PUSHF; XOR AX,AX; PUSHF; POP AX; TEST AX,8000h`). `core/Cpu.lua` sets
   `FIXEDFLAGS = 0xF002` and `Cpu.new` starts with `0xF202`, so bits 12-15
   always read as 1 and the probe returns `AX=0` ("8086"). The 286 path must
   model bits 12-14 as read-only 0 (the 386 path makes them writable), while
   preserving 8086 behaviour on the `cpuLevel="8086"` path. A test-only XMS
   shim alone does not reach DOSX; it still needs the 286 identity and the
   remaining DOS services.
3. **With the CPU probe forced to 286 and the XMS version gate bypassed**,
   `WIN.CNF` reaches `INT 21h AH=38h` (country information) at `1000:3DF6`;
   `core/Dos.lua` does not implement it. That is the next practical DOS gap
   before DOSX.
4. **The first missing protected-mode instruction in DOSX (the real 3.1 path)
   is `0F 01 E0` (`SMSW AX`)** — `core/Cpu.lua` currently errors on every `0F`
   opcode. DOSX then needs `LGDT/LIDT/LMSW`, `MOV CR0`, `LLDT/LTR`, 32-bit
   operands, and eventually `LAR/LSL`, `ENTER/LEAVE`, `BOUND`, and string I/O.

Directly loading `DOSX.EXE` with today's `loadMZ` gets through its packed
decompressor but jumps into the IVT at `0000:0601`; that is a loader/environment
mismatch, not a useful CPU result. The real path is through `WIN.CNF`.

## Implementation sequence

### 1. CPU generation switch (small, safe first)

Add `cpuLevel = "8086" | "286" | "386"` to `Cpu.new`/`Machine.new`, default
`8086` so the 3.0a baseline and all 471 assertions remain unchanged.

- At 286+, `0xC8/0xC9` must be `ENTER`/`LEAVE`, not the current 8086 `RETF`
  aliases. This alone is a hard blocker for KRNL286.
- Add 186 forms used by 3.1: `BOUND` (`0x62`), `INS/OUTS` (`0x6C..0x6F`),
  `PUSH imm8/imm16` (`0x6A/0x68`), `IMUL r,r/m,imm` (`0x69/0x6B`), and the
  `0xC0/0xC1` shift-immediate forms already present.
- Keep the 8086 aliases on the 8086 path; 3.0a guest code depends on the current
  behaviour.

### 2. 24-bit memory and A20

`core/Memory.lua` is a 1 MiB buffer with a 20-bit mask. Make the size
configurable (1 MiB default, 4 MiB for 3.1, 16 MiB max) and translate 24-bit
physical addresses. In real mode, apply the A20 gate (fold bit 20 when off);
in protected mode use the full 24-bit address. Keep the `A0000-AFFFF` VGA
aperture and dirty-rect path. Avoid allocating 16 MiB per test machine; sparse
high pages or a per-machine `memorySize` option is enough.

### 3. Descriptor caches and segment translation

Add to `Cpu`:

- `gdtr`, `idtr` = `{ base, limit }`, `ldtr`, `tr`, `cr0`, `pe`.
- `segCache[6]` for `ES CS SS DS FS GS` = `{ sel, base, limit, access, flags }`.
- `realMode` caches: `base = sel << 4`, `limit = 0xFFFF`, 20-bit wrap.

Introduce `cpu:linear(segReg, off, size)` and `cpu:loadSeg(reg, selector)`.
`loadSeg` does the null-selector, GDT/LDT lookup, present/type, limit and
privilege checks, then fills the cache. Replace the direct `lshift(seg,4)`
uses in `fetch8`, `push16/pop16`, `modrm`, string operations, far
call/jump/return, `INT`/`IRET` frames, and `LDS/LES/LSS`. In real mode the
helper is the old `seg<<4`; in protected mode it validates `off+size <= limit`
and returns `base+off` (24-bit).

`core/Cpu.lua` currently has 8 direct `<<4` sites; `core/Memory.lua` has the
20-bit mask. Audit those first, then the `Executables` loader (which can keep
real-mode paragraph mapping for 3.0a and use selectors for 3.1).

### 4. `0F` system instructions and the 386 subset

Implement, behind `cpuLevel >= 286`:

- `0F 00`: `SLDT`, `STR`, `LLDT`, `LTR`, `VERR`, `VERW`.
- `0F 01`: `SGDT`, `SIDT`, `LGDT`, `LIDT`, `SMSW`, `LMSW`.
- `0F 02/03`: `LAR`, `LSL` (KRNL286 uses both).
- `0F 06`: `CLTS`; `0F 20/21/22/23`: `MOV CR/DR` (DOSX uses CR0 in its 386 path).
- `0F B6/B7/BE/BF`: `MOVZX/MOVSX`; `0F BC/BD`: `BSF/BSR`; `0F A3/AB/B3/BB`:
  `BT/BTS/BTR/BTC`; `0F A4/A5/AC/AD`: `SHLD/SHRD`; `0F 90..9F`: `SETcc`;
  `0F C0/C1`: `XADD`; `0F 80..8F`: near `Jcc rel32`.
- `0x66` operand-size and `0x67` address-size prefixes, plus 32-bit
  `EAX..EDI` storage. A practical layout is to keep the existing 16-bit `r`
  table as the low halves and add a parallel high-half table (`rHi[1..8]`);
  `wr32/rr32` combine/split, and 16-bit writes clear the high half.
- `0x63 ARPL`, `0F B2 LSS`, `0F B4 LFS`, `0F B5 LGS`, `FS/GS` segment
  registers.

The 286 `LGDT/LIDT` operand is 6 bytes (16-bit limit, 24-bit base, 8 reserved
bits); the 386 form is 6 bytes (16-bit limit + 32-bit base). DOSX selects
between a plain and `66`-prefixed form, so both paths must decode.

### 5. Protected-mode interrupts, exceptions, rings

Rebuild `Cpu.interrupt` for PE=1:

- IDT gate types: task, interrupt, trap; 286 error-code frames for `#TS`,
  `#NP`, `#SS`, `#GP`; `#UD`, `#DE`, `#DF`; push `CS:IP` and flags, clear
  IF/TF as the gate says.
- Ring transitions: interrupt/trap gate to inner ring loads `SS:SP` from the
  TSS; `IRET` to outer ring pops `SS:SP`; call gates and the TSS busy bit.
  DOSX explicitly does `LLDT 0x38`, patches the TSS descriptor, `LTR 0x88`,
  then `IRET`s to `0x5B:0xB51` with `SS=0x4B` (ring 3). That frame is the
  concrete acceptance test for ring transitions.
- Keep the real-mode IVT/shadow/stub behavior when PE=0. In PM, vector
  delivery must use the IDT, and the PIT/PIC must raise the PM vector without
  corrupting the guest's IF (the R6 lesson still applies).

### 6. XMS/HIMEM and DOS gaps

Add `core/Xms.lua` (or a `Machine` service) implementing the INT 2Fh XMS entry:

- `AX=4300h` → `AL=80h`; `AX=4310h` → real-mode far entry for the XMS handler.
- Functions DOSX/WIN.CNF actually call: `00h` version, `01h/02h` UMB alloc/free,
  `03h..07h` A20, `08h` query free, `09h/0Ah` allocate/free, `0Bh` move,
  `0Ch/0Dh` lock/unlock, `0Eh` info, `88h/89h` any-memory. `0Bh` is a
  memcpy over the flat 24-bit space.
- This is enough to pass WIN.CNF's HIMEM probe without loading a real
  `HIMEM.SYS`; staging the file for realism is optional.

Then trace DOSX's `INT 21h` calls and add the first missing services. The probe
already found `AH=38h` (country info) before DOSX; expect `4Ah/48h/49h`,
`44h`, `47h`, `4Bh`, `25h/35h`, `2Fh`, and the DPMI/Windows multiplex calls.
Do not guess: run the harness and add one AH at a time.

### 7. DOSX handoff and KRNL286

Once WIN.CNF passes the XMS/CPU/DOS checks it EXECs
`C:\WINDOWS\SYSTEM\DOSX.EXE` with ` krnl286.exe /b /q:`. Observed unpacked DOSX
sequence (linear addresses from the dump, not guest selectors):

```
25C79  SMSW AX
25C7C  OR AX,1
25C86  LGDT [0x110]      ; 66-prefixed on the 386 path
25C8C  LIDT [0x11C]
25C9F  LMSW AX
25CA2  LJMP 0x78:0xB0E   ; ring 0 PM entry
...
25CDB  LLDT AX (0x38)
25CEC  LTR SI (0x88)     ; TSS descriptor patched at +5 = E1
25D00  push SS=0x4B, SP, FLAGS|0x3000, CS=0x5B, IP=0xB51; IRET
```

That `IRET` is the ring-3 handoff point (DOSX's client entry, expected to be
KRNL286). The first goal is to let real DOSX do this, rather than reimplement
its NE loader. If DOSX insists on its own PM↔RM callback path, implement the
minimum DOS/BIOS callback it uses; if that becomes disproportionate, fall back
to a machine-side PM NE loader for KRNL286, keeping the same
selector/descriptor semantics.

`KRNL286.EXE` is a 4-segment NE (`flags=0x8009`, PROTMODE) with no imports.
It is loaded as selectors, not paragraphs: allocate an LDT/GDT entry per
segment, set code/data DPL, apply NE relocations as selector values, and enter
at the DOSX-provided handoff selector/offset rather than the NE header's
`CS:IP` (which is not a usable real-mode entry). Then KERNEL's own loader brings
up USER/GDI/drivers; keep the current NE header/import parser and add a PM
segment allocator rather than rewriting it.

### 8. 3.1 shell and drivers

After KRNL286 runs, stage the 3.1 equivalents of the 3.0a profile:
`SYSTEM.INI` with `shell=progman.exe`, `display.drv=vga.drv`,
`system.drv=system.drv`, `keyboard.drv=keyboard.drv`, `mouse.drv=mouse.drv`,
`fonts.fon=vgasys.fon`, `fixedfon.fon=vgafix.fon`, `oemfonts.fon=vgaoem.fon`,
`286grabber=vgacolor.2gr`, `386grabber=vga.3gr`, `taskman.exe=taskman.exe`.
Add `SHELL.DLL`, `COMMDLG.DLL`, `TOOLHELP.DLL`, `WIN87EM.DLL`, and the 3.1 VGA
driver/font set. `WIN87EM`/FPU and 3.1 `USER/GDI` are the next compatibility
frontier, not part of the first PM milestone.

## Test harness

- **Unit:** `tests/PmCpuTests.lua` — descriptor decode (all types, expand-down,
  granularity), selector load rules, GDT/LDT, `LGDT/LIDT/LMSW/SMSW`, `LAR/LSL`,
  `ENTER/LEAVE`, `BOUND`, `0x66` 32-bit ALU, `MOV CR0`, `#GP/#UD` frames,
  ring 0↔3 `IRET`/call gate. `tests/XmsTests.lua` for the XMS functions/A20.
- **Regression:** keep `cpuLevel="8086"` for the existing 3.0a tests; require
  `lune run tools/run.lua` green after every CPU commit.
- **Integration:** a `win31` profile for `tools/app_harness.lua` (proposed; do
  not edit `tools/` in this prep pass) that seeds
  `media/win31/install/WINDOWS`, reports the trace
  `WIN.COM -> EXEC DOSX.EXE [ krnl286.exe /b /q:] -> PM ENTERED -> KRNL286 ->
  USER/GDI -> PROGMAN`, and stops on the first fault with `CS:IP`, selector,
  descriptor (base/limit/access), `CR0`, `GDTR/IDTR`, `LDTR/TR`, stack, and 32
  bytes at the fault. Add `--pm-state` and `--dump-pm` options.
- **Acceptance gates:** (1) WIN.CNF reaches `EXEC DOSX`; (2) DOSX sets PE and
  reaches the `IRET` to `0x5B:0xB51`; (3) KRNL286 entry executes; (4) USER/GDI
  load; (5) Program Manager desktop in 640x480. Each gate gets a screenshot or
  a deterministic trace assertion.

## First commits

1. `cpu: add 286 execution level (enter/leave, bound, ins/outs)` — default
   8086, tests unchanged.
2. `memory: configurable 24-bit space and A20 gate` — 1 MiB default, 4 MiB for
   3.1.
3. `cpu: descriptor caches and protected-mode segment translation` — replace
   the direct `<<4` paths, real mode bit-identical.
4. `cpu: 0f system instructions and 32-bit subset` — `SMSW/LMSW/LGDT/LIDT`,
   `LAR/LSL`, `MOV CR0`, `0x66`; first `SMSW` test passes.
5. `cpu: protected-mode faults and ring transitions` — IDT, TSS/LDT, call
   gates, `IRET` to ring 3.
6. `xms: int 2f xms driver and A20` — WIN.CNF's HIMEM probe passes; harness
   reaches `EXEC DOSX`.
7. `win31: media extract/expand profile and harness` — 3.1 staging, INI
   profile, trace gates; no binaries committed.
8. `dosx: first protected-mode handoff` — fix DOSX's first faults, record the
   PM entry and KRNL286 handoff.
9. `krnl286: protected-mode NE load` — only if DOSX cannot load it itself.

Keep 3.0a real mode as the regression baseline. 386 Enhanced mode
(`WIN386.EXE`, `KRNL386.EXE`, VxD/VMM, paging, V86) remains a later track.
