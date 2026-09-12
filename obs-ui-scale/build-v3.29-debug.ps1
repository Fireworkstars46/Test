$ErrorActionPreference = 'Stop'

# v3.29 DEBUG
# Fixes the v3.28 automatic-matrix failure:
# 1) automatic UP read the dock height too early (99px) before Qt committed the
#    requested 279px resize, so the test expected the wrong value;
# 2) CaptureAndApplySceneRowLock still had the old unconditional "resize to the
#    selected minimum" step BEFORE v3.27's minimum-only preservation branch.
#    That caused Apply to transiently collapse a tall manual dock to the 1-row
#    floor and then restore it, producing six smooth-guard excursions.
#
# v3.29 waits for Qt to settle the automatic drag-equivalent before recording
# its result, and skips the old floor-collapse entirely whenever a higher manual
# height is authoritative. Minimum rows remains a floor, never a forced height.
& ./build-v3.28-debug.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v3.29 debug patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "3.28.0-debug";' 'static constexpr const char *PLUGIN_VERSION = "3.29.0-debug";' 'plugin version'

if (-not $s.Contains('#include <QEventLoop>')) {
    $s = $s.Replace('#include <QFileInfo>', "#include <QEventLoop>`n#include <QFileInfo>")
}

# IMPORTANT: patch ONLY CaptureAndApplySceneRowLock(). The same resizeDocks
# line also exists under single-line if statements elsewhere; replacing it
# globally would put a local declaration inside that if and break scope.
$captureStart = $s.IndexOf('    void CaptureAndApplySceneRowLock()')
$captureEnd = $s.IndexOf('    void ScheduleSceneRowLockCapture(double uiPercent)', $captureStart)
if ($captureStart -lt 0 -or $captureEnd -lt 0) {
    throw 'v3.29 could not isolate CaptureAndApplySceneRowLock'
}
$captureBlock = $s.Substring($captureStart, $captureEnd - $captureStart)
$floorResizeNeedle = '        mainWindow->resizeDocks({sceneDock}, {lockedSceneDockHeight_}, Qt::Vertical);'
if (-not $captureBlock.Contains($floorResizeNeedle)) {
    throw 'v3.29 capture floor-resize call missing'
}
$floorResizeReplacement = @'
        int preFloorManualTarget = -1;
        if (realApplySmoothGuardActive_ && realApplySmoothExpectedHeight_ > 0)
            preFloorManualTarget = realApplySmoothExpectedHeight_;
        else if (applyPreservedSceneDockHeight_ > 0)
            preFloorManualTarget = applyPreservedSceneDockHeight_;
        else if (savedManualSceneDockHeight_ > 0)
            preFloorManualTarget = savedManualSceneDockHeight_;

        const int preFloorPitch = qMax(1, CurrentSceneRowHeight());
        const bool preserveHigherBeforeFloorResize =
            sceneVisibleRows_ <= 2 &&
            preFloorManualTarget > lockedSceneDockHeight_ + preFloorPitch;

        if (!preserveHigherBeforeFloorResize) {
            mainWindow->resizeDocks({sceneDock}, {lockedSceneDockHeight_},
                                    Qt::Vertical);
        } else {
            DebugWrite(QStringLiteral(
                "ROW CAPTURE SKIPPED FLOOR COLLAPSE floor=%1 manualTarget=%2 live=%3")
                           .arg(lockedSceneDockHeight_)
                           .arg(preFloorManualTarget)
                           .arg(sceneDock->height()));
        }
'@
$captureBlock = $captureBlock.Replace($floorResizeNeedle, $floorResizeReplacement.TrimEnd())
$s = $s.Substring(0, $captureStart) + $captureBlock + $s.Substring($captureEnd)

# The fully automatic test is allowed to run a tiny nested Qt event loop because
# it explicitly excludes user input. This lets resizeDocks/layout events settle
# before the test records the automatic drag result.
Replace-Required @'
        } else {
            const int pitch = qMax(1, CurrentSceneRowHeight());
            const int desired = qMax(floor + qMax(180, pitch * 7),
                                     dock->height() + qMax(120, pitch * 5));
            restoringDockTargets_ = true;
            mainWindow->resizeDocks({dock}, {desired}, Qt::Vertical);
            restoringDockTargets_ = false;
        }

        const int actual = dock->height();
'@ @'
        } else {
            const int pitch = qMax(1, CurrentSceneRowHeight());
            const int desired = qMax(floor + qMax(180, pitch * 7),
                                     dock->height() + qMax(120, pitch * 5));
            restoringDockTargets_ = true;
            mainWindow->resizeDocks({dock}, {desired}, Qt::Vertical);
            restoringDockTargets_ = false;

            // resizeDocks posts layout work. v3.28 read dock->height()
            // immediately and captured the old 99px floor even though Qt moved
            // to 279px a moment later. Wait for the real settled geometry.
            QEventLoop settleLoop;
            QTimer::singleShot(320, &settleLoop, &QEventLoop::quit);
            settleLoop.exec(QEventLoop::ExcludeUserInputEvents);
        }

        const int actual = dock->height();
'@ 'automatic UP waits for settled Qt geometry'

# Record enough detail to make a future auto-test timing issue obvious.
$s = $s.Replace(
    'AUTO MATRIX DRAG direction=%1 floor=%2 actual=%3 serial=%4',
    'AUTO MATRIX DRAG SETTLED direction=%1 floor=%2 actual=%3 serial=%4')

$s = $s.Replace('OBS UI Scale v3.28 DEBUG', 'OBS UI Scale v3.29 DEBUG')
$s = $s.Replace('OBS UI Scale v3.28 DEBUG LOG', 'OBS UI Scale v3.29 DEBUG LOG')
$s = $s.Replace('v3.28 DEBUG', 'v3.29 DEBUG')

Set-Content $path $s -Encoding utf8

$issPath = 'installer/ObsUiScale.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('3.28.0', '3.29.0')
$iss = $iss.Replace('OBS-UI-Scale-Debug-Setup-3.28.0', 'OBS-UI-Scale-Debug-Setup-3.29.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared OBS UI Scale v3.29 DEBUG settled automatic drag + no Apply floor collapse.'
