# Windows 3.0 real-mode application compatibility

Status: 2026-11-03, branch `r5-program-manager`. Scope is **Windows 3.0a real mode** on an
8086/8088 (and a 286 running real mode). Standard mode (286 protected mode) and
386 enhanced mode are out of scope except where a third-party app needs them.
Current result: **20 of 20 SETUP.INF applications launch and render**.

The tests use the genuine Windows 3.0a media in `media/win30/` through
`tools/app_harness.lua`; no guest behaviour is stubbed or faked. "Blocked"
means the guest really did not reach an app EXEC.

## 1. Reproduce

```powershell
# NE header facts for the built-ins (real-mode eligibility, imports, CPU flags)
lune run tools/app_harness.lua list

# Load each app through the real NE loader against real KERNEL/GDI/USER/DLLs
lune run tools/app_harness.lua static all

# Queue every app in WIN.INI [windows] run= and boot to the budget
lune run tools/app_harness.lua boot all --via ini --steps 5000000

# Boot with "WIN.COM C:\WINDOWS\<app>" (real win app.exe command line)
lune run tools/app_harness.lua boot all --steps 4000000

# Single app, full report, screenshot
lune run tools/app_harness.lua boot CALC

# SETUP.INF coverage
lune run tools/app_harness.lua audit
```

Screenshots are written to `tools/out/` (git-ignored) as dependency-free PNGs.
`--via ini` sets `WIN.INI [windows] run=`; the default `--via cmdline` writes
the app to WIN.COM's DOS command tail, the same as `WIN CALC.EXE`.

## 2. Built-in Windows 3.0a applications

### 2.1 NE header facts

All thirteen apps are Windows-targeted NE 3.0 images with the protected-mode-only
bit (`NE_FFLAGS_PROTMODE`, program flags bit 3) clear. None requires 386 code.
PROGMAN and WINFILE explicitly set the 8086 flag; the others leave the CPU bits
at zero, which is the 8086-compatible Windows 3.0 baseline.

| App | Bytes | Req. Win | PMODE-only | CPU baseline | Real mode | Segs | Imported modules |
| --- | ---: | --- | --- | --- | --- | ---: | --- |
| PROGMAN.EXE | 55,200 | 3.0 | no | 8086 | **yes** | 8 | GDI KERNEL KEYBOARD USER |
| WINFILE.EXE | 106,288 | 3.0 | no | 8086 | **yes** | 17 | GDI KERNEL KEYBOARD SYSTEM USER |
| WRITE.EXE | 211,168 | 3.0 | no | 8086 | **yes** | 79 | GDI KERNEL KEYBOARD USER |
| PBRUSH.EXE | 161,200 | 3.0 | no | 8086 | **yes** | 33 | GDI KERNEL PBRUSH USER |
| NOTEPAD.EXE | 31,936 | 3.0 | no | 8086 | **yes** | 8 | GDI KERNEL KEYBOARD USER |
| CARDFILE.EXE | 53,952 | 3.0 | no | 8086 | **yes** | 8 | GDI KERNEL KEYBOARD USER |
| CALENDAR.EXE | 64,352 | 3.0 | no | 8086 | **yes** | 10 | GDI KERNEL KEYBOARD USER |
| CALC.EXE | 40,480 | 3.0 | no | 8086 | **yes** | 5 | GDI KERNEL USER WIN87EM |
| CLOCK.EXE | 11,136 | 3.0 | no | 8086 | **yes** | 2 | GDI KERNEL USER |
| REVERSI.EXE | 16,688 | 3.0 | no | 8086 | **yes** | 2 | GDI KERNEL USER |
| CONTROL.EXE | 161,824 | 3.0 | no | 8086 | **yes** | 22 | GDI KERNEL KEYBOARD USER |
| TASKMAN.EXE | 3,296 | 3.0 | no | 8086 | **yes** | 2 | KERNEL USER |
| WINVER.EXE | 8,704 | 3.0 | no | 8086 | **yes** | 2 | KERNEL USER |

All imported dependency files are present in the install: `PBRUSH.DLL`,
`WIN87EM.DLL`, `SYSTEM.DRV`, `KEYBOARD.DRV`, `GDI.EXE` and `USER.EXE`. No built-in
app needs a missing DLL.

### 2.2 Static NE load against the real core

This loads real KERNEL, the five drivers, VGA.DRV, GDI and USER, then the app
image through `core/Executables.loadNEImage`. It proves the file parses and
every import resolves; it does not execute app code.

| App | Result | Detail |
| --- | --- | --- |
| PROGMAN.EXE | loaded | 8 segments, entry 1:0274, DGROUP 7F52 |
| WINFILE.EXE | loaded | 17 segments, entry 1:0884, DGROUP 8881 |
| WRITE.EXE | image OK, loader memory | 79 segments / 185 imports all resolve, but the eager 640K DOS-arena loader cannot fit every segment at once |
| PBRUSH.EXE | loaded | 33 segments, entry 1:0224, DGROUP 936B |
| NOTEPAD.EXE | loaded | 8 segments, entry 1:19D4, DGROUP 7DCB |
| CARDFILE.EXE | loaded | 8 segments, entry 1:14F4, DGROUP 8238 |
| CALENDAR.EXE | loaded | 10 segments, entry 1:00E4, DGROUP 840A |
| CALC.EXE | loaded | 5 segments, entry 4:0074, DGROUP 7F2A |
| CLOCK.EXE | loaded | 2 segments, entry 1:1644, DGROUP 0DE9 |
| REVERSI.EXE | loaded | 2 segments, entry 1:20D4, DGROUP 0E85 |
| CONTROL.EXE | loaded | 22 segments, entry 1:1DF4, DGROUP 9081 |
| TASKMAN.EXE | loaded | 2 segments, entry 1:04E4, DGROUP 0CC6 |
| WINVER.EXE | loaded | 2 segments, entry 1:01B4, DGROUP 0C93 |

The NE loader now indexes both the resident and **non-resident** export tables:

- KERNEL.EXE exports its API by name in the non-resident table at absolute
  file offset `2Ch` (`__WINFLAGS` #178, `GLOBALALLOC` #15, `WEP` etc.).
- PBRUSH.DLL's resident table is just `SCOOLVM #0`; `VBITBLT` and friends are in
  its non-resident table. Both CALC and PBRUSH now load.
- `Executables.loadNEImage` parses only `restab` (NE `26h`), so
  `resolveWinImportByName` cannot see either set. This is the highest-leverage
  isolated app-loader fix.

WRITE's failure is the loader's eager-segment policy, not the app: real Windows
demand-loads code segments; `loadNEImage` maps every segment up front. Its 185
imports all resolve against the real images.

### 2.3 Boot state and app launch

At `--timer 55000` the real `WIN.COM` → KERNEL → drivers/fonts → GDI/USER
chain reaches the Program Manager desktop. The app matrix below comes from
`tools/app_harness.lua boot <APP>`, which delivers the app through WIN.COM's
command line; Program Manager's group icons use the same `AH=4Bh` EXEC path.
The earlier KERNEL allocator spin at `0A67:929A` and the WIN.COM
command-line jump at `BD00:53BD` were intermediate states. They no longer
reproduce after the BIOS timer EOI and flag fixes, the DOS SFT/arena and
environment layout, and the real FindFirst DTA layout. The historical traces
remain in git history for reference, not as current blockers.

Per-app status at `--timer 55000` (the faithful PIT rate):

| App | Launch | Status |
| --- | --- | --- |
| PROGMAN.EXE | yes | shell renders; Main/Accessories/Games groups |
| WINFILE.EXE | yes | File Manager directory tree and drive/free-space status |
| WRITE.EXE | yes | Write window, menus, document area and Page 1 status |
| PBRUSH.EXE | yes | Paintbrush window, tools and palette |
| NOTEPAD.EXE | yes | Notepad window with menus and scrollbars |
| CARDFILE.EXE | yes | Cardfile window |
| CALENDAR.EXE | yes | Calendar window with day view |
| CALC.EXE | yes | complete Calculator UI |
| CLOCK.EXE | yes | analog Clock window |
| REVERSI.EXE | yes | Reversi board |
| CONTROL.EXE | yes | Control Panel with all nine icons |
| TASKMAN.EXE | yes | Task List window |
| WINVER.EXE | yes | real "Real Mode Windows Version 3.00a" dialog |
| CLIPBRD.EXE | yes | Clipboard window |
| PIFEDIT.EXE | yes | PIF Editor form |
| RECORDER.EXE | yes | Recorder window |
| PRINTMAN.EXE | yes | real "There are no printers connected" dialog |
| SOL.EXE | yes | Solitaire table with dealt cards |
| TERMINAL.EXE | yes | Terminal window and serial-port chooser |
| MSDOS.EXE | yes | MS-DOS Executive with the complete `c:\windows` file list |

Summary: **20 of 20 SETUP.INF applications launch and render**. No missing DLLs
or 386-only apps. CALENDAR/REVERSI were blocked by a child PSP freeing KERNEL's
inherited VGA.DRV/font handles; CLOCK needed a moving `INT 21h AH=2C` clock.
The DTA FindFirst layout (attribute at `15h`, size at `1Ah`, name at `1Eh`)
fixed both MS-DOS Executive's list and File Manager's tree; volume-label
searches no longer return an ordinary file.

## 3. Third-party 16-bit Windows software

### 3.1 How eligibility is decided

For any NE file, read the header (the harness `list` does this):

| Field | Meaning for real mode |
| --- | --- |
| NE `0Ch` program flags bit 3 (`08h`) | `NE_FFLAGS_PROTMODE`: protected-mode only, so **no real mode** |
| NE `3Eh` expected Windows version | `< 3.0`: real mode yes; `3.0` + bit 3 clear: real mode yes; `> 3.0`: no |
| NE `36h` target OS | `02h` = Windows |
| NE program flags bits 4/5/6 | 8086 / 286 / 386 instructions; absent = 8086-compatible baseline |
| NE `37h` "other flags" | OS/2-era flags; do not use for Windows mode eligibility |

An app that says "requires Standard or Enhanced Mode Windows" has the
protected-only bit set (or is a 3.1+ image). Windows 3.1 dropped real mode
entirely, so a Windows 3.1-only app cannot run under 3.0a in any mode.

The general rule from contemporary documentation is blunt: real mode existed to
run Windows 2.x applications. Most apps written specifically for Windows 3.0
were built for standard/enhanced mode. Word 1.x and Excel 2.x are the famous
exceptions because they were Windows 2.x applications.

### 3.2 Positive matrix (known to run in real mode)

| Software | Version / year | Stated requirements | Real mode | Evidence | Confidence |
| --- | --- | --- | --- | --- | --- |
| Microsoft Word for Windows | 1.0 / 1.1a (1989–90) | Windows 2.11; 286/1MB/EGA per contemporary review | **yes** | Wikipedia: Word 1.x designed for Windows 2.x and runs real mode; VOGONS tested 1.1a on 80186/CGA/600KB | High |
| Microsoft Excel for Windows | 2.1c / 2.1d (1989–90) | 640K; Windows 2.x | **yes** | Wikipedia names Excel 2.x; VOGONS tested 2.1d; Virtually Fun ran 2.1c on 3.0 real mode | High |
| Lotus Ami Pro | 1.2b (1990) | Windows 3.0; 286 class | **yes** | VOGONS tested on 80186/CGA/600KB | Medium-high |
| Aldus PageMaker | 1.0, 1.0a, 3.0 (1989–90) | Windows 3.0 for 3.0; 286 class | **yes** | VOGONS tested all three in real mode | Medium-high |
| CorelDRAW | 1.10 (1989–90) | Windows 3.0 | **yes** | VOGONS tested | Medium-high |
| Micrografx Designer | 2.0, 3.1 (1990–92) | Windows 3.0 | **yes** | VOGONS tested | Medium-high |
| Aldus/U-Lead PhotoStyler | 1.1a (1991) | Windows 3.0 | **yes** | VOGONS tested | Medium-high |
| Z-Soft PC Paintbrush | 1.05, Plus 1.22 | Windows 2.x/3.0 | **yes** | VOGONS tested | Medium-high |
| BeckerTools Plus | 2.0 | Windows 3.0 | **yes** | VOGONS tested | Medium |
| Harvard Graphics (DOS) | 3.0 (1991) | DOS 3.x, 512K+ | **yes (DOS app via PIF)** | Microsoft KB Q92365: runs correctly in real and standard mode | High |
| Pipe Dream, Tut's Tomb | Windows shareware | Windows 3.0 | **yes** | VOGONS tested | Medium |

The VOGONS list was produced on an 80186, CGA mono, MS-DOS 5.0 machine with
600KB free conventional memory, which is exactly the RVDM target class.

### 3.3 Negative or unproven matrix

| Software | Version / year | Requirement | Real mode | Evidence | Confidence |
| --- | --- | --- | --- | --- | --- |
| Microsoft Excel | 3.0 (1990) | Windows 3.0 **standard or 386 enhanced**, 1MB extended, 286 | **no** | Microsoft KB Q4461 explicitly says Excel 3.0 refuses real mode | High |
| Microsoft Word | 2.0 (1991) | 286, Windows 3.0 standard mode class | **no (likely)** | Windows 3.0-era app; no primary requirement sheet found; treat as unverified | Low |
| Lotus 1-2-3 for Windows | 1.0 (1991) | **Standard mode** | **no** | *Inside OS/2 2.0* (1992) states "1-2-3 for Windows requires Standard mode" | Medium |
| Harvard Graphics for Windows | 3.0 (1994) | 386, 4MB, Windows 3.1 | **no** | Museum/retail box requirements; Windows 3.1 only | High |
| Micrografx Picture Publisher | 3.0 / 3.1 (1992–93) | Windows 3.0; no published CPU/RAM minimum located | **unproven** | Wikipedia says 3.0 was rewritten for Windows 3.0; WinWorld says the 3.1 line is "for Windows 3.0"; not in the tested real-mode list. 24-bit image buffers make standard mode likely | Low — needs media test |
| CorelDRAW | 2.0 / 3.0 (1991–92) | 386 class | **no (likely)** | Era requirements; 1.10 is the tested real-mode version | Low |
| Aldus PageMaker | 4.0+ (1991+) | 386 class | **no (likely)** | PageMaker 3.0 is the tested real-mode version | Low |

A Picture Publisher 3.x retail copy is the most valuable missing third-party
test medium: it is explicitly a Windows 3.0 rewrite and its real-mode status is
not documented anywhere authoritative.

## 4. Install coverage and missing SETUP.INF material

`tools/install.lua` now stages the following into the runtime VFS (never into
git):

- `[windows.system]` KERNEL/GDI/USER/WIN.CNF in both `WINDOWS` and `SYSTEM`.
- `[windows]` WINHELP, SETUP.HLP, the WIN/SYSTEM INI templates.
- `[shell]` PROGMAN.EXE; `[win.apps]` all 22 built-ins (DLLs and DIGITAL.FON
  also in `SYSTEM`).
- `[win.help]` 16 files, `[win.bmps]` 5, `[win.readme]` 9.
- `[win.other]` WINOLDAP/LZEXPAND/WIN87EM/SYSEDIT in `SYSTEM`.
- `[pwin286]` and `[pwin386]` kernels/modules in `SYSTEM`.
- `[fonts]`, `[sysfonts]`, `[fixedfonts]`, `[oemfonts]` at VGA resolution
  (`100,96,96`) and the continuously-scaled ROMAN/SCRIPT/MODERN faces.
- VGA.DRV, VGA.GR3, VGACOLOR.GR2, VGALOGO.LGO/RLE, VGASYS/VGAFIX/VGAOEM.FON,
  plus the DISPLAY.DRV/FONTS.FON/FIXEDFON.FON/OEMFONTS.FON aliases.
- CONTROL.INI, WINVER.EXE (the media ships it extensionless as `WINVER`),
  SETUP.EXE and EXPAND.EXE.
- `MAIN.GRP`, `ACCESSOR.GRP` and `GAMES.GRP` generated from SETUP.INF
  `[progman.groups]` plus the `[Main]`/`[Accessories]`/`[Games]` item lists,
  with each item's real NE icon resource embedded in the Windows 3.0 VGA
  planar form. PROGMAN.INI lists the three groups with full 8.3 paths
  (`C:\WINDOWS\MAIN.GRP`, etc.). The Main group includes all seven SETUP.INF
  items; DOS Prompt carries its PROGMAN.EXE icon but cannot launch until a
  DOS `COMMAND.COM` is staged.

`lune run tools/app_harness.lua audit` currently reports **0 files absent from
the media** for the audited sections; the only non-staged files are:

| Section | Files | Why not staged |
| --- | --- | --- |
| `[display]` | 42/43 present, only VGA staged | Other display drivers (CGA/EGA/Herc/8514/Plasma) are not needed by the VGA profile |
| `[net]` | CONTROL.INI + WINVER staged | SMARTDRV/RAMDRIVE/EMM386 are DOS drivers, present only as `.SY$` |
| `[network]` | 10 present | `network.drv` is empty; real mode needs no network stack |
| `[dos.mouse.drivers]` | MOUSE.SYS/MOUSEHP.SYS as `.SY$` | DOS mouse drivers need expansion and CONFIG.SYS support; Windows gets a driver via `mouse.drv` |
| `[pif]` | generated by Setup | Only 123.PIF ships; the rest of the PIF table is generated text |
| `[progman.groups]` | generated from SETUP.INF | `Install.seed` builds the three standard `.GRP` files from the item sections |

Files that still need action for a *complete* DOS+Windows install:

1. `EXPAND.EXE` must expand `SMARTDRV.SY$`, `RAMDRIVE.SY$`, `EMM386.SY$`,
   `MOUSE.SY$`, `MOUSEHP.SY$` and `EGA.SY$` before a real CONFIG.SYS can use them.
2. `COMMAND.COM` is a DOS file, not present on the Windows media. The Main group
   "DOS Prompt" item is staged with its icon, but cannot launch until a DOS
   command interpreter is staged.
3. Program groups: `MAIN.GRP`, `ACCESSOR.GRP`, `GAMES.GRP` are now generated
   by `Install.seed` and listed in PROGMAN.INI. The format is the real 3.0
   `PMCC` group file: zero-sum checksum, word `wBitsPerPixel`/`wPlanes`
   matching VGA mode 12h (`1`/`4`), and icons stored as four interleaved 1bpp
   planes for `USER.408 CreateCursorIconIndirect`. A plain 55k WIN.COM boot
   opens all three groups and paints the Main group window, its item icons,
   and the minimized Accessories/Games group icons
   (`tools/out/groups-win.png`).
4. Printer drivers: none are installed. The `[display]`/printer sections are
   present in the media but no `[PrinterPorts]`/`[Devices]` entries exist in
   WIN.INI.

## 5. Next concrete blockers

The 640K real-mode wall is now the limiting factor, not the boot chain:

1. **Icon and label polish.** A few icon planes still show colour artifacts,
   and Program Manager packs group labels too tightly in 640x480. Both are
   cosmetic; the group items launch through the real `AH=4Bh` path.
2. **Demand segment loading** (or at least a swap/segment allocator) so
   79-segment apps like WRITE fit without loading every segment eagerly.
   WRITE already renders in the harness; this is the general fix.
3. **DOS Prompt / `COMMAND.COM`.** The Main group carries the item and its
   icon, but `COMMAND.COM` is a DOS file and is not on the Windows media.
   Staging a real DOS 5.0 command interpreter unlocks it.
4. **Third-party media matrix.** Word 1.x, Excel 2.x and PhotoStyler 1.1a are
   the next real-mode targets; see section 3 and `docs/PHOTOSHOP.md`.
5. **Real-mode resource budget.** USER/GDI heaps are 64K each in real mode;
   group files and `RUN=`/`LOAD=` entries compete for them (KB Q65452). The
   standard three groups load together; keep `RUN=`/`LOAD=` empty while
   checking the shell.


## 6. Interactive input

The Windows path now uses the real input hardware model rather than LED
fakes:

| Input | Path | Verified |
| --- | --- | --- |
| Keyboard | Roblox KeyCode → PC set-1 make/break → 8042 port 0x60 → IRQ1 → KEYBOARD.DRV | Alt+F opens Program Manager's File menu; Notepad accepts `hello world`, `Hello, World!`, Enter, and typematic `aaaaaa` |
| Mouse | host pointer → 640×480 guest coordinates → PS/2 packets → IRQ12/C207 → MOUSE.DRV | Program Manager File menu opens, a desktop click closes it, and a minimized group's control menu opens |
| Calculator | Keyboard scan codes | `1 + 2 Enter` displays `3.` |

MOUSE.DRV moves two pixels per PS/2 count. `Machine.setMouse` therefore sends
half-counts with a remainder; the guest pointer now tracks the host 1:1. The
8042 keyboard keeps one latched output byte so a chained BIOS INT 9 handler
sees the same scan code its caller read. `INT 9` acknowledges IRQ1; Windows
does its own translation and chains only for the keys it wants the BIOS to
handle.

The same DOS pass fixed the directory views: MS-DOS Executive's file list and
File Manager's tree were reading the FindFirst filename at the real DTA offset
`1Eh`, while the emulator wrote it at `20h` after a non-DOS cluster field.
The screenshots below are unprompted app output from the normal harness, with
no GDI or app patches.

Screenshots: `docs/screenshots/r6-notepad-keyboard.png`,
`docs/screenshots/r6-calculator-keyboard.png`,
`docs/screenshots/r6-progman-mouse-menu.png`,
`docs/screenshots/r6-studio-keyboard.jpg` (Alt+F in Studio),
`docs/screenshots/r7-studio-program-manager.jpg` (Place B),
`docs/screenshots/r6-msdos-executive.png`,
`docs/screenshots/r6-winfile-tree.png`.

## 7. Sources

- Microsoft KB Q58317, "Windows 3.0 Modes and Memory Requirements":
  <http://jeffpar.github.io/kbarchive/kb/058/Q58317/>
- Microsoft KB Q4461, "Excel 3.0 requires Windows standard or 386 enhanced mode":
  <https://helparchive.huntertur.net/document/4461>
- Microsoft KB Q92365, "Using Harvard Graphics with Windows 3.0, 3.0a"
  (DOS Harvard Graphics runs in real mode):
  <https://helparchive.huntertur.net/document/41752>
- Microsoft KB Q65452, "Windows 3.0 Err Msg: Cannot Open Group File (in Real Mode)":
  <https://helparchive.huntertur.net/document/42184>
- VOGONS, "The big list of 8086 real-mode Windows 3.0 compatible software":
  <https://www.vogons.org/viewtopic.php?t=79572>
- Wikipedia, "Windows 3.0" (real mode, 8088 minimum, 4MB EMS, Word 1.x/Excel
  2.x exception): <https://en.wikipedia.org/wiki/Windows_3.0>
- OSDev wiki, NE format (flag word and real/protected-mode table):
  <https://wiki.osdev.org/NE>
- Wikipedia, "Picture Publisher" (version 3.0 rewritten for Windows 3.0):
  <https://en.wikipedia.org/wiki/Picture_Publisher>
- WinWorld, "Micrografx Picture Publisher 3.1" (Windows 3.0 line):
  <https://winworldpc.com/product/micrografx-picture-publisher/31>
- Australian Computer Museum Society, Harvard Graphics 3.0 for Windows
  requirements (386/4MB/Windows 3.1):
  <https://hub.catalogit.app/australian-computer-museum-society-(acms)/folder/entry/527aef90-9c71-11ee-8646-4b09c5861d69>
