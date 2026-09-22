# How IconCloak works on macOS 27

Classic menu bar hiders (Vanilla, Hidden Bar, early Ice) all use one trick: add a divider
item and, to hide, make it thousands of points wide, pushing everything left of it off
the screen. macOS 27 changed how the menu bar is laid out, and that trick no longer works.
This page covers what changed, what IconCloak does instead, and what didn't work.

Everything here was found by experiment on a 14" MacBook Pro (notch, 2056 pt wide) and on
external displays without a notch (2560 × 1440 and a 1440 × 2560 portrait display), running
macOS 27.0 (26A428). None of it is documented by Apple.

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

**Displays without a notch have an invisible one in the middle.** Status items fill the right
half first, then continue left of the center, and only then go into the overflow. A single
item can be at most half the display wide; a wider one is simply dropped.

**The space left of the notch fills from the notch outwards,** in the items' order. An item
that doesn't fit there is dropped, even when smaller items further out would have fit.

**Every display has its own menu bar, but an item has one width for all of them.** A width
that is right for one display is wrong for a display of another size.

## What IconCloak does

IconCloak adds three status items: `»` (collapse), `|` (the boundary) and an invisible
filler directly left of `|`. Everything left of `|` gets hidden:

```
Expanded:   [app menus]  (notch)  [»] [hidden icons] [|] [visible icons]
Collapsed:  [app menus][filler] (notch) [| as filler] [«] [visible icons]
```

- **Collapsing,** `|` grows to fill the space from the notch's right edge
  (`NSScreen.auxiliaryTopRightArea`, or the display's center without a notch) to its own
  right edge. The filler is shown and no longer fits on the right, so macOS moves it left
  of the notch. It sits directly left of `|`, so it's placed there before the icons it's
  meant to push out, and IconCloak sizes it to fill the gap between the app menus and the
  notch. The icons left of it fit nowhere and go into the overflow.
- **The filler is hidden while expanded** (`isVisible = false`; a zero-length item still
  leaves a gap). macOS puts it back in the same place when it's shown again.
- **Sizing follows the pointer.** The fillers are sized for the display the pointer is on,
  and resized when it moves to another display, when the frontmost app changes (its menus'
  width is read via the Accessibility API, `kAXMenuBarAttribute`), and when displays change.
- **Safety net.** One second after collapsing, IconCloak checks that the display's `«`
  exists. If not (a filler was dropped), it expands again and pauses auto-hide, so the user
  is never left without `»` or `«`.
- **Its own `«`.** Without a notch, macOS puts `«` at the boundary between the two sides,
  near the display's center, far from the visible icons (apps that draw a fake notch can
  even cover it). When that's the case, IconCloak draws its own `«` at the right edge of
  the right filler. macOS centers a status item's content and ignores text alignment, so
  it's an image as wide as the filler with the chevron at its right edge.
- **Finding its own items.** `NSStatusItem` window frames don't follow the layout macOS
  shows, so IconCloak gives its items accessibility labels and reads their real positions
  from `MenuBarAgent`'s accessibility tree.
- **Clicking `«`** would make macOS show the hidden icons left of the notch, where the
  left filler sits, so either nothing shows or the icons jump. IconCloak uses an event tap
  to catch left clicks on the button's frame (read via Accessibility from `MenuBarAgent`)
  and expands itself instead, so macOS never opens its overflow. As a fallback, it polls
  the button's label and expands if it changes.
- **Roles are assigned by position.** macOS 27 decides the initial order of new items and
  doesn't store it in the app's defaults, so on launch the left one of `»`/`|` becomes `»`.
- **Arranging the items.** Item positions are owned by `MenuBarAgent` and aren't stored
  anywhere an app can change (the app's defaults only hold a visibility flag). So IconCloak
  posts ⌘-drags with `CGEvent` (then restores the cursor) to put the filler directly left
  of `|` and `»` in front of the leftmost icon. This happens at launch, from the menu, and
  half a second after the user ⌘-drags something in the menu bar (a global `leftMouseUp`
  monitor), so icons can't be placed left of `»`.
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
| Using `»` (on the far left) as the left filler | Worked with the notch, but without one the icons are placed left of the center first and the filler gets dropped. It has to sit directly left of `\|`. |
| One filler spanning the whole free space (no notch) | Dropped once it's wider than half the display. |
| Making the icons slide right (toward the visible icons) when collapsing | macOS animates hidden icons into its `«`, which always sits at the left end of the right filler. A shorter filler just shifts everything, `«` included. |
| Sizing the fillers once for all displays | Wrong on displays of another width: the filler gets dropped or leaves room for the icons. |

## Open questions

- Whether the three-item layout needs any tuning on the MacBook's own notched display
  (tested before the filler moved next to `|`).
- Whether `MenuBarAgent` changes this behavior in later macOS 27.x updates.
