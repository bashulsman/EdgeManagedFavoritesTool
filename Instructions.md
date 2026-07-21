# Instructions.md — context for the next AI assistant

This file captures the assignment, design decisions, pitfalls and open ideas so that another
assistant (or human) can continue this project without the original chat transcript.

---

## 1. Original assignment

The user (Bas, Dutch-speaking, works with Microsoft Intune) asked, in sequence:

1. An Intune Configuration Profile to populate **Microsoft Edge Favorites**.
2. Specifically one favorite: `https://login.afasonline.com/49744/Apps`, display name **"Afas Online"**.
3. What exactly to type into the *Configure favorites (Device)* field in the Settings Catalog.
4. **An offline PowerShell tool** to load and edit the JSON — extra top levels, extra URLs,
   folders, and so on.
5. Everything saved into the project folder, with a `README.md` and this `Instructions.md`.
6. **The tool and its GUI must be in English**, even though the conversation is in Dutch.

### Decisions confirmed by the user

- Deployment method: **ManagedFavorites via Settings Catalog** (not OMA-URI, not a one-off
  editable import).
- Tool shape: **GUI with a tree view** (WinForms), not a console menu and not a module.
- Language: **UI and documentation in English**; chat replies to the user in **Dutch**.

### User preferences

- Replies in the chat in **Dutch**.
- Concise and direct; little explanation, no lengthy postambles.

---

## 2. Files in this project

| File | Role |
|---|---|
| `Edge-FavoritesEditor.ps1` | The tool. One self-contained script, no dependencies. |
| `README.md` | User documentation: running it, features, Intune deployment, JSON format, pitfalls. |
| `Instructions.md` | This file: project context for further development. |

---

## 3. Domain knowledge — Edge ManagedFavorites

Verified against Microsoft Learn (July 2026).

### Policy

- Policy name: `ManagedFavorites`, displayed as **Configure favorites**.
- Data type: **Dictionary** (in practice a JSON **array** of objects).
- Supported from: Windows/macOS ≥ 77, Android ≥ 30, iOS ≥ 85.
- Can be mandatory: yes. Can be recommended: **no**.
- Dynamic policy refresh: **yes** (no browser restart needed).
- Per profile: yes. Does **not** apply to profiles signed in with a personal Microsoft account.
- Registry path (mandatory): `SOFTWARE\Policies\Microsoft\Edge`.

### JSON structure

```json
[
  { "toplevel_name": "Company links" },
  { "name": "Afas Online", "url": "https://login.afasonline.com/49744/Apps" },
  { "name": "Folder", "children": [ { "name": "Sub", "url": "example.com" } ] }
]
```

- Item with `url` → link. Item with `children` (and no `url`) → folder. Nestable to any depth.
- `toplevel_name` is a standalone dictionary item somewhere in the array; defaults to
  "Managed favorites".
- Edge expands incomplete URLs as if they had been typed in the address bar.
- The folder is not editable or removable by the user (hiding is allowed); it does not sync to
  the account and cannot be modified by extensions.

### Intune

**Settings catalog:** Devices → Configuration → Create → Windows 10 and later →
Settings catalog → category *Microsoft Edge* → **Configure favorites** → Enabled →
paste the **bare JSON array** into the value field (no `<enabled/>`, no surrounding quotes).

**OMA-URI (fallback):**

```
./Device/Vendor/MSFT/Policy/Config/Edge~Policy~microsoft_edge/ManagedFavorites
```

Type String, value:

```
<enabled/><data id="ManagedFavorites" value="[{...}]"/>
```

**Useful trick:** in Edge set `edge://flags/#edge-favorites-admin-export` to Enabled, build the
favorites in `edge://favorites`, then **…** → *Export favorites configuration*. That produces
ready-made JSON (requires Edge ≥ 85).

---

## 4. Architecture of `Edge-FavoritesEditor.ps1`

Single file, built top to bottom:

1. **Header + `Add-Type`** for `System.Windows.Forms` and `System.Drawing`, `EnableVisualStyles()`.
2. **Model helpers**
   - `New-FavoriteNode` — creates a `TreeNode`; `.Tag` is a hashtable `@{ Type='Folder'|'Url'; Url='' }`.
   - `Update-NodeLabel` — sets the tooltip.
   - `ConvertFrom-FavoritesJson` — recursively maps JSON objects → `TreeNodeCollection`.
   - `ConvertTo-FavoritesObject` — recursively maps `TreeNodeCollection` → array of `[ordered]` hashtables.
   - `Get-FavoritesJson` — prepends `toplevel_name` and serialises (`-Depth 30`, optional `-Compress`).
3. **Form**: top bar with the `toplevel_name` text box, `StatusStrip` at the bottom,
   `SplitContainer` with the `TreeView` on the left and a `FlowLayoutPanel` of buttons on the right.
4. **`Show-ItemDialog`** — modal dialog for name (+ URL for links); reused for both add and edit.
5. **Actions** — buttons created through the `Add-Btn` and `Add-Header` helpers, grouped as
   *Add*, *Edit*, *File*, *Export to Intune*, *Other*.

   The groups are **collapsible**. `Add-Header` creates a clickable bold `Label` plus its own
   auto-sizing `FlowLayoutPanel`, stores `@{ Panel; Title; Expanded }` in the label's `Tag`, and
   sets `$script:CurrentSection`. Every subsequent `Add-Btn` adds to that section panel.
   `Set-SectionState` toggles `Panel.Visible` and swaps the chevron (▾ / ▸) in the heading.
   `Add-Header -Collapsed` starts a section closed — used for *File*, *Export to Intune* and *Other*.

   An earlier iteration replaced the three move buttons with a row of small Segoe MDL2 Assets
   icon buttons; the user reverted that. Keep them as full-width buttons.
6. **`Import-JsonText`** — strips the OMA-URI wrapper, replaces `&quot;`, normalises smart
   quotes, parses and populates the tree.
7. **Drag & drop, double-click, Delete key, in-place label edit.**
8. **Start** — the tree opens empty; there is no seed/example content.

### Placement rules for new items (deliberate)

- `Get-TargetCollection` — used by *New link*: inside the selected folder, otherwise next to the
  selection.
- `Get-SiblingCollection` — used by *New folder*: always at the same level as the selection.
  Without this, creating a folder selects it and the next *New folder* would nest inside it,
  which the user reported as a bug.
- *New subfolder* is the explicit way to nest, and requires a folder to be selected.

### Icons

No external files are used: `New-DotIcon` draws 16×16 coloured dots into an `ImageList`
(amber = folder, blue = link).

---

## 5. PowerShell pitfalls already handled

Leave these as they are; they are deliberate.

1. **Collection unrolling.** `Get-TargetCollection` uses `return , $tree.Nodes`.
   Without the comma operator PowerShell unrolls the `TreeNodeCollection` into individual nodes
   and `(Get-TargetCollection).Add(...)` fails.
2. **`SplitterDistance`.** Must be set *after* the `SplitContainer` is added to the form.
   Before that its width is still the default 150 px and an `ArgumentException` is thrown.
   Current code: `[Math]::Max(200, $split.Width - 260)`.
3. **Docking order.** The `Fill` control is added last and then `BringToFront()`, otherwise it
   overlaps the top panel and the status strip.
4. **`ConvertTo-Json` and single-element arrays.** It emits an object instead of an array;
   `Get-FavoritesJson` checks for `[` and re-wraps when needed.
5. **UTF-8 without BOM** on save via `[IO.File]::WriteAllText(..., (New-Object Text.UTF8Encoding $false))`.
   A BOM breaks pasting into Intune.
6. **Drag & drop into itself.** On drop the parent chain is walked to prevent a folder from
   ending up inside its own descendant.

### Not yet verified

The script has **not been executed** — the development environment was Linux without PowerShell
and without WinForms. Syntax and API usage were reviewed by hand. Whoever continues: run it once
on Windows and check the drag & drop behaviour and the dialog layout in particular.

---

## 6. Ideas for further development

Not requested, but logical next steps:

- **Validation** of URLs (shape only, since offline reachability checks are impossible) and a
  warning on duplicate names.
- **Import from an existing Edge profile**: `%LOCALAPPDATA%\Microsoft\Edge\User Data\Default\Bookmarks`
  is JSON and can be converted into the ManagedFavorites format.
- **Import from an HTML export** (`bookmarks.html`) of any browser.
- **Write directly to Intune** via Microsoft Graph (`deviceManagement/configurationPolicies`) —
  requires authentication and breaks the "offline" premise. Alternative: export a ready-made
  Graph JSON payload the admin can post themselves.
- **Local testing**: a button that writes the policy to
  `HKLM\SOFTWARE\Policies\Microsoft\Edge\ManagedFavorites` (needs admin) so the result is visible
  in Edge immediately.
- **Undo/redo** and a "modified" indicator in the title bar.
- **Multiple profiles** side by side (tabs or a profile picker).
- **Code signing** of the script if the organisation enforces a strict execution policy.

---

## 7. Working agreements for whoever continues

- Keep it a single self-contained `.ps1` with no external dependencies — that is the heart of the
  "offline" requirement.
- **UI strings, code comments and documentation in English.** Chat replies to the user in Dutch.
- Update `README.md` on every functional change, and this file on every architectural or context change.
- Test on both Windows PowerShell 5.1 and PowerShell 7; `Add-Type -AssemblyName System.Windows.Forms`
  works in both, but only on Windows.

---

## 8. References

- <https://learn.microsoft.com/deployedge/microsoft-edge-policies/managedfavorites>
- <https://learn.microsoft.com/deployedge/edge-learnmore-provision-favorites>
- <https://learn.microsoft.com/deployedge/configure-edge-with-mdm>
