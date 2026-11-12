# x_rls_console

A replacement for BeamNG's in-game console (the one on **~**), written against BeamNG.drive 0.40.5. It works with or
without RLS. It replaces `lua/ge/extensions/ui/console.lua`, so the same key and anything that calls `ui_console` open
the new one. It keeps everything the stock console does (level filters, origin filter, GE Lua / TorqueScript / CEF JS /
per-vehicle commands, history, sandboxing, vehicle-controls toggle, fullscreen, font size, background alpha) and adds:

| | Stock console | This one |
| --- | --- | --- |
| Lines kept | 1,000 | 50,000 by default, adjustable from 1,000 to 500,000 (Log → Max lines kept) |
| Lines logged while the console is closed | Lost | Kept |
| Lines from before the console/Lua loaded | Missing | Back-filled from `beamng.log` (also Log → Reload everything from beamng.log) |
| Long messages | Cut at 256 characters on screen | Full text in the tooltip and the details pane, up to 64 KB per line |
| Pause (Scroll Lock) | Drops lines while paused | Holds them and adds them on resume |
| Selecting text | Not possible | Select rows, plus a details pane with real selectable text |
| Search | Origin only | Message and origin, as a filter or as highlight with next/previous |

## Selecting and copying

- **Click** a row to select it, **Ctrl+click** to add or remove one row, **Shift+click** for a range, or **click and drag**.
- **Ctrl+A** selects every shown row, **Up/Down** moves the selection (with Shift it extends), **Esc** clears it.
- **Double-click** selects a whole multi-line message, such as a full stack trace.
- **Ctrl+C** copies the selected rows as `time|level|origin|message`.
- The **details pane** under the log shows the selected text in a read-only text box, where you can select any part with
  the mouse and copy it with Ctrl+C. For one message it shows the message alone; for several it shows full lines.
- **Right-click** a row to copy the line or the message, select the whole message, filter or search by its origin, or
  show it in context.
- The **Copy** menu copies all shown lines, shown errors, shown errors and warnings, or the search matches. The **Log**
  menu exports shown or selected lines to `console_export_<date>.txt` in the BeamNG user folder.

## Searching

Type in the search box (or press **Ctrl+F**). It looks in the message and the origin.

- `career save` matches lines that contain both words, in any order
- `"failed to load"` matches the exact phrase
- `-traffic` hides lines containing `traffic`
- **Aa** makes the search case-sensitive. **.\*** treats the whole box as a Lua pattern
- **Filter** / **Highlight** switches modes. Filter hides lines that don't match. Highlight shows every line, highlights
  the matches, and steps through them with the arrows, **F3 / Shift+F3** or **Enter**. "Show in context" on a row's
  right-click menu switches from Filter to Highlight and keeps that row in view.

The origin box (left of the search box) is the stock Lua-pattern origin filter.

## Install

**From a release:** download `x_rls_console_<version>.zip` from the
[Releases](https://github.com/Xetius/x_rls_console/releases) page and put it, still zipped, in
`%LOCALAPPDATA%\BeamNG\BeamNG.drive\current\mods`.

**From this repo:** close the game, then from this folder:

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1
```

This copies `mod\` to `%LOCALAPPDATA%\BeamNG\BeamNG.drive\current\mods\unpacked\x_rls_console`.

Use one or the other, not both: two copies would both replace the console. Remove the mod to go back to the stock
console. Settings are saved in `settings/xRlsDebugConsole.json` in the user folder. Command history is shared with the
stock console (`consoleHistory.json`).

## Releasing

Push a semver tag with no `v` prefix:

```bash
git tag 1.0.0
git push origin 1.0.0
```

The Release workflow checks the tag is semver (`1.2.3`, or `1.2.3-beta.1`, which is marked as a pre-release), runs both
offline tests, builds `x_rls_console_<tag>.zip` with the contents of `mod/` and this README at its root, and publishes
it as a GitHub release.

## Notes

- A game update that changes the stock `ui/console.lua` won't affect this mod, because the mod's copy replaces it. If
  an update adds a feature to the stock console, it won't appear here until this mod is updated too.
- Capturing while closed costs very little (it reads that frame's new lines). Turn it off in Log →
  Capture while console is closed if you want the stock behaviour.
- Offline tests: `luajit tools/test_console.lua` (storage, search, selection, back-fill) and
  `luajit tools/test_ui.lua` (draws the whole window against a stub ImGui and checks every Begin/Push is closed).
