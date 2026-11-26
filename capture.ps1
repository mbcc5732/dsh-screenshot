param(
  [string]$OutDir = '',
  [int]$TimeoutSeconds = 120,
  [switch]$FullScreen,
  [int]$DelaySeconds = 0,
  # Resident mode: stay alive, take commands from stdin, one overlay per command.
  # A cold powershell.exe costs ~1.2s before any pixel is grabbed; keeping the
  # process (and its compiled types) warm is what makes the button feel instant.
  [switch]$Serve,
  # Host process to watch: if it dies, a full-screen overlay must not survive it.
  [int]$ParentPid = 0
)

$ErrorActionPreference = 'Stop'

# Keep captured pixels and overlay coordinates aligned on scaled displays.
# System-DPI awareness only survives a single scaling factor: on a laptop panel
# at 150% plus an external 100% monitor, hover rectangles drift and the captured
# frame comes back scaled. Prefer per-monitor v2 and fall back on older builds
# (the call is a no-op once the process already carries an awareness setting).
try {
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DshDpi {
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr context);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  public static void Enable() {
    try { if (SetProcessDpiAwarenessContext(new IntPtr(-4))) return; } catch { }
    try { SetProcessDPIAware(); } catch { }
  }
}
'@ -ErrorAction Stop
  [DshDpi]::Enable()
} catch { }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Window P/Invoke used to enumerate and filter top-level windows for hover
# selection. Hit testing runs against the cached z-order list; the overlay form
# is never moved or hidden at runtime.
try {
  Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public struct DshRect { public int Left; public int Top; public int Right; public int Bottom; }
public struct DshPoint { public int X; public int Y; }
public delegate bool DshEnumProc(IntPtr hWnd, IntPtr lParam);
public static class DshWin {
  [DllImport("user32.dll")] public static extern bool EnumWindows(DshEnumProc lpEnumFunc, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out DshRect lpRect);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr hWnd);
  [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
  [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(DshPoint p);
  [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr hWnd, uint gaFlags);
}
'@ -ErrorAction Stop
} catch { }

# This file is saved as UTF-8 with BOM on purpose: Windows PowerShell 5.1 decodes
# BOM-less scripts as ANSI (GBK on zh-CN) and would mangle every literal below.

# Toolbar labels, matched to the Doubao capture bar.
$script:labelCopy = '复制'
$script:labelCopied = '已复制'
$script:labelCancel = '取消'
$script:labelInsert = '插入对话'

# Painting resources live for the whole process: a resident helper pays their
# construction once instead of per click. Fonts are declared in pixels rather
# than points so the chrome keeps its measured size at any display scaling.
$script:chipFont = New-Object System.Drawing.Font('Microsoft YaHei UI', 15, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
$script:labelFont = New-Object System.Drawing.Font('Microsoft YaHei UI', 14, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)

# Chrome is authored in logical pixels and painted in physical ones: the desktop
# here is physical-pixel space, so every size below runs through S() using the
# display scale measured when the overlay opens (150% -> 1.5).
$script:scale = 1.0
function S {
  param([double]$v)
  return [int][Math]::Round($v * $script:scale)
}

# Palette: near-black ink on white cards, hairline #E5E6EB boundaries.
$script:inkColor = [System.Drawing.Color]::FromArgb(255, 31, 35, 41)
$script:inkBrush = New-Object System.Drawing.SolidBrush($script:inkColor)
$script:whiteBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
$script:shadowBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(30, 0, 0, 0))
$script:hoverBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 242, 243, 245))
# The unselected desktop is knocked back by half, the way the Doubao tool does.
$script:dimBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(128, 0, 0, 0))
$script:chipBorderPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 229, 230, 235), 1)
$script:dividerPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 221, 224, 230), 1)
$script:iconPen = New-Object System.Drawing.Pen($script:inkColor, 1.4)

# Selection outline: dark dashes around the region, the rest of the desktop
# dimmed underneath.
$script:accentPen = New-Object System.Drawing.Pen($script:inkColor, 1)
$script:accentPen.DashStyle = [System.Drawing.Drawing2D.DashStyle]::Dash
$script:accentPen.DashPattern = @([single]4, [single]3)

# Round handles: white fill, hairline outline.
$script:handleBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
$script:handlePen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 68, 72, 80), 1)

# Re-derive every scaled resource for the display the overlay landed on.
function Set-UiScale {
  param([double]$factor)
  if ($factor -lt 1) { $factor = 1 }
  $script:scale = $factor
  if ($null -ne $script:chipFont) { try { $script:chipFont.Dispose() } catch { } }
  if ($null -ne $script:labelFont) { try { $script:labelFont.Dispose() } catch { } }
  $script:chipFont = New-Object System.Drawing.Font('Microsoft YaHei UI', ([single](15 * $factor)), [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
  $script:labelFont = New-Object System.Drawing.Font('Microsoft YaHei UI', ([single](14 * $factor)), [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
  $script:accentPen.Width = [single][Math]::Max(1, [Math]::Round(1.4 * $factor))
  $script:accentPen.DashPattern = @([single]2.5, [single]2.5)
  $script:iconPen.Width = [single](1.4 * $factor)
  $script:handlePen.Width = [single][Math]::Max(1, [Math]::Round(0.7 * $factor))
  $script:chipBorderPen.Width = 1
  $script:dividerPen.Width = 1
}

$script:centerFormat = New-Object System.Drawing.StringFormat
$script:centerFormat.Alignment = [System.Drawing.StringAlignment]::Center
$script:centerFormat.LineAlignment = [System.Drawing.StringAlignment]::Center
$script:centerFormat.FormatFlags = [System.Drawing.StringFormatFlags]::NoWrap

# Classes that are shell / IME / widget backdrops, never a capture target.
$excludeClasses = @(
  'Progman', 'WorkerW', 'Shell_TrayWnd', 'Shell_SecondaryTrayWnd',
  'IPHlpAPI', 'MsgWnd', 'CEF-OSC-WIDGET', 'Windows.UI.Core.CoreWindow',
  'Intermediate D3D Window', 'Chrome_RenderWidgetHostHWND', 'CiceroUIWndFrame'
)

# Per-capture state. Everything is $script: scoped because the form handlers are
# scriptblocks that run after this frame has left the caller's local scope.
$script:vs = $null
$script:bmp = $null
$script:measureG = $null
$script:copiedAt = 0
$script:form = $null
$script:overlayHwnd = [IntPtr]::Zero
$script:windows = New-Object System.Collections.ArrayList
$script:tick = 0
$script:timeout = 120
$script:parentPid = $ParentPid

function Reset-GestureState {
  $script:sel = New-Object System.Drawing.Rectangle(0, 0, 0, 0)
  $script:origin = New-Object System.Drawing.Point(0, 0)
  $script:pressed = $false
  $script:dragged = $false
  $script:downWindow = $null
  $script:committed = $false
  # idle | selecting | adjust
  $script:phase = 'idle'
  # none | window | drag
  $script:mode = 'none'
  $script:hoverTitle = ''
  # drag inside the selection, or a handle
  $script:adjustMode = ''
  $script:resizeEdge = ''
  $script:resizeStart = New-Object System.Drawing.Point(0, 0)
  $script:resizeStartRect = New-Object System.Drawing.Rectangle(0, 0, 0, 0)
  $script:moveStart = New-Object System.Drawing.Point(0, 0)
  $script:moveStartRect = New-Object System.Drawing.Rectangle(0, 0, 0, 0)
  $script:hoverButton = ''
}

function Test-ParentAlive {
  if ($script:parentPid -le 0) { return $true }
  try {
    $null = [System.Diagnostics.Process]::GetProcessById($script:parentPid)
    return $true
  } catch {
    return $false
  }
}

function Test-FilteredWindow {
  param([IntPtr]$hWnd)
  if ($hWnd -eq $script:overlayHwnd) { return $true }
  if (-not [DshWin]::IsWindowVisible($hWnd)) { return $true }

  $r = New-Object DshRect
  if (-not [DshWin]::GetWindowRect($hWnd, [ref]$r)) { return $true }
  $w = $r.Right - $r.Left; $h = $r.Bottom - $r.Top
  if ($w -lt 40 -or $h -lt 30) { return $true }

  $cls = New-Object System.Text.StringBuilder(256)
  [void][DshWin]::GetClassName($hWnd, $cls, 256)
  if ($excludeClasses -contains $cls.ToString()) { return $true }

  # Tool windows (IME host, popups, floating widgets) and click-through
  # transparent windows swallow the hover hit-test but are not real targets.
  $exStyle = [DshWin]::GetWindowLong($hWnd, -20)
  if (($exStyle -band 0x80) -ne 0) { return $true }
  if (($exStyle -band 0x20) -ne 0) { return $true }

  $len = [DshWin]::GetWindowTextLength($hWnd)
  if ($len -le 0) { return $true }
  return $false
}

function Get-WindowEntry {
  param([IntPtr]$hWnd)
  $r = New-Object DshRect
  [void][DshWin]::GetWindowRect($hWnd, [ref]$r)
  $len = [DshWin]::GetWindowTextLength($hWnd)
  $title = New-Object System.Text.StringBuilder(($len + 1))
  [void][DshWin]::GetWindowText($hWnd, $title, ($len + 1))
  return [pscustomobject]@{ Hwnd = $hWnd; Rect = $r; Title = $title.ToString() }
}

$script:enumProc = [DshEnumProc]{
  param($hWnd, $lParam)
  if (Test-FilteredWindow $hWnd) { return $true }
  [void]$script:windows.Add((Get-WindowEntry $hWnd))
  return $true
}

# Hit test against the cached z-order list. We deliberately do NOT move or hide
# the overlay to call WindowFromPoint: toggling Bounds / visibility pumps a
# repaint on every mouse move and makes the overlay flash.
function Resolve-Window {
  param([int]$px, [int]$py)
  $vs = $script:vs
  foreach ($w in $script:windows) {
    $r = $w.Rect
    $lx = $r.Left - $vs.X; $ly = $r.Top - $vs.Y
    $rx = $r.Right - $vs.X; $ry = $r.Bottom - $vs.Y
    if ($px -ge $lx -and $px -le $rx -and $py -ge $ly -and $py -le $ry) {
      return $w
    }
  }
  return $null
}

function Set-WindowSelection {
  param($w)
  $vs = $script:vs
  $r = $w.Rect
  $script:sel = New-Object System.Drawing.Rectangle(
    ($r.Left - $vs.X), ($r.Top - $vs.Y),
    ($r.Right - $r.Left), ($r.Bottom - $r.Top))
  $script:mode = 'window'
  $script:hoverTitle = $w.Title
}

function Get-HandlePoints {
  param($r)
  $mx = $r.X + [int]($r.Width / 2)
  $my = $r.Y + [int]($r.Height / 2)
  $rt = $r.X + $r.Width
  $bt = $r.Y + $r.Height
  return @{
    nw = @($r.X, $r.Y); n = @($mx, $r.Y); ne = @($rt, $r.Y)
    w  = @($r.X, $my);                   e  = @($rt, $my)
    sw = @($r.X, $bt);  s = @($mx, $bt); se = @($rt, $bt)
  }
}

# Handles are hit-tested by geometry rather than stored rects, so they keep
# working while the selection is being resized. Written without allocations:
# this runs on every mouse move.
function Get-HandleAt {
  param([int]$px, [int]$py)
  $sel = $script:sel
  if ($sel.Width -lt 6 -or $sel.Height -lt 6) { return '' }
  $l = $sel.X; $t = $sel.Y
  $r = $sel.X + $sel.Width; $b = $sel.Y + $sel.Height
  $mx = $l + [int]($sel.Width / 2); $my = $t + [int]($sel.Height / 2)
  $d = S 6
  if ([Math]::Abs($px - $l) -le $d -and [Math]::Abs($py - $t) -le $d) { return 'nw' }
  if ([Math]::Abs($px - $r) -le $d -and [Math]::Abs($py - $t) -le $d) { return 'ne' }
  if ([Math]::Abs($px - $l) -le $d -and [Math]::Abs($py - $b) -le $d) { return 'sw' }
  if ([Math]::Abs($px - $r) -le $d -and [Math]::Abs($py - $b) -le $d) { return 'se' }
  if ([Math]::Abs($px - $mx) -le $d -and [Math]::Abs($py - $t) -le $d) { return 'n' }
  if ([Math]::Abs($px - $mx) -le $d -and [Math]::Abs($py - $b) -le $d) { return 's' }
  if ([Math]::Abs($px - $l) -le $d -and [Math]::Abs($py - $my) -le $d) { return 'w' }
  if ([Math]::Abs($px - $r) -le $d -and [Math]::Abs($py - $my) -le $d) { return 'e' }
  return ''
}

# Toolbar geometry, laid out like the Doubao bar: a white rounded strip under
# the selection, left aligned with it - [复制] [取消] | [插入对话].
function Get-ToolbarLayout {
  param($r)
  $barH = S 42
  $padOuter = S 8
  $padItem = S 12
  $iconSize = S 14
  $iconGap = S 6
  $divPad = S 10

  $mg = $script:measureG
  $twCopy = [int][Math]::Ceiling($mg.MeasureString($script:labelCopy, $script:labelFont).Width)
  $twCancel = [int][Math]::Ceiling($mg.MeasureString($script:labelCancel, $script:labelFont).Width)
  $twInsert = [int][Math]::Ceiling($mg.MeasureString($script:labelInsert, $script:labelFont).Width)

  $wCopy = $padItem * 2 + $iconSize + $iconGap + $twCopy
  $wCancel = $padItem * 2 + $iconSize + $iconGap + $twCancel
  $wInsert = $padItem * 2 + $iconSize + $iconGap + $twInsert
  $wDiv = 1 + $divPad * 2

  $barW = $padOuter * 2 + $wCopy + $wCancel + $wDiv + $wInsert
  $x = $r.X
  $gap = S 11
  $margin = S 4
  if (($x + $barW) -gt ($script:vs.Width - $margin)) { $x = $script:vs.Width - $margin - $barW }
  if ($x -lt $margin) { $x = $margin }
  $y = $r.Y + $r.Height + $gap
  if (($y + $barH) -gt ($script:vs.Height - $margin)) { $y = $r.Y - $barH - $gap }
  if ($y -lt $margin) { $y = $margin }

  $cx = $x + $padOuter
  $copy = New-Object System.Drawing.Rectangle($cx, $y, $wCopy, $barH)
  $cx += $wCopy
  $cancel = New-Object System.Drawing.Rectangle($cx, $y, $wCancel, $barH)
  $cx += $wCancel + $divPad
  $divider = New-Object System.Drawing.Rectangle($cx, ($y + (S 12)), 1, ($barH - (S 24)))
  $cx += 1 + $divPad
  $insert = New-Object System.Drawing.Rectangle($cx, $y, $wInsert, $barH)

  return @{
    bar     = (New-Object System.Drawing.Rectangle($x, $y, $barW, $barH))
    copy    = $copy
    cancel  = $cancel
    divider = $divider
    insert  = $insert
  }
}

function Get-ButtonAt {
  param([int]$px, [int]$py)
  if ($script:phase -ne 'adjust') { return '' }
  if ($null -eq $script:measureG) { return '' }
  $layout = Get-ToolbarLayout $script:sel
  if ($layout['copy'].Contains($px, $py)) { return 'copy' }
  if ($layout['cancel'].Contains($px, $py)) { return 'cancel' }
  if ($layout['insert'].Contains($px, $py)) { return 'insert' }
  return ''
}

function Set-SelectionFromEdges {
  param([int]$left, [int]$top, [int]$right, [int]$bottom)
  if ($left -gt $right) { $t = $left; $left = $right; $right = $t }
  if ($top -gt $bottom) { $t = $top; $top = $bottom; $bottom = $t }
  if ($left -lt 0) { $left = 0 }
  if ($top -lt 0) { $top = 0 }
  if ($right -gt $script:vs.Width) { $right = $script:vs.Width }
  if ($bottom -gt $script:vs.Height) { $bottom = $script:vs.Height }
  $script:sel = New-Object System.Drawing.Rectangle($left, $top, ($right - $left), ($bottom - $top))
}

# --- Drawing primitives --------------------------------------------------
function Get-RoundRectPath {
  param($rect, [single]$radius)
  $path = New-Object System.Drawing.Drawing2D.GraphicsPath
  $d = [single]($radius * 2)
  if ($d -gt $rect.Width) { $d = [single]$rect.Width }
  if ($d -gt $rect.Height) { $d = [single]$rect.Height }
  $x = [single]$rect.X; $y = [single]$rect.Y
  $w = [single]$rect.Width; $h = [single]$rect.Height
  if ($d -le 2) {
    $path.AddRectangle((New-Object System.Drawing.RectangleF($x, $y, $w, $h)))
    return $path
  }
  $path.AddArc($x, $y, $d, $d, 180, 90)
  $path.AddArc(($x + $w - $d), $y, $d, $d, 270, 90)
  $path.AddArc(($x + $w - $d), ($y + $h - $d), $d, $d, 0, 90)
  $path.AddArc($x, ($y + $h - $d), $d, $d, 90, 90)
  $path.CloseFigure()
  return $path
}

function Fill-RoundedRect {
  param($gg, $rect, [single]$radius, $brush)
  $path = Get-RoundRectPath $rect $radius
  try { $gg.FillPath($brush, $path) } finally { $path.Dispose() }
}

# White card, hairline border, faint drop shadow. Used by the size chip and the
# toolbar so both read as the same surface family.
function Draw-Card {
  param($gg, $rect, [single]$radius)
  $sh = New-Object System.Drawing.Rectangle(($rect.X - (S 2)), ($rect.Y + (S 1)), ($rect.Width + (S 4)), ($rect.Height + (S 5)))
  Fill-RoundedRect $gg $sh ($radius + (S 2)) $script:shadowBrush
  Fill-RoundedRect $gg $rect $radius $script:whiteBrush
  $path = Get-RoundRectPath $rect $radius
  try { $gg.DrawPath($script:chipBorderPen, $path) } finally { $path.Dispose() }
}

function Draw-IconCopy {
  param($gg, [single]$x, [single]$y, [single]$s, $pen)
  $half = [single]($s * 0.6)
  $off = [single]($s * 0.4)
  # Two rounded sheets, the front one offset down-left, like the Doubao icon.
  $back = New-Object System.Drawing.Rectangle([int]($x + $off), [int]$y, [int]$half, [int]$half)
  $front = New-Object System.Drawing.Rectangle([int]$x, [int]($y + $off), [int]$half, [int]$half)
  foreach ($r in @($back, $front)) {
    $path = Get-RoundRectPath $r 1.5
    try { $gg.DrawPath($pen, $path) } finally { $path.Dispose() }
  }
}

function Draw-IconCheck {
  param($gg, [single]$x, [single]$y, [single]$s, $pen)
  $pts = New-Object 'System.Drawing.PointF[]' 3
  $pts[0] = New-Object System.Drawing.PointF(($x + $s * 0.14), ($y + $s * 0.54))
  $pts[1] = New-Object System.Drawing.PointF(($x + $s * 0.4), ($y + $s * 0.8))
  $pts[2] = New-Object System.Drawing.PointF(($x + $s * 0.86), ($y + $s * 0.2))
  $gg.DrawLines($pen, $pts)
}

function Draw-IconX {
  param($gg, [single]$x, [single]$y, [single]$s, $pen)
  $gg.DrawLine($pen, ($x + $s * 0.2), ($y + $s * 0.2), ($x + $s * 0.8), ($y + $s * 0.8))
  $gg.DrawLine($pen, ($x + $s * 0.8), ($y + $s * 0.2), ($x + $s * 0.2), ($y + $s * 0.8))
}

# Icon plus label, centred as one group inside the item rect.
function Draw-ItemContent {
  param($gg, $rect, [string]$label, [string]$icon, $pen, $brush, $font)
  $iconSize = S 14
  $iconGap = S 6
  $ts = $gg.MeasureString($label, $font)
  $total = $iconSize + $iconGap + $ts.Width
  $ix = [single]($rect.X + ($rect.Width - $total) / 2)
  $iy = [single]($rect.Y + ($rect.Height - $iconSize) / 2)
  if ($icon -eq 'copy') { Draw-IconCopy $gg $ix $iy $iconSize $pen }
  elseif ($icon -eq 'check') { Draw-IconCheck $gg $ix $iy $iconSize $pen }
  elseif ($icon -eq 'x') { Draw-IconX $gg $ix $iy $iconSize $pen }
  $ty = [single]($rect.Y + ($rect.Height - $ts.Height) / 2)
  $gg.DrawString($label, $font, $brush, (New-Object System.Drawing.PointF(($ix + $iconSize + $iconGap), $ty)))
}

# White rounded size chip ("640 * 480") just outside the top-left corner.
function Draw-SizeChip {
  param($gg, $r)
  $label = ('{0} * {1}' -f $r.Width, $r.Height)
  $ts = $gg.MeasureString($label, $script:chipFont)
  $padX = S 10; $padY = S 6
  $w = [int][Math]::Ceiling($ts.Width + $padX * 2)
  $h = [int][Math]::Ceiling($ts.Height + $padY * 2)
  $x = $r.X
  $offset = S 5
  $margin = S 4
  $y = $r.Y - $h - $offset
  # Flip inside the selection when the region is flush with the top edge, then
  # clamp again: a maximised window reports a small negative Y.
  if ($y -lt $margin) { $y = $r.Y + $offset }
  if ($y -lt $margin) { $y = $margin }
  if (($x + $w) -gt ($script:vs.Width - $margin)) { $x = $script:vs.Width - $margin - $w }
  if ($x -lt $margin) { $x = $margin }
  $rect = New-Object System.Drawing.Rectangle($x, $y, $w, $h)
  Draw-Card $gg $rect (S 8)
  $tf = New-Object System.Drawing.RectangleF(($x + $padX), ($y + $padY), ($w - $padX * 2), ($h - $padY * 2))
  $gg.DrawString($label, $script:chipFont, $script:inkBrush, $tf, $script:centerFormat)
}

# Eight white round handles on the corners and edge midpoints.
function Draw-Handles {
  param($gg, $r)
  $points = Get-HandlePoints $r
  $d = S 8
  $rad = $d / 2
  foreach ($key in $points.Keys) {
    $p = $points[$key]
    $gg.FillEllipse($script:handleBrush, ($p[0] - $rad), ($p[1] - $rad), $d, $d)
    $gg.DrawEllipse($script:handlePen, ($p[0] - $rad), ($p[1] - $rad), $d, $d)
  }
}

function Draw-Toolbar {
  param($gg, $r)
  $layout = Get-ToolbarLayout $r
  Draw-Card $gg $layout['bar'] (S 10)

  foreach ($key in @('copy', 'cancel', 'insert')) {
    if ($script:hoverButton -eq $key) {
      $it = $layout[$key]
      $hv = New-Object System.Drawing.Rectangle(($it.X + (S 2)), ($it.Y + (S 5)), ($it.Width - (S 4)), ($it.Height - (S 10)))
      Fill-RoundedRect $gg $hv (S 6) $script:hoverBrush
    }
  }

  $copyLabel = $script:labelCopy
  if ($script:copiedAt -gt 0) {
    $age = [Environment]::TickCount - $script:copiedAt
    if ($age -ge 0 -and $age -lt 1500) { $copyLabel = $script:labelCopied }
  }
  Draw-ItemContent $gg $layout['copy'] $copyLabel 'copy' $script:iconPen $script:inkBrush $script:labelFont
  Draw-ItemContent $gg $layout['cancel'] $script:labelCancel 'x' $script:iconPen $script:inkBrush $script:labelFont

  $dv = $layout['divider']
  $gg.DrawLine($script:dividerPen, ($dv.X + 0.5), $dv.Y, ($dv.X + 0.5), ($dv.Y + $dv.Height))

  Draw-ItemContent $gg $layout['insert'] $script:labelInsert 'check' $script:iconPen $script:inkBrush $script:labelFont
}

function Copy-SelectionToClipboard {
  $sel = $script:sel
  if ($sel.Width -lt 1 -or $sel.Height -lt 1) { return }
  $crop = $script:bmp.Clone($sel, $script:bmp.PixelFormat)
  try {
    [System.Windows.Forms.Clipboard]::SetImage($crop)
  } finally {
    $crop.Dispose()
  }
}

function Save-Crop {
  param($rect, [string]$OutDir)
  $crop = $script:bmp.Clone($rect, $script:bmp.PixelFormat)
  try {
    # Milliseconds keep back-to-back captures from overwriting each other.
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $file = Join-Path $OutDir ('shot-' + $stamp + '.png')
    $crop.Save($file, [System.Drawing.Imaging.ImageFormat]::Png)
    try { [System.Windows.Forms.Clipboard]::SetImage($crop) } catch { }
    [System.Media.SystemSounds]::Asterisk.Play()
    return $file
  } finally {
    $crop.Dispose()
  }
}

# One full gesture: grab the frame, run the overlay, return what happened.
# Called once per click in -Serve mode and once per process otherwise.
function Invoke-OneCapture {
  param(
    [string]$OutDir = '',
    [int]$TimeoutSeconds = 120,
    [bool]$FullScreen = $false,
    [int]$DelaySeconds = 0
  )

  # Menus, tooltips and hover panels close as soon as the button is pressed
  # outside them, so a delayed grab is the only way to catch them.
  if ($DelaySeconds -gt 0) { Start-Sleep -Seconds $DelaySeconds }

  if ([string]::IsNullOrWhiteSpace($OutDir)) {
    $OutDir = Join-Path $env:TEMP 'dsh-screenshots'
  }
  if (-not (Test-Path -LiteralPath $OutDir)) {
    try {
      New-Item -ItemType Directory -Path $OutDir -Force -ErrorAction Stop | Out-Null
    } catch {
      $OutDir = Join-Path $env:TEMP ('dsh-shot-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
      New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    }
  }

  # Release the previous frame first: at 4480x1600 each full-desktop bitmap is
  # ~28MB, and holding two of them between clicks costs more than rebuilding.
  if ($null -ne $script:measureG) { try { $script:measureG.Dispose() } catch { } }
  if ($null -ne $script:bmp) { try { $script:bmp.Dispose() } catch { } }
  $script:measureG = $null
  $script:bmp = $null

  $script:vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
  $script:bmp = New-Object System.Drawing.Bitmap($script:vs.Width, $script:vs.Height)
  $g = [System.Drawing.Graphics]::FromImage($script:bmp)
  $g.CopyFromScreen($script:vs.X, $script:vs.Y, 0, 0, (New-Object System.Drawing.Size($script:vs.Width, $script:vs.Height)))
  $g.Dispose()

  # One measuring context shared by layout and painting, so the toolbar's hit
  # rects are exactly the rects that were drawn.
  $script:measureG = [System.Drawing.Graphics]::FromImage($script:bmp)

  if ($FullScreen) {
    $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $sel = New-Object System.Drawing.Rectangle(($b.X - $script:vs.X), ($b.Y - $script:vs.Y), $b.Width, $b.Height)
    $file = Save-Crop $sel $OutDir
    return @{ Status = 'OK'; Path = $file }
  }

  Reset-GestureState
  $script:tick = 0
  $script:copiedAt = 0
  $script:timeout = $TimeoutSeconds

  $form = New-Object System.Windows.Forms.Form
  $script:form = $form
  $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
  $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
  $form.Bounds = New-Object System.Drawing.Rectangle($script:vs.X, $script:vs.Y, $script:vs.Width, $script:vs.Height)
  # Under per-monitor DPI awareness WinForms would re-scale the form when it spans
  # displays with different factors; every coordinate here is already a physical
  # pixel, so layout scaling must stay out of the way.
  $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
  $form.TopMost = $true
  $form.ShowInTaskbar = $false
  $form.Cursor = [System.Windows.Forms.Cursors]::Cross
  $form.KeyPreview = $true
  $form.BackColor = [System.Drawing.Color]::Black
  $form.Text = 'DSH Screen Capture'

  # DoubleBuffered and SetStyle are protected members, so plain property assignment
  # silently fails and the overlay flickers. Reach them through reflection instead.
  try {
    $flags = [System.Reflection.BindingFlags]::Instance -bor [System.Reflection.BindingFlags]::NonPublic
    [System.Windows.Forms.Form].GetProperty('DoubleBuffered', $flags).SetValue($form, $true, $null)
    $style = [System.Windows.Forms.ControlStyles]::AllPaintingInWmPaint -bor `
      [System.Windows.Forms.ControlStyles]::OptimizedDoubleBuffer -bor `
      [System.Windows.Forms.ControlStyles]::UserPaint
    [System.Windows.Forms.Control].GetMethod('SetStyle', $flags).Invoke($form, @($style, $true)) | Out-Null
  } catch { }

  # Force the handle into existence so the probe can exclude it.
  $script:overlayHwnd = $form.Handle

  # The chrome is authored in logical pixels; read the physical factor off the
  # overlay's own device context (WinForms' DeviceDpi reports 96 here under
  # per-monitor v2, Graphics.DpiX is the real 144).
  try {
    $probe = [System.Drawing.Graphics]::FromHwnd($script:overlayHwnd)
    $factor = [double]$probe.DpiX / 96.0
    $probe.Dispose()
    Set-UiScale $factor
  } catch {
    Set-UiScale 1
  }

  # Rebuild the target list per capture: windows open and close between clicks.
  # EnumWindows returns them topmost-first (z-order); after filtering shell / tool
  # / transparent / title-less windows, the first entry containing the cursor wins.
  $script:windows = New-Object System.Collections.ArrayList
  [void][DshWin]::EnumWindows($script:enumProc, [IntPtr]::Zero)

  $form.Add_Paint({
    param($s, $e)
    $gg = $e.Graphics
    $gg.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $gg.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit

    # Blit the frozen desktop, then knock back everything outside the region the
    # way the Doubao tool does. Four fills instead of an even-odd clip: it is
    # one GDI call each and stays cheap on a 4480x1600 surface.
    $gg.DrawImageUnscaled($script:bmp, 0, 0)

    $sel = $script:sel
    $vw = $script:vs.Width
    $vh = $script:vs.Height

    if ($sel.Width -gt 1 -and $sel.Height -gt 1) {
      $top = [Math]::Max(0, $sel.Y)
      $bottom = [Math]::Min($vh, $sel.Y + $sel.Height)
      $left = [Math]::Max(0, $sel.X)
      $right = [Math]::Min($vw, $sel.X + $sel.Width)
      $gg.FillRectangle($script:dimBrush, 0, 0, $vw, $top)
      $gg.FillRectangle($script:dimBrush, 0, $bottom, $vw, ($vh - $bottom))
      $gg.FillRectangle($script:dimBrush, 0, $top, $left, ($bottom - $top))
      $gg.FillRectangle($script:dimBrush, $right, $top, ($vw - $right), ($bottom - $top))

      # The half-pixel offset keeps a 1px dash crisp instead of blurred across
      # two rows of pixels.
      $gg.DrawRectangle($script:accentPen, ($sel.X - 0.5), ($sel.Y - 0.5), ($sel.Width + 1), ($sel.Height + 1))
      Draw-SizeChip $gg $sel
      # Adjust mode: eight handles plus the action bar, so the region can be
      # nudged and resized before it becomes an attachment.
      if ($script:phase -eq 'adjust') {
        Draw-Handles $gg $sel
        Draw-Toolbar $gg $sel
      }
      return
    }

    # No region yet: the whole desktop sits under the dim until a drag starts.
    $gg.FillRectangle($script:dimBrush, 0, 0, $vw, $vh)
  })

  $form.Add_MouseDown({
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) {
      $script:committed = $false
      $s.Close()
      return
    }
    if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }

    # Adjust mode owns every press: handles and body resize/move the same
    # selection instead of starting a new one, and the confirm bar acts on press.
    if ($script:phase -eq 'adjust') {
      $button = Get-ButtonAt $e.X $e.Y
      if ($button -eq 'insert') { $script:committed = $true; $s.Close(); return }
      if ($button -eq 'cancel') { $script:committed = $false; $s.Close(); return }
      if ($button -eq 'copy') {
        # Copy without closing: the region stays editable, and confirming still
        # sends it to the conversation.
        Copy-SelectionToClipboard
        $script:copiedAt = [Environment]::TickCount
        [System.Media.SystemSounds]::Asterisk.Play()
        $s.Invalidate()
        return
      }
      $handle = Get-HandleAt $e.X $e.Y
      if ($handle -ne '') {
        $script:adjustMode = 'resize'
        $script:resizeEdge = $handle
        $script:resizeStart = New-Object System.Drawing.Point($e.X, $e.Y)
        $script:resizeStartRect = $script:sel
        return
      }
      if ($script:sel.Contains($e.X, $e.Y)) {
        $script:adjustMode = 'move'
        $script:moveStart = New-Object System.Drawing.Point($e.X, $e.Y)
        $script:moveStartRect = $script:sel
        return
      }
      # A press outside the selection starts over.
    }

    # A press only records intent. Committing here would steal every drag that
    # starts inside a window - which is most of the screen - so a manual region
    # could never be drawn over an application. Release decides instead.
    $script:phase = 'selecting'
    $script:origin = New-Object System.Drawing.Point($e.X, $e.Y)
    $script:downWindow = Resolve-Window $e.X $e.Y
    $script:dragged = $false
    $script:pressed = $true
    $script:hoverButton = ''
    if ($null -ne $script:downWindow) {
      Set-WindowSelection $script:downWindow
    } else {
      $script:sel = New-Object System.Drawing.Rectangle(0, 0, 0, 0)
      $script:mode = 'none'
      $script:hoverTitle = ''
    }
    $s.Invalidate()
  })

  $form.Add_MouseMove({
    param($s, $e)
    if ($script:adjustMode -eq 'resize') {
      $r = $script:resizeStartRect
      $dx = $e.X - $script:resizeStart.X
      $dy = $e.Y - $script:resizeStart.Y
      $l = $r.X; $t = $r.Y; $rt = $r.Right; $bt = $r.Bottom
      if ($script:resizeEdge -match 'w') { $l += $dx }
      if ($script:resizeEdge -match 'e') { $rt += $dx }
      if ($script:resizeEdge -match 'n') { $t += $dy }
      if ($script:resizeEdge -match 's') { $bt += $dy }
      Set-SelectionFromEdges $l $t $rt $bt
      $s.Invalidate()
      return
    }
    if ($script:adjustMode -eq 'move') {
      $r = $script:moveStartRect
      $dx = $e.X - $script:moveStart.X
      $dy = $e.Y - $script:moveStart.Y
      $l = $r.X + $dx; $t = $r.Y + $dy
      $rt = $l + $r.Width; $bt = $t + $r.Height
      # Clamp by shifting the whole rect so the size survives hitting an edge.
      if ($l -lt 0) { $l = 0; $rt = $r.Width }
      if ($t -lt 0) { $t = 0; $bt = $r.Height }
      if ($rt -gt $script:vs.Width) { $rt = $script:vs.Width; $l = $rt - $r.Width }
      if ($bt -gt $script:vs.Height) { $bt = $script:vs.Height; $t = $bt - $r.Height }
      $script:sel = New-Object System.Drawing.Rectangle($l, $t, $r.Width, $r.Height)
      $s.Invalidate()
      return
    }

    if ($script:pressed) {
      # Movement inside the click tolerance keeps the window highlight, so a
      # slightly shaky click still selects the window instead of a 3px sliver.
      if (-not $script:dragged) {
        if ([Math]::Abs($e.X - $script:origin.X) -lt 4 -and [Math]::Abs($e.Y - $script:origin.Y) -lt 4) {
          return
        }
        $script:dragged = $true
        $script:hoverTitle = ''
      }
      $x1 = $script:origin.X; $x2 = $e.X
      if ($x1 -gt $x2) { $t = $x1; $x1 = $x2; $x2 = $t }
      $y1 = $script:origin.Y; $y2 = $e.Y
      if ($y1 -gt $y2) { $t = $y1; $y1 = $y2; $y2 = $t }
      $script:sel = New-Object System.Drawing.Rectangle($x1, $y1, ($x2 - $x1), ($y2 - $y1))
      $script:mode = 'drag'
      $s.Invalidate()
      return
    }

    if ($script:phase -eq 'adjust') {
      # Cursor feedback is what makes the handles discoverable.
      $handle = Get-HandleAt $e.X $e.Y
      $button = Get-ButtonAt $e.X $e.Y
      if ($handle -eq 'nw' -or $handle -eq 'se') {
        $s.Cursor = [System.Windows.Forms.Cursors]::SizeNWSE
      } elseif ($handle -eq 'ne' -or $handle -eq 'sw') {
        $s.Cursor = [System.Windows.Forms.Cursors]::SizeNESW
      } elseif ($handle -eq 'n' -or $handle -eq 's') {
        $s.Cursor = [System.Windows.Forms.Cursors]::SizeNS
      } elseif ($handle -eq 'e' -or $handle -eq 'w') {
        $s.Cursor = [System.Windows.Forms.Cursors]::SizeWE
      } elseif ($button -ne '') {
        $s.Cursor = [System.Windows.Forms.Cursors]::Hand
      } elseif ($script:sel.Contains($e.X, $e.Y)) {
        $s.Cursor = [System.Windows.Forms.Cursors]::SizeAll
      } else {
        $s.Cursor = [System.Windows.Forms.Cursors]::Cross
      }
      if ($button -ne $script:hoverButton) {
        $script:hoverButton = $button
        $s.Invalidate()
      }
      return
    }

    $w = Resolve-Window $e.X $e.Y
    if ($null -ne $w) {
      Set-WindowSelection $w
    } else {
      $script:sel = New-Object System.Drawing.Rectangle(0, 0, 0, 0)
      $script:mode = 'none'
      $script:hoverTitle = ''
    }
    $s.Invalidate()
  })

  $form.Add_MouseUp({
    param($s, $e)
    if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
    if ($script:adjustMode -ne '') {
      $script:adjustMode = ''
      $s.Invalidate()
      return
    }
    if (-not $script:pressed) { return }
    $script:pressed = $false
    $wasDragged = $script:dragged
    $pressedWindow = $script:downWindow
    if ($wasDragged) {
      # Recompute from the release point: the last MouseMove can lag one message
      # behind the cursor, which would shave a few pixels off the region.
      $x1 = $script:origin.X; $x2 = $e.X
      if ($x1 -gt $x2) { $t = $x1; $x1 = $x2; $x2 = $t }
      $y1 = $script:origin.Y; $y2 = $e.Y
      if ($y1 -gt $y2) { $t = $y1; $y1 = $y2; $y2 = $t }
      $script:sel = New-Object System.Drawing.Rectangle($x1, $y1, ($x2 - $x1), ($y2 - $y1))
      # A real drag under 8px is a slip, not a region.
      if ($script:sel.Width -ge 8 -and $script:sel.Height -ge 8) {
        $script:phase = 'adjust'
        $script:mode = 'drag'
        $s.Cursor = [System.Windows.Forms.Cursors]::SizeAll
      } else {
        $script:phase = 'idle'
        $script:sel = New-Object System.Drawing.Rectangle(0, 0, 0, 0)
        $script:mode = 'none'
        $script:hoverTitle = ''
      }
      $s.Invalidate()
      return
    }
    # No movement: the window under the cursor becomes the selection, still
    # editable, so a clicked window can be trimmed before confirming.
    if ($null -ne $pressedWindow) {
      Set-WindowSelection $pressedWindow
      $script:phase = 'adjust'
    } else {
      $script:phase = 'idle'
      $script:sel = New-Object System.Drawing.Rectangle(0, 0, 0, 0)
      $script:mode = 'none'
      $script:hoverTitle = ''
    }
    $s.Invalidate()
  })

  # Double-click inside the selection is the fast confirm path.
  $form.Add_DoubleClick({
    param($s, $e)
    if ($script:phase -eq 'adjust' -and $script:sel.Contains($e.X, $e.Y)) {
      $script:committed = $true
      $s.Close()
    }
  })

  $form.Add_KeyDown({
    param($s, $e)
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) {
      $script:committed = $false
      $s.Close()
      return
    }
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter -and $script:phase -eq 'adjust') {
      $script:committed = $true
      $s.Close()
    }
  })

  $timer = New-Object System.Windows.Forms.Timer
  $timer.Interval = 1000
  $timer.Add_Tick({
    $script:tick++
    # An overlay left behind by a dead host would cover the desktop with a
    # topmost form that no one can dismiss.
    if (-not (Test-ParentAlive)) {
      $script:committed = $false
      $script:form.Close()
      return
    }
    if ($script:tick -ge $script:timeout) { $script:form.Close() }
    # Repaint while the "已复制" acknowledgement is still on screen, so the label
    # reverts to "复制" even if the mouse never moves again.
    if ($script:copiedAt -gt 0) {
      $age = [Environment]::TickCount - $script:copiedAt
      if ($age -ge 0 -and $age -lt 2000) { $script:form.Invalidate() }
    }
  })
  $timer.Start()

  $form.Add_Shown({
    param($s, $e)
    $s.Activate()
    $s.BringToFront()
  })

  try {
    if ($script:serveMode -and $null -ne $script:gestureWatch) {
      [Console]::Out.WriteLine('SHOWN|' + $script:gestureWatch.ElapsedMilliseconds)
      [Console]::Out.Flush()
    }
    [void]$form.ShowDialog()
  } finally {
    $timer.Stop()
    $timer.Dispose()
    $form.Dispose()
    $script:form = $null
  }

  try {
    if (-not $script:committed) { return @{ Status = 'CANCELLED' } }

    $sel = $script:sel
    if ($sel.X -lt 0) { $sel.Width += $sel.X; $sel.X = 0 }
    if ($sel.Y -lt 0) { $sel.Height += $sel.Y; $sel.Y = 0 }
    if (($sel.X + $sel.Width) -gt $script:vs.Width) { $sel.Width = $script:vs.Width - $sel.X }
    if (($sel.Y + $sel.Height) -gt $script:vs.Height) { $sel.Height = $script:vs.Height - $sel.Y }
    if ($sel.Width -lt 4 -or $sel.Height -lt 4) { return @{ Status = 'CANCELLED' } }

    $file = Save-Crop $sel $OutDir
    return @{ Status = 'OK'; Path = $file }
  } finally {
    if ($null -ne $script:measureG) { try { $script:measureG.Dispose() } catch { } }
    if ($null -ne $script:bmp) { try { $script:bmp.Dispose() } catch { } }
    $script:measureG = $null
    $script:bmp = $null
  }
}

# Relay one result line to the host. Flush matters: PowerShell buffers redirected
# stdout, and the host is blocked waiting for this line.
function Write-Result {
  param([string]$Status, [string]$Detail = '')
  [Console]::Out.WriteLine('RESULT|' + $Status + '|' + $Detail)
  [Console]::Out.Flush()
}

# Serve mode reports when the overlay is actually on screen, so the host (and a
# test) can tell the perceived click latency apart from the time spent waiting
# for the user.
$script:serveMode = [bool]$Serve
$script:gestureWatch = $null

if ($Serve) {
  # Announce readiness only after the expensive part (process start, assembly
  # load, two Add-Type compiles) is behind us, so the host knows a click will be
  # served warm.
  [Console]::Out.WriteLine('READY')
  [Console]::Out.Flush()

  while ($true) {
    $line = [Console]::In.ReadLine()
    # EOF means the host went away; do not outlive it.
    if ($null -eq $line) { break }
    $line = $line.Trim()
    if ($line -eq '') { continue }
    if ($line -eq 'QUIT') { break }

    $parts = $line.Split('|')
    if ($parts[0] -ne 'CAPTURE') {
      Write-Result 'ERROR' ('unknown command: ' + $parts[0])
      continue
    }

    $delay = 0
    if ($parts.Count -gt 1) { [void][int]::TryParse($parts[1], [ref]$delay) }
    $full = $false
    if ($parts.Count -gt 2 -and $parts[2] -eq '1') { $full = $true }

    try {
      $script:gestureWatch = [System.Diagnostics.Stopwatch]::StartNew()
      $r = Invoke-OneCapture -OutDir $OutDir -TimeoutSeconds $TimeoutSeconds -FullScreen $full -DelaySeconds $delay
      if ($r.Status -eq 'OK') { Write-Result 'OK' $r.Path } else { Write-Result 'CANCELLED' }
    } catch {
      Write-Result 'ERROR' ($_.Exception.Message -replace "`r?`n", ' ')
    } finally {
      $script:gestureWatch = $null
    }
  }
  exit 0
}

try {
  $r = Invoke-OneCapture -OutDir $OutDir -TimeoutSeconds $TimeoutSeconds -FullScreen:$FullScreen -DelaySeconds $DelaySeconds
  if ($r.Status -eq 'OK') {
    Write-Output $r.Path
  } else {
    Write-Output 'CANCELLED'
  }
  exit 0
} catch {
  [Console]::Error.WriteLine($_.Exception.Message)
  exit 1
}
