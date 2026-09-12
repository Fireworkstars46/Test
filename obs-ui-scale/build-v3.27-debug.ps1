$ErrorActionPreference = 'Stop'

# v3.27 DEBUG
# v3.26 fixed physical 1-row reachability and manual-drag locking. Its full
# matrix exposed one remaining regression:
#   Matrix UP -> Apply: expected 452px, Apply forced the dock back to 95px.
#
# Root cause: the v3.23 low-row capture helper still treated rows=1/2 as an
# instruction to FORCE the dock to the minimum on every Apply. But this setting
# is a MINIMUM, not a fixed height. If the user manually drags higher, Apply must
# keep that higher manual height while retaining the 1-row floor underneath it.
#
# v3.27 forces the low-row floor only when the authoritative manual target is
# actually near that floor. If Apply/Scene/manual state says the dock belongs
# higher, it preserves/restores that height and only installs the minimum.
& ./build-v3.26-debug.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v3.27 debug patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "3.26.0-debug";' 'static constexpr const char *PLUGIN_VERSION = "3.27.0-debug";' 'plugin version'

Replace-Required @'
        if (sceneVisibleRows_ <= 2 && lockedSceneDockHeight_ > 0) {
            ForceBottomRowHeightNow(lockedSceneDockHeight_,
                                    QStringLiteral("row capture immediate"), true);
            const int expectedLowRow = lockedSceneDockHeight_;
            QTimer::singleShot(80, this, [this, expectedLowRow]() {
                if (!sceneRowLockEnabled_ || sceneVisibleRows_ > 2 ||
                    lockedSceneDockHeight_ != expectedLowRow)
                    return;
                QDockWidget *dock = ScenesDock();
                if (dock && qAbs(dock->height() - expectedLowRow) > 3)
                    ForceBottomRowHeightNow(expectedLowRow,
                                            QStringLiteral("row capture settled"), true);
            });
        }
'@ @'
        if (sceneVisibleRows_ <= 2 && lockedSceneDockHeight_ > 0) {
            QDockWidget *lowRowDock = ScenesDock();
            auto *lowRowMain =
                static_cast<QMainWindow *>(obs_frontend_get_main_window());
            const int requestedLowRowFloor = lockedSceneDockHeight_;
            const int lowRowPitch = qMax(1, CurrentSceneRowHeight());

            int authoritativeManualTarget = -1;
            if (realApplySmoothGuardActive_ && realApplySmoothExpectedHeight_ > 0)
                authoritativeManualTarget = realApplySmoothExpectedHeight_;
            else if (applyPreservedSceneDockHeight_ > 0)
                authoritativeManualTarget = applyPreservedSceneDockHeight_;
            else if (savedManualSceneDockHeight_ > 0)
                authoritativeManualTarget = savedManualSceneDockHeight_;

            // "Minimum rows" is a floor, never a fixed dock height. A manual
            // position more than one row above the floor must survive Apply.
            const bool preserveHigherManual =
                authoritativeManualTarget >
                requestedLowRowFloor + lowRowPitch;

            if (preserveHigherManual && lowRowDock && lowRowMain) {
                RelaxBottomRowSiblingMinimums();
                RelaxSceneDockInternalMinimums();

                const int preserveTarget =
                    qMax(requestedLowRowFloor, authoritativeManualTarget);

                restoringDockTargets_ = true;
                lowRowMain->resizeDocks({lowRowDock}, {preserveTarget},
                                        Qt::Vertical);
                restoringDockTargets_ = false;

                savedManualSceneDockHeight_ = preserveTarget;
                lastImmediateManualSceneDockHeight_ = preserveTarget;
                if (realApplySmoothGuardActive_)
                    realApplySmoothExpectedHeight_ = preserveTarget;
                if (applyPreservedSceneDockHeight_ > 0)
                    applyPreservedSceneDockHeight_ = preserveTarget;
                if (pendingCalibrationSceneDockHeight_ > 0)
                    pendingCalibrationSceneDockHeight_ = preserveTarget;

                if (settings_)
                    settings_->setValue(
                        QStringLiteral("ui/manualSceneDockHeight"),
                        preserveTarget);

                DebugWrite(QStringLiteral(
                    "LOW ROW MINIMUM ONLY rows=%1 floor=%2 preservedManual=%3 live=%4")
                               .arg(sceneVisibleRows_)
                               .arg(requestedLowRowFloor)
                               .arg(preserveTarget)
                               .arg(lowRowDock->height()));
            } else {
                ForceBottomRowHeightNow(
                    requestedLowRowFloor,
                    QStringLiteral("row capture immediate"), true);

                const int expectedLowRow = lockedSceneDockHeight_;
                QTimer::singleShot(80, this, [this, expectedLowRow]() {
                    if (!sceneRowLockEnabled_ || sceneVisibleRows_ > 2 ||
                        lockedSceneDockHeight_ != expectedLowRow)
                        return;

                    QDockWidget *dock = ScenesDock();
                    if (!dock)
                        return;

                    const int manualTarget =
                        realApplySmoothGuardActive_ &&
                                realApplySmoothExpectedHeight_ > 0
                            ? realApplySmoothExpectedHeight_
                            : (applyPreservedSceneDockHeight_ > 0
                                   ? applyPreservedSceneDockHeight_
                                   : savedManualSceneDockHeight_);
                    const int pitch = qMax(1, CurrentSceneRowHeight());

                    // A real/manual higher position appeared during the settle
                    // window. It wins; do not collapse it to the minimum.
                    if (manualTarget > expectedLowRow + pitch)
                        return;

                    if (qAbs(dock->height() - expectedLowRow) > 3)
                        ForceBottomRowHeightNow(
                            expectedLowRow,
                            QStringLiteral("row capture settled"), true);
                });
            }
        }
'@ 'minimum rows must preserve higher manual height'

# v3.26's physical-floor adoption is intentionally limited to a live height near
# the floor. Make that explicit for Apply so a large manual height can never be
# reclassified as the low-row floor.
Replace-Required @'
        const int actual = dock->height();
        const int pitch = qMax(1, CurrentSceneRowHeight());
        if (actual < requestedTarget || actual > requestedTarget + pitch)
            return false;
'@ @'
        const int actual = dock->height();
        const int pitch = qMax(1, CurrentSceneRowHeight());
        if (actual < requestedTarget || actual > requestedTarget + pitch)
            return false;

        // If Apply already has an authoritative manual position clearly above
        // the minimum, this helper must never replace it with the floor.
        if (realApplySmoothGuardActive_ &&
            realApplySmoothExpectedHeight_ > requestedTarget + pitch)
            return false;
        if (applyPreservedSceneDockHeight_ > requestedTarget + pitch)
            return false;
'@ 'physical floor adoption cannot override higher Apply target'

$s = $s.Replace('OBS UI Scale v3.26 DEBUG', 'OBS UI Scale v3.27 DEBUG')
$s = $s.Replace('OBS UI Scale v3.26 DEBUG LOG', 'OBS UI Scale v3.27 DEBUG LOG')
$s = $s.Replace('v3.26 DEBUG', 'v3.27 DEBUG')

Set-Content $path $s -Encoding utf8

$issPath = 'installer/ObsUiScale.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('3.26.0', '3.27.0')
$iss = $iss.Replace('OBS-UI-Scale-Debug-Setup-3.26.0', 'OBS-UI-Scale-Debug-Setup-3.27.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared OBS UI Scale v3.27 DEBUG minimum-only low-row Apply preservation.'
