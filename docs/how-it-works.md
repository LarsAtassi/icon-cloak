# How IconCloak works on macOS 27

Classic menu bar hiders (Vanilla, Hidden Bar, early Ice) all use one trick: add a divider
item and, to hide, make it thousands of points wide, pushing everything left of it off
the screen. macOS 27 changed how the menu bar is laid out, and that trick no longer works.
This page covers what changed, what IconCloak does instead, and what didn't work.

Everything here was found by experiment on a 14" MacBook Pro (notch, 2056 pt wide) and on
external displays without a notch (2560 × 1440 and a 1440 × 2560 portrait display), running
macOS 27.0 (26A428) to 27.2.1 (26B131). None of it is documented by Apple.

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
- **Following the visible icons.** The right filler is sized to end exactly where the
  visible icons begin. If one of them changes width while collapsed (an icon appears or
  shows changing text), the filler no longer fits. So every 0.3 s IconCloak reads where `|`
  really is and resizes the fillers when it moved.
- **Where macOS puts its `«`** differs: on the MacBook's notched display it sits at the
  right end of the right filler, next to the visible icons; on displays without a notch,
  near the middle. IconCloak only draws its own `«` (and covers macOS's) in the second case,
  and only switches after seeing the change on two checks in a row, since `«` is briefly
  missing or in between while macOS relays out the menu bar.
- **Items macOS never hides** (the microphone/camera pill during calls, a screen-recording
  button) are moved next to the visible icons while collapsed, which takes room the right
  filler didn't account for. If the filler gets pushed aside, IconCloak shrinks it in
  growing steps (32, 64, 128 … pt) until it fits, then measures the exact room. It doesn't
  hide again from scratch (that measures the expanded layout again, which doesn't include
  those items, and loops). What it learned is reused on the next hide.
- **macOS 27.2 changes:** the overflow button `«` (now identified as
  `menu-bar-overflow-indicator`) needs its own room next to the right filler, so IconCloak
  leaves ~24 pt for it. The right filler may extend under the notch; it counts as in place
  as long as its right edge is right of the notch. Simulated ⌘-drags only register with a
  short hold after pressing and a pause before releasing.
- **Settling.** Measurements only count when seen twice in a row, and the own-`«` decision
  waits 1.5 s after a resize and needs three consistent checks, because macOS passes
  through in-between layouts (and can move its `«` between the fillers) while animating.
- **Stranded tooltips.** If the pointer rests on an icon that then goes into the overflow,
  its app never gets a "mouse exited", and the icon's tooltip stays on screen for good (only
  real pointer movement over the visible icon clears it; events sent straight to the app
  don't). So when another app's tooltip is showing at the moment IconCloak hides, it first
  moves the pointer off the menu bar for a moment and puts it back without events.
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
- **New icons.** macOS puts a new app's status item at the far left, which is the hidden
  section, so new icons would disappear right away. IconCloak remembers which apps' icons it
  has seen (by bundle ID). When an unknown app's icon shows up left of `|`, it ⌘-drags it right
  of `|`, then re-arranges its own items, since the move can leave the invisible filler on the
  wrong side of `|` (which keeps the right filler from ever fitting). Hidden icons can't be
  seen through accessibility at all, so when an unknown app launches while collapsed,
  IconCloak briefly expands to check. Background-only apps are skipped, and apps without an
  icon are remembered too. On the first run, everything already in the menu bar counts as
  known, and more than three unknown icons at once are taken as an existing arrangement, not
  new apps. `NSWorkspace.didLaunchApplicationNotification` isn't posted for apps without a
  Dock icon (most menu bar apps), so IconCloak observes `runningApplications` instead.
- **A filler on the wrong side.** If the filler ends up right of `|` (an icon dropped between
  them, for example), no width makes the icons hide. While hidden, IconCloak checks for that
  (the filler is then the rightmost of its items), shows the icons, re-arranges and hides
  again, once. And if shrinking and growing the right filler keeps repeating, it stops after
  three rounds, shows the icons and pauses auto-hide.
- **Its own drags.** IconCloak never starts a drag while a mouse button is held (you may be
  dragging an icon yourself), and it ignores the mouse-up of its own drags, which otherwise
  look like yours when the pointer is put back onto the menu bar. After a drag the pointer is
  put back without events, so the icon under the drop point still thinks it's hovered and
  may show its tooltip at the restored position for good. Two seconds after a drag, if
  another app's tooltip is on screen, IconCloak moves the pointer away for a moment, as it
  does before hiding.
- **Don't touch the drag sequence.** macOS 27.2 reorders status items with a WindowServer
  window drag (`MenuBarAgent` logs `com.apple.menubar:drag`, the WindowServer logs under
  `windowinteraction`). Extra simulated events around the drop (a pointer move 50 ms after
  releasing, key events for ⌘) left the WindowServer unable to track any drag, real ones
  included, until the next logout: "no client initiated window drag trait gesture to
  activate for mouse". Restarting `MenuBarAgent` doesn't help. After changing `drag()`, do
  one drag and check the log before doing more:
  `/usr/bin/log show --last 1m --info --predicate 'process == "WindowServer" AND eventMessage CONTAINS "window drag trait"'`
  (a healthy drag has one `commitDragMovement` per step and no such error).
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
- On the notched display, a right filler a few points too short lets macOS squeeze the left
  filler in under the notch (with `«` between them), and `|`'s right edge then reads 8 pt
  further right. IconCloak's measurements settle on the right size, but it's one more layout
  to keep in mind.
