# R7 callback contract: 286 standard-mode DOSX reset path

Status: implemented in R7 pass 16. The 286 callback is **not** a direct PE=0
entry, a selector-0 alias, or the `0078:0C63` MOV CR0 helper. Windows 3.1
standard mode leaves protected mode by **resetting the CPU via a triple
fault**, then resumes through the BIOS shutdown handler and the frame saved
in the BDA. DOSX now reaches `KRNL286.EXE`; see the result at the end.

## References

- Michal Necasek, "FasterModeSwitch: Is It Really?", OS/2 Museum, 2018-10-31:
  <http://www.os2museum.com/wp/fastermodeswitch-is-it-really>
  - Windows 3.1 Standard (286) mode switches protected -> real by causing a
    triple fault/reset, not by clearing PE with an instruction.
  - Default uses CMOS shutdown status **09h** in CMOS byte 0Fh.
  - `FasterModeSwitch=1` uses shutdown status **0Ah**, which jumps back via a
    far address/stack state stored in the BDA.
  - Shutdown 09h force-disables A20; 0Ah does not touch A20.
- Microsoft KB Q83387, Windows 3.1 `SYSTEM.INI [standard]`:
  <https://jeffpar.github.io/kbarchive/kb/083/Q83387>
  - `FasterModeSwitch` is standard-mode only; `Stacks`/`StackSize` describe
    DOSX interrupt-reflector stacks.
- Microsoft KB Q92587, standard-mode boot process:
  <https://jeffpar.github.io/kbarchive/kb/092/Q92587>
  - DOSX provides extended memory access, then loads KRNL286.EXE.
- Local DOSX.EXE disassembly (Windows 3.1 3.10.103, `SYSTEM\\DOSX.EXE`).

No local DOSBox-X/86Box/PCem instruction trace was available. The DOSX code
matches the published 286 reset contract closely enough to identify it.

## DOSX evidence

### 286 callback setup: `005B:0B61`

At `005B:0B61`, `[0x134]=2` (<3) and `[0x2F5A]=0` select the 286 path:

```text
0B66  CMP word [0x134], 3
0B6B  JB  0B8B                 ; 286 path
...
0B8B  CMP word [0x2F5A], 0
0B90  JNE 0B9A
0B92  PUSHF
0B93  PUSH word [0x148]
0B97  PUSH 0C13                ; resume frame: IP=0C13, CS=3838, FLAGS
0B9A  MOV AX, CS:[0]           ; 005B:[0] = 340D
...
0BAF  PUSH 40h
0BB1  POP DS                   ; DS = 0040 (BDA)
0BB2  CMP word ES:[0x2F5A], 0
0BB8  JNE 0BC3
0BBA  MOV [0x69], AX           ; BDA 40:69 = 340D (saved SS)
0BBD  MOV [0x67], SP           ; BDA 40:67 = 00F2 (saved SP)
0BC1  JMP 0BD7
0BC3  MOV BX, ES:[0x148]
0BC8  MOV [0x69], BX
0BCC  MOV word [0x67], 0C05
0BD2  MOV ES:[0x2A3F], SP
...
0BE6  MOV AL, 8Fh
0BE8  OUT 70h, AL              ; CMOS index 0Fh, NMI off
0BEA  MOV AL, 9
0BEC  CMP word [0x2F5A], 0
0BF1  JE  0BF5
0BF3  MOV AL, 0Ah               ; FasterModeSwitch shutdown code
0BF5  OUT 71h, AL              ; CMOS shutdown status 09h/0Ah
...
0BF7  IN AL, 21h
0BF9  MOV [0x2A30], AL
0BFC  MOV AL, 0FFh
0BFE  OUT 21h, AL              ; mask IRQs
0C00  LCALL 0CB,0              ; gate 0CB -> 0078:0C5D
```

So the 286 path does **not** intend to run `005B:0340` in PM. It:

1. pushes the real-mode resume frame `0C13/3838/0046`;
2. saves SS:SP in the BDA (`0040:0069`/`0040:0067`);
3. writes CMOS shutdown status 09h or 0Ah;
4. masks IRQs and calls gate 0CB.

### Gate target: `0078:0C5D`

```text
0C5D  0F 01 1E 31 2A   LIDT [DS:0x2A31]
0C62  CC               INT3
0C63  52 ...           MOV CR0 helper
```

The `LIDT [DS:0x2A31]` operand at `0x36B01` is six zero bytes. That is
**intentional** for this path: IDTR=0/0. The following `INT3` then faults
(#GP), the double-fault handler faults, and the CPU triple-faults/resets. The
BIOS shutdown handler resumes from the saved BDA SS:SP and IRETs to
`3838:0C13`.

Our current emulator treats the all-zero LIDT as an uninitialised copy, keeps
the compact IDT, and patches vector 3 to `0078:0C63`. That takes the **386**
helper (`MOV EAX,CR0`/`MOV CR0,EAX`, `0F 20 C0`/`0F 22 C0`) instead of the
286 reset. The helper's `MOV CR0` cannot clear PE on a real 286; it is a
386-only path. This is why the callback frame is wrong.

### Resume routine: `3838:0C13`

```text
0C13  FA             CLI
0C14  33 C0          XOR AX,AX
0C16  8E C0          MOV ES,AX
0C18  56             PUSH SI
0C19  57             PUSH DI
0C1A  BE 37 2A       MOV SI,0x2A37
0C1D  BF FA 03       MOV DI,0x03FA
0C20  FC             CLD
0C21  A5 A5 A5       MOVSW x3
0C24  5F             POP DI
0C25  5E             POP SI
0C26  1E             PUSH DS
0C27  07             POP ES
0C28  A0 30 2A       MOV AL,[0x2A30]
0C2B  E6 21          OUT 0x21,AL
0C2D  83 3E 5A 2F 00 CMP word [0x2F5A],0
...
0C3C  C3             RET
```

This restores the PIC mask and the real-mode IVT after the reset. It expects
to run in **real mode** at `3838:0C13`, not in PM at `0053:0FE3`/`005B:0340`.

## Contract answer

- Real 286 DOSX enters the callback by **triple-fault reset**, not by
  `PE=0 + 005B:0340`.
- The resume frame is the `0C13/3838/0046` frame pushed at `0B92-0B97`; its
  SS:SP is saved in BDA `0040:0067`/`0040:0069` and restored by the BIOS
  shutdown handler (CMOS status 09h default, 0Ah with `FasterModeSwitch`).
- `IDTR=0/0` from the zero `LIDT` operand is intentional. `INT3` is the
  triple-fault trigger.
- `GDT[0]` is correctly null. Selector `0x18` is the real-mode alias, but it
  is not used by this path.
- The `0078:0C63` MOV-CR0 helper and `0053:0FE3`/`005B:0340` dispatcher are
  **not** the 286 standard-mode contract; they belong to a 386/V86 or
  post-reset path.

## Smallest CPU/PM behavior change that matches the reference

1. **286 triple fault/reset:** on `cpuLevel=286`, when the guest executes the
   intentional zero `LIDT` and then `INT3`, let IDTR become 0/0 and allow the
   #GP/double/triple fault to reset the CPU. Do not substitute the compact
   IDT on this path.
2. **BIOS shutdown handler:** implement CMOS shutdown status 09h/0Ah.
   - 09h (SHUT9): restore SS:SP from BDA `0040:0069`/`0040:0067`, disable
     A20, `POP DS; POP ES; POPA`, then `RETF 2` to the saved `3838:0C13`
     frame.
   - 0Ah (SHUTA): jump to the CS:IP at BDA `0040:0067`; preserve A20.
3. **Gate MOV CR0 to 386:** `0F 20/22` (`MOV EAX,CR0`/`MOV CR0,EAX`) plus
   `0F 21/23` (MOV DR) are 386 instructions. On a 286 they are `#UD`; the
   `0078:0C63` helper is not the 286 path.
4. Keep GDT[0] null and selector `0x18` as the real-mode alias; no guest
   patch is needed.

## Reference confirmation

The PC/AT BIOS reconstruction (Gawlas/IBM-PC-BIOS, AT BIOS V3,
`TEST1.ASM`/`BIOS1.ASM`) confirms the handler:

- `SHUT9` loads `DS=0040`, `SS=@IO_ROM_SEG` (`0040:0069`),
  `SP=@IO_ROM_INIT` (`0040:0067`), disables A20, pops DS/ES and the PUSHAW
  frame, then `RET 2` (far) — exactly the SS:SP/PUSHAW/RETF 2 layout DOSX
  builds at `0B92-0B97`.
- `SHUTA` is `JMP DWORD PTR @IO_ROM_INIT` (`0040:0067` CS:IP), matching the
  `[0x2F5A] != 0` DOSX path that stores `0C05`/`[0x148]`.

## Implementation result

- Probe reset at step 44000: `status=09`, BDA `SS:SP=340D:00DE`; the
  SS:SP frame is `DS=340D, ES=340D, PUSHAW..., IP=0C13, CS=3838, skip=0046`.
  DOSX resumes at `3838:0C13` in real mode.
- DOSX then EXECs **`C:\WINDOWS\SYSTEM\KRNL286.EXE` (71,730 bytes)**.
- The 114000 `02EF:1CFE` DS=0 fault was a **VERR/VERW emulation bug**, not a
  missing KRNL286 initialization. DOSX API `0x0A` (create data alias) at
  `0053:2C71` starts `MOV AX,BX; VERR AX`, called with `BX=CS=02EF`.
  `Cpu` used to set `ZF = (descriptor == nil)`, so a valid code selector
  cleared ZF and DOSX skipped the alias; KRNL286's `CS:[0x30]` stayed 0.
  After implementing VERR (readable code/data) and VERW (writable data),
  DOSX creates the alias, KRNL286's `CS:0x30` becomes `02E7` and
  `CS:0x32` becomes `009B`, and the DS=0 fault is gone.
- The `0053:14FB` fault was the missing **outer-privilege `RETF`**, not the
  call-gate frame alone. The `0070` dispatcher returns from ring 0 to ring 3
  with `[IP=0E63, CS=0053, SP=01F8, SS=027F]` at `0068:309C`; our `RETF`
  popped only IP/CS, so `148F` ran on `0068:30A0` instead of `027F:01F8`.
  `RETF`/`RETF imm16` now pop SP and SS when the return CS.RPL is greater
  than CPL. The `148F` entry is now `SS=027F, SP=01F6`, top
  `[0E66, 9A19, 02EF, 0296, ...]`; the `14E1` frame is
  `[DS=02E7, ES=02DF, IP=9A19, CS=02EF, FLAGS=0296, ...]` and IRETs to
  KRNL286 at `02EF:9A19`.
- The 16-bit call-gate frame was corrected to IP, CS, old SP, old SS,
  parameters (no FLAGS), matching the Intel 286 manual Figure 7-12 and
  86Box; FLAGS belongs only to interrupt gates.
- Next fault at step 144000: `02EF:728C`,
  `#GP: es selector FB00: absent or outside GDT limit`, PE=1, CS=02EF base
  `0x8FDB0`, DS=02EF, ES=03F7, SS=027F, SP=01B0, AX=FB00, BX=02EF, CX=B6CB,
  SI=0040, DI=B6CB, BP=01CC; last PC `0053:2197`. The faulting instruction is
  `MOV ES,[BP-4]` at `02EF:7289` with `[BP-4]=FB00`.

## Remaining questions

- Why the KRNL286 helper after the `0053:2197` DOSX callback returns the
  real-mode segment `FB00` where a PM selector is expected.
- Whether the `[0x2F5A] != 0` 0Ah path is exercised by a different DOSX
  configuration.
- Whether the pre-reset `0053:0FE3`/`005B:0340` path is only used after a
  386/V86 transition.
