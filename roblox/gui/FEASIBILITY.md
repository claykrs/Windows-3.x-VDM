# Native ScreenGui mapping for the Windows 3.0 GUI — spike result

**Verdict: reject.** A 1:1 native mapping is not feasible, and the parts that
are feasible are not worth the cost. The VGA framebuffer sink should stay the
only renderer for the Windows 3.0 guest.

Windows 3.0's GUI is not a widget tree. It is a window manager (USER.EXE) plus
an immediate-mode raster API (GDI.EXE) plus a display driver. What a native
mapper can own is the small declarative layer USER keeps: window rectangles,
styles, captions, menu item lists and standard control kinds. What it cannot
own is the content of every window: applications, USER's own control window
procedures and USER's non-client code all paint with GDI into a device context,
inside a clip region, using pens, brushes, bitmap fonts, bitmaps and raster
operations. There is no retained scene graph to translate.

## 1. What maps, what does not

| Win16 surface | ScreenGui? | Why |
| --- | --- | --- |
| Window rects, parent/child nesting, z-order | **Mostly** | A Frame tree with `ZIndex` maps the window tree. Win16 z-order is a sibling list; child coordinates are parent-client-relative. Roblox `ClipsDescendants` gives rectangular clipping only. |
| Captions, borders, min/max boxes, menu bar | **Cosmetic only** | The shapes are easy, but every size comes from the display driver's non-client metrics (`SM_CYCAPTION`, `SM_CYMENU`, `SM_CXVSCROLL`, ...). Copying those integer metrics is possible; keeping them exact under Roblox's fractional viewport scaling is not. |
| Standard controls (`BUTTON`, `EDIT`, `STATIC`, `LISTBOX`, `COMBOBOX`, `SCROLLBAR`) | **Only by reimplementing them** | Those classes are USER window procedures that paint themselves with GDI. Intercepting `CreateWindow` for them means also owning `BM_*`, `EM_*`, `LB_*`, `WM_CTLCOLOR*`, focus, selection, scrolling, keyboard and owner-draw. That is a widget-set rewrite, not a mapping. |
| Menus (bar, popup, system menu, MDI menu merge) | **Standard items only** | Menu text, check marks, separators, accelerators and disabled items map to Frames/TextButtons. Metrics, mnemonic underlines, `MF_BITMAP`, `MF_OWNERDRAW`, system menus and MDI merging do not. |
| Text | **No, not faithfully** | Win3 uses bitmap fonts (`VGASYS.FON`, `VGAFIX.FON`, `VGAOEM.FON` and app fonts). Apps call `GetTextExtent`/`GetTextMetrics` and lay out to those integer metrics. Roblox's vector fonts have different metrics, so labels, dialogs and control alignment drift. An exact mapping means blitting glyphs from a font atlas — a rasterizer. |
| 16-colour palette and system colours | **Yes** | The VGA palette and `COLOR_*` defaults map cleanly to `Color3`. Per-control `WM_CTLCOLOR*` overrides need a message bridge; palettes and DIB colours go beyond the 16-colour subset. |
| Pens, brushes, regions, clipping | **No** | Win16 has styled and wide pens, hatch/bitmap brushes, arbitrary clip regions, mapping modes and ROP codes. Roblox has rectangular clipping, solid/simple strokes and images. |
| `BitBlt` / `StretchBlt` / `PatBlt`, DDBs and DIBs | **No** | Icons, bitmaps, brushes and many animations are raster operations, often with AND/OR/XOR ROPs. Supporting them means a software blitter with the same pixel semantics. |
| Owner-draw and custom controls | **No** | `WM_DRAWITEM`, `WM_MEASUREITEM`, `WM_COMPAREITEM`, `BS_OWNERDRAW`, `LBS_OWNERDRAW*`, `MF_OWNERDRAW`, `RegisterClass` window procs and subclassing all let the application paint arbitrary pixels. Only the guest knows what to draw. |
| Application client areas | **No** | Program Manager groups/icons, File Manager panes, Write pages and rulers, Paintbrush's canvas and tools, Solitaire's cards and animations are all `WM_PAINT` + GDI. |
| Invalidation and `WM_PAINT` sequencing | **No** | Win16 paints only the update region and clips to it. A retained tree can fake the result but not the message/clip semantics apps rely on. |
| Dialog layout | **No, not exact** | Dialog templates use dialog units derived from the system font (`MapDialogRect`). Substitute font metrics move every control. |
| Focus, capture, caret, modal stacks, menus-as-modal | **Possible, but orthogonal** | These are USER message semantics, not rendering. Native widgets do not remove the need to emulate them; they add a second implementation. |

## 2. Why the natural interception point is still a raster API

The display driver boundary is the obvious place to intercept. In the Windows
3.x DDK, a display driver exports `Output`, `StrBlt`/`ExtTextOut`, `BitBlt`,
`StretchBlt`, `Pixel`, `RealizeObject`, `SetAttribute`, `ScanLR`,
`SetPalette` and friends. That sounds close to a drawing API, but look at what
the driver actually receives:

- `Output(lpDestDev, wStyle, wCount, lpPoints, lpPPen, lpPBrush, lpDrawMode,
  lpClipRect)` — a destination surface, a shape code, points, a **physical
  pen**, a **physical brush**, a draw mode (ROP, colours, background mode) and
  a **clip rectangle**. No window handle, no control, no text box.
- `StrBlt`/`ExtTextOut` — a string, a `FONTINFO`, a `DRAWMODE` and a
  `TEXTXFORM`. The driver is expected to convert characters to glyphs or ask
  GDI to simulate the text.
- `BitBlt`/`StretchBlt` — source/destination surfaces and a raster operation.

The driver sees a flat destination surface, not an HWND. Windows share the
screen PDEVICE; a DC's clip region is how USER/GDI restrict painting to the
visible part of a window. So a "native display driver" cannot assign a
primitive to the right Frame without also intercepting DC creation,
`GetDC`/`BeginPaint` and USER's window regions. At that point you are
reimplementing the USER/GDI seam, not translating a display driver.

Two more consequences:

1. **Clip regions are load-bearing.** Overlapping windows, child controls, the
   menu bar, scrollbars and the update region all intersect. Roblox's
   `ClipsDescendants` is rectangular and hierarchy-based; arbitrary Win16
   regions would have to be intersected per primitive in Luau.
2. **The fallback is pixels anyway.** GDI's `Output` may return `-1` for an
   unsupported shape and let GDI simulate it. Simulation produces a bitmap
   that still has to be shown. Once arbitrary app painting exists, a bitmap
   path is mandatory — which is the VGA sink with extra steps.

The same applies one level up: hooking GDI's NE imports and interpreting
`Rectangle`/`TextOut`/`BitBlt` per HDC requires a full DC state machine
(mapping modes, saved DCs, objects, clip regions, memory DCs, ROPs). Apps also
create memory DCs, blit between them and read pixels back; without a pixel
surface for those, the semantics are wrong.

This is also a goal mismatch: the project exists to run genuine Microsoft
binaries. A native adapter would reimplement USER.EXE/GDI.EXE in Luau above the
emulated CPU, so the guest would no longer be the thing drawing the screen.

## 3. The prototype in this folder

`GuiSpike.client.lua`, `MockHost.lua` and `Win3Skin.lua` render a Win3-style
window through ScreenGui. It is a **visual mock**, not an adapter:

- `MockHost` exposes only declarative operations: create a window from a rect,
  styles, caption and menu list; create a standard control from a rect and a
  kind; set text/check/selection. Those are the parts that can map.
- It deliberately has **no** `onPaint`, no HDC, no pen/brush/font object, no
  clip region and no `BitBlt`. The missing paint hook is the finding, not a
  shortcut.
- It shows the window chrome (system menu, min/max, caption, menu bar), a
  popup menu (check mark, accelerator, separator, disabled item), a group box,
  static text, a checkbox, an edit field, a push button and a list box with a
  scrollbar. A small About dialog demonstrates z-order and overlap.
- Drag the title text to move a window; click a menu title to open it; `File >
  Exit` closes the main window.

Run it with:

```powershell
rojo serve roblox/gui/gui-spike.project.json
```

or copy `roblox/gui/` into `StarterPlayerScripts` as a folder. It is
independent of `VdmUi` and the emulator.

Studio smoke test (Place1, Play mode): the window, menu bar, File/Help popups,
About dialog, checkbox, edit field and push buttons were exercised. Opening a
menu, clicking a menu item, toggling the checkbox and closing the About dialog
all worked without errors. The screenshot used for review is not committed.

Fidelity caveats: Arial stands in for the System bitmap font; the metrics are
approximate; mnemonic underlines, exact menu metrics, owner-draw, focus rings
and real caret behaviour are absent; the checkbox uses a `✓` glyph; popup
dismissal and drag-from-title are simplified. The mock is ~1.4k lines of
visual-only code with no layout engine, font metrics, scrolling, focus model,
message loop or guest connection.

## 4. Effort comparison: shell + 5 apps vs. the VGA sink

| Work item | VGA sink (current) | Native adapter |
| --- | --- | --- |
| Renderer | Done: one EditableImage, 640x480 RGBA, dirty-rect uploads (`core/Vga` + `VgaSink`) | Per-window Frame trees plus a GDI primitive-to-instance mapper; a Luau rasterizer for the parts that cannot map |
| Guest support | VGA.DRV initialization, ports/VRAM (already in `core/Vga`), font resources | A fake USER/GDI seam: HWND tree, message routing, DC/object/clip state, owner-draw callbacks that have no ScreenGui representation |
| Standard controls | Free — USER paints them | 6 classes plus messages, focus, selection, scrolling, `WM_CTLCOLOR*`, owner-draw |
| Menus | Free — USER paints them | Menu bar, popups, metrics, mnemonics, system/MDI menus, owner-draw |
| Fonts | Free — the guest's FON resources | Glyph atlas + metrics + text layout; otherwise every dialog/control misaligns |
| Application painting | Free — the app's own GDI calls | Per-app shims; arbitrary owner-draw/custom controls are open-ended |
| Fidelity | Exact guest pixels | Approximate at best; never 1:1 |
| Per-app work | None | Unbounded; each new app exercises new GDI/USER paths |
| Host cost per frame | One image upload (region-limited) | Many instance/property updates per repaint, plus GC churn |
| Failure mode | Driver bring-up (the current critical path) | App renders wrong or not at all; silent message/clip divergence |

Sizing, using this repo as the yardstick:

- Existing renderer: ~1.4k lines in `core/Vga.lua` plus ~440 lines in
  `VgaSink.lua`. It already carries every Windows app and the DOS text mode.
- This mock: ~1.4k lines for the **visuals** of one window plus an About
  dialog. It has only click-level behaviour, no layout engine, no font
  metrics, no clipping regions, no guest and no real controls.
- A credible native adapter for a shell + 5 apps is an order of magnitude
  larger than the mock before it is usable (optimistically ~20k-40k lines,
  4-9 engineer-months), and it still fails on owner-draw, custom classes and
  exact text/dialog metrics. Every additional app adds compatibility work.
  This is an estimate, but the lower bound is driven by the message/DC/GDI
  surface, not by how pretty the chrome is.
- Both paths still need the guest booted (KERNEL/USER/GDI loads); the native
  adapter does not remove that work. Remaining VGA-specific work is
  driver/font bring-up on the existing path: no new UI code and no per-app
  work.

## 5. Recommendation

1. **Reject** native ScreenGui mapping as the Windows 3.0 renderer. Do not
   build a native adapter for the shell or the five apps.
2. **Keep the VGA sink authoritative.** It is the only path that runs the real
   guest and gives exact pixels. The remaining work is VGA.DRV/font bring-up,
   not UI.
3. **Optional, clearly scoped:** reuse `Win3Skin.lua` for a Roblox-native
   **host shell/skin** around the framebuffer — Win3-style window frame,
   emulator menus (Boot, Reset, Mount, About), status line. That is chrome for
   *our* UI, not a mapping of guest windows, and it can be built cheaply
   because the framebuffer stays the content surface.
4. **Narrow use case:** native rendering only for emulator-owned surfaces
   (boot splash, disk-swap prompt, About/settings). Never intercept guest
   dialogs or controls.

If someone wants to revisit this, the go/no-go prototype is one app
(Solitaire or Paintbrush) at the display-driver boundary, measured against
the VGA sink. Expect it to fail on animations and owner-draw; do not start
with five apps.

## Sources / caveats

- Windows 3.1 Device Drivers (`ddag31qh.hlp`), Graphics Functions —
  `Output`, `StrBlt`, `ExtTextOut`, `BitBlt`, `StretchBlt`, `Pixel`,
  `RealizeObject`, `SetAttribute`, `ScanLR`, `SetPalette`:
  <https://fragglet.github.io/dos-help-files/ddag31qh.hlp/Graphics_Functions.html>.
  Windows 3.0's VGA.DRV follows the same driver shape; the exact 3.0 export set
  is smaller.
- Metrics in the mock are approximations at 96 dpi, not measured from the
  staged 3.0a media. Treat them as illustrative.
- `VgaSink` line count is from the current branch; `core/Vga` is rounded.
