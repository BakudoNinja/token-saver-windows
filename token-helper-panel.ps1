param(
    [string]$ProjectPath = ".",
    [string]$DataPath = "",
    [switch]$AllProjects
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot "token-helper-core.ps1")

$mutexCreated = $false
$script:panelMutex = [System.Threading.Mutex]::new($true, "Global\TokenUsageHelperPanel", [ref]$mutexCreated)
if (-not $mutexCreated) {
    return
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies @("System.Windows.Forms", "System.Drawing") -TypeDefinition @"
using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public class TuhClickThroughForm : Form
{
    public static bool Pinned = true;
    public static Rectangle SettingsRect = Rectangle.Empty;
    public static Rectangle PinRect = Rectangle.Empty;
    public static Rectangle CloseRect = Rectangle.Empty;

    private const int WM_NCHITTEST = 0x0084;
    private const int HTCLIENT = 1;
    private const int HTTRANSPARENT = -1;
    private const int GWL_EXSTYLE = -20;
    private const int WS_EX_LAYERED = 0x00080000;
    private const int WS_EX_TRANSPARENT = 0x00000020;

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr GetWindowLongPtr(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWindowLongPtr(IntPtr hWnd, int nIndex, IntPtr dwNewLong);

    public static void SetHandleMouseClickThrough(IntPtr handle, bool enabled, bool layered)
    {
        if (handle == IntPtr.Zero) return;
        long style = GetWindowLongPtr(handle, GWL_EXSTYLE).ToInt64();
        long next = enabled ? (style | WS_EX_TRANSPARENT) : (style & ~WS_EX_TRANSPARENT);
        if (enabled && layered)
        {
            next = next | WS_EX_LAYERED;
        }
        if (next != style)
        {
            SetWindowLongPtr(handle, GWL_EXSTYLE, new IntPtr(next));
        }
    }

    public void SetMouseClickThrough(bool enabled)
    {
        SetHandleMouseClickThrough(Handle, enabled, true);
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == WM_NCHITTEST && Pinned)
        {
            int x = unchecked((short)((long)m.LParam & 0xffff));
            int y = unchecked((short)(((long)m.LParam >> 16) & 0xffff));
            Point clientPoint = PointToClient(new Point(x, y));
            if (SettingsRect.Contains(clientPoint) || PinRect.Contains(clientPoint) || CloseRect.Contains(clientPoint))
            {
                m.Result = (IntPtr)HTCLIENT;
                return;
            }
            m.Result = (IntPtr)HTTRANSPARENT;
            return;
        }
        base.WndProc(ref m);
    }
}
"@

$ChartMinutes = 15
$ChartSlotSeconds = 30
$script:panelConfig = Read-TuhConfig -DataPath $DataPath
$script:panelConfig.panelOpacityPercent = [Math]::Min([int]$script:panelConfig.panelOpacityPercent, 72)
$script:latestResult = $null
$script:latestDiagnostic = $null
$script:lastRefreshError = ""
$script:latestSamples = @()
$script:dragging = $false
$script:dragOffset = [System.Drawing.Point]::Empty
$script:panelForm = $null
$script:settingsRect = [System.Drawing.Rectangle]::Empty
$script:pinRect = [System.Drawing.Rectangle]::Empty
$script:closeRect = [System.Drawing.Rectangle]::Empty
$script:hoverCaption = ""
$script:panelHover = $false
$script:panelPinned = $true
$script:settingsDialog = $null
$script:lastPanelStatusLabel = ""
$script:lastHealthEventKey = ""
$script:lastChartRenderKey = ""
$script:usageScaleMax = 1L
$script:savingScaleMax = 1L
$script:refreshProcess = $null
$script:refreshOutputPath = ""
$script:refreshErrorPath = ""
$script:refreshStartedAtUtc = [datetime]::MinValue
$script:lastResetAtUtc = [datetime]::MinValue
$script:refreshTimeoutSeconds = 25
$script:clickThroughEnabled = $false
$script:transparentKeyColor = [System.Drawing.Color]::FromArgb(1, 2, 3)
$script:settingsResetApplied = $false

function Get-TuhPanelOpacity {
    param([object]$Config)
    $percent = [int][Math]::Min(100, [Math]::Max(35, (Get-TuhLong -Value (Get-TuhProp -Object $Config -Name "panelOpacityPercent" -DefaultValue 72) -DefaultValue 72)))
    return ($percent / 100.0)
}

function Get-TuhPinnedOpacity {
    param([object]$Config)
    return Get-TuhPanelOpacity -Config $Config
}

function Get-TuhUnpinnedOpacity {
    return 1.0
}

function Get-TuhChartBackColor {
    return [System.Drawing.Color]::FromArgb(11, 18, 29)
}

function Get-TuhStripBackColor {
    return [System.Drawing.Color]::FromArgb(6, 18, 14)
}

function Get-TuhFormBackColor {
    if ($script:panelPinned) {
        return [System.Drawing.Color]::FromArgb(6, 10, 18)
    }
    return [System.Drawing.Color]::FromArgb(7, 12, 20)
}

function Set-TuhPanelPinned {
    param([bool]$Pinned)

    $script:panelPinned = $Pinned
    [TuhClickThroughForm]::Pinned = $Pinned
    if ($null -ne $script:panelForm) {
        $script:panelForm.Opacity = if ($script:panelPinned) { Get-TuhPinnedOpacity -Config $script:panelConfig } else { Get-TuhUnpinnedOpacity }
        $script:panelForm.BackColor = Get-TuhFormBackColor
        $script:panelForm.TransparencyKey = [System.Drawing.Color]::Empty
        Update-TuhPanelClickThrough
    }
    $usageChartVar = Get-Variable -Name usageChart -ErrorAction SilentlyContinue
    if ($null -ne $usageChartVar -and $null -ne $usageChartVar.Value) {
        $usageChart.BackColor = Get-TuhChartBackColor
        $usageChart.Invalidate()
    }
    $savingChartVar = Get-Variable -Name savingChart -ErrorAction SilentlyContinue
    if ($null -ne $savingChartVar -and $null -ne $savingChartVar.Value) {
        $savingChart.BackColor = Get-TuhStripBackColor
        $savingChart.Invalidate()
    }
}

function Test-TuhCursorOverCaptionButton {
    if ($null -eq $script:panelForm) {
        return $false
    }
    Update-TuhCaptionRects -Width $script:panelForm.ClientSize.Width
    $clientPoint = $script:panelForm.PointToClient([System.Windows.Forms.Cursor]::Position)
    return (-not [string]::IsNullOrWhiteSpace((Test-TuhCaptionHit -Point $clientPoint)))
}

function Update-TuhPanelClickThrough {
    if ($null -eq $script:panelForm -or $script:panelForm -isnot [TuhClickThroughForm]) {
        return
    }
    $shouldPassThrough = ($script:panelPinned -and -not (Test-TuhCursorOverCaptionButton))
    if ($shouldPassThrough -ne $script:clickThroughEnabled) {
        $script:panelForm.SetMouseClickThrough($shouldPassThrough)
        $usageChartVar = Get-Variable -Name usageChart -ErrorAction SilentlyContinue
        if ($null -ne $usageChartVar -and $null -ne $usageChartVar.Value -and $usageChart.IsHandleCreated) {
            [TuhClickThroughForm]::SetHandleMouseClickThrough($usageChart.Handle, $shouldPassThrough, $false)
        }
        $savingChartVar = Get-Variable -Name savingChart -ErrorAction SilentlyContinue
        if ($null -ne $savingChartVar -and $null -ne $savingChartVar.Value -and $savingChart.IsHandleCreated) {
            [TuhClickThroughForm]::SetHandleMouseClickThrough($savingChart.Handle, $shouldPassThrough, $false)
        }
        $script:clickThroughEnabled = $shouldPassThrough
    }
}

function Test-TuhCursorInsidePanel {
    if ($null -eq $script:panelForm) {
        return $false
    }
    return $script:panelForm.Bounds.Contains([System.Windows.Forms.Cursor]::Position)
}

function Set-TuhPanelHover {
    param([bool]$Hover)

    if (-not $Hover -and (Test-TuhCursorInsidePanel)) {
        $Hover = $true
    }
    if ($script:panelHover -eq $Hover) {
        return
    }
    $script:panelHover = $Hover
    $usageChartVar = Get-Variable -Name usageChart -ErrorAction SilentlyContinue
    if ($null -ne $usageChartVar -and $null -ne $usageChartVar.Value) {
        $usageChart.Invalidate()
    }
}

function Enable-TuhDoubleBuffer {
    param([System.Windows.Forms.Control]$Control)

    try {
        $property = [System.Windows.Forms.Control].GetProperty("DoubleBuffered", [System.Reflection.BindingFlags]::Instance -bor [System.Reflection.BindingFlags]::NonPublic)
        if ($null -ne $property) {
            $property.SetValue($Control, $true, $null)
        }
    }
    catch {
    }
}

function Get-TuhWorkingArea {
    return [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
}

function Set-TuhPanelSafeBounds {
    param(
        [System.Windows.Forms.Form]$Form,
        [object]$Config
    )

    $area = Get-TuhWorkingArea
    $width = [int][Math]::Min($area.Width, [Math]::Max(380, (Get-TuhLong -Value (Get-TuhProp -Object $Config -Name "panelWidth" -DefaultValue 460) -DefaultValue 460)))
    $height = [int][Math]::Min($area.Height, [Math]::Max(220, (Get-TuhLong -Value (Get-TuhProp -Object $Config -Name "panelHeight" -DefaultValue 270) -DefaultValue 270)))
    $x = [int](Get-TuhLong -Value (Get-TuhProp -Object $Config -Name "panelX" -DefaultValue -1) -DefaultValue -1)
    $y = [int](Get-TuhLong -Value (Get-TuhProp -Object $Config -Name "panelY" -DefaultValue -1) -DefaultValue -1)

    if ($x -lt $area.Left -or $y -lt $area.Top -or $x -gt ($area.Right - 80) -or $y -gt ($area.Bottom - 80)) {
        $x = $area.Right - $width - 56
        $y = $area.Top + 84
    }

    $x = [Math]::Min([Math]::Max($area.Left, $x), [Math]::Max($area.Left, $area.Right - $width))
    $y = [Math]::Min([Math]::Max($area.Top, $y), [Math]::Max($area.Top, $area.Bottom - $height))
    $Form.StartPosition = "Manual"
    $Form.Size = [System.Drawing.Size]::new($width, $height)
    $Form.Location = [System.Drawing.Point]::new($x, $y)
}

function Repair-TuhPanelBounds {
    if ($null -eq $script:panelForm) {
        return $false
    }

    $area = Get-TuhWorkingArea
    $form = $script:panelForm
    $visibleWidth = [Math]::Min($form.Width, 80)
    $visibleHeight = [Math]::Min($form.Height, 80)
    $isOffscreen = (
        $form.Right -lt ($area.Left + $visibleWidth) -or
        $form.Bottom -lt ($area.Top + $visibleHeight) -or
        $form.Left -gt ($area.Right - $visibleWidth) -or
        $form.Top -gt ($area.Bottom - $visibleHeight)
    )

    if (-not $isOffscreen) {
        return $false
    }

    $form.Left = [Math]::Min([Math]::Max($area.Left, $form.Left), [Math]::Max($area.Left, $area.Right - $form.Width))
    $form.Top = [Math]::Min([Math]::Max($area.Top, $form.Top), [Math]::Max($area.Top, $area.Bottom - $form.Height))
    return $true
}

function Save-TuhPanelWindowState {
    if ($null -eq $script:panelForm -or $null -eq $script:panelConfig) {
        return
    }
    $script:panelConfig.panelX = $script:panelForm.Left
    $script:panelConfig.panelY = $script:panelForm.Top
    $script:panelConfig.panelWidth = $script:panelForm.Width
    $script:panelConfig.panelHeight = $script:panelForm.Height
    $script:panelConfig.panelOpacityPercent = 72
    $script:panelConfig = Save-TuhConfig -Config $script:panelConfig -DataPath $DataPath
}

function Update-TuhLiveDiagnostic {
    if ($null -eq $script:latestResult -or $null -eq $script:latestResult.state -or $null -eq $script:latestResult.metrics) {
        return
    }

    $script:latestDiagnostic = Get-TuhDiagnostic -Config $script:latestResult.config -State $script:latestResult.state -Metrics $script:latestResult.metrics -RefreshError $script:lastRefreshError
}

function Record-TuhPanelHealthEventIfNeeded {
    if ($null -eq $script:latestDiagnostic) {
        return
    }

    $level = [string](Get-TuhProp -Object $script:latestDiagnostic -Name "level" -DefaultValue "ok")
    $label = [string](Get-TuhProp -Object $script:latestDiagnostic -Name "label" -DefaultValue "")
    $detail = [string](Get-TuhProp -Object $script:latestDiagnostic -Name "detail" -DefaultValue "")
    if ($level -eq "ok") {
        $script:lastHealthEventKey = ""
        return
    }

    $key = ("{0}|{1}|{2}" -f $level, $label, $detail)
    if ($key -eq $script:lastHealthEventKey) {
        return
    }
    $script:lastHealthEventKey = $key

    try {
        [void](Write-TuhHealthEvent -DataPath $DataPath -Level $level -Label $label -Detail $detail -ProjectPath $ProjectPath -Source "panel")
    }
    catch {
    }
}

function Reset-TuhPanelPosition {
    if ($null -eq $script:panelForm -or $null -eq $script:panelConfig) {
        return
    }
    $script:panelConfig.panelX = -1
    $script:panelConfig.panelY = -1
    $script:panelConfig.panelWidth = 460
    $script:panelConfig.panelHeight = 270
    Set-TuhPanelSafeBounds -Form $script:panelForm -Config $script:panelConfig
    Set-TuhRoundedRegion -Form $script:panelForm
    $script:panelConfig = Save-TuhConfig -Config $script:panelConfig -DataPath $DataPath
}

function New-TuhAppIcon {
    $iconPath = Join-Path $scriptRoot "token-saver.ico"
    if (Test-Path -LiteralPath $iconPath -PathType Leaf) {
        return [System.Drawing.Icon]::new($iconPath)
    }

    $bitmap = [System.Drawing.Bitmap]::new(32, 32)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.Clear([System.Drawing.Color]::FromArgb(12, 18, 30))
    $pen = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(66, 232, 132), 3)
    $points = @(
        [System.Drawing.Point]::new(4, 24),
        [System.Drawing.Point]::new(10, 18),
        [System.Drawing.Point]::new(15, 21),
        [System.Drawing.Point]::new(21, 8),
        [System.Drawing.Point]::new(28, 14)
    )
    $graphics.DrawLines($pen, $points)
    $pen.Dispose()
    $graphics.Dispose()
    return [System.Drawing.Icon]::FromHandle($bitmap.GetHicon())
}

function Update-TuhCaptionRects {
    param([int]$Width)

    $script:closeRect = [System.Drawing.Rectangle]::new($Width - 30, 6, 22, 22)
    $script:pinRect = [System.Drawing.Rectangle]::new($Width - 56, 6, 22, 22)
    $script:settingsRect = [System.Drawing.Rectangle]::new($Width - 82, 6, 22, 22)
    [TuhClickThroughForm]::CloseRect = $script:closeRect
    [TuhClickThroughForm]::PinRect = $script:pinRect
    [TuhClickThroughForm]::SettingsRect = $script:settingsRect
}

function New-TuhRoundedRectPath {
    param(
        [System.Drawing.RectangleF]$Rect,
        [float]$Radius
    )

    $path = [System.Drawing.Drawing2D.GraphicsPath]::new()
    $diameter = [Math]::Max(1, $Radius * 2)
    $path.AddArc($Rect.X, $Rect.Y, $diameter, $diameter, 180, 90)
    $path.AddArc($Rect.Right - $diameter, $Rect.Y, $diameter, $diameter, 270, 90)
    $path.AddArc($Rect.Right - $diameter, $Rect.Bottom - $diameter, $diameter, $diameter, 0, 90)
    $path.AddArc($Rect.X, $Rect.Bottom - $diameter, $diameter, $diameter, 90, 90)
    $path.CloseFigure()
    return $path
}

function Draw-TuhCaptionGlyph {
    param(
        [System.Drawing.Graphics]$Graphics,
        [System.Drawing.Rectangle]$Rect,
        [char]$Glyph,
        [System.Drawing.Color]$Color,
        [float]$Angle = 0
    )

    if (-not [string]::IsNullOrWhiteSpace($script:hoverCaption)) {
        $hoverRect = switch ($script:hoverCaption) {
            "settings" { $script:settingsRect }
            "pin" { $script:pinRect }
            "close" { $script:closeRect }
            default { [System.Drawing.Rectangle]::Empty }
        }
        if (-not $hoverRect.IsEmpty -and $hoverRect.Equals($Rect)) {
            $hoverBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(34, 255, 255, 255))
            $hoverPath = New-TuhRoundedRectPath -Rect ([System.Drawing.RectangleF]::new($Rect.X, $Rect.Y, $Rect.Width, $Rect.Height)) -Radius 7
            $Graphics.FillPath($hoverBrush, $hoverPath)
            $hoverPath.Dispose()
            $hoverBrush.Dispose()
        }
    }

    $font = [System.Drawing.Font]::new("Segoe MDL2 Assets", 10.5, [System.Drawing.FontStyle]::Regular)
    $brush = [System.Drawing.SolidBrush]::new($Color)
    $format = [System.Drawing.StringFormat]::new()
    $format.Alignment = [System.Drawing.StringAlignment]::Center
    $format.LineAlignment = [System.Drawing.StringAlignment]::Center
    $state = $null
    if ([Math]::Abs($Angle) -gt 0.1) {
        $state = $Graphics.Save()
        $Graphics.TranslateTransform([float]($Rect.Left + ($Rect.Width / 2.0)), [float]($Rect.Top + ($Rect.Height / 2.0)))
        $Graphics.RotateTransform($Angle)
        $rectF = [System.Drawing.RectangleF]::new([float](-$Rect.Width / 2.0), [float](-$Rect.Height / 2.0), [float]$Rect.Width, [float]$Rect.Height)
    }
    else {
        $rectF = [System.Drawing.RectangleF]::new([float]$Rect.X, [float]$Rect.Y, [float]$Rect.Width, [float]$Rect.Height)
    }
    $Graphics.DrawString(([string]$Glyph), $font, $brush, $rectF, $format)
    if ($null -ne $state) {
        $Graphics.Restore($state)
    }
    $format.Dispose()
    $brush.Dispose()
    $font.Dispose()
}

function Draw-TuhCaptionIcons {
    param(
        [System.Drawing.Graphics]$Graphics,
        [int]$Width
    )

    Update-TuhCaptionRects -Width $Width
    if ($script:panelPinned -and -not $script:panelHover -and [string]::IsNullOrWhiteSpace($script:hoverCaption)) {
        return
    }
    $normal = [System.Drawing.Color]::FromArgb(226, 236, 242, 247)
    $dim = [System.Drawing.Color]::FromArgb(132, 150, 165, 180)
    $pinAngle = if ($script:panelPinned) { 0 } else { -45 }
    $pinColor = if ($script:panelPinned) { $dim } else { $normal }
    Draw-TuhCaptionGlyph -Graphics $Graphics -Rect $script:settingsRect -Glyph ([char]0xE713) -Color $normal
    Draw-TuhCaptionGlyph -Graphics $Graphics -Rect $script:pinRect -Glyph ([char]0xE718) -Color $pinColor -Angle $pinAngle
    Draw-TuhCaptionGlyph -Graphics $Graphics -Rect $script:closeRect -Glyph ([char]0xE711) -Color $normal
}

function Get-TuhRelativeRefreshLabel {
    if ($null -eq $script:latestResult -or $null -eq $script:latestResult.state) {
        return "waiting"
    }
    $raw = [string](Get-TuhProp -Object $script:latestResult.state -Name "lastRefreshAtUtc" -DefaultValue "")
    $at = [datetime]::MinValue
    if (-not [datetime]::TryParse($raw, [ref]$at)) {
        return "waiting"
    }
    $seconds = [Math]::Max(0, [int]((Get-Date).ToUniversalTime() - $at.ToUniversalTime()).TotalSeconds)
    if ($seconds -lt 10) {
        return "just now"
    }
    if ($seconds -lt 60) {
        return ("{0}s ago" -f $seconds)
    }
    return ("{0}m ago" -f [int][Math]::Floor($seconds / 60))
}

function Get-TuhPanelStatusLabel {
    $configForStatus = if ($null -ne $script:latestResult -and $null -ne $script:latestResult.config) { $script:latestResult.config } else { $script:panelConfig }
    if (-not (Get-TuhBool -Value (Get-TuhProp -Object $configForStatus -Name "helperEnabled" -DefaultValue $true) -DefaultValue $true)) {
        return "offline"
    }

    if ($null -ne $script:latestDiagnostic) {
        $label = [string](Get-TuhProp -Object $script:latestDiagnostic -Name "label" -DefaultValue "waiting")
        $confidence = [string](Get-TuhProp -Object $script:latestDiagnostic -Name "confidence" -DefaultValue "unknown")
        $refreshSeconds = Get-TuhLong -Value (Get-TuhProp -Object $script:latestDiagnostic -Name "secondsSinceRefresh" -DefaultValue -1) -DefaultValue -1
        $confidenceLabel = switch ($confidence) {
            "global-history+live-session" { "live" }
            "request-matched" { "request" }
            "context-estimate" { "context" }
            "context-only" { "context" }
            "log-estimate" { "log" }
            "manual" { "manual" }
            default { $confidence }
        }
        $refresh = if ($refreshSeconds -lt 0) {
            "waiting"
        }
        elseif ($refreshSeconds -lt 20) {
            "now"
        }
        elseif ($refreshSeconds -lt 60) {
            ("{0}s" -f ([int][Math]::Floor($refreshSeconds / 5) * 5))
        }
        else {
            ("{0}m" -f [int][Math]::Floor($refreshSeconds / 60))
        }

        if ($label -eq "healthy") {
            return ("online / {0} / {1}" -f $confidenceLabel, $refresh)
        }
        return ("{0} / {1}" -f $label, $refresh)
    }
    if ($null -eq $script:latestResult -or $null -eq $script:latestResult.metrics) {
        return "waiting"
    }
    $confidence = [string](Get-TuhProp -Object $script:latestResult.metrics -Name "confidence" -DefaultValue "unknown")
    $status = [string](Get-TuhProp -Object $script:latestResult.metrics -Name "status" -DefaultValue "unknown")
    $refresh = Get-TuhRelativeRefreshLabel
    $confidenceLabel = switch ($confidence) {
        "global-history+live-session" { "live" }
        "request-matched" { "request" }
        "context-estimate" { "context" }
        "context-only" { "context" }
        "log-estimate" { "log" }
        "manual" { "manual" }
        default { $confidence }
    }
    if ($status -eq "missing") {
        return ("no data / {0}" -f $refresh)
    }
    return ("online / {0} / {1}" -f $confidenceLabel, $refresh)
}

function Invalidate-TuhCharts {
    param([bool]$All = $false)

    if ($null -eq $usageChart -or $null -eq $savingChart) {
        return
    }

    $currentStatus = Get-TuhPanelStatusLabel
    $statusChanged = ($currentStatus -ne $script:lastPanelStatusLabel)
    $script:lastPanelStatusLabel = $currentStatus

    $usageValues = Get-TuhFixedSampleSeries -Samples $script:latestSamples -Field "usageTokens" -Minutes $ChartMinutes -SlotSeconds $ChartSlotSeconds
    $savedValues = Get-TuhFixedSampleSeries -Samples $script:latestSamples -Field "savedTokens" -Minutes $ChartMinutes -SlotSeconds $ChartSlotSeconds
    $currentUsageTotal = if ($null -ne $script:latestResult -and $null -ne $script:latestResult.metrics) { [string]$script:latestResult.metrics.currentUsageTokens } else { "0" }
    $currentSavedTotal = if ($null -ne $script:latestResult -and $null -ne $script:latestResult.metrics) { [string]$script:latestResult.metrics.currentSavedTokens } else { "0" }
    $sampleKey = "{0}|{1}|{2}|{3}|{4}" -f `
        $currentStatus, `
        $currentUsageTotal, `
        $currentSavedTotal, `
        ([string]::Join(",", $usageValues)), `
        ([string]::Join(",", $savedValues))
    $dataChanged = ($sampleKey -ne $script:lastChartRenderKey)
    if ($dataChanged) {
        $script:lastChartRenderKey = $sampleKey
    }

    if (($All -and $dataChanged) -or $statusChanged) {
        $usageChart.Invalidate()
    }
    if ($All -and $dataChanged) {
        $savingChart.Invalidate()
    }
}

function Apply-TuhDoctorResultToPanel {
    param([object]$Doctor)

    if ($null -eq $Doctor -or $null -eq $Doctor.state -or $null -eq $Doctor.metrics) {
        return
    }
    $script:latestResult = [PSCustomObject]@{
        ok = $Doctor.ok
        config = $Doctor.config
        state = $Doctor.state
        metrics = $Doctor.metrics
        deltas = $Doctor.deltas
    }
    $script:lastRefreshError = ""
    $script:latestDiagnostic = $Doctor.diagnostic
    $script:latestSamples = @($Doctor.state.samples)
    Record-TuhPanelHealthEventIfNeeded
    Invalidate-TuhCharts -All $true
    $script:panelForm.Text = ("Token saver - {0} - {1} - {2} usage / {3} saved" -f (Get-TuhScopeLabel), ([string]$Doctor.diagnostic.label), (Format-TuhCompact -Value ([long]$Doctor.metrics.currentUsageTokens)), (Format-TuhCompact -Value ([long]$Doctor.metrics.currentSavedTokens)))
}

function Apply-TuhRefreshResultToPanel {
    param([object]$Result)

    if ($null -eq $Result -or $null -eq $Result.state -or $null -eq $Result.metrics) {
        return
    }
    $script:latestResult = $Result
    $script:lastRefreshError = ""
    $script:latestDiagnostic = Get-TuhDiagnostic -Config $Result.config -State $Result.state -Metrics $Result.metrics
    Record-TuhPanelHealthEventIfNeeded
    $script:latestSamples = @($Result.state.samples)
    Invalidate-TuhCharts -All $true
    $script:panelForm.Text = ("Token saver - {0} - {1} - {2} usage / {3} saved" -f (Get-TuhScopeLabel), ([string]$script:latestDiagnostic.label), (Format-TuhCompact -Value ([long]$Result.metrics.currentUsageTokens)), (Format-TuhCompact -Value ([long]$Result.metrics.currentSavedTokens)))
}

function Apply-TuhPanelConfigImmediately {
    param([object]$Config)

    $script:panelConfig = $Config
    if ($null -ne $script:latestResult) {
        $script:latestResult | Add-Member -NotePropertyName config -NotePropertyValue $Config -Force
    }
    else {
        $script:latestResult = [PSCustomObject]@{
            ok = $true
            config = $Config
            state = $null
            metrics = $null
            deltas = $null
        }
    }
    $script:lastRefreshError = ""
    $script:latestDiagnostic = Get-TuhDiagnostic `
        -Config $Config `
        -State $(if ($null -ne $script:latestResult) { $script:latestResult.state } else { $null }) `
        -Metrics $(if ($null -ne $script:latestResult) { $script:latestResult.metrics } else { $null })
    Record-TuhPanelHealthEventIfNeeded
    Set-TuhPanelPinned -Pinned $script:panelPinned
    Invalidate-TuhCharts -All $true
    $status = if (-not (Get-TuhBool -Value (Get-TuhProp -Object $Config -Name "helperEnabled" -DefaultValue $true) -DefaultValue $true)) { "offline" } else { "online" }
    $script:panelForm.Text = ("Token saver - {0}" -f $status)
}

function Invoke-TuhPanelReset {
    param([bool]$FromSettings = $false)

    $script:lastResetAtUtc = (Get-Date).ToUniversalTime()
    Clear-TuhRefreshProcess -Kill $true
    $resetState = Reset-TuhState -DataPath $DataPath
    $zeroMetrics = [PSCustomObject]@{
        status = "reset"
        confidence = "baseline"
        source = "reset data"
        currentUsageTokens = 0L
        currentSavedTokens = 0L
    }
    $script:latestResult = [PSCustomObject]@{
        ok = $true
        config = $script:panelConfig
        state = $resetState
        metrics = $zeroMetrics
        deltas = [PSCustomObject]@{
            usageTokens = 0L
            savedTokens = 0L
        }
    }
    $script:lastRefreshError = ""
    $script:latestSamples = @()
    $script:latestDiagnostic = Get-TuhDiagnostic -Config $script:panelConfig -State $resetState -Metrics $zeroMetrics
    $script:usageScaleMax = 1L
    $script:savingScaleMax = 1L
    $script:lastChartRenderKey = ""
    if ($FromSettings) {
        $script:settingsResetApplied = $true
    }
    Record-TuhPanelHealthEventIfNeeded
    Invalidate-TuhCharts -All $true
    if ($null -ne $usageChart) {
        $usageChart.Refresh()
    }
    if ($null -ne $savingChart) {
        $savingChart.Refresh()
    }
    if ($null -ne $script:panelForm) {
        $script:panelForm.Text = "Token saver - reset"
        $script:panelForm.Refresh()
    }
}

function Clear-TuhRefreshProcess {
    param([bool]$Kill = $false)

    if ($null -ne $script:refreshProcess) {
        try {
            if ($Kill -and -not $script:refreshProcess.HasExited) {
                $script:refreshProcess.Kill()
                [void]$script:refreshProcess.WaitForExit(2000)
            }
        }
        catch {
        }
        try {
            $script:refreshProcess.Dispose()
        }
        catch {
        }
    }
    foreach ($path in @($script:refreshOutputPath, $script:refreshErrorPath)) {
        if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path -PathType Leaf)) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }
    $script:refreshProcess = $null
    $script:refreshOutputPath = ""
    $script:refreshErrorPath = ""
    $script:refreshStartedAtUtc = [datetime]::MinValue
}

function Complete-TuhPanelRefresh {
    if ($null -eq $script:refreshProcess) {
        return
    }

    $nowUtc = (Get-Date).ToUniversalTime()
    if (-not $script:refreshProcess.HasExited) {
        if (($nowUtc - $script:refreshStartedAtUtc).TotalSeconds -gt $script:refreshTimeoutSeconds) {
            Clear-TuhRefreshProcess -Kill $true
            $script:lastRefreshError = "refresh timed out"
            $script:latestDiagnostic = Get-TuhDiagnostic -Config $script:panelConfig -State $(if ($null -ne $script:latestResult) { $script:latestResult.state } else { $null }) -Metrics $(if ($null -ne $script:latestResult) { $script:latestResult.metrics } else { $null }) -RefreshError $script:lastRefreshError
            Record-TuhPanelHealthEventIfNeeded
            Invalidate-TuhCharts -All $true
            $script:panelForm.Text = "Token saver - refresh timed out"
        }
        return
    }

    try {
        $completedRefreshStartedAtUtc = $script:refreshStartedAtUtc
        try {
            $script:refreshProcess.Refresh()
            [void]$script:refreshProcess.WaitForExit(0)
        }
        catch {
        }
        $exitCode = if ($null -eq $script:refreshProcess.ExitCode) { 0 } else { [int]$script:refreshProcess.ExitCode }
        $raw = if (Test-Path -LiteralPath $script:refreshOutputPath -PathType Leaf) { Get-Content -LiteralPath $script:refreshOutputPath -Raw } else { "" }
        if ($exitCode -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) {
            $errRaw = if (Test-Path -LiteralPath $script:refreshErrorPath -PathType Leaf) { Get-Content -LiteralPath $script:refreshErrorPath -Raw } else { "" }
            $err = if ($null -eq $errRaw) { "" } else { ([string]$errRaw).Trim() }
            if ([string]::IsNullOrWhiteSpace($err)) {
                $err = "refresh exited with code $exitCode"
            }
            throw $err
        }
        $result = $raw | ConvertFrom-Json
        if ($completedRefreshStartedAtUtc -lt $script:lastResetAtUtc) {
            return
        }
        Apply-TuhRefreshResultToPanel -Result $result
    }
    catch {
        $script:lastRefreshError = $_.Exception.Message
        $script:latestDiagnostic = Get-TuhDiagnostic -Config $script:panelConfig -State $(if ($null -ne $script:latestResult) { $script:latestResult.state } else { $null }) -Metrics $(if ($null -ne $script:latestResult) { $script:latestResult.metrics } else { $null }) -RefreshError $script:lastRefreshError
        Record-TuhPanelHealthEventIfNeeded
        Invalidate-TuhCharts -All $true
        $script:panelForm.Text = "Token saver - refresh failed"
    }
    finally {
        Clear-TuhRefreshProcess
    }
}

function Set-TuhRoundedRegion {
    param(
        [System.Windows.Forms.Form]$Form,
        [int]$Radius = 14
    )

    $width = [Math]::Max(1, $Form.ClientSize.Width)
    $height = [Math]::Max(1, $Form.ClientSize.Height)
    $path = [System.Drawing.Drawing2D.GraphicsPath]::new()
    $diameter = $Radius * 2
    $path.AddArc(0, 0, $diameter, $diameter, 180, 90)
    $path.AddArc($width - $diameter - 1, 0, $diameter, $diameter, 270, 90)
    $path.AddArc($width - $diameter - 1, $height - $diameter - 1, $diameter, $diameter, 0, 90)
    $path.AddArc(0, $height - $diameter - 1, $diameter, $diameter, 90, 90)
    $path.CloseFigure()
    if ($null -ne $Form.Region) {
        $Form.Region.Dispose()
    }
    $Form.Region = [System.Drawing.Region]::new($path)
    $path.Dispose()
}

function Test-TuhCaptionHit {
    param([System.Drawing.Point]$Point)

    if ($script:settingsRect.Contains($Point)) {
        return "settings"
    }
    if ($script:pinRect.Contains($Point)) {
        return "pin"
    }
    if ($script:closeRect.Contains($Point)) {
        return "close"
    }
    return ""
}

function Add-TuhDragHandlers {
    param(
        [System.Windows.Forms.Control]$Control
    )

    $Control.Add_MouseDown({
        param($sender, $eventArgs)
        if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            if ($script:panelPinned) {
                return
            }
            $script:dragging = $true
            $script:dragOffset = [System.Drawing.Point]::new($eventArgs.X, $eventArgs.Y)
        }
    })
    $Control.Add_MouseMove({
        param($sender, $eventArgs)
        Set-TuhPanelHover -Hover $true
        if ($script:dragging) {
            $screen = $sender.PointToScreen([System.Drawing.Point]::new($eventArgs.X, $eventArgs.Y))
            $script:panelForm.Location = [System.Drawing.Point]::new($screen.X - $script:dragOffset.X, $screen.Y - $script:dragOffset.Y)
        }
    })
    $Control.Add_MouseLeave({
        Set-TuhPanelHover -Hover $false
    })
    $Control.Add_MouseUp({
        $script:dragging = $false
    })
}

function Format-TuhCompact {
    param([long]$Value)
    if ($Value -ge 1000000) {
        return ("{0:N1}M" -f ($Value / 1000000.0))
    }
    if ($Value -ge 1000) {
        return ("{0:N0}K" -f ($Value / 1000.0))
    }
    return ("{0:N0}" -f $Value)
}

function Get-TuhProjectLabel {
    try {
        $fullPath = [System.IO.Path]::GetFullPath($ProjectPath)
        $name = Split-Path -Leaf $fullPath
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            return $name
        }
    }
    catch {
    }
    return "current project"
}

function Get-TuhShortPathLabel {
    param(
        [string]$Path,
        [int]$MaxLength = 18
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -eq "__all_codex_projects__") {
        return "all projects"
    }
    try {
        $name = Split-Path -Leaf ([System.IO.Path]::GetFullPath($Path))
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            if ($name.Length -gt $MaxLength) {
                return ($name.Substring(0, [Math]::Max(1, $MaxLength - 1)) + ".")
            }
            return $name
        }
    }
    catch {
    }
    if ($Path.Length -gt $MaxLength) {
        return ($Path.Substring(0, [Math]::Max(1, $MaxLength - 1)) + ".")
    }
    return $Path
}

function Get-TuhScopeLabel {
    if ($AllProjects) {
        return "all projects"
    }
    return Get-TuhProjectLabel
}

function Get-TuhFixedSampleSeries {
    param(
        [object[]]$Samples,
        [string]$Field,
        [int]$Minutes = 15,
        [int]$SlotSeconds = 30
    )

    $now = (Get-Date).ToUniversalTime()
    $slotCount = [Math]::Max(2, [int][Math]::Ceiling(($Minutes * 60.0) / [Math]::Max(1, $SlotSeconds)))
    $buckets = New-Object long[] $slotCount
    $nowSlot = [long][Math]::Floor(((New-TimeSpan -Start ([datetime]"1970-01-01T00:00:00Z") -End $now).TotalSeconds) / $SlotSeconds)
    foreach ($sample in @($Samples)) {
        $at = [datetime]::MinValue
        $raw = [string](Get-TuhProp -Object $sample -Name "atUtc" -DefaultValue "")
        if (-not [datetime]::TryParse($raw, [ref]$at)) {
            continue
        }
        $sampleSlot = [long][Math]::Floor(((New-TimeSpan -Start ([datetime]"1970-01-01T00:00:00Z") -End $at.ToUniversalTime()).TotalSeconds) / $SlotSeconds)
        $slotsAgo = [int]($nowSlot - $sampleSlot)
        if ($slotsAgo -lt 0 -or $slotsAgo -ge $slotCount) {
            continue
        }
        $index = ($slotCount - 1) - $slotsAgo
        $buckets[$index] += Get-TuhLong -Value (Get-TuhProp -Object $sample -Name $Field -DefaultValue 0) -DefaultValue 0
    }
    return $buckets
}

function Update-TuhStickyScale {
    param(
        [long]$CurrentScale,
        [long[]]$Values
    )

    $max = 1L
    foreach ($value in $Values) {
        if ($value -gt $max) {
            $max = $value
        }
    }
    if ($max -gt $CurrentScale) {
        return $max
    }
    return [Math]::Max(1L, $CurrentScale)
}

function Draw-TuhChart {
    param(
        [System.Drawing.Graphics]$Graphics,
        [System.Drawing.Rectangle]$Bounds,
        [string]$Title,
        [long[]]$Values,
        [System.Drawing.Color]$LineColor,
        [System.Drawing.Color]$FillColor,
        [System.Drawing.Color]$BackColor,
        [string]$StatusLabel = "",
        [string]$EmptyLabel = "no activity in this window",
        [long]$ScaleMax = 0,
        [string]$SummaryLabel = "",
        [string]$SummaryValue = "",
        [System.Drawing.Color]$SummaryColor = [System.Drawing.Color]::Empty,
        [string]$StatusState = "",
        [long[]]$SecondaryValues = @(),
        [System.Drawing.Color]$SecondaryLineColor = [System.Drawing.Color]::Empty
    )

    $Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $Graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $Graphics.Clear($BackColor)
    $font = [System.Drawing.Font]::new("Segoe UI", 8, [System.Drawing.FontStyle]::Bold)
    $smallFont = [System.Drawing.Font]::new("Segoe UI", 7)
    $summaryFont = [System.Drawing.Font]::new("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
    $textBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(238, 244, 248))
    $mutedBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(122, 174, 187, 202))
    $quietBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(82, 174, 187, 202))
    $gridPen = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(16, 170, 190, 210), 1)
    $axisPen = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(32, 210, 225, 238), 1)
    $linePen = [System.Drawing.Pen]::new($LineColor, 1.6)
    $secondaryLineColorActual = if ($SecondaryLineColor.IsEmpty) { [System.Drawing.Color]::FromArgb(64, 210, 139) } else { $SecondaryLineColor }
    $secondaryPen = [System.Drawing.Pen]::new($secondaryLineColorActual, 1.4)
    $fillBrush = [System.Drawing.SolidBrush]::new($FillColor)

    $left = 32
    $right = 36
    $top = 42
    $bottom = 18
    $plot = [System.Drawing.Rectangle]::new($left, $top, [Math]::Max(10, $Bounds.Width - $left - $right), [Math]::Max(10, $Bounds.Height - $top - $bottom))

    $max = 0L
    foreach ($value in $Values) {
        if ($value -gt $max) {
            $max = $value
        }
    }
    foreach ($value in @($SecondaryValues)) {
        if ($value -gt $max) {
            $max = $value
        }
    }
    $scaleMax = [Math]::Max(1L, $(if ($ScaleMax -gt 0) { $ScaleMax } else { $max }))

    $Graphics.DrawString($Title, $font, $textBrush, 14, 9)
    if (-not [string]::IsNullOrWhiteSpace($StatusState)) {
        $dotColor = switch ($StatusState) {
            "online" { [System.Drawing.Color]::FromArgb(82, 220, 132) }
            "offline" { [System.Drawing.Color]::FromArgb(245, 101, 101) }
            default { [System.Drawing.Color]::FromArgb(180, 174, 187, 202) }
        }
        $titleSize = $Graphics.MeasureString($Title, $font)
        $dotX = [Math]::Min($Bounds.Width - 18, [int](18 + $titleSize.Width))
        $dotBrush = [System.Drawing.SolidBrush]::new($dotColor)
        $Graphics.FillEllipse($dotBrush, $dotX, 13, 7, 7)
        $dotBrush.Dispose()
    }
    if (-not [string]::IsNullOrWhiteSpace($SummaryValue)) {
        $summaryTextColor = if ($SummaryColor.IsEmpty) { $textBrush.Color } else { $SummaryColor }
        $summaryBrush = [System.Drawing.SolidBrush]::new($summaryTextColor)
        $summaryLabelBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(150, 204, 222, 214))
        $summaryFormat = [System.Drawing.StringFormat]::new()
        $summaryFormat.Alignment = [System.Drawing.StringAlignment]::Far
        $summaryFormat.LineAlignment = [System.Drawing.StringAlignment]::Center
        $summaryRect = [System.Drawing.RectangleF]::new([float]($Bounds.Width - 236), 10, 112, 18)
        $summaryValueRect = [System.Drawing.RectangleF]::new([float]($Bounds.Width - 122), 7, 106, 24)
        $Graphics.DrawString($SummaryLabel, $smallFont, $summaryLabelBrush, $summaryRect, $summaryFormat)
        $Graphics.DrawString($SummaryValue, $summaryFont, $summaryBrush, $summaryValueRect, $summaryFormat)
        $summaryFormat.Dispose()
        $summaryLabelBrush.Dispose()
        $summaryBrush.Dispose()
    }
    for ($i = 0; $i -le 4; $i++) {
        $y = $plot.Top + [int](($plot.Height / 4.0) * $i)
        $Graphics.DrawLine($gridPen, $plot.Left, $y, $plot.Right, $y)
        if ($max -gt 0 -or $i -eq 4) {
            $labelValue = if ($max -gt 0) { [long][Math]::Round($scaleMax * (1 - ($i / 4.0))) } else { 0L }
            $Graphics.DrawString((Format-TuhCompact -Value $labelValue), $smallFont, $mutedBrush, $plot.Right + 4, $y - 7)
        }
    }
    for ($i = 0; $i -le 6; $i++) {
        $x = $plot.Left + [int](($plot.Width / 6.0) * $i)
        $Graphics.DrawLine($gridPen, $x, $plot.Top, $x, $plot.Bottom)
    }
    $Graphics.DrawLine($axisPen, $plot.Left, $plot.Bottom, $plot.Right, $plot.Bottom)

    if ($Values.Length -gt 0) {
        $points = New-Object System.Collections.Generic.List[System.Drawing.PointF]
        for ($i = 0; $i -lt $Values.Length; $i++) {
            $x = $plot.Left + (($plot.Width * $i) / [Math]::Max(1, $Values.Length - 1))
            $ratio = [double]$Values[$i] / [double]$scaleMax
            $y = $plot.Bottom - ($plot.Height * $ratio)
            [void]$points.Add([System.Drawing.PointF]::new([float]$x, [float]$y))
        }
        if ($points.Count -gt 1) {
            if ($max -gt 0) {
                $poly = New-Object System.Collections.Generic.List[System.Drawing.PointF]
                [void]$poly.Add([System.Drawing.PointF]::new([float]$plot.Left, [float]$plot.Bottom))
                foreach ($point in $points) {
                    [void]$poly.Add($point)
                }
                [void]$poly.Add([System.Drawing.PointF]::new([float]$plot.Right, [float]$plot.Bottom))
                $Graphics.FillPolygon($fillBrush, $poly.ToArray())
            }
            $Graphics.DrawLines($linePen, $points.ToArray())
        }
    }
    else {
        $Graphics.DrawLine($linePen, $plot.Left, $plot.Bottom, $plot.Right, $plot.Bottom)
    }

    if ($SecondaryValues.Length -gt 0) {
        $secondaryPoints = New-Object System.Collections.Generic.List[System.Drawing.PointF]
        for ($i = 0; $i -lt $SecondaryValues.Length; $i++) {
            $x = $plot.Left + (($plot.Width * $i) / [Math]::Max(1, $SecondaryValues.Length - 1))
            $ratio = [double]$SecondaryValues[$i] / [double]$scaleMax
            $y = $plot.Bottom - ($plot.Height * $ratio)
            [void]$secondaryPoints.Add([System.Drawing.PointF]::new([float]$x, [float]$y))
        }
        if ($secondaryPoints.Count -gt 1) {
            $Graphics.DrawLines($secondaryPen, $secondaryPoints.ToArray())
        }
    }

    $Graphics.DrawString(("{0}m" -f $ChartMinutes), $smallFont, $mutedBrush, $plot.Left, $plot.Bottom + 3)
    $nowFormat = [System.Drawing.StringFormat]::new()
    $nowFormat.Alignment = [System.Drawing.StringAlignment]::Far
    $nowRect = [System.Drawing.RectangleF]::new([float]($plot.Right - 44), [float]($plot.Bottom + 3), 44, 16)
    $Graphics.DrawString("now", $smallFont, $mutedBrush, $nowRect, $nowFormat)
    $nowFormat.Dispose()

    $font.Dispose()
    $smallFont.Dispose()
    $summaryFont.Dispose()
    $textBrush.Dispose()
    $mutedBrush.Dispose()
    $quietBrush.Dispose()
    $gridPen.Dispose()
    $axisPen.Dispose()
    $linePen.Dispose()
    $secondaryPen.Dispose()
    $fillBrush.Dispose()
}

function Draw-TuhDataStrip {
    param(
        [System.Drawing.Graphics]$Graphics,
        [System.Drawing.Rectangle]$Bounds
    )

    $Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $Graphics.Clear((Get-TuhStripBackColor))

    $labelFont = [System.Drawing.Font]::new("Segoe UI", 7)
    $valueFont = [System.Drawing.Font]::new("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $miniFont = [System.Drawing.Font]::new("Segoe UI", 8)
    $labelBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(140, 190, 204, 198))
    $usageColor = [System.Drawing.Color]::FromArgb(80, 170, 255)
    $savedColor = [System.Drawing.Color]::FromArgb(64, 230, 140)
    $usageBrush = [System.Drawing.SolidBrush]::new($usageColor)
    $savedBrush = [System.Drawing.SolidBrush]::new($savedColor)
    $mutedBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(155, 185, 200, 194))
    $dividerPen = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(28, 160, 190, 170), 1)

    $usageTotal = if ($null -ne $script:latestResult -and $null -ne $script:latestResult.state) { [long]$script:latestResult.state.cumulativeUsageTokens } else { 0L }
    $savedTotal = if ($null -ne $script:latestResult -and $null -ne $script:latestResult.state) { [long]$script:latestResult.state.cumulativeSavedTokens } else { 0L }
    $usageValues = Get-TuhFixedSampleSeries -Samples $script:latestSamples -Field "usageTokens" -Minutes $ChartMinutes -SlotSeconds $ChartSlotSeconds
    $savedValues = Get-TuhFixedSampleSeries -Samples $script:latestSamples -Field "savedTokens" -Minutes $ChartMinutes -SlotSeconds $ChartSlotSeconds
    $usagePeak = 0L
    foreach ($value in $usageValues) {
        if ($value -gt $usagePeak) {
            $usagePeak = $value
        }
    }
    $savedPeak = 0L
    foreach ($value in $savedValues) {
        if ($value -gt $savedPeak) {
            $savedPeak = $value
        }
    }
    $state = if ((Get-TuhPanelStatusLabel) -eq "offline") { "offline" } else { "online" }
    $dotBrush = [System.Drawing.SolidBrush]::new($(if ($state -eq "online") { [System.Drawing.Color]::FromArgb(82, 220, 132) } else { [System.Drawing.Color]::FromArgb(245, 101, 101) }))

    $colW = [Math]::Max(112, [int](($Bounds.Width - 32) / 3))
    $x1 = 14
    $x2 = $x1 + $colW
    $x3 = $x2 + $colW
    $labelY = 8
    $valueY = 23
    $peakY = 42

    $Graphics.DrawLine($dividerPen, 0, 0, $Bounds.Width, 0)
    $Graphics.FillEllipse($usageBrush, $x1, $labelY + 3, 7, 7)
    $Graphics.DrawString("Token usage", $labelFont, $labelBrush, $x1 + 12, $labelY)
    $Graphics.DrawString(("total {0}" -f (Format-TuhCompact -Value $usageTotal)), $valueFont, $usageBrush, $x1, $valueY)
    $Graphics.DrawString(("usage peak {0}" -f (Format-TuhCompact -Value $usagePeak)), $miniFont, $mutedBrush, $x1, $peakY)

    $Graphics.FillEllipse($savedBrush, $x2, $labelY + 3, 7, 7)
    $Graphics.DrawString("Token saved", $labelFont, $labelBrush, $x2 + 12, $labelY)
    $Graphics.DrawString(("total {0}" -f (Format-TuhCompact -Value $savedTotal)), $valueFont, $savedBrush, $x2, $valueY)
    $savedPeakLabel = "max/run {0}" -f (Format-TuhCompact -Value $savedPeak)
    $Graphics.DrawString($savedPeakLabel, $miniFont, $mutedBrush, $x2, $peakY)

    $Graphics.DrawString("Token saver", $labelFont, $labelBrush, $x3, $labelY)
    $Graphics.FillEllipse($dotBrush, $x3, $valueY + 3, 8, 8)
    $Graphics.DrawString($state, $valueFont, $mutedBrush, $x3 + 15, $valueY - 3)

    $dotBrush.Dispose()
    $dividerPen.Dispose()
    $mutedBrush.Dispose()
    $savedBrush.Dispose()
    $usageBrush.Dispose()
    $labelBrush.Dispose()
    $miniFont.Dispose()
    $valueFont.Dispose()
    $labelFont.Dispose()
}

function Show-TuhSettings {
    param([System.Windows.Forms.Form]$Owner)

    $script:settingsResetApplied = $false
    $config = Read-TuhConfig -DataPath $DataPath
    $dialog = New-Object System.Windows.Forms.Form
    $script:settingsDialog = $dialog
    $dialog.Text = "Token saver"
    $dialog.Size = [System.Drawing.Size]::new(460, 410)
    $dialog.StartPosition = "CenterParent"
    $dialog.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.BackColor = [System.Drawing.Color]::FromArgb(18, 27, 42)

    $title = New-Object System.Windows.Forms.Label
    $title.Text = "Token saver"
    $title.Location = [System.Drawing.Point]::new(18, 16)
    $title.Size = [System.Drawing.Size]::new(240, 24)
    $title.Font = [System.Drawing.Font]::new("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
    $title.ForeColor = [System.Drawing.Color]::FromArgb(238, 244, 248)

    $subtitle = New-Object System.Windows.Forms.Label
    $subtitle.Text = "Simple controls"
    $subtitle.Location = [System.Drawing.Point]::new(18, 40)
    $subtitle.Size = [System.Drawing.Size]::new(240, 20)
    $subtitle.Font = [System.Drawing.Font]::new("Segoe UI", 8)
    $subtitle.ForeColor = [System.Drawing.Color]::FromArgb(155, 174, 190)

    $helperCheck = New-Object System.Windows.Forms.CheckBox
    $helperCheck.Text = "Enable token saver"
    $helperCheck.Checked = [bool]$config.helperEnabled
    $helperCheck.Location = [System.Drawing.Point]::new(20, 72)
    $helperCheck.Size = [System.Drawing.Size]::new(240, 24)
    $helperCheck.Font = [System.Drawing.Font]::new("Segoe UI", 9)
    $helperCheck.ForeColor = [System.Drawing.Color]::FromArgb(224, 235, 242)
    $helperCheck.BackColor = $dialog.BackColor

    $thresholdLabel = New-Object System.Windows.Forms.Label
    $thresholdLabel.Text = "Start saving above"
    $thresholdLabel.Location = [System.Drawing.Point]::new(20, 112)
    $thresholdLabel.Size = [System.Drawing.Size]::new(120, 22)
    $thresholdLabel.Font = [System.Drawing.Font]::new("Segoe UI", 9)
    $thresholdLabel.ForeColor = [System.Drawing.Color]::FromArgb(180, 198, 212)

    $thresholdBox = New-Object System.Windows.Forms.NumericUpDown
    $thresholdBox.Location = [System.Drawing.Point]::new(150, 110)
    $thresholdBox.Size = [System.Drawing.Size]::new(120, 24)
    $thresholdBox.Minimum = 0
    $thresholdBox.Maximum = 2000000
    $thresholdBox.Increment = 1000
    $thresholdBox.Value = [decimal][Math]::Min([int]$thresholdBox.Maximum, [Math]::Max([int]$thresholdBox.Minimum, [int]$config.thresholdTokens))
    $thresholdBox.Font = [System.Drawing.Font]::new("Segoe UI", 9)

    $thresholdHelp = New-Object System.Windows.Forms.Label
    $thresholdHelp.Text = "When one request is likely to use more than this many tokens, token saver prepares a smaller context package first. Lower saves more often; higher interferes less."
    $thresholdHelp.Location = [System.Drawing.Point]::new(20, 144)
    $thresholdHelp.Size = [System.Drawing.Size]::new(410, 36)
    $thresholdHelp.Font = [System.Drawing.Font]::new("Segoe UI", 8)
    $thresholdHelp.ForeColor = [System.Drawing.Color]::FromArgb(155, 174, 190)

    $budgetLabel = New-Object System.Windows.Forms.Label
    $budgetLabel.Text = "Context budget"
    $budgetLabel.Location = [System.Drawing.Point]::new(20, 192)
    $budgetLabel.Size = [System.Drawing.Size]::new(120, 22)
    $budgetLabel.Font = [System.Drawing.Font]::new("Segoe UI", 9)
    $budgetLabel.ForeColor = [System.Drawing.Color]::FromArgb(180, 198, 212)

    $budgetBox = New-Object System.Windows.Forms.NumericUpDown
    $budgetBox.Location = [System.Drawing.Point]::new(150, 190)
    $budgetBox.Size = [System.Drawing.Size]::new(120, 24)
    $budgetBox.Minimum = 4000
    $budgetBox.Maximum = 120000
    $budgetBox.Increment = 1000
    $budgetBox.Value = [decimal][Math]::Min([int]$budgetBox.Maximum, [Math]::Max([int]$budgetBox.Minimum, [int](Get-TuhProp -Object $config -Name "contextBudgetChars" -DefaultValue 12000)))
    $budgetBox.Font = [System.Drawing.Font]::new("Segoe UI", 9)

    $budgetHelp = New-Object System.Windows.Forms.Label
    $budgetHelp.Text = "How many characters the compact context package may keep. Lower saves more tokens but can drop useful project context."
    $budgetHelp.Location = [System.Drawing.Point]::new(20, 224)
    $budgetHelp.Size = [System.Drawing.Size]::new(410, 36)
    $budgetHelp.Font = [System.Drawing.Font]::new("Segoe UI", 8)
    $budgetHelp.ForeColor = [System.Drawing.Color]::FromArgb(155, 174, 190)

    $riskLabel = New-Object System.Windows.Forms.Label
    $riskLabel.Location = [System.Drawing.Point]::new(20, 272)
    $riskLabel.Size = [System.Drawing.Size]::new(410, 34)
    $riskLabel.Font = [System.Drawing.Font]::new("Segoe UI", 8, [System.Drawing.FontStyle]::Bold)

    $updateRisk = {
        $threshold = [int]$thresholdBox.Value
        $budget = [int]$budgetBox.Value
        $riskText = "Low performance risk"
        $riskColor = [System.Drawing.Color]::FromArgb(78, 201, 126)
        if ($budget -lt 8000 -or $threshold -lt 4000) {
            $riskText = "High performance risk: context may be too small or token saver may interfere too often."
            $riskColor = [System.Drawing.Color]::FromArgb(245, 101, 101)
        }
        elseif ($budget -lt 12000 -or $threshold -lt 6000) {
            $riskText = "Medium performance risk: usable, but complex coding tasks may need more context."
            $riskColor = [System.Drawing.Color]::FromArgb(236, 201, 116)
        }
        elseif ($budget -gt 30000) {
            $riskText = "Low performance risk; token savings may be lower."
        }
        $riskLabel.Text = "Performance risk: $riskText"
        $riskLabel.ForeColor = $riskColor
    }

    $thresholdBox.Add_ValueChanged($updateRisk)
    $budgetBox.Add_ValueChanged($updateRisk)
    & $updateRisk

    $saveButton = New-Object System.Windows.Forms.Button
    $saveButton.Text = "Save"
    $saveButton.Location = [System.Drawing.Point]::new(116, 334)
    $saveButton.Size = [System.Drawing.Size]::new(78, 30)
    $saveButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $saveButton.BackColor = [System.Drawing.Color]::FromArgb(48, 130, 92)
    $saveButton.ForeColor = [System.Drawing.Color]::White
    $saveButton.Add_Click({
        $newConfig = [PSCustomObject]@{
            helperEnabled = $helperCheck.Checked
            thresholdTokens = [int]$thresholdBox.Value
            contextBudgetChars = [int]$budgetBox.Value
            refreshSeconds = 5
            dataPath = [string]$config.dataPath
            panelOpacityPercent = 72
            panelX = $script:panelForm.Left
            panelY = $script:panelForm.Top
            panelWidth = $script:panelForm.Width
            panelHeight = $script:panelForm.Height
        }
        Clear-TuhRefreshProcess -Kill $true
        $savedConfig = Save-TuhConfig -Config $newConfig -DataPath $DataPath
        $savedConfig.panelOpacityPercent = 72
        Apply-TuhPanelConfigImmediately -Config $savedConfig
        $script:settingsDialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $script:settingsDialog.Close()
    })

    $resetButton = New-Object System.Windows.Forms.Button
    $resetButton.Text = "Reset data"
    $resetButton.Location = [System.Drawing.Point]::new(202, 334)
    $resetButton.Size = [System.Drawing.Size]::new(92, 30)
    $resetButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $resetButton.BackColor = [System.Drawing.Color]::FromArgb(42, 54, 70)
    $resetButton.ForeColor = [System.Drawing.Color]::FromArgb(230, 236, 242)
    $resetButton.Add_Click({
        Invoke-TuhPanelReset -FromSettings $true
        $script:settingsDialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $script:settingsDialog.Close()
    })

    $closeButton = New-Object System.Windows.Forms.Button
    $closeButton.Text = "Close"
    $closeButton.Location = [System.Drawing.Point]::new(302, 334)
    $closeButton.Size = [System.Drawing.Size]::new(70, 30)
    $closeButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $closeButton.BackColor = [System.Drawing.Color]::FromArgb(30, 39, 52)
    $closeButton.ForeColor = [System.Drawing.Color]::FromArgb(210, 222, 232)
    $closeButton.Add_Click({ $script:settingsDialog.Close() })

    foreach ($control in @($title, $subtitle, $helperCheck, $thresholdLabel, $thresholdBox, $thresholdHelp, $budgetLabel, $budgetBox, $budgetHelp, $riskLabel, $saveButton, $resetButton, $closeButton)) {
        $dialog.Controls.Add($control)
    }
    [void]$dialog.ShowDialog($Owner)
    $script:settingsDialog = $null
}

function Show-TuhHealthLog {
    param([System.Windows.Forms.Form]$Owner)

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = "Token saver - Health Log"
    $dialog.Size = [System.Drawing.Size]::new(620, 360)
    $dialog.StartPosition = "CenterParent"
    $dialog.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::SizableToolWindow
    $dialog.BackColor = [System.Drawing.Color]::FromArgb(18, 27, 42)

    $title = New-Object System.Windows.Forms.Label
    $title.Text = "Health Log"
    $title.Location = [System.Drawing.Point]::new(16, 14)
    $title.Size = [System.Drawing.Size]::new(220, 24)
    $title.Font = [System.Drawing.Font]::new("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
    $title.ForeColor = [System.Drawing.Color]::FromArgb(238, 244, 248)

    $box = New-Object System.Windows.Forms.TextBox
    $box.Location = [System.Drawing.Point]::new(16, 48)
    $box.Size = [System.Drawing.Size]::new(586, 262)
    $box.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $box.Multiline = $true
    $box.ReadOnly = $true
    $box.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $box.Font = [System.Drawing.Font]::new("Consolas", 9)
    $box.BackColor = [System.Drawing.Color]::FromArgb(9, 14, 23)
    $box.ForeColor = [System.Drawing.Color]::FromArgb(220, 232, 240)
    $box.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

    $events = Read-TuhHealthEvents -DataPath $DataPath
    if ($events.Count -eq 0) {
        $box.Text = "No health events recorded."
    }
    else {
        $lines = New-Object System.Collections.Generic.List[string]
        foreach ($event in @($events.ToArray())) {
            $line = "[{0}] {1} {2} - {3}" -f $event.atUtc, $event.level, $event.label, $event.detail
            if (-not [string]::IsNullOrWhiteSpace([string]$event.projectPath)) {
                $line = "{0}`r`n  {1}" -f $line, $event.projectPath
            }
            [void]$lines.Add($line)
        }
        $box.Text = [string]::Join("`r`n`r`n", $lines.ToArray())
        $box.SelectionStart = $box.TextLength
        $box.ScrollToCaret()
    }

    $closeButton = New-Object System.Windows.Forms.Button
    $closeButton.Text = "Close"
    $closeButton.Location = [System.Drawing.Point]::new(522, 318)
    $closeButton.Size = [System.Drawing.Size]::new(80, 28)
    $closeButton.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
    $closeButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $closeButton.BackColor = [System.Drawing.Color]::FromArgb(30, 39, 52)
    $closeButton.ForeColor = [System.Drawing.Color]::FromArgb(230, 236, 242)
    $closeButton.Add_Click({ $dialog.Close() })

    foreach ($control in @($title, $box, $closeButton)) {
        $dialog.Controls.Add($control)
    }
    [void]$dialog.ShowDialog($Owner)
}

function Show-TuhDoctor {
    param([System.Windows.Forms.Form]$Owner)

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = "Token saver - Doctor"
    $dialog.Size = [System.Drawing.Size]::new(660, 420)
    $dialog.StartPosition = "CenterParent"
    $dialog.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::SizableToolWindow
    $dialog.BackColor = [System.Drawing.Color]::FromArgb(18, 27, 42)

    $title = New-Object System.Windows.Forms.Label
    $title.Text = "Doctor"
    $title.Location = [System.Drawing.Point]::new(16, 14)
    $title.Size = [System.Drawing.Size]::new(220, 24)
    $title.Font = [System.Drawing.Font]::new("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
    $title.ForeColor = [System.Drawing.Color]::FromArgb(238, 244, 248)

    $box = New-Object System.Windows.Forms.TextBox
    $box.Location = [System.Drawing.Point]::new(16, 48)
    $box.Size = [System.Drawing.Size]::new(626, 314)
    $box.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $box.Multiline = $true
    $box.ReadOnly = $true
    $box.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $box.Font = [System.Drawing.Font]::new("Consolas", 9)
    $box.BackColor = [System.Drawing.Color]::FromArgb(9, 14, 23)
    $box.ForeColor = [System.Drawing.Color]::FromArgb(220, 232, 240)
    $box.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

    try {
        $doctor = Invoke-TuhDoctor -ProjectPath $ProjectPath -DataPath $DataPath -AllProjects:$AllProjects
        Apply-TuhDoctorResultToPanel -Doctor $doctor
        $lines = New-Object System.Collections.Generic.List[string]
        [void]$lines.Add(("Overall:     {0}" -f $(if ($doctor.ok) { "ok" } else { "needs attention" })))
        [void]$lines.Add(("Diagnostic:  {0} / {1}" -f $doctor.diagnostic.level, $doctor.diagnostic.label))
        [void]$lines.Add(("Detail:      {0}" -f $doctor.diagnostic.detail))
        [void]$lines.Add("")
        [void]$lines.Add(("Scope:       {0}" -f $doctor.scope))
        [void]$lines.Add(("Project:     {0}" -f $doctor.projectPath))
        [void]$lines.Add(("Source:      {0} / {1}" -f $doctor.metrics.source, $doctor.metrics.confidence))
        [void]$lines.Add(("Usage:       {0:N0}" -f [long]$doctor.metrics.currentUsageTokens))
        [void]$lines.Add(("Saved:       {0:N0}" -f [long]$doctor.metrics.currentSavedTokens))
        [void]$lines.Add("")
        [void]$lines.Add("Paths:")
        [void]$lines.Add(("  data:      {0}" -f $doctor.paths.dataPath))
        [void]$lines.Add(("  state:     {0}" -f $doctor.paths.statePath))
        [void]$lines.Add(("  config:    {0}" -f $doctor.paths.configPath))
        [void]$lines.Add(("  health:    {0}" -f $doctor.paths.healthEventsPath))
        [void]$lines.Add("")
        [void]$lines.Add("Checks:")
        foreach ($check in @($doctor.checks)) {
            [void]$lines.Add(("  [{0}] {1}: {2}" -f $(if ($check.ok) { "ok" } else { "fail" }), $check.name, $check.detail))
        }
        [void]$lines.Add("")
        [void]$lines.Add(("Recent health events: {0}" -f @($doctor.recentHealthEvents).Count))
        $box.Text = [string]::Join("`r`n", $lines.ToArray())
    }
    catch {
        $box.Text = "Doctor failed.`r`n" + $_.Exception.Message
    }

    $closeButton = New-Object System.Windows.Forms.Button
    $closeButton.Text = "Close"
    $closeButton.Location = [System.Drawing.Point]::new(562, 370)
    $closeButton.Size = [System.Drawing.Size]::new(80, 28)
    $closeButton.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
    $closeButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $closeButton.BackColor = [System.Drawing.Color]::FromArgb(30, 39, 52)
    $closeButton.ForeColor = [System.Drawing.Color]::FromArgb(230, 236, 242)
    $closeButton.Add_Click({ $dialog.Close() })

    foreach ($control in @($title, $box, $closeButton)) {
        $dialog.Controls.Add($control)
    }
    [void]$dialog.ShowDialog($Owner)
}

function Open-TuhDataFolder {
    try {
        $folder = Resolve-TuhDataPath -DataPath $DataPath
        if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
            New-Item -ItemType Directory -Force -Path $folder | Out-Null
        }
        Start-Process -FilePath explorer.exe -ArgumentList @($folder) | Out-Null
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Could not open data folder.`r`n$($_.Exception.Message)",
            "Token saver",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
    }
}

$form = New-Object TuhClickThroughForm
$script:panelForm = $form
$form.Text = "Token saver"
$form.MinimumSize = [System.Drawing.Size]::new(380, 220)
$form.TopMost = $true
$form.Opacity = if ($script:panelPinned) { Get-TuhPinnedOpacity -Config $script:panelConfig } else { Get-TuhUnpinnedOpacity }
$form.BackColor = Get-TuhFormBackColor
$form.TransparencyKey = [System.Drawing.Color]::Empty
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$form.Icon = New-TuhAppIcon
Enable-TuhDoubleBuffer -Control $form
Set-TuhPanelSafeBounds -Form $form -Config $script:panelConfig
Update-TuhCaptionRects -Width $form.ClientSize.Width
[TuhClickThroughForm]::Pinned = $script:panelPinned

$usageChart = New-Object System.Windows.Forms.Panel
$usageChart.Location = [System.Drawing.Point]::new(0, 0)
$usageChart.Size = [System.Drawing.Size]::new($form.ClientSize.Width, [Math]::Max(120, $form.ClientSize.Height - 64))
$usageChart.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$usageChart.BackColor = Get-TuhChartBackColor
Enable-TuhDoubleBuffer -Control $usageChart

$savingChart = New-Object System.Windows.Forms.Panel
$savingChart.Location = [System.Drawing.Point]::new(0, $usageChart.Bottom)
$savingChart.Size = [System.Drawing.Size]::new($form.ClientSize.Width, 64)
$savingChart.Anchor = [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right -bor [System.Windows.Forms.AnchorStyles]::Bottom
$savingChart.BackColor = Get-TuhStripBackColor
Enable-TuhDoubleBuffer -Control $savingChart

$form.Controls.Add($usageChart)
$form.Controls.Add($savingChart)

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$settingsItem = $menu.Items.Add("Settings")
$resetItem = $menu.Items.Add("Reset Stats")
$exitItem = $menu.Items.Add("Exit")
$form.ContextMenuStrip = $menu
$usageChart.ContextMenuStrip = $menu
$savingChart.ContextMenuStrip = $menu

Add-TuhDragHandlers -Control $form
Add-TuhDragHandlers -Control $savingChart

$form.Add_MouseMove({
    Set-TuhPanelHover -Hover $true
})
$form.Add_MouseLeave({
    Set-TuhPanelHover -Hover $false
})
$savingChart.Add_MouseMove({
    Set-TuhPanelHover -Hover $true
})
$savingChart.Add_MouseLeave({
    Set-TuhPanelHover -Hover $false
})

function Refresh-TuhPanel {
    Complete-TuhPanelRefresh
    if ($null -ne $script:refreshProcess) {
        return
    }

    try {
        $script:refreshOutputPath = [System.IO.Path]::GetTempFileName()
        $script:refreshErrorPath = [System.IO.Path]::GetTempFileName()
        $cli = Join-Path $scriptRoot "token-helper.ps1"
        $args = @(
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            $cli,
            "refresh",
            "-ProjectPath",
            $ProjectPath,
            "-Json"
        )
        if (-not [string]::IsNullOrWhiteSpace($DataPath)) {
            $args += @("-DataPath", $DataPath)
        }
        if ($AllProjects) {
            $args += "-AllProjects"
        }

        $script:refreshStartedAtUtc = (Get-Date).ToUniversalTime()
        $script:refreshProcess = Start-Process -FilePath powershell.exe `
            -WindowStyle Hidden `
            -ArgumentList $args `
            -RedirectStandardOutput $script:refreshOutputPath `
            -RedirectStandardError $script:refreshErrorPath `
            -PassThru
    }
    catch {
        Clear-TuhRefreshProcess -Kill $true
        $script:lastRefreshError = $_.Exception.Message
        $script:latestDiagnostic = Get-TuhDiagnostic -Config $script:panelConfig -State $(if ($null -ne $script:latestResult) { $script:latestResult.state } else { $null }) -Metrics $(if ($null -ne $script:latestResult) { $script:latestResult.metrics } else { $null }) -RefreshError $script:lastRefreshError
        Record-TuhPanelHealthEventIfNeeded
        Invalidate-TuhCharts -All $true
        $script:panelForm.Text = "Token saver - refresh failed"
    }
}

$usageChart.Add_Paint({
    param($sender, $eventArgs)
    $values = Get-TuhFixedSampleSeries -Samples $script:latestSamples -Field "usageTokens" -Minutes $ChartMinutes -SlotSeconds $ChartSlotSeconds
    $savedValues = Get-TuhFixedSampleSeries -Samples $script:latestSamples -Field "savedTokens" -Minutes $ChartMinutes -SlotSeconds $ChartSlotSeconds
    $script:usageScaleMax = Update-TuhStickyScale -CurrentScale $script:usageScaleMax -Values $values
    $script:usageScaleMax = Update-TuhStickyScale -CurrentScale $script:usageScaleMax -Values $savedValues
    $usageEmptyText = "no new usage"
    $usageEmptyLabel = if ($null -ne $script:latestResult -and $null -ne $script:latestResult.metrics) { ("{0} - total {1}" -f $usageEmptyText, (Format-TuhCompact -Value ([long]$script:latestResult.metrics.currentUsageTokens))) } else { "waiting for usage data" }
    $usageTitle = "Token activity - 15m"
    Draw-TuhChart `
        -Graphics $eventArgs.Graphics `
        -Bounds $sender.ClientRectangle `
        -Title $usageTitle `
        -Values $values `
        -LineColor ([System.Drawing.Color]::FromArgb(80, 170, 255)) `
        -FillColor ([System.Drawing.Color]::FromArgb(36, 80, 170, 255)) `
        -BackColor ([System.Drawing.Color]::FromArgb(11, 18, 29)) `
        -EmptyLabel $usageEmptyLabel `
        -ScaleMax $script:usageScaleMax `
        -SecondaryValues $savedValues `
        -SecondaryLineColor ([System.Drawing.Color]::FromArgb(64, 230, 140))
    Draw-TuhCaptionIcons -Graphics $eventArgs.Graphics -Width $sender.ClientRectangle.Width
})

$savingChart.Add_Paint({
    param($sender, $eventArgs)
    Draw-TuhDataStrip -Graphics $eventArgs.Graphics -Bounds $sender.ClientRectangle
})

$settingsItem.Add_Click({
    Show-TuhSettings -Owner $script:panelForm
    if (-not $script:settingsResetApplied) {
        Refresh-TuhPanel
    }
})
$resetItem.Add_Click({
    Invoke-TuhPanelReset
})
$exitItem.Add_Click({ $script:panelForm.Close() })

$usageChart.Add_MouseDown({
    param($sender, $eventArgs)
    if ($eventArgs.Button -ne [System.Windows.Forms.MouseButtons]::Left) {
        return
    }
    $hit = Test-TuhCaptionHit -Point ([System.Drawing.Point]::new($eventArgs.X, $eventArgs.Y))
    if ($hit -eq "settings") {
        Show-TuhSettings -Owner $script:panelForm
        if (-not $script:settingsResetApplied) {
            Refresh-TuhPanel
        }
        return
    }
    if ($hit -eq "pin") {
        Set-TuhPanelPinned -Pinned (-not $script:panelPinned)
        $script:dragging = $false
        $usageChart.Invalidate()
        return
    }
    if ($hit -eq "close") {
        $script:panelForm.Close()
        return
    }
    if (-not $script:panelPinned) {
        $script:dragging = $true
        $script:dragOffset = [System.Drawing.Point]::new($eventArgs.X, $eventArgs.Y)
    }
})
$usageChart.Add_MouseMove({
    param($sender, $eventArgs)
    Set-TuhPanelHover -Hover $true
    $hit = Test-TuhCaptionHit -Point ([System.Drawing.Point]::new($eventArgs.X, $eventArgs.Y))
    if ($hit -ne $script:hoverCaption) {
        $script:hoverCaption = $hit
        $usageChart.Invalidate()
    }
    $sender.Cursor = if (-not [string]::IsNullOrWhiteSpace($hit)) { [System.Windows.Forms.Cursors]::Hand } elseif ($script:panelPinned) { [System.Windows.Forms.Cursors]::Default } else { [System.Windows.Forms.Cursors]::SizeAll }
    if ($script:dragging) {
        $screen = $sender.PointToScreen([System.Drawing.Point]::new($eventArgs.X, $eventArgs.Y))
        $script:panelForm.Location = [System.Drawing.Point]::new($screen.X - $script:dragOffset.X, $screen.Y - $script:dragOffset.Y)
    }
})
$usageChart.Add_MouseUp({
    $script:dragging = $false
})
$usageChart.Add_MouseLeave({
    Set-TuhPanelHover -Hover $false
    if (-not [string]::IsNullOrWhiteSpace($script:hoverCaption)) {
        $script:hoverCaption = ""
    }
    $usageChart.Invalidate()
})

$form.Add_Resize({
    $stripHeight = 64
    $usageChart.Location = [System.Drawing.Point]::new(0, 0)
    $usageChart.Size = [System.Drawing.Size]::new($script:panelForm.ClientSize.Width, [Math]::Max(80, $script:panelForm.ClientSize.Height - $stripHeight))
    $savingChart.Location = [System.Drawing.Point]::new(0, $usageChart.Bottom)
    $savingChart.Size = [System.Drawing.Size]::new($script:panelForm.ClientSize.Width, $stripHeight)
    Update-TuhCaptionRects -Width $usageChart.Width
    Set-TuhRoundedRegion -Form $script:panelForm
})

$stripHeight = 64
$usageChart.Location = [System.Drawing.Point]::new(0, 0)
$usageChart.Size = [System.Drawing.Size]::new($form.ClientSize.Width, [Math]::Max(80, $form.ClientSize.Height - $stripHeight))
$savingChart.Location = [System.Drawing.Point]::new(0, $usageChart.Bottom)
$savingChart.Size = [System.Drawing.Size]::new($form.ClientSize.Width, $stripHeight)
Update-TuhCaptionRects -Width $usageChart.Width
Set-TuhRoundedRegion -Form $form

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 8000
$timer.Add_Tick({ Refresh-TuhPanel })
$timer.Start()

$watchdogTimer = New-Object System.Windows.Forms.Timer
$watchdogTimer.Interval = 1000
$watchdogTimer.Add_Tick({
    Complete-TuhPanelRefresh
    $moved = Repair-TuhPanelBounds
    Set-TuhPanelHover -Hover (Test-TuhCursorInsidePanel)
    Update-TuhLiveDiagnostic
    Record-TuhPanelHealthEventIfNeeded
    if ($moved) {
        Set-TuhRoundedRegion -Form $script:panelForm
        Invalidate-TuhCharts -All $true
    }
    else {
        Invalidate-TuhCharts
    }
})
$watchdogTimer.Start()

$clickThroughTimer = New-Object System.Windows.Forms.Timer
$clickThroughTimer.Interval = 100
$clickThroughTimer.Add_Tick({
    Set-TuhPanelHover -Hover (Test-TuhCursorInsidePanel)
    Update-TuhPanelClickThrough
})
$clickThroughTimer.Start()

$form.Add_FormClosed({
    $timer.Stop()
    $timer.Dispose()
    $watchdogTimer.Stop()
    $watchdogTimer.Dispose()
    $clickThroughTimer.Stop()
    $clickThroughTimer.Dispose()
    Clear-TuhRefreshProcess -Kill $true
    Save-TuhPanelWindowState
    if ($null -ne $script:panelMutex) {
        try {
            $script:panelMutex.ReleaseMutex()
        }
        catch {
        }
        $script:panelMutex.Dispose()
        $script:panelMutex = $null
    }
})

$form.Add_Shown({
    try {
        $script:panelForm.TopMost = $false
        $script:panelForm.TopMost = $true
        $script:panelForm.Show()
        $script:panelForm.Activate()
        $script:panelForm.BringToFront()
        Invalidate-TuhCharts -All $true
        $script:clickThroughEnabled = -not ($script:panelPinned -and -not (Test-TuhCursorOverCaptionButton))
        Update-TuhPanelClickThrough
    }
    catch {
    }
})

Refresh-TuhPanel
[void]$form.ShowDialog()
