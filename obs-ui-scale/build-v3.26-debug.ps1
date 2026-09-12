$ErrorActionPreference = 'Stop'

# v3.26 DEBUG
# v3.25 made manual dragging much freer, but the new trace shows one remaining
# feedback loop: the theoretical 1-row floor can be a few pixels lower than the
# physical Qt/OBS row height even though exactly one Scene row is already fully
# visible. Apply and Scene guards then keep trying to repair 95px -> 89px (or
# similar), which creates the remaining "locked" feeling and makes the exact
# floor test fail.
#
# v3.26 treats a physically stable height as authoritative whenever:
# - rows <= 2,
# - the live height is within one row pitch above the calculated floor, and
# - the requested number of Scene rows is exactly what is fully visible.
#
# That means a real one-row layout such as 95px/1 visible row is accepted as the
# one-row floor instead of being fought down to an unreachable 89px. Apply and
# Scene guards adopt that same physical floor, eliminating their resize fight.
# The old low-row mouse-poll latch is also fully disabled.
& ./build-v3.25-debug.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v3.26 debug patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}
function Replace-Block([string]$startMarker, [string]$endMarker, [string]$newBlock, [string]$label) {
    $start = $script:s.IndexOf($startMarker)
    if ($start -lt 0) { throw "v3.26 could not locate start of $label" }
    $end = $script:s.IndexOf($endMarker, $start)
    if ($end -lt 0) { throw "v3.26 could not locate end of $label" }
    $script:s = $script:s.Substring(0, $start) + $newBlock.Replace("`r`n", "`n") + $script:s.Substring($end)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "3.25.0-debug";' 'static constexpr const char *PLUGIN_VERSION = "3.26.0-debug";' 'plugin version'

# The v3.22-style polling latch is no longer part of low-row behavior. Make the
# helper a hard no-op so no stale/generated call can release/reassert constraints
# underneath a live mouse drag.
$pollNoop = @'
    void PollLowRowFloorLatchForUnlock(int generation)
    {
        Q_UNUSED(generation);
    }

'@
Replace-Block '    void PollLowRowFloorLatchForUnlock(int generation)' '    bool ForceBottomRowHeightNow' $pollNoop 'disable low-row polling latch'

# Insert one central physical-floor adoption helper before ForceBottomRowHeightNow.
$forceMarker = '    bool ForceBottomRowHeightNow(int targetHeight, const QString &reason, bool latch)'
$forcePos = $s.IndexOf($forceMarker)
if ($forcePos -lt 0) { throw 'v3.26 could not locate ForceBottomRowHeightNow' }
$adoptHelper = @'
    bool AdoptEquivalentLowRowPhysicalHeight(int requestedTarget, const QString &reason)
    {
        if (!sceneRowLockEnabled_ || sceneVisibleRows_ > 2 || requestedTarget <= 0)
            return false;

        QDockWidget *dock = ScenesDock();
        if (!dock || !dock->isVisible())
            return false;

        const int actual = dock->height();
        const int pitch = qMax(1, CurrentSceneRowHeight());
        if (actual < requestedTarget || actual > requestedTarget + pitch)
            return false;

        const int visibleRows = CountFullyVisibleSceneRows();
        if (visibleRows != sceneVisibleRows_)
            return false;

        if (qAbs(actual - requestedTarget) <= 2)
            return true;

        const int oldFloor = lockedSceneDockHeight_;
        lockedSceneDockHeight_ = actual;
        lowRowFloorLatchHeight_ = actual;
        dock->setMinimumHeight(actual);

        // Keep every active protection path on the SAME physical value. This is
        // what removes the Apply/Scene tug-of-war seen in v3.25.
        if (realApplySmoothGuardActive_)
            realApplySmoothExpectedHeight_ = actual;
        if (applyPreservedSceneDockHeight_ > 0)
            applyPreservedSceneDockHeight_ = actual;
        if (pendingCalibrationSceneDockHeight_ > 0)
            pendingCalibrationSceneDockHeight_ = actual;

        if (suppressManualDockCapture_ || realApplySmoothGuardActive_ ||
            savedManualSceneDockHeight_ <= requestedTarget + pitch) {
            savedManualSceneDockHeight_ = actual;
            lastImmediateManualSceneDockHeight_ = actual;
            if (settings_)
                settings_->setValue(QStringLiteral("ui/manualSceneDockHeight"), actual);
        }

        DebugWrite(QStringLiteral(
            "LOW ROW PHYSICAL FLOOR ADOPTED reason='%1' requested=%2 actual=%3 oldFloor=%4 visibleRows=%5 pitch=%6")
                       .arg(reason)
                       .arg(requestedTarget)
                       .arg(actual)
                       .arg(oldFloor)
                       .arg(visibleRows)
                       .arg(pitch));
        return true;
    }

'@
$s = $s.Substring(0, $forcePos) + $adoptHelper.Replace("`r`n", "`n") + $s.Substring($forcePos)

# If the exact pixel request cannot be reached but the physical result already
# shows exactly the requested row count, adopt it and report the force as reached.
Replace-Required @'
        const int actual = sceneDock->height();
        const bool reached = qAbs(actual - targetHeight) <= 3;

        if (reached && sceneRowLockEnabled_ && sceneVisibleRows_ <= 2 &&
'@ @'
        int actual = sceneDock->height();
        bool reached = qAbs(actual - targetHeight) <= 3;

        if (!reached && AdoptEquivalentLowRowPhysicalHeight(
                            targetHeight, QStringLiteral("force %1").arg(reason))) {
            actual = sceneDock->height();
            targetHeight = actual;
            reached = true;
        }

        if (reached && sceneRowLockEnabled_ && sceneVisibleRows_ <= 2 &&
'@ 'adopt equivalent physical low-row force result'

# The real-Apply same-turn guard must also accept the equivalent physical one-row
# result instead of synchronously resizing against Qt over and over.
Replace-Required @'
                if (qAbs(dock->height() - expected) > 2) {
                    ++lastRealApplySmoothExcursions_;
                    DebugWrite(QStringLiteral(
                        "REAL APPLY TRANSIENT EXCURSION actual=%1 expected=%2 count=%3 - repaired synchronously")
                                   .arg(dock->height()).arg(expected).arg(lastRealApplySmoothExcursions_));
                    restoringDockTargets_ = true;
                    mainWindow->resizeDocks({dock}, {expected}, Qt::Vertical);
                    restoringDockTargets_ = false;
                    ReassertSceneRowLock();
                }
'@ @'
                if (qAbs(dock->height() - expected) > 2) {
                    if (AdoptEquivalentLowRowPhysicalHeight(
                            expected, QStringLiteral("Apply smooth guard"))) {
                        // The live row already has the requested visible-row
                        // count. Do not fight Qt for a cosmetic few pixels.
                    } else {
                        ++lastRealApplySmoothExcursions_;
                        DebugWrite(QStringLiteral(
                            "REAL APPLY TRANSIENT EXCURSION actual=%1 expected=%2 count=%3 - repaired synchronously")
                                       .arg(dock->height()).arg(expected).arg(lastRealApplySmoothExcursions_));
                        restoringDockTargets_ = true;
                        mainWindow->resizeDocks({dock}, {expected}, Qt::Vertical);
                        restoringDockTargets_ = false;
                        ReassertSceneRowLock();
                    }
                }
'@ 'Apply guard accepts physical one-row floor'

# Scene repair gets the same rule, but patch ONLY
# RestoreAuthoritativeSceneDockTarget(). The same mixer declarations also exist
# in several unrelated functions that do not have a targetHeight variable.
$sceneStart = $s.IndexOf('    void RestoreAuthoritativeSceneDockTarget()')
$sceneEnd = $s.IndexOf('    void ArmSceneDockGuard()', $sceneStart)
if ($sceneStart -lt 0 -or $sceneEnd -lt 0) {
    throw 'v3.26 could not isolate RestoreAuthoritativeSceneDockTarget'
}
$sceneBlock = $s.Substring($sceneStart, $sceneEnd - $sceneStart)
$sceneNeedle = @'
        QStackedWidget *mixer = StackedMixerArea();
        QDockWidget *mixerDock = AudioMixerDock();
'@
if (-not $sceneBlock.Contains($sceneNeedle)) {
    throw 'v3.26 Scene guard mixer insertion point missing'
}
$sceneInsert = @'
        if (AdoptEquivalentLowRowPhysicalHeight(
                targetHeight, QStringLiteral("Scene guard"))) {
            targetHeight = sceneDock->height();
            if (sceneDockGuardActive_)
                sceneGuardTargetHeight_ = targetHeight;
        }

        QStackedWidget *mixer = StackedMixerArea();
        QDockWidget *mixerDock = AudioMixerDock();
'@
$sceneBlock = $sceneBlock.Replace($sceneNeedle, $sceneInsert)
$s = $s.Substring(0, $sceneStart) + $sceneBlock + $s.Substring($sceneEnd)

# The complete test is testing "one visible row", not an impossible theoretical
# padding pixel. Once the physical equivalent is adopted, lockedSceneDockHeight_
# is the reachable physical floor and the existing exact floor assertion remains
# valid without weakening the test.
#
# Reduce the low-row release settle threshold from two pitches to one pitch. This
# prevents a release at 115px from being programmatically pulled while the user
# clearly stopped well above a one-row floor.
Replace-Required @'
                                        if (dock->height() > floor + 2 &&
                                            dock->height() <= floor + (pitchNow * 2)) {
'@ @'
                                        if (dock->height() > floor + 2 &&
                                            dock->height() <= floor + pitchNow) {
'@ 'narrow post-release low-row settle window'

$s = $s.Replace('OBS UI Scale v3.25 DEBUG', 'OBS UI Scale v3.26 DEBUG')
$s = $s.Replace('OBS UI Scale v3.25 DEBUG LOG', 'OBS UI Scale v3.26 DEBUG LOG')
$s = $s.Replace('v3.25 DEBUG', 'v3.26 DEBUG')

Set-Content $path $s -Encoding utf8

$issPath = 'installer/ObsUiScale.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('3.25.0', '3.26.0')
$iss = $iss.Replace('OBS-UI-Scale-Debug-Setup-3.25.0', 'OBS-UI-Scale-Debug-Setup-3.26.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared OBS UI Scale v3.26 DEBUG physical one-row floor adoption + fully unlocked manual drag.'
