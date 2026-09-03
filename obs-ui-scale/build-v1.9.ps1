$ErrorActionPreference = 'Stop'

# Start from v1.8. The new recording proves the remaining jump is the whole
# bottom dock row getting taller immediately after a scene click. The context
# toolbar stays in the same no-source-selected state, so it is not the cause.
#
# v1.9 captures the EXACT good dock-row height produced by Apply and pins only
# OBS's built-in Scenes dock to that maximum height. Because all docks in that
# horizontal row share one row geometry, one anchor prevents the row from
# expanding without imposing max-height constraints on custom docks such as
# Win Capture Audio Health. The cap is released before every new Apply/100%
# restore so changing scale still works normally.
& ./build-v1.8.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v1.9 patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "1.8.0";' 'static constexpr const char *PLUGIN_VERSION = "1.9.0";' 'plugin version'

# Insert the row-anchor helper before v1.8's context toolbar helper.
$insertMarker = '    bool IsInsideContextContainer(QWidget *widget) const'
$insertPos = $s.IndexOf($insertMarker)
if ($insertPos -lt 0) { throw 'v1.9 could not locate helper insertion point' }

$helper = @'
    QDockWidget *DockRowAnchor() const
    {
        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
        if (!mainWindow)
            return nullptr;

        // Scenes is a stock OBS dock and is in the same bottom row as Sources,
        // Mixer, Transitions, Controls and the user's custom health dock.
        auto *anchor = mainWindow->findChild<QDockWidget *>(QStringLiteral("scenesDock"),
                                                            Qt::FindChildrenRecursively);
        if (!anchor || !anchor->isVisible() || anchor->isFloating()) {
            anchor = mainWindow->findChild<QDockWidget *>(QStringLiteral("sourcesDock"),
                                                          Qt::FindChildrenRecursively);
        }
        return anchor;
    }

    void ReleaseDockRowAnchor()
    {
        if (QDockWidget *anchor = DockRowAnchor()) {
            // Only v1.9 owns maximumHeight. Minimum height remains under the
            // normal scaling pass, so custom content is never starved by this.
            anchor->setMaximumHeight(QWIDGETSIZE_MAX);
            anchor->updateGeometry();
        }
        dockRowAnchorHeight_ = -1;
    }

    void CaptureAndLockDockRow(double uiPercent)
    {
        if (!proportionalMode_ || uiPercent >= 99.999) {
            ReleaseDockRowAnchor();
            return;
        }

        QDockWidget *anchor = DockRowAnchor();
        if (!anchor)
            return;

        const int h = anchor->height();
        if (h <= 0)
            return;

        // This is the exact post-Apply height visible to the user, not a height
        // recalculated from the old 100% baseline. Pinning one stock dock anchors
        // the entire horizontal dock row while leaving custom dock contents free.
        dockRowAnchorHeight_ = h;
        anchor->setMaximumHeight(h);
        anchor->updateGeometry();
    }

    void ScheduleDockRowAnchor(double uiPercent)
    {
        // ApplyProportionalDockGeometry() and the one queued refresh settle very
        // quickly. Capture after that point, then re-confirm once without changing
        // the target. Scene clicks cannot enlarge the row after the max is active.
        QTimer::singleShot(90, this, [this, uiPercent]() {
            if (qAbs(currentUiPercent_ - uiPercent) < 0.01)
                CaptureAndLockDockRow(uiPercent);
        });
        QTimer::singleShot(220, this, [this, uiPercent]() {
            if (qAbs(currentUiPercent_ - uiPercent) < 0.01 && dockRowAnchorHeight_ > 0) {
                if (QDockWidget *anchor = DockRowAnchor()) {
                    anchor->setMaximumHeight(dockRowAnchorHeight_);
                    anchor->updateGeometry();
                }
            }
        });
    }

'@
$s = $s.Substring(0, $insertPos) + $helper + $s.Substring($insertPos)

# Release the old row cap before applying a different percentage. Otherwise a
# previous smaller scale could prevent the new Apply from growing the row.
Replace-Required @'
    void ApplyScale(double requestedUiPercent, double requestedTextPercent)
    {
        CaptureBaselineIfNeeded();
'@ @'
    void ApplyScale(double requestedUiPercent, double requestedTextPercent)
    {
        ReleaseDockRowAnchor();
        CaptureBaselineIfNeeded();
'@ 'release row anchor before Apply'

# Once Apply has produced the desired good layout, remember and pin that exact
# height. This is what the video shows the user wants to survive scene clicks.
Replace-Required @'
        FitSourceDockHideCounter(uiPercent);
        ScheduleLatePluginWidgetFixes(uiPercent);
        ScheduleContextBarRescale(uiPercent);

        if (mainWindow) {
'@ @'
        FitSourceDockHideCounter(uiPercent);
        ScheduleLatePluginWidgetFixes(uiPercent);
        ScheduleContextBarRescale(uiPercent);
        ScheduleDockRowAnchor(uiPercent);

        if (mainWindow) {
'@ 'capture exact good dock row after Apply'

# A 100% restore must remove the scaled-row cap before restoring normal metrics.
Replace-Required @'
    void Restore100()
    {
        if (!baselineReady_)
            return;
'@ @'
    void Restore100()
    {
        ReleaseDockRowAnchor();
        if (!baselineReady_)
            return;
'@ 'release row anchor for 100 percent restore'

Replace-Required 'dialog.setWindowTitle(QStringLiteral("OBS UI Scale v1.8"));' 'dialog.setWindowTitle(QStringLiteral("OBS UI Scale v1.9"));' 'dialog title'
Replace-Required @'
            QStringLiteral("v1.8 keeps Source Dock Hide width ownership and fixes the remaining vertical jump. "
                           "OBS's dynamically rebuilt source context toolbar is scaled as it appears, so scene changes no longer undo the applied layout."),
'@ @'
            QStringLiteral("v1.9 keeps the applied dock row at the exact height produced by Apply. "
                           "Scene changes can no longer make the bottom OBS docks jump upward, while custom dock contents remain unconstrained."),
'@ 'dialog intro'

Replace-Required @'
    bool contextScaleQueued_ = false;
'@ @'
    bool contextScaleQueued_ = false;
    int dockRowAnchorHeight_ = -1;
'@ 'dock row anchor member'

Set-Content $path $s -Encoding utf8

$issPath = 'installer/ObsUiScale.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('1.8.0', '1.9.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared OBS UI Scale v1.9 exact post-Apply dock-row anchor.'
