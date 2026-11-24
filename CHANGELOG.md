# Changelog

## v0.8.1

- Windows 3.1 standard mode resumes after the MS-DOS Prompt: the swap-in
  restores the KRNL286 block that DSWAP was handed (`core/Dos.lua`, test
  `dos_swap_in_restores_the_kernel_block_dswap_was_handed`).
- The emulator window stays centred in Studio: it is sized from the desktop
  frame and refitted when that frame resizes.
- Test suite: 1017 assertions, gate green.

## v0.8.0

Windows 3.0a (real mode) is feature complete for its scope: Program Manager,
all 20 bundled applications, mouse and keyboard, and the MS-DOS Prompt.

- MS-DOS Prompt in the real-mode build: stand-in `COMMAND.COM`
  (`fixtures/Command.lua`), EXEC return semantics after the kernel starts,
  scan-code to DOS key-buffer bridge, `VGACOLOR.GR2` grabber packed.
- Program Manager captions no longer clip: 110 px group item pitch and
  `IconSpacing=110` in WIN.INI.
- Windows 3.1 standard mode: boots to a drawn Program Manager; MS-DOS Prompt
  launches and exits. Fixed the DSWAP memory check (EXEC gives DSWAP all free
  memory), `INT 21h AH=4A` growth over a free neighbour, drive types for the
  swap file (`AH=44/08`, `AH=36`), reclaiming the ended DOSX/KRNL286 session,
  and seek-past-EOF zero fill. Resuming Windows after the swap-in is open
  (HANDOFF.md, R15; fixed afterwards by restoring the kernel block).
- Release models and archives contain emulator source only. Earlier releases
  attached Microsoft media; this one does not, and the README no longer
  points at it.
- Test suite: 1015 assertions, gate green (stylua, selene, luau-analyze strict,
  tests).

## v0.7.1 and earlier

See the GitHub releases page.
