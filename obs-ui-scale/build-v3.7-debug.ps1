$ErrorActionPreference = 'Stop'

# v3.7 fixes the v3.6 self-feeding scene-row refresh bug. v3.6 correctly
# calculated 7 rows as 199px during Apply, but then ReassertSceneRowLock()
# recalculated again while Qt was still settling after the temporary Apply
# ceiling was released. The transient viewport geometry made the floor jump
# 199 -> 250 -> 252, so the user could no longer drag down to the requested
# 7-row minimum.
#
# Keep the v3.6 visual-row measurement, but never recalculate the floor
# synchronously inside ReassertSceneRowLock(). Reassert only ENFORCES the last
# known-good floor. Resize/Layout events schedule one debounced refresh after
# the layout has been quiet for 300ms and only when Apply/restore/manual-capture
# suppression is inactive. This keeps the minimum correct when the OBS window
# or dock width changes (including scrollbar/layout changes) without allowing
# transient Apply geometry to feed back into the minimum.
& ./build-v3.6-debug.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v3.7 debug patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "3.6.0-debug";' 'static constexpr const char *PLUGIN_VERSION = "3.7.0-debug";' 'plugin version'

# Remove v3.6's synchronous refresh from ReassertSceneRowLock. This was the
# exact source of the 199 -> 250 -> 252 growth shown in the user's v3.6 log.
Replace-Required @'
        const int refreshedFloor = CalculateSceneDockHeightForRows();
        if (refreshedFloor > 0 && qAbs(refreshedFloor - lockedSceneDockHeight_) > 1) {
            const int delta = refreshedFloor - lockedSceneDockHeight_;
            lockedSceneDockHeight_ = refreshedFloor;
            lockedMixerHeight_ = qMax(1, lockedMixerHeight_ + delta);
            mixerMinHeightTarget_ = lockedMixerHeight_;
            DebugWrite(QStringLiteral("SCENE ROW MINIMUM REFRESH rows=%1 pitch=%2 sceneDockMinH=%3 mixerMinH=%4")
                           .arg(sceneVisibleRows_)
                           .arg(CurrentSceneRowHeight())
                           .arg(lockedSceneDockHeight_)
                           .arg(lockedMixerHeight_));
        }

        sceneRowLockApplying_ = true;
'@ @'
        // Reassert must only enforce the last settled row floor. Recalculating
        // from viewport geometry here is unsafe because this function is also
        // called during Apply/Qt layout transitions.
        sceneRowLockApplying_ = true;
'@ 'remove synchronous self-feeding row refresh'

# Insert a debounced, settled-layout refresh immediately before Reassert.
$insertMarker = '    void ReassertSceneRowLock()'
$insertPos = $s.IndexOf($insertMarker)
if ($insertPos -lt 0) { throw 'v3.7 could not locate ReassertSceneRowLock insertion point' }
$helper = @'
    void ScheduleSceneRowMinimumRefresh()
    {
        const int generation = ++sceneRowRefreshGeneration_;
        QTimer::singleShot(300, this, [this, generation]() {
            if (generation != sceneRowRefreshGeneration_ || !sceneRowLockEnabled_ ||
                sceneRowLockApplying_ || suppressManualDockCapture_ || restoringDockTargets_ ||
                applyPreservedSceneDockHeight_ > 0)
                return;

            auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
            QDockWidget *sceneDock = ScenesDock();
            QStackedWidget *mixer = StackedMixerArea();
            if (!mainWindow || !sceneDock || !mixer || sceneDock->isFloating())
                return;
            if (mainWindow->dockWidgetArea(sceneDock) != Qt::BottomDockWidgetArea)
                return;
            if (!sceneDock->isVisible() || sceneDock->width() <= 100 || sceneDock->height() <= 30)
                return;

            const int refreshedFloor = CalculateSceneDockHeightForRows();
            if (refreshedFloor <= 0 || qAbs(refreshedFloor - lockedSceneDockHeight_) <= 1)
                return;

            const int oldFloor = lockedSceneDockHeight_;
            const int delta = refreshedFloor - oldFloor;
            lockedSceneDockHeight_ = refreshedFloor;
            lockedMixerHeight_ = qMax(1, lockedMixerHeight_ + delta);
            mixerMinHeightTarget_ = lockedMixerHeight_;

            ReassertSceneRowLock();

            DebugWrite(QStringLiteral("SCENE ROW MINIMUM SETTLED REFRESH rows=%1 pitch=%2 old=%3 new=%4 mixerMinH=%5 dockH=%6")
                           .arg(sceneVisibleRows_)
                           .arg(CurrentSceneRowHeight())
                           .arg(oldFloor)
                           .arg(lockedSceneDockHeight_)
                           .arg(lockedMixerHeight_)
                           .arg(sceneDock->height()));
        });
    }

'@
$s = $s.Substring(0, $insertPos) + $helper + $s.Substring($insertPos)

# Keep immediate synchronous protection, but only schedule the dynamic
# recalculation once the resize/layout has settled and Apply is not active.
Replace-Required @'
        if (sceneRowLockEnabled_ && !sceneRowLockApplying_ && event &&
            (event->type() == QEvent::Resize || event->type() == QEvent::LayoutRequest ||
             event->type() == QEvent::Show)) {
            if (watched == ScenesDock() || watched == StackedMixerArea())
                ReassertSceneRowLock();
        }
'@ @'
        if (sceneRowLockEnabled_ && !sceneRowLockApplying_ && event &&
            (event->type() == QEvent::Resize || event->type() == QEvent::LayoutRequest ||
             event->type() == QEvent::Show)) {
            if (watched == ScenesDock() || watched == StackedMixerArea()) {
                ReassertSceneRowLock();
                if (!suppressManualDockCapture_ && !restoringDockTargets_ &&
                    applyPreservedSceneDockHeight_ <= 0)
                    ScheduleSceneRowMinimumRefresh();
            }
        }
'@ 'debounce row refresh from layout events'

# Generation counter collapses a burst of resize/layout events into one stable
# recalculation. This is what makes window-size changes safe without feedback.
Replace-Required @'
    bool startupAutoApplyDone_ = false;
'@ @'
    bool startupAutoApplyDone_ = false;
    int sceneRowRefreshGeneration_ = 0;
'@ 'scene row refresh generation member'

$s = $s.Replace('OBS UI Scale v3.6 DEBUG', 'OBS UI Scale v3.7 DEBUG')
$s = $s.Replace('OBS UI Scale v3.6 DEBUG LOG', 'OBS UI Scale v3.7 DEBUG LOG')
$s = $s.Replace('v3.6 DEBUG keeps the v3.5 startup/restart fixes and measures actual laid-out scene-row geometry, so the selected minimum is the exact visible row count and stays correct as the OBS window is resized. Debug logging remains optional.',
                'v3.7 DEBUG keeps the v3.6 visual row measurement but refreshes the row minimum only after dock/window layout has settled, preventing Apply-time geometry from inflating the minimum while still adapting to OBS window-size changes. Debug logging remains optional.')

Set-Content $path $s -Encoding utf8

$issPath = 'installer/ObsUiScale.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('3.6.0', '3.7.0')
$iss = $iss.Replace('OBS-UI-Scale-Debug-Setup-3.6.0', 'OBS-UI-Scale-Debug-Setup-3.7.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared OBS UI Scale v3.7 DEBUG settled scene-row minimum refresh.'
