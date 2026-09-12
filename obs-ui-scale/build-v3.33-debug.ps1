$ErrorActionPreference = 'Stop'

# v3.33 DEBUG
# v3.32 proved the exact 1-row geometry itself is reachable (74px), but it
# restored recursive child layout policies only 55ms later. The uploaded log
# then shows Qt immediately expanding the row from 74px to 121px.
#
# Correct lifetime:
# - while resting at exact 1/2-row minimum, keep the temporary low-row child
#   relaxation needed to physically fit that row;
# - BEFORE the next upward/manual splitter drag, release the latch and restore
#   normal child policies so text/buttons render normally at larger heights;
# - while a real manual drag is shrinking, temporarily relax bottom-row
#   descendants again so Qt does not stop at the old 3/4-row size hint;
# - if the drag ends high, normal visuals are restored; if it ends near floor,
#   exact snap/latch keeps relaxation only for that tiny resting row.
& ./build-v3.32-debug.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = [regex]::Replace($s, "\r\n", "\n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = [regex]::Replace($old, "\r\n", "\n")
    $new = [regex]::Replace($new, "\r\n", "\n")
    if (-not $script:s.Contains($old)) { throw "v3.33 debug patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "3.32.0-debug";' 'static constexpr const char *PLUGIN_VERSION = "3.33.0-debug";' 'plugin version'

Replace-Required @'
            QTimer::singleShot(55, this, [this, latchGeneration]() {
                if (!lowRowFloorLatchActive_ ||
                    latchGeneration != lowRowFloorLatchGeneration_)
                    return;
                RestoreLowRowDescendantVisualState();
                PollLowRowFloorLatchForUnlock(latchGeneration);
            });
'@ @'
            QTimer::singleShot(8, this, [this, latchGeneration]() {
                if (!lowRowFloorLatchActive_ ||
                    latchGeneration != lowRowFloorLatchGeneration_)
                    return;
                PollLowRowFloorLatchForUnlock(latchGeneration);
            });
'@ 'keep exact-row relaxation alive while latched'

$s = $s.Replace(
    'QTimer::singleShot(24, this, [this, generation]() {',
    'QTimer::singleShot(8, this, [this, generation]() {')

$restoreMarker = '    void RestoreLowRowDescendantVisualState()'
$restorePos = $s.IndexOf($restoreMarker)
if ($restorePos -lt 0) { throw 'v3.33 could not locate RestoreLowRowDescendantVisualState' }

$manualRelaxHelper = @'
    void RelaxLowRowDescendantsForManualDrag()
    {
        if (!sceneRowLockEnabled_ || sceneVisibleRows_ > 2)
            return;

        auto *mainWindow =
            static_cast<QMainWindow *>(obs_frontend_get_main_window());
        QDockWidget *sceneDock = ScenesDock();
        if (!mainWindow || !sceneDock)
            return;

        RelaxBottomRowSiblingMinimums();
        RelaxSceneDockInternalMinimums();

        const int rowY = sceneDock->y();
        const int floor = qMax(1, lockedSceneDockHeight_);
        const auto docks =
            mainWindow->findChildren<QDockWidget *>(QString(),
                                                   Qt::FindDirectChildrenOnly);
        for (QDockWidget *dock : docks) {
            if (!dock || !dock->isVisible() || dock->isFloating())
                continue;
            if (mainWindow->dockWidgetArea(dock) != Qt::BottomDockWidgetArea)
                continue;
            if (qAbs(dock->y() - rowY) > 4)
                continue;

            if (QWidget *content = dock->widget()) {
                ApplyLowRowWidgetCap(content, floor);
                const auto descendants =
                    content->findChildren<QWidget *>(QString(),
                                                     Qt::FindChildrenRecursively);
                for (QWidget *child : descendants)
                    ApplyLowRowWidgetCap(child, floor);
            }
            dock->updateGeometry();
        }

        if (QLayout *layout = mainWindow->layout()) {
            layout->invalidate();
            layout->activate();
        }
    }

'@
$s = $s.Substring(0, $restorePos) + $manualRelaxHelper + $s.Substring($restorePos)

Replace-Required @'
                        if (sceneRowLockEnabled_ && sceneVisibleRows_ <= 2)
                            ScheduleManualReleasePerfectRowSnap();

                        Q_UNUSED(shrinking);
                        Q_UNUSED(pitch);
'@ @'
                        if (sceneRowLockEnabled_ && sceneVisibleRows_ <= 2) {
                            if (shrinking)
                                RelaxLowRowDescendantsForManualDrag();
                            ScheduleManualReleasePerfectRowSnap();
                        }

                        Q_UNUSED(pitch);
'@ 'temporarily relax hints during real downward drag'

Replace-Required @'
        } else {
            const int pitch = qMax(1, CurrentSceneRowHeight());
            const int desired = qMax(floor + qMax(180, pitch * 7),
'@ @'
        } else {
            if (lowRowFloorLatchActive_)
                ReleaseLowRowFloorLatch();

            const int pitch = qMax(1, CurrentSceneRowHeight());
            const int desired = qMax(floor + qMax(180, pitch * 7),
'@ 'automatic UP releases exact-row latch first'

$s = $s.Replace('OBS UI Scale v3.32 DEBUG', 'OBS UI Scale v3.33 DEBUG')
$s = $s.Replace('OBS UI Scale v3.32 DEBUG LOG', 'OBS UI Scale v3.33 DEBUG LOG')
$s = $s.Replace('v3.32 DEBUG', 'v3.33 DEBUG')

Set-Content $path $s -Encoding utf8

$issPath = 'installer/ObsUiScale.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('3.32.0', '3.33.0')
$iss = $iss.Replace('OBS-UI-Scale-Debug-Setup-3.32.0', 'OBS-UI-Scale-Debug-Setup-3.33.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared OBS UI Scale v3.33 DEBUG exact-row lifetime + visual restore on next drag.'
