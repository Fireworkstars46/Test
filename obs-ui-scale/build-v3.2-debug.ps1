$ErrorActionPreference = 'Stop'

# v3.2 removes the last visible Apply flash found in the v3.1 trace. v3.1
# correctly restored the user's saved dock height at the end, but OBS was still
# allowed to expand the bottom row (199 -> 223 in the trace) while Apply was
# settling. Keep a TEMPORARY ceiling on only the docks in the same bottom row
# during Apply, then remove it when Apply is finished. This is not a permanent
# lock: normal manual upward dragging remains unrestricted after Apply.
& ./build-v3.1-debug.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v3.2 debug patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "3.1.0-debug";' 'static constexpr const char *PLUGIN_VERSION = "3.2.0-debug";' 'plugin version'

# Property used only while Apply is in progress so each sibling dock can have
# its exact pre-cap maximum restored afterward.
Replace-Required @'
static constexpr const char *PROP_DOCK_GUARD_WATCHED = "obsUiScaleDockGuardWatched";
'@ @'
static constexpr const char *PROP_DOCK_GUARD_WATCHED = "obsUiScaleDockGuardWatched";
static constexpr const char *PROP_APPLY_OLD_MAX_H = "obsUiScaleApplyOldMaxH";
'@ 'temporary Apply ceiling property'

# Insert helpers immediately before the scene-row reassertion. Only docks that
# share the Scenes dock's current y coordinate are capped, so unrelated/offscreen
# bottom docks are not touched.
$insertMarker = '    void ReassertSceneRowLock()'
$insertPos = $s.IndexOf($insertMarker)
if ($insertPos -lt 0) { throw 'v3.2 could not locate ReassertSceneRowLock insertion point' }
$helper = @'
    void SetApplyBottomRowCeiling(int ceilingHeight)
    {
        if (ceilingHeight <= 0)
            return;

        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
        QDockWidget *sceneDock = ScenesDock();
        if (!mainWindow || !sceneDock)
            return;

        const int rowY = sceneDock->y();
        const auto docks = mainWindow->findChildren<QDockWidget *>(QString(), Qt::FindDirectChildrenOnly);
        for (QDockWidget *dock : docks) {
            if (!dock || !dock->isVisible() || dock->isFloating())
                continue;
            if (mainWindow->dockWidgetArea(dock) != Qt::BottomDockWidgetArea)
                continue;
            if (qAbs(dock->y() - rowY) > 4)
                continue;

            if (!dock->property(PROP_APPLY_OLD_MAX_H).isValid())
                dock->setProperty(PROP_APPLY_OLD_MAX_H, dock->maximumHeight());

            dock->setMaximumHeight(qMax(dock->minimumHeight(), ceilingHeight));
        }
    }

    void ReleaseApplyBottomRowCeiling()
    {
        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
        if (!mainWindow)
            return;

        const auto docks = mainWindow->findChildren<QDockWidget *>(QString(), Qt::FindDirectChildrenOnly);
        for (QDockWidget *dock : docks) {
            if (!dock || !dock->property(PROP_APPLY_OLD_MAX_H).isValid())
                continue;

            const int oldMax = dock->property(PROP_APPLY_OLD_MAX_H).toInt();
            dock->setMaximumHeight(oldMax > 0 ? oldMax : QWIDGETSIZE_MAX);
            dock->setProperty(PROP_APPLY_OLD_MAX_H, QVariant());
        }
    }

'@
$s = $s.Substring(0, $insertPos) + $helper + $s.Substring($insertPos)

# Put the ceiling back immediately after v3.1 releases the persistent row
# minimum constraints. This all happens synchronously before Qt gets a chance to
# paint the temporary proportional-layout expansion.
Replace-Required @'
        ReleaseSceneRowLockConstraints();
        suppressManualDockCapture_ = true;
'@ @'
        ReleaseSceneRowLockConstraints();
        if (applyPreservedSceneDockHeight_ > 0)
            SetApplyBottomRowCeiling(applyPreservedSceneDockHeight_);
        suppressManualDockCapture_ = true;
'@ 'arm temporary row ceiling before Apply layout'

# Reassertions during Apply must keep the temporary ceiling instead of clearing
# it. If the user changed the configured minimum to something taller than their
# previous manual position, the new minimum wins and the temporary ceiling grows
# to that height.
Replace-Required @'
        // The selected row count remains a minimum only. The user can freely
        // drag the dock row taller than this floor.
        sceneDock->setMaximumHeight(QWIDGETSIZE_MAX);
        sceneDock->setMinimumHeight(lockedSceneDockHeight_);
'@ @'
        // The selected row count remains a minimum only. During Apply, however,
        // temporarily cap the whole current bottom row at the user's preserved
        // position so there is no one-frame/timed expansion before restoration.
        // The ceiling is removed at the end of Apply, so manual upward dragging
        // remains unrestricted during normal use.
        const int applyCeiling = (suppressManualDockCapture_ && applyPreservedSceneDockHeight_ > 0)
                                     ? qMax(lockedSceneDockHeight_, applyPreservedSceneDockHeight_)
                                     : QWIDGETSIZE_MAX;
        if (applyCeiling != QWIDGETSIZE_MAX)
            SetApplyBottomRowCeiling(applyCeiling);
        sceneDock->setMaximumHeight(applyCeiling);
        sceneDock->setMinimumHeight(lockedSceneDockHeight_);
'@ 'keep temporary ceiling during row reassert'

# At the end of v3.1's Apply-preservation window, remove every sibling cap and
# then return to the normal minimum-only behavior. Keep suppression alive for a
# short extra quiet period so releasing the temporary ceilings itself cannot be
# mistaken for a user drag.
Replace-Required @'
            applyPreservedSceneDockHeight_ = -1;
            suppressManualDockCapture_ = false;
        });
'@ @'
            ReleaseApplyBottomRowCeiling();
            applyPreservedSceneDockHeight_ = -1;
            ReassertSceneRowLock();

            QTimer::singleShot(400, this, [this, manualSuppressGeneration]() {
                if (manualSuppressGeneration == manualDockSuppressGeneration_)
                    suppressManualDockCapture_ = false;
            });
        });
'@ 'release temporary ceiling after Apply settles'

# Self-identifying UI/log text.
$s = $s.Replace('OBS UI Scale v3.1 DEBUG', 'OBS UI Scale v3.2 DEBUG')
$s = $s.Replace('OBS UI Scale v3.1 DEBUG LOG', 'OBS UI Scale v3.2 DEBUG LOG')
$s = $s.Replace('v3.1 DEBUG keeps the adjustable minimum scene rows and mixer overflow protection, and preserves the user-manually-dragged bottom dock position across Apply. Debug logging remains optional.',
                'v3.2 DEBUG keeps the adjustable scene-row minimum, mixer overflow protection, and manual dock preservation, while preventing the temporary taller bottom-row flash during Apply. Debug logging remains optional.')

Set-Content $path $s -Encoding utf8

$issPath = 'installer/ObsUiScale.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('3.1.0', '3.2.0')
$iss = $iss.Replace('OBS-UI-Scale-Debug-Setup-3.1.0', 'OBS-UI-Scale-Debug-Setup-3.2.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared OBS UI Scale v3.2 DEBUG immediate Apply dock-row stabilization.'
