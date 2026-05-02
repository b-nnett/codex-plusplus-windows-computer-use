---
name: computer
description: Use when the user mentions @computer, asks to control Windows desktop apps, asks for Windows screenshots/UI state, or asks what apps/windows are open.
---

# Windows Computer Use

Use the Windows Computer Use MCP server from the `co.bennett.windows-computer-use` Codex++ tweak.

- For "what apps are open?", call `list_apps` only. It has a fast native path; do not call `get_app_state`.
- Before the first real app-control tool in a task, call `start_computer_use` so the UI shows "Starting Computer Use" while the cold PowerShell/UIA bridge warms. Skip it for simple `list_apps` questions.
- Before controlling an app, call `get_app_state` for that app. Use `dump_app_targets` only when you need a denser target list.
- `get_app_state` and `dump_app_targets` include ControlView targets, high-value RawView targets, and synthetic app-chrome targets by default; exact data is hidden in `_meta.raw`.
- Use compact target `i` as `element_index`; `screen` and `window` are `[x,y]` centers.
- For browser URL/search input, prefer target `synthetic:browser-address-bar` with `set_value`; it uses the reliable address-bar shortcut instead of guessing text clearing.
- For File Explorer path/search input, prefer `synthetic:file-explorer-address-bar` and `synthetic:file-explorer-search` with `set_value`; they use Alt+D and Ctrl+F instead of guessing where editable chrome appears in UIA.
- For screenshot/window-relative coordinates, pass `app` plus `coordinateSpace: "screenshot"` or `"window"`.
- `move_cursor`, `click`, `type_text`, and `press_key` return app-scoped summaries plus hidden `_meta.presentation` for icon/name rendering. Do not show raw JSON.
- `press_key` and `type_text` verify the target app is foreground before sending input.
- Use `screenshot_window` freely for visual validation after navigation, page loads, dialogs, and media playback.
- Use `move_cursor` before visible clicks when it helps communicate intent. `click`, `scroll`, and `drag` show/move the fake cursor by default and must not move the user's real OS cursor.
- Do not surface `hide_fake_cursor`; it is cleanup.
- Keep behavior Windows-local. Do not use SSH, sockets, or remote bridges as product behavior.
