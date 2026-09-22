# Installing IconCloak

This guide walks through installing, updating and removing IconCloak, and fixing the problems
people most often run into. IconCloak needs **macOS 27**.

- [Install](#install)
- [First steps](#first-steps)
- [Update](#update)
- [Uninstall](#uninstall)
- [Troubleshooting](#troubleshooting)
- [Build from source](#build-from-source)

## Install

### 1. Download

Download **IconCloak-&lt;version&gt;.zip** from the
[latest release](https://github.com/LarsAtassi/icon-cloak/releases/latest) and double-click
it to unzip. You get **IconCloak.app**.

Optional: to check the download, compare its checksum with the `.sha256` file from the release.

```bash
shasum -a 256 ~/Downloads/IconCloak-*.zip
```

### 2. Move it to Applications

Drag **IconCloak.app** into your **Applications** folder. Run it from there, not from
Downloads: macOS ties the Accessibility permission to the app's location, and Launch at Login
expects it in Applications.

### 3. Open it the first time

IconCloak isn't notarized by Apple, because that needs a paid developer account. So the first
time you open it, macOS shows a warning that it can't verify the app, and doesn't open it.

1. Click **Done** (or **OK**) in the warning.
2. Open **System Settings → Privacy & Security**.
3. Scroll down to the **Security** section. There's a message about IconCloak being blocked.
   Click **Open Anyway**.
4. Confirm with your password or Touch ID, then click **Open Anyway** once more.

You only need to do this once. The **Open Anyway** button only appears for a while after you
try to open the app, so if you don't see it, open IconCloak again and go back to that page.

### 4. Grant Accessibility

IconCloak needs Accessibility to read where the app menus end, to catch clicks on the `«`
button, and to keep `»` in front. It doesn't use the network or collect any data.

1. When IconCloak asks, click **Open System Settings**. If there's no prompt, open
   **System Settings → Privacy & Security → Accessibility** yourself.
2. Switch on **IconCloak**. If it isn't in the list, click **+**, choose
   **Applications → IconCloak**, then switch it on.

IconCloak notices the permission within a couple of seconds. No restart is needed.

## First steps

After launch you'll see two new items in the menu bar: `»` and a thin `|`.

```
» [icons that get hidden] | [icons that stay visible]
```

- **Choose what to hide:** hold **⌘** and drag menu bar icons between `»` and `|`. Icons
  right of `|` always stay visible.
- **Hide:** click `»`, or press **⌃⌥⌘H**. Only macOS's own `«` button stays.
- **Show:** click `«`, or press **⌃⌥⌘H** again.
- **Settings:** right-click `»` → **Settings…**. There you'll find:
  - **Hide icons automatically** after a number of seconds you choose. IconCloak waits while
    your pointer is on the menu bar or a menu is open, so it never hides an icon you're using.
  - **The keyboard shortcut**, which you can change: click it and press the new combination
    (Esc cancels, **Reset** restores ⌃⌥⌘H).
  - **Launch at login.**

`»` always stays in front of the leftmost icon. If you drag an icon to its left, IconCloak
moves `»` back in front after a moment (your mouse pointer briefly jumps), and the icon
becomes one of the hidden ones.

## Update

1. Right-click `»` → **Quit IconCloak**.
2. Download the new release and replace **IconCloak.app** in Applications.
3. Open it.

All official releases are signed with the same certificate, so the Accessibility permission
carries over, and macOS normally keeps your icon arrangement too. You may need to click
**Open Anyway** once more (step 3 of the install).

## Uninstall

1. Right-click `»` → switch off **Launch at Login**, then **Quit IconCloak**.
2. Delete **IconCloak.app** from Applications.
3. Remove it from **System Settings → Privacy & Security → Accessibility** (select it, click **–**).
4. Optional: remove its settings and log.

```bash
defaults delete io.github.larsatassi.IconCloak
```

```bash
rm -f ~/Library/Logs/IconCloak.log
```

Your menu bar icons aren't affected. Once IconCloak quits, they're all shown normally again.

## Troubleshooting

### The Accessibility switch is on, but IconCloak still doesn't work

Signs of this: icons "bounce" to the left of the notch when you click `«`, or hidden icons
show up next to the app menus when you switch apps.

The entry in the list probably belongs to an older copy of the app, for example one that
was built from source or ran from a different folder. macOS then shows the switch as on, but
it doesn't apply.

1. Quit IconCloak.
2. In **Privacy & Security → Accessibility**, select **IconCloak** and remove it with **–**.
   Just switching it off isn't enough.
3. Reset the permission in Terminal:

   ```bash
   tccutil reset Accessibility io.github.larsatassi.IconCloak
   ```

4. Open **/Applications/IconCloak.app** again and grant the permission when asked.

### I can't find the Accessibility settings

Open them directly: paste this into Terminal, or into Safari's address bar.

```bash
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
```

### "Open Anyway" doesn't appear

Try to open IconCloak again, then go straight back to **Privacy & Security**. The button
only shows up for a while after a blocked launch.

If it still doesn't appear, you can remove the download quarantine in Terminal instead.
Only do this for a copy you downloaded from this project's releases page.

```bash
xattr -dr com.apple.quarantine /Applications/IconCloak.app
```

### Hidden icons show up next to the app menus

IconCloak can't read the app menus. This is almost always the Accessibility permission; see
[the first entry](#the-accessibility-switch-is-on-but-iconcloak-still-doesnt-work).

### `»` isn't on the far left

Right-click `»` → **Settings…** → **Move » to the Far Left**. This needs the Accessibility
permission.

### The wrong icons are hidden

Everything between `»` and `|` gets hidden. Expand with `«`, then hold **⌘** and drag icons
into or out of that area.

### There are two `«` buttons (external display)

On displays without a notch, macOS puts its own `«` near the middle of the menu bar, so
IconCloak adds one next to your visible icons. Both show the hidden icons. (If an app draws a
fake notch in the middle of the screen, it may cover macOS's one.)

### Hiding doesn't work on one of my displays

IconCloak sets up hiding for the display your pointer is on. Move the pointer onto that
display and hide the icons again. If hiding fails, IconCloak shows the icons again right away
and pauses auto-hide until the next successful hide.

### The keyboard shortcut doesn't do anything

Another app may already be using it. Choose a different one in **Settings…**, or use `»`
and `«` with the mouse.

### Something else

Right-click `»` → **Settings…** → **Open Log** and include the last lines in an
[issue](https://github.com/LarsAtassi/icon-cloak/issues), together with your macOS version
and display setup (built-in with notch, external display, …). The log only contains
IconCloak's own layout events and the names of apps you switched to.

## Build from source

You need macOS 27 and the Xcode Command Line Tools.

```bash
xcode-select --install
```

```bash
git clone https://github.com/LarsAtassi/icon-cloak.git
cd icon-cloak
scripts/create-dev-cert.sh
scripts/build-app.sh --install
```

`create-dev-cert.sh` creates a self-signed "IconCloak Dev" certificate in your login keychain.
It's optional, but without it macOS forgets the Accessibility permission after every build.
`build-app.sh --install` builds the app, copies it to `/Applications` and opens it. Grant
Accessibility to that copy as described [above](#4-grant-accessibility).

A build you make yourself is signed with your own certificate, not the one used for official
releases. When switching between the two, follow
[the first troubleshooting entry](#the-accessibility-switch-is-on-but-iconcloak-still-doesnt-work)
to reset the permission.
