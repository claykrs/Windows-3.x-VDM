# Photoshop 2.x feasibility (RVDM)

Research note, not a commitment. RVDM currently targets **8086 real mode /
Windows 3.0a real mode**. This document records why Photoshop 2.5 is a
different class of target and what real-mode alternative to use instead.

## Requirements

| Item | Photoshop 2.5 / 2.5.1 / 2.5 LE |
| --- | --- |
| CPU | 80386 minimum (486 recommended) |
| OS | MS-DOS 5.0+ and **Windows 3.1 or later** |
| RAM | 4 MB minimum, 8 MB recommended; 3–5× image size in practice |
| Windows mode | Windows 3.1 **Standard** mode works; 386 Enhanced is only Adobe's recommended/performance mode |
| Display | VGA 640×480×16 minimum; 256-colour/24-bit for real work |
| Mouse | Required |
| FPU | WIN87EM.DLL imported by the graphics/colour DLLs |
| DLLs | KERNEL, USER, GDI, KEYBOARD, **SHELL**, **COMMDLG**, **TOOLHELP**, WIN87EM, Adobe DLLs |
| Disk | 10 MB free + Windows swap + Photoshop scratch disks |

Windows 3.0a does not ship SHELL.DLL, COMMDLG.DLL or TOOLHELP.DLL. Even a
hacked install would still need 4 MB and a 386.

## Is it 386-only code?

No. `PHOTOSHP.EXE` is a 2.2 MB 16-bit NE executable with 143 segments, no
32-bit segments, no DPMI/VxD/WINMEM32 imports, and only 152 32-bit-register
instructions in ~2.06 MB of code. It relies on **Windows 3.1's protected-mode
environment**, not on a private 32-bit engine. Adobe's 386 floor is a
platform/performance requirement. Photoshop 2.5 can run in Windows 3.1
**Standard mode**; 386 Enhanced mode adds JPEG/MacPaint filters and more RAM
access, but is not required for the application itself.

## Emulator work

### Track A — Windows 3.1 Standard mode (minimum to run Photoshop)

1. 386 instruction set (0x66/0x67, 32-bit GPRs, FS/GS, MOVZX/MOVSX,
   BSF/BSR, BT*, SHLD/SHRD, SETcc, XADD, system instructions).
2. 286 protected mode: GDT/IDT/LDT, descriptors, selector loads, privilege
   levels, call gates, TSS, ring transitions, faults, real↔protected mode.
3. XMS/HIMEM + A20, run DOSX.EXE and KRNL286.EXE, 16-bit PM NE loader,
   selector-based global heap, per-instance DGROUP, discardable segments,
   swap file.
4. Windows 3.1 system files: KRNL286, DOSX, USER/GDI 3.1, SHELL, COMMDLG,
   TOOLHELP, WIN87EM, VGA/MOUSE/KEYBOARD drivers, 3.1 SETUP.INF install.
5. FPU/WIN87EM, mouse (INT 33h + MOUSE.DRV), PIC/PIT, VGA 640×480×16.
6. Multi-MB scratch/swap storage in the VFS.

Relative effort: **3–5× the remaining Windows 3.0 real-mode work**. High risk
in DOSX/KRNL286 expectations, selectors/rings and the 3.1 memory manager.

### Track B — Windows 3.1 386 Enhanced mode (recommended by Adobe)

Adds 32-bit protected mode, paging, V86, VMM/VxD, DPMI, SVGA and device
virtualization. Relative effort **8–15×**; a new emulator generation. Do not
start here for Photoshop 2.5 — Standard mode is enough.

## Real-mode alternative

**Aldus/U-Lead PhotoStyler 1.1a (1992)** is the recommended R6 flagship:

- Windows 3.0, 286/2 MB class; actually tested in Windows 3.0a real mode on an
  80186/CGA/600 KB (VOGONS).
- 24-bit images, masks, magic wand, filters, colour correction, scanner input.
- Needs EMS (LIM 4.0), mouse and a multi-MB scratch disk; those also benefit
  Paintbrush and other real-mode apps.

Fallbacks: Microsoft Paintbrush 3.x (ships with Windows 3.0), ZSoft PC
Paintbrush 1.x/Plus, Micrografx Picture Publisher 3.x (real-mode status
unverified).

Not real mode: ZSoft PhotoFinish (Windows 3.1/386), Corel PHOTO-PAINT 3.0,
Photoshop 2.5.

## Roadmap verdict

- **R6 (real mode):** PhotoStyler 1.1a as the "Photoshop-class" app; add EMS,
  mouse and scratch-disk support.
- **R7+ (separate track):** Windows 3.1 **Standard mode** (386 ISA + 286
  protected mode + DOSX/KRNL286 + XMS + WIN87EM). Photoshop 2.5 is a good
  north star for that track because it is 16-bit and Standard-mode-capable.
- Do not make 386 Enhanced mode the first 386 target; it multiplies work for
  one app.

## Sources

- WinWorld Photoshop 2.x: https://winworldpc.com/product/ad-ps/2x
- Photoshop 2.5 README (shipped, `PSREADME.WRI`): Windows 3.1, 386, 4 MB;
  Standard mode supported, Enhanced recommended.
- Windows 3.1 memory modes: https://jeffpar.github.io/kbarchive/kb/092/Q92587/
- VOGONS 8086 real-mode app list: https://www.vogons.org/viewtopic.php?t=79572
- WinWorld PhotoStyler 1.x: https://winworldpc.com/product/aldus-photostyler/1x
