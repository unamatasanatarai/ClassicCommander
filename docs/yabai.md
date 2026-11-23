# Floating ClassicCommander's windows in yabai

ClassicCommander has one main window and opens its other windows separately: Find Files,
Synchronize, Lister, and so on. yabai tiles every standard window, so by default these get
pushed into the layout next to the main window.

Every window title starts with the app name, so a yabai rule can tell the main window apart
from the rest. Windows open centred on the main window, so floating windows appear on top of
it, not in a corner. Older builds didn't have the `ClassicCommander - ` prefix; if
`yabai -m query --windows` shows titles without it, rebuild the app.

| Window | Title | Kind |
|---|---|---|
| Main window | `ClassicCommander` | window |
| Find Files (⌥7) | `ClassicCommander - Find Files` | window |
| Synchronize directories | `ClassicCommander - Synchronize directories` | window |
| Synchronize confirmation | `ClassicCommander - Synchronize` | sheet on Synchronize |
| Compare (View in Synchronize) | `ClassicCommander - Compare: <file name>` | window |
| Lister (View) | `ClassicCommander - Lister - [<path>]` | window |
| Multi-Rename Tool (⌃M) | `ClassicCommander - Multi-Rename Tool` | window |
| Copy / move queue (Net → Queue) | `ClassicCommander - Queue` | window |
| Copy / Move dialog | `ClassicCommander - Copy`, `ClassicCommander - Move` | window (modal) |
| Target file exists | `ClassicCommander - Target file exists` | window (modal) |
| Options | `ClassicCommander - Options` | window |
| FTP connection manager (⌃F) | `ClassicCommander - Connect to FTP server` | window |
| FTP connection settings | `ClassicCommander - Connection settings` | sheet on the connection manager |

Sheets and alerts (confirmations, password prompts, errors) are attached to their window or
reported to macOS as dialogs. yabai leaves those alone, so the rules below are only needed
for the windows marked *window*.

Rules go in `~/.yabairc` (or `~/.config/yabai/yabairc`). The regular expressions use the app
name as it appears in `yabai -m query --windows` (`"app"`). If you build the app under
another name (`APP_NAME` in `scripts/config.sh`), use that name instead.

## 1. Float every window except the main one (recommended)

```sh
yabai -m rule --add label=cc-float app="^ClassicCommander$" title!="^ClassicCommander$" manage=off
```

The main window stays tiled. Everything else opens floating, centred where macOS puts it.

## 2. Float by title prefix

The same result, written as "titles that start with `ClassicCommander - `":

```sh
yabai -m rule --add label=cc-float app="^ClassicCommander$" title="^ClassicCommander - " manage=off
```

## 3. One rule per window

Pick the windows you want floating and leave out the lines for the ones you want tiled.
This is every window ClassicCommander opens:

```sh
yabai -m rule --add label=cc-find     app="^ClassicCommander$" title="^ClassicCommander - Find Files$" manage=off
yabai -m rule --add label=cc-sync     app="^ClassicCommander$" title="^ClassicCommander - Synchronize directories$" manage=off
yabai -m rule --add label=cc-sync-ok  app="^ClassicCommander$" title="^ClassicCommander - Synchronize$" manage=off
yabai -m rule --add label=cc-diff     app="^ClassicCommander$" title="^ClassicCommander - Compare: " manage=off
yabai -m rule --add label=cc-lister   app="^ClassicCommander$" title="^ClassicCommander - Lister - " manage=off
yabai -m rule --add label=cc-queue    app="^ClassicCommander$" title="^ClassicCommander - Queue$" manage=off
yabai -m rule --add label=cc-options  app="^ClassicCommander$" title="^ClassicCommander - Options$" manage=off
yabai -m rule --add label=cc-ftp      app="^ClassicCommander$" title="^ClassicCommander - Connect to FTP server$" manage=off
yabai -m rule --add label=cc-ftp-edit app="^ClassicCommander$" title="^ClassicCommander - Connection settings$" manage=off
yabai -m rule --add label=cc-copy     app="^ClassicCommander$" title="^ClassicCommander - (Copy|Move)$" manage=off
yabai -m rule --add label=cc-rename   app="^ClassicCommander$" title="^ClassicCommander - Multi-Rename Tool$" manage=off
yabai -m rule --add label=cc-exists   app="^ClassicCommander$" title="^ClassicCommander - Target file exists$" manage=off
```

The Synchronize confirmation and the connection settings normally open as sheets, which yabai
doesn't tile anyway. Their rules only matter if you have yabai manage sheets.

### Dialogs only

The short-lived dialogs float; Synchronize, Compare and Lister stay tiled:

```sh
yabai -m rule --add label=cc-copy    app="^ClassicCommander$" title="^ClassicCommander - (Copy|Move|Target file exists)$" manage=off
yabai -m rule --add label=cc-find    app="^ClassicCommander$" title="^ClassicCommander - Find Files$" manage=off
yabai -m rule --add label=cc-options app="^ClassicCommander$" title="^ClassicCommander - Options$" manage=off
yabai -m rule --add label=cc-ftp     app="^ClassicCommander$" title="^ClassicCommander - Connect to FTP server$" manage=off
yabai -m rule --add label=cc-queue   app="^ClassicCommander$" title="^ClassicCommander - Queue$" manage=off
```

### Working windows only

Synchronize directories, Compare and Lister float; the dialogs stay tiled:

```sh
yabai -m rule --add label=cc-sync   app="^ClassicCommander$" title="^ClassicCommander - Synchronize directories$" manage=off
yabai -m rule --add label=cc-diff   app="^ClassicCommander$" title="^ClassicCommander - Compare: " manage=off
yabai -m rule --add label=cc-lister app="^ClassicCommander$" title="^ClassicCommander - Lister - " manage=off
```

## 4. Float and keep above the main window

Add a layer so a floating window doesn't disappear behind the tiled main window when you click it:

```sh
# yabai 6 and later
yabai -m rule --add label=cc-float app="^ClassicCommander$" title!="^ClassicCommander$" manage=off sub-layer=above
# yabai 5 and earlier
yabai -m rule --add label=cc-float app="^ClassicCommander$" title!="^ClassicCommander$" manage=off layer=above
```

## 5. Float with a fixed position and size

`grid=<rows>:<cols>:<x>:<y>:<width>:<height>` places a floating window on a grid of the screen.
This rule opens every secondary window in the middle two-thirds of the screen:

```sh
yabai -m rule --add label=cc-float app="^ClassicCommander$" title!="^ClassicCommander$" manage=off grid=6:6:1:1:4:4
```

## 6. Don't tile ClassicCommander at all

```sh
yabai -m rule --add label=cc-all app="^ClassicCommander$" manage=off
```

## 7. Toggle by hand

To float or tile the focused window yourself (for example with skhd):

```sh
# ~/.skhdrc
alt - t : yabai -m window --toggle float --grid 6:6:1:1:4:4
```

## Applying, checking and removing rules

New rules only affect windows that open afterwards. To apply them to windows already open (yabai 6+):

```sh
yabai -m rule --apply
```

To check how yabai sees ClassicCommander's windows:

```sh
yabai -m query --windows | jq '.[] | select(.app == "ClassicCommander") | {title, subrole, "is-floating"}'
```

To list your rules and remove one by its label:

```sh
yabai -m rule --list
yabai -m rule --remove cc-float
```
