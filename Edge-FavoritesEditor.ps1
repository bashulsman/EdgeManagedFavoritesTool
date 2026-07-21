<#
.SYNOPSIS
    Offline editor for the Microsoft Edge "Configure favorites" policy (ManagedFavorites).

.DESCRIPTION
    Graphical tool (WinForms) for building and maintaining the JSON used by the Intune
    Settings Catalog setting "Configure favorites".

      - Tree view with folders (children) and links (url)
      - Configurable top-level folder name (toplevel_name)
      - Add / edit / delete / reorder (drag & drop or buttons)
      - Load JSON from file or from the clipboard (paste back out of Intune)
      - Export as single-line JSON (Settings Catalog) or as an OMA-URI value
      - Fully offline: no modules, no internet, no installation

.NOTES
    Windows PowerShell 5.1 or PowerShell 7 on Windows.
    Right-click the file and choose "Run with PowerShell", or:
        powershell -ExecutionPolicy Bypass -File .\Edge-FavoritesEditor.ps1
#>

#Requires -Version 5.1

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ============================================================================
#  Model  ->  TreeView
# ============================================================================

# Node.Tag holds a hashtable: @{ Type = 'Folder'|'Url'; Url = '<string>' }

function New-FavoriteNode {
    param(
        [Parameter(Mandatory)][string]$Name,
        [ValidateSet('Folder', 'Url')][string]$Type = 'Url',
        [string]$Url = ''
    )
    $node = New-Object System.Windows.Forms.TreeNode
    $node.Text = $Name
    $node.Tag = @{ Type = $Type; Url = $Url }
    if ($Type -eq 'Folder') {
        $node.ImageKey = 'folder'; $node.SelectedImageKey = 'folder'
    } else {
        $node.ImageKey = 'link';   $node.SelectedImageKey = 'link'
    }
    return $node
}

function Update-NodeLabel {
    param([System.Windows.Forms.TreeNode]$Node)
    if ($Node.Tag.Type -eq 'Url') {
        $Node.ToolTipText = $Node.Tag.Url
    } else {
        $Node.ToolTipText = 'Folder'
    }
}

# --- JSON (array of dictionaries) -> TreeNodes -------------------------------

function ConvertFrom-FavoritesJson {
    param(
        [Parameter(Mandatory)][object[]]$Items,
        [System.Windows.Forms.TreeNodeCollection]$Target
    )
    foreach ($item in $Items) {
        if ($null -eq $item) { continue }

        # toplevel_name is handled separately by the caller
        $props = @($item.PSObject.Properties.Name)
        if ($props -contains 'toplevel_name' -and $props.Count -eq 1) { continue }

        $name = [string]$item.name
        if ([string]::IsNullOrWhiteSpace($name)) { $name = '(unnamed)' }

        if ($props -contains 'children') {
            $node = New-FavoriteNode -Name $name -Type 'Folder'
            Update-NodeLabel -Node $node
            $Target.Add($node) | Out-Null
            if ($item.children) {
                ConvertFrom-FavoritesJson -Items @($item.children) -Target $node.Nodes
            }
        } else {
            $node = New-FavoriteNode -Name $name -Type 'Url' -Url ([string]$item.url)
            Update-NodeLabel -Node $node
            $Target.Add($node) | Out-Null
        }
    }
}

# --- TreeNodes -> JSON objects ----------------------------------------------

function ConvertTo-FavoritesObject {
    param([System.Windows.Forms.TreeNodeCollection]$Nodes)

    $list = New-Object System.Collections.ArrayList
    foreach ($node in $Nodes) {
        if ($node.Tag.Type -eq 'Folder') {
            $children = ConvertTo-FavoritesObject -Nodes $node.Nodes
            $list.Add([ordered]@{ name = $node.Text; children = @($children) }) | Out-Null
        } else {
            $list.Add([ordered]@{ name = $node.Text; url = $node.Tag.Url }) | Out-Null
        }
    }
    return $list.ToArray()
}

function Get-FavoritesJson {
    param(
        [System.Windows.Forms.TreeView]$Tree,
        [string]$TopLevelName,
        [switch]$Compress
    )
    $list = New-Object System.Collections.ArrayList
    if (-not [string]::IsNullOrWhiteSpace($TopLevelName)) {
        $list.Add([ordered]@{ toplevel_name = $TopLevelName }) | Out-Null
    }
    foreach ($o in (ConvertTo-FavoritesObject -Nodes $Tree.Nodes)) { $list.Add($o) | Out-Null }

    if ($list.Count -eq 0) { return '[]' }

    $json = ConvertTo-Json -InputObject @($list) -Depth 30 -Compress:$Compress
    # ConvertTo-Json emits a bare object instead of an array when there is one element
    if (-not $json.TrimStart().StartsWith('[')) { $json = "[$json]" }
    return $json
}

# ============================================================================
#  Main form
# ============================================================================

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Edge Managed Favorites Editor'
$form.Size = New-Object System.Drawing.Size(900, 640)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object System.Drawing.Size(760, 520)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

# --- Top bar: top-level folder name ------------------------------------------

$pnlTop = New-Object System.Windows.Forms.Panel
$pnlTop.Dock = 'Top'
$pnlTop.Height = 42
$form.Controls.Add($pnlTop)

$lblTop = New-Object System.Windows.Forms.Label
$lblTop.Text = 'Managed folder name (toplevel_name):'
$lblTop.AutoSize = $true
$lblTop.Location = New-Object System.Drawing.Point(12, 13)
$pnlTop.Controls.Add($lblTop)

$txtTop = New-Object System.Windows.Forms.TextBox
$txtTop.Location = New-Object System.Drawing.Point(248, 10)
$txtTop.Width = 260
$txtTop.Text = 'Company links'
$txtTop.Anchor = 'Top,Left'
$pnlTop.Controls.Add($txtTop)

$lblHint = New-Object System.Windows.Forms.Label
$lblHint.Text = '(empty = default "Managed favorites")'
$lblHint.AutoSize = $true
$lblHint.ForeColor = [System.Drawing.Color]::Gray
$lblHint.Location = New-Object System.Drawing.Point(516, 13)
$pnlTop.Controls.Add($lblHint)

# --- Bottom bar: status ------------------------------------------------------

$status = New-Object System.Windows.Forms.StatusStrip
$statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusLabel.Text = 'Ready.'
$status.Items.Add($statusLabel) | Out-Null
$form.Controls.Add($status)

function Set-Status { param([string]$Text) $statusLabel.Text = $Text }

# --- Split container: tree on the left, buttons on the right -----------------

$split = New-Object System.Windows.Forms.SplitContainer
$split.Dock = 'Fill'
$split.FixedPanel = 'Panel2'
$form.Controls.Add($split)
$split.BringToFront()
# Set SplitterDistance only after the control has its final size, otherwise
# an ArgumentException is thrown.
$split.SplitterDistance = [Math]::Max(200, $split.Width - 260)

$tree = New-Object System.Windows.Forms.TreeView
$tree.Dock = 'Fill'
$tree.HideSelection = $false
$tree.ShowLines = $true
$tree.LabelEdit = $true
$tree.AllowDrop = $true
$tree.ShowNodeToolTips = $true
$tree.ItemHeight = 22
$split.Panel1.Controls.Add($tree)

# Icons are drawn in code so that no external files are required
$imgs = New-Object System.Windows.Forms.ImageList
$imgs.ImageSize = New-Object System.Drawing.Size(16, 16)
$imgs.ColorDepth = 'Depth32Bit'

function New-DotIcon {
    param([System.Drawing.Color]$Color)
    $bmp = New-Object System.Drawing.Bitmap 16, 16
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $brush = New-Object System.Drawing.SolidBrush $Color
    $g.FillEllipse($brush, 3, 3, 10, 10)
    $g.Dispose(); $brush.Dispose()
    return $bmp
}
$imgs.Images.Add('folder', (New-DotIcon ([System.Drawing.Color]::FromArgb(230, 170, 40))))
$imgs.Images.Add('link',   (New-DotIcon ([System.Drawing.Color]::FromArgb(0, 120, 212))))
$tree.ImageList = $imgs

# --- Button panel ------------------------------------------------------------

$pnl = New-Object System.Windows.Forms.FlowLayoutPanel
$pnl.Dock = 'Fill'
$pnl.FlowDirection = 'TopDown'
$pnl.WrapContents = $false
$pnl.Padding = New-Object System.Windows.Forms.Padding(10, 8, 10, 8)
$pnl.AutoScroll = $true
$split.Panel2.Controls.Add($pnl)

# Collapsible sections. Add-Header starts a new section; every Add-Btn after it
# lands in that section's own panel, which the header can show or hide.

$script:CurrentSection = $null

function Set-SectionState {
    param(
        [System.Windows.Forms.Label]$Header,
        [bool]$Expanded
    )
    $info = $Header.Tag
    $info.Expanded = $Expanded
    $info.Panel.Visible = $Expanded
    $chevron = if ($Expanded) { [char]0x25BE } else { [char]0x25B8 }   # ▾ / ▸
    $Header.Text = "$chevron  $($info.Title)"
}

function Add-Header {
    param(
        [string]$Text,
        [switch]$Collapsed
    )

    $l = New-Object System.Windows.Forms.Label
    $l.AutoSize = $true
    $l.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $l.Margin = New-Object System.Windows.Forms.Padding(0, 8, 0, 4)
    $l.Cursor = [System.Windows.Forms.Cursors]::Hand
    $l.ForeColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $pnl.Controls.Add($l)

    $sec = New-Object System.Windows.Forms.FlowLayoutPanel
    $sec.FlowDirection = 'TopDown'
    $sec.WrapContents = $false
    $sec.AutoSize = $true
    $sec.AutoSizeMode = 'GrowAndShrink'
    $sec.Width = 230
    $sec.Margin = New-Object System.Windows.Forms.Padding(0)
    $pnl.Controls.Add($sec)

    $l.Tag = @{ Panel = $sec; Title = $Text; Expanded = $true }
    $l.Add_Click({
        param($s, $e)
        Set-SectionState -Header $s -Expanded (-not $s.Tag.Expanded)
    })

    Set-SectionState -Header $l -Expanded (-not $Collapsed.IsPresent)
    $script:CurrentSection = $sec
    return $l
}

function Add-Btn {
    param([string]$Text, [scriptblock]$OnClick)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Width = 230
    $b.Height = 30
    $b.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 6)
    $b.TextAlign = 'MiddleLeft'
    $b.Padding = New-Object System.Windows.Forms.Padding(8, 0, 0, 0)
    $b.Add_Click($OnClick)
    if ($script:CurrentSection) { $script:CurrentSection.Controls.Add($b) }
    else { $pnl.Controls.Add($b) }
    return $b
}

# ============================================================================
#  Add / edit dialog
# ============================================================================

function Show-ItemDialog {
    param(
        [string]$Title = 'Favorite',
        [string]$Name = '',
        [string]$Url = '',
        [switch]$IsFolder
    )
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = $Title
    $dlg.Size = New-Object System.Drawing.Size(520, ($(if ($IsFolder) { 160 } else { 205 })))
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    $l1 = New-Object System.Windows.Forms.Label
    $l1.Text = 'Display name:'; $l1.Location = '14,18'; $l1.AutoSize = $true
    $dlg.Controls.Add($l1)

    $t1 = New-Object System.Windows.Forms.TextBox
    $t1.Location = '14,38'; $t1.Width = 470; $t1.Text = $Name
    $dlg.Controls.Add($t1)

    $t2 = $null
    if (-not $IsFolder) {
        $l2 = New-Object System.Windows.Forms.Label
        $l2.Text = 'URL:'; $l2.Location = '14,70'; $l2.AutoSize = $true
        $dlg.Controls.Add($l2)

        $t2 = New-Object System.Windows.Forms.TextBox
        $t2.Location = '14,90'; $t2.Width = 470; $t2.Text = $Url
        $dlg.Controls.Add($t2)
    }

    $y = $(if ($IsFolder) { 78 } else { 128 })

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'OK'; $ok.Location = New-Object System.Drawing.Point(308, $y); $ok.Width = 85
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $dlg.Controls.Add($ok); $dlg.AcceptButton = $ok

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Cancel'; $cancel.Location = New-Object System.Drawing.Point(399, $y); $cancel.Width = 85
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dlg.Controls.Add($cancel); $dlg.CancelButton = $cancel

    if ($dlg.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
        if ([string]::IsNullOrWhiteSpace($t1.Text)) {
            [System.Windows.Forms.MessageBox]::Show('Display name cannot be empty.', 'Notice',
                'OK', 'Warning') | Out-Null
            return $null
        }
        $result = @{ Name = $t1.Text.Trim(); Url = '' }
        if ($t2) { $result.Url = $t2.Text.Trim() }
        return $result
    }
    return $null
}

# ============================================================================
#  Actions
# ============================================================================

function Get-TargetCollection {
    # Where does a new link go? Into the selected folder, otherwise next to the
    # selection, otherwise at the root.
    # NOTE: the comma operator prevents PowerShell from unrolling the collection.
    $sel = $tree.SelectedNode
    if ($null -eq $sel) { return , $tree.Nodes }
    if ($sel.Tag.Type -eq 'Folder') { return , $sel.Nodes }
    if ($sel.Parent) { return , $sel.Parent.Nodes }
    return , $tree.Nodes
}

function Get-SiblingCollection {
    # The collection the selected node itself lives in, i.e. the level *next to*
    # the selection rather than inside it. Used for new folders so that repeatedly
    # clicking "New folder..." keeps creating folders at the same level instead of
    # nesting each one inside the previous.
    $sel = $tree.SelectedNode
    if ($null -eq $sel -or $null -eq $sel.Parent) { return , $tree.Nodes }
    return , $sel.Parent.Nodes
}

$script:CurrentFile = $null

Add-Header 'Add' | Out-Null

Add-Btn '  New link...' {
    $r = Show-ItemDialog -Title 'New link'
    if ($r) {
        $n = New-FavoriteNode -Name $r.Name -Type 'Url' -Url $r.Url
        Update-NodeLabel -Node $n
        (Get-TargetCollection).Add($n) | Out-Null
        $n.EnsureVisible(); $tree.SelectedNode = $n
        Set-Status "Link added: $($r.Name)"
    }
} | Out-Null

Add-Btn '  New folder...' {
    # Always created next to the selection, never inside it.
    $r = Show-ItemDialog -Title 'New folder' -IsFolder
    if ($r) {
        $n = New-FavoriteNode -Name $r.Name -Type 'Folder'
        Update-NodeLabel -Node $n
        (Get-SiblingCollection).Add($n) | Out-Null
        $n.EnsureVisible(); $tree.SelectedNode = $n
        Set-Status "Folder added: $($r.Name)"
    }
} | Out-Null

Add-Btn '  New subfolder...' {
    # Explicitly created inside the selected folder.
    $sel = $tree.SelectedNode
    if (-not $sel -or $sel.Tag.Type -ne 'Folder') {
        Set-Status 'Select a folder first to create a subfolder in.'
        return
    }
    $r = Show-ItemDialog -Title "New subfolder in '$($sel.Text)'" -IsFolder
    if ($r) {
        $n = New-FavoriteNode -Name $r.Name -Type 'Folder'
        Update-NodeLabel -Node $n
        $sel.Nodes.Add($n) | Out-Null
        $sel.Expand()
        $n.EnsureVisible(); $tree.SelectedNode = $n
        Set-Status "Subfolder added: $($r.Name)"
    }
} | Out-Null

Add-Header 'Edit' | Out-Null

$btnEdit = Add-Btn '  Edit...' {
    $sel = $tree.SelectedNode
    if (-not $sel) { Set-Status 'Select an item first.'; return }
    if ($sel.Tag.Type -eq 'Folder') {
        $r = Show-ItemDialog -Title 'Edit folder' -Name $sel.Text -IsFolder
    } else {
        $r = Show-ItemDialog -Title 'Edit link' -Name $sel.Text -Url $sel.Tag.Url
    }
    if ($r) {
        $sel.Text = $r.Name
        $sel.Tag = @{ Type = $sel.Tag.Type; Url = $r.Url }
        Update-NodeLabel -Node $sel
        Set-Status 'Item updated.'
    }
}

Add-Btn '  Delete' {
    $sel = $tree.SelectedNode
    if (-not $sel) { Set-Status 'Select an item first.'; return }
    $msg = "Delete '$($sel.Text)'?"
    if ($sel.Nodes.Count -gt 0) { $msg += "`nAll items inside it will be removed as well." }
    if ([System.Windows.Forms.MessageBox]::Show($msg, 'Confirm', 'YesNo', 'Question') -eq 'Yes') {
        $sel.Remove()
        Set-Status 'Item deleted.'
    }
} | Out-Null

Add-Btn '  Move up' {
    $sel = $tree.SelectedNode
    if (-not $sel) { return }
    $coll = if ($sel.Parent) { $sel.Parent.Nodes } else { $tree.Nodes }
    $i = $coll.IndexOf($sel)
    if ($i -gt 0) {
        $coll.RemoveAt($i); $coll.Insert($i - 1, $sel); $tree.SelectedNode = $sel
    }
} | Out-Null

Add-Btn '  Move down' {
    $sel = $tree.SelectedNode
    if (-not $sel) { return }
    $coll = if ($sel.Parent) { $sel.Parent.Nodes } else { $tree.Nodes }
    $i = $coll.IndexOf($sel)
    if ($i -ge 0 -and $i -lt $coll.Count - 1) {
        $coll.RemoveAt($i); $coll.Insert($i + 1, $sel); $tree.SelectedNode = $sel
    }
} | Out-Null

Add-Btn '  Move to root' {
    $sel = $tree.SelectedNode
    if (-not $sel -or -not $sel.Parent) { return }
    $sel.Remove()
    $tree.Nodes.Add($sel) | Out-Null
    $tree.SelectedNode = $sel
    Set-Status 'Moved to root level.'
} | Out-Null

Add-Header 'File' -Collapsed | Out-Null

Add-Btn '  Load JSON...' {
    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Filter = 'JSON files (*.json)|*.json|All files (*.*)|*.*'
    if ($ofd.ShowDialog($form) -ne 'OK') { return }
    try {
        $raw = Get-Content -LiteralPath $ofd.FileName -Raw -Encoding UTF8
        Import-JsonText -Text $raw
        $script:CurrentFile = $ofd.FileName
        Set-Status "Loaded: $($ofd.FileName)"
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Could not read the file:`n$($_.Exception.Message)",
            'Error', 'OK', 'Error') | Out-Null
    }
} | Out-Null

Add-Btn '  Paste from clipboard' {
    $raw = [System.Windows.Forms.Clipboard]::GetText()
    if ([string]::IsNullOrWhiteSpace($raw)) { Set-Status 'Clipboard is empty.'; return }
    try {
        Import-JsonText -Text $raw
        Set-Status 'JSON loaded from clipboard.'
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Invalid JSON:`n$($_.Exception.Message)",
            'Error', 'OK', 'Error') | Out-Null
    }
} | Out-Null

Add-Btn '  Save as JSON...' {
    $sfd = New-Object System.Windows.Forms.SaveFileDialog
    $sfd.Filter = 'JSON files (*.json)|*.json'
    $sfd.FileName = 'EdgeManagedFavorites.json'
    if ($script:CurrentFile) { $sfd.FileName = [IO.Path]::GetFileName($script:CurrentFile) }
    if ($sfd.ShowDialog($form) -ne 'OK') { return }
    $json = Get-FavoritesJson -Tree $tree -TopLevelName $txtTop.Text
    # UTF-8 without BOM
    [IO.File]::WriteAllText($sfd.FileName, $json, (New-Object Text.UTF8Encoding $false))
    $script:CurrentFile = $sfd.FileName
    Set-Status "Saved: $($sfd.FileName)"
} | Out-Null

Add-Header 'Export to Intune' -Collapsed | Out-Null

Add-Btn '  Copy for Settings Catalog' {
    $json = Get-FavoritesJson -Tree $tree -TopLevelName $txtTop.Text -Compress
    [System.Windows.Forms.Clipboard]::SetText($json)
    Set-Status 'Compact JSON copied to clipboard.'
} | Out-Null

Add-Btn '  Copy as OMA-URI value' {
    $json = Get-FavoritesJson -Tree $tree -TopLevelName $txtTop.Text -Compress
    $value = '<enabled/><data id="ManagedFavorites" value="' + $json + '"/>'
    [System.Windows.Forms.Clipboard]::SetText($value)
    Set-Status 'OMA-URI value copied to clipboard.'
} | Out-Null

Add-Btn '  Preview JSON...' {
    $json = Get-FavoritesJson -Tree $tree -TopLevelName $txtTop.Text
    $pv = New-Object System.Windows.Forms.Form
    $pv.Text = 'JSON preview'
    $pv.Size = New-Object System.Drawing.Size(700, 520)
    $pv.StartPosition = 'CenterParent'
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Multiline = $true; $tb.ScrollBars = 'Both'; $tb.WordWrap = $false
    $tb.Dock = 'Fill'; $tb.ReadOnly = $true
    $tb.Font = New-Object System.Drawing.Font('Consolas', 9)
    $tb.Text = $json
    $pv.Controls.Add($tb)
    $pv.ShowDialog($form) | Out-Null
} | Out-Null

Add-Header 'Other' -Collapsed | Out-Null

Add-Btn '  Clear all' {
    if ([System.Windows.Forms.MessageBox]::Show('Clear the entire list?', 'Confirm',
        'YesNo', 'Warning') -eq 'Yes') {
        $tree.Nodes.Clear(); $script:CurrentFile = $null
        Set-Status 'List cleared.'
    }
} | Out-Null

Add-Btn '  Expand all'   { $tree.ExpandAll() } | Out-Null
Add-Btn '  Collapse all' { $tree.CollapseAll() } | Out-Null

# ============================================================================
#  Import helper
# ============================================================================

function Import-JsonText {
    param([Parameter(Mandatory)][string]$Text)

    $t = $Text.Trim()

    # Strip the OMA-URI wrapper if it is present
    if ($t -match '(?s)value\s*=\s*"(.*)"\s*/>') {
        $t = $Matches[1]
    }
    $t = $t -replace '&quot;', '"'

    # Normalise smart quotes
    $t = $t -replace [char]0x201C, '"' -replace [char]0x201D, '"'

    $parsed = $t | ConvertFrom-Json -ErrorAction Stop
    $items = @($parsed)

    $tree.BeginUpdate()
    $tree.Nodes.Clear()

    $tl = $items | Where-Object { $_.PSObject.Properties.Name -contains 'toplevel_name' } |
          Select-Object -First 1
    if ($tl) { $txtTop.Text = [string]$tl.toplevel_name } else { $txtTop.Text = '' }

    ConvertFrom-FavoritesJson -Items $items -Target $tree.Nodes
    $tree.ExpandAll()
    $tree.EndUpdate()
}

# ============================================================================
#  Drag & drop, double-click, keyboard
# ============================================================================

$tree.Add_ItemDrag({
    param($s, $e)
    $tree.DoDragDrop($e.Item, [System.Windows.Forms.DragDropEffects]::Move) | Out-Null
})

$tree.Add_DragEnter({
    param($s, $e)
    $e.Effect = [System.Windows.Forms.DragDropEffects]::Move
})

$tree.Add_DragOver({
    param($s, $e)
    $pt = $tree.PointToClient((New-Object System.Drawing.Point($e.X, $e.Y)))
    $target = $tree.GetNodeAt($pt)
    if ($target) { $tree.SelectedNode = $target }
    $e.Effect = [System.Windows.Forms.DragDropEffects]::Move
})

$tree.Add_DragDrop({
    param($s, $e)
    $dragged = $e.Data.GetData([System.Windows.Forms.TreeNode])
    if (-not $dragged) { return }

    $pt = $tree.PointToClient((New-Object System.Drawing.Point($e.X, $e.Y)))
    $target = $tree.GetNodeAt($pt)

    # Do not allow dropping a folder into itself or into its own descendant
    $walk = $target
    while ($walk) {
        if ($walk -eq $dragged) { Set-Status 'Cannot move a folder into itself.'; return }
        $walk = $walk.Parent
    }

    $dragged.Remove()
    if ($null -eq $target) {
        $tree.Nodes.Add($dragged) | Out-Null
    } elseif ($target.Tag.Type -eq 'Folder') {
        $target.Nodes.Add($dragged) | Out-Null
        $target.Expand()
    } else {
        $coll = if ($target.Parent) { $target.Parent.Nodes } else { $tree.Nodes }
        $coll.Insert(($coll.IndexOf($target) + 1), $dragged)
    }
    $tree.SelectedNode = $dragged
    Set-Status 'Item moved.'
})

$tree.Add_NodeMouseDoubleClick({ $btnEdit.PerformClick() })

$tree.Add_KeyDown({
    param($s, $e)
    if ($e.KeyCode -eq 'Delete') {
        $e.SuppressKeyPress = $true
        $sel = $tree.SelectedNode
        if ($sel) { $sel.Remove(); Set-Status 'Item deleted.' }
    }
})

$tree.Add_AfterLabelEdit({
    param($s, $e)
    if ([string]::IsNullOrWhiteSpace($e.Label)) { $e.CancelEdit = $true }
})

# ============================================================================
#  Start
# ============================================================================

Set-Status 'Ready. Add an item, or load JSON from a file or the clipboard.'

[void]$form.ShowDialog()
$form.Dispose()
