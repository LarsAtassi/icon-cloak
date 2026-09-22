# How IconCloak works on macOS 27

Classic menu bar hiders (Vanilla, Hidden Bar, early Ice) all use one trick: add a divider
item and, to hide, make it thousands of points wide, pushing everything left of it off
the screen. macOS 27 changed how the menu bar is laid out, and that trick no longer works.
This page covers what changed, what IconCloak does instead, and what didn't work.

Everything here was found by experiment on a 14" MacBook Pro (notch, 2056 pt wide)
running macOS 27.0 (26A428). None of it is documented by Apple.

## What changed in macOS 27

**One process draws the whole menu bar.** Apps no longer get their own menu bar windows.
The window list shows a single `MenuBarAgent` window spanning the menu bar, and the
frames an app reads from its own `NSStatusItem` windows no longer track where the item
actually appears.

**Items that don't fit are moved, not clipped.** `MenuBarAgent` places status items:

1. right of the notch,
2. then **left of the notch**, after the frontmost app's menus,
3. and only when both are full, in its own overflow, a `«` button
   (accessibility label "Show Hidden Menu Bar Items").

**Clicking `«` re-lays out the menu bar.** The overflowed items are shown inline, using
the space left of the notch, and the button turns into `»` ("Hide Menu Bar Items"). The
button has no accessibility press action, so it only reacts to real clicks.

**The overflow button can't be removed.** Whenever any item is in overflow, macOS reserves
room for `«`. Widening other items shrinks them instead.

## What IconCloak does

IconCloak adds two status items: a divider that shows `»` (collapse) and a toggle that
shows `|` (the boundary). Everything left of `|` gets hidden:

```
Expanded:   [app menus]  (notch)  [» divider] [hidden icons] [| toggle] [visible icons]
Collapsed:  [app menus][divider filler] (notch) [toggle filler] [«] [visible icons]
```

- **Collapsing,** the toggle grows to fill the space from the notch's right edge
  (`NSScreen.auxiliaryTopRightArea`) to its own right edge. The divider no longer fits on
  the right, so macOS moves it left of the notch, where IconCloak sizes it to fill the gap
  between the app menus and the notch. The icons left of the toggle fit nowhere and go
  into the overflow.
- **Switching apps** changes the width of the app menus, so the left filler is resized on
  every `didActivateApplicationNotification`. The app menus' extent is read through the
  Accessibility API (`kAXMenuBarAttribute` of the frontmost app).
- **Clicking `«`** would make macOS show the hidden icons left of the notch, where the
  left filler sits, so either nothing shows or the icons jump. IconCloak uses an event tap
  to catch left clicks on the button's frame (read via Accessibility from `MenuBarAgent`)
  and expands itself instead, so macOS never opens its overflow. As a fallback, it polls
  the button's label and expands if it changes.
- **Roles are assigned by position.** macOS 27 decides the initial order of new items and
  doesn't store it in the app's defaults, so on launch (with both items visible) the left
  one becomes the divider and the right one the toggle.
- **Moving `»` to the front.** Item positions are owned by `MenuBarAgent` and aren't
  stored anywhere an app can change (the app's defaults only hold a visibility flag). To
  put `»` in front of the leftmost icon, IconCloak reads the item frames from
  `MenuBarAgent`'s accessibility tree and posts a ⌘-drag with `CGEvent`, then restores the
  cursor. This happens at launch, from the menu, and half a second after the user
  ⌘-drags something in the menu bar (a global `leftMouseUp` monitor), so icons can't be
  placed left of `»`.
- **Expanding** animates the items shrinking back from filler width (~300 ms, drawn by
  `MenuBarAgent`, so `NSAnimationContext` can't turn it off). During that time `»` and `|`
  are drawn transparent: they take their final width, so nothing shifts when they appear,
  but they don't visibly slide in from the far left.

## What didn't work

| Attempt | Result |
|---|---|
| Divider 10,000 pt wide (the classic trick) | Width capped at ~5,000 pt. macOS moved the divider itself out of the way, and the icons stayed. |
| Divider 250–1,000 pt wide | The divider and toggle moved left of the notch and **covered the app menus**. |
| Divider sized to the gap right of the notch | Worked with long app menus. With short ones (Finder, Calendar), the "hidden" icons appeared left of the notch. |
| Divider slightly wider, to squeeze out `«` | macOS shrank the divider instead. |
| Pressing `«` via Accessibility | The button has no press action. |
| Reading our own item positions | `NSStatusItem` window frames don't follow the layout `MenuBarAgent` actually shows. |
| Zero-length divider while expanded | Still leaves a ~16 pt gap. Hiding it with `isVisible` works. |
| Hiding the divider while expanded (`isVisible = false`) | Works and leaves no gap, but a visible `»` on the left plus a `\|` boundary turned out easier to use. |

## Open questions

- Displays without a notch (external monitors, older Macs) and multiple displays.
- Whether `MenuBarAgent` changes this behavior in later macOS 27.x updates.
