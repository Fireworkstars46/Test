$ErrorActionPreference = 'Stop'

# v3.24 DEBUG
# Fixes the v3.23 complete-test deadlock/conflict shown in the 2026-09-12 trace:
# the exact 1-row force DID reach 72-76 px, but the older real-Apply smooth guard
# still expected the pre-Apply manual height (84/89/112 px) and immediately
# repaired the correct low-row move upward. The late mixer calibration also kept
# the old Apply target and could lift the row again.
#
# v3.24 makes an intentional 1/2-row transition retarget ALL Apply-owned height
# guards to the new floor, so low-row forcing and Apply preservation no longer
# fight each other. It also removes full-window geometry snapshots from ordinary
# Apply/Scene events; debug logging remains useful but no longer does expensive
# whole-OBS scans during normal interaction.
& ./build-v3.23-debug.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v3.24 debug patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}

function Replace-Block([string]$startMarker, [string]$endMarker, [string]$newBlock, [string]$label) {
    $start = $script:s.IndexOf($startMarker)
    if ($start -lt 0) { throw "v3.24 could not locate start of $label" }
    $end = $script:s.IndexOf($endMarker, $start)
    if ($end -lt 0) { throw "v3.24 could not locate end of $label" }
    $script:s = $script:s.Substring(0, $start) + $newBlock.Replace("`r`n", "`n") + $script:s.Substring($end)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "3.23.0-debug";' 'static constexpr const char *PLUGIN_VERSION = "3.24.0-debug";' 'plugin version'

# Retarget every Apply-owned height preservation path before forcing an
# intentional low-row floor. This is the key fix for the trace where v3.23
# reached 72/76 px but REAL APPLY TRANSIENT EXCURSION repaired it back to
# 84/89/112 px and the late calibration lifted it again.
Replace-Required @'
        lowRowForceActive_ = true;
        RelaxBottomRowSiblingMinimums();
        RelaxSceneDockInternalMinimums();
'@ @'
        lowRowForceActive_ = true;

        if (sceneRowLockEnabled_ && sceneVisibleRows_ <= 2) {
            if (realApplySmoothGuardActive_) {
                realApplySmoothExpectedHeight_ = targetHeight;
                lastRealApplySmoothExcursions_ = 0;
            }
            if (suppressManualDockCapture_ || applyPreservedSceneDockHeight_ > 0) {
                applyPreservedSceneDockHeight_ = targetHeight;
                pendingCalibrationSceneDockHeight_ = targetHeight;
            }
        }

        RelaxBottomRowSiblingMinimums();
        RelaxSceneDockInternalMinimums();
'@ 'retarget Apply guards before low-row force'

# When a low-row force succeeds during Apply, keep the authoritative manual
# visible height in sync too. This prevents a later old-manual restore from
# re-expanding the row after the force has already succeeded.
Replace-Required @'
        const int actual = sceneDock->height();
        const bool reached = qAbs(actual - targetHeight) <= 3;
        lowRowForceActive_ = false;
'@ @'
        const int actual = sceneDock->height();
        const bool reached = qAbs(actual - targetHeight) <= 3;

        if (reached && sceneRowLockEnabled_ && sceneVisibleRows_ <= 2 &&
            (suppressManualDockCapture_ || realApplySmoothGuardActive_)) {
            applyPreservedSceneDockHeight_ = targetHeight;
            pendingCalibrationSceneDockHeight_ = targetHeight;
            applyCalibrationDockHeight_ = targetHeight;
            realApplySmoothExpectedHeight_ = targetHeight;
            savedManualSceneDockHeight_ = targetHeight;
            lastImmediateManualSceneDockHeight_ = targetHeight;
            if (settings_)
                settings_->setValue(QStringLiteral("ui/manualSceneDockHeight"), targetHeight);
        }

        lowRowForceActive_ = false;
'@ 'commit successful low-row Apply destination'

# Ordinary debug logging should never make the plugin feel unlike vanilla OBS.
# Keep one-line event records, but remove expensive full-window snapshots and
# their timer bursts from Scene and Apply paths.
$frontend = @'
    void DebugFrontendEvent(enum obs_frontend_event event)
    {
        const QString eventName = DebugFrontendEventName(event);
        DebugWrite(QStringLiteral("FRONTEND EVENT %1 scene='%2'").arg(eventName, DebugSceneName()));
    }

'@
Replace-Block '    void DebugFrontendEvent(enum obs_frontend_event event)' '    void DebugScheduleApplySnapshots' $frontend 'lightweight frontend debug logging'

Replace-Required @'
    void DebugScheduleApplySnapshots(const QString &prefix)
    {
        if (!debugLoggingEnabled_)
            return;
        const int delays[] = {300};
        for (int delay : delays) {
            QTimer::singleShot(delay, this, [this, prefix, delay]() {
                DebugSnapshot(QStringLiteral("%1 +%2ms").arg(prefix).arg(delay));
            });
        }
    }
'@ @'
    void DebugScheduleApplySnapshots(const QString &prefix)
    {
        Q_UNUSED(prefix);
    }
'@ 'disable scheduled Apply snapshots'

$s = $s.Replace('        DebugSnapshot(QStringLiteral("Apply BEFORE"));' + "
", '')
$s = $s.Replace('        DebugSnapshot(QStringLiteral("Apply immediate AFTER"));' + "
", '')
$s = $s.Replace('        DebugScheduleApplySnapshots(QStringLiteral("Apply settle"));' + "
", '')

# Keep complete-test logging on for the duration of the test even when the
# user's original debug setting is OFF. The checkbox itself is still exercised;
# the forced-test logger is independent and is restored when test keys clear.
Replace-Required @'
        completePreflightResults_.clear();

        if (status)
'@ @'
        completePreflightResults_.clear();
        completeTestForceLogging_ = true;

        if (status)
'@ 'force complete-test diagnostics'

# DebugWrite normally returns when user logging is disabled. Allow the complete
# test's private diagnostic flag to bypass that one guard.
Replace-Required @'
        if (!debugLoggingEnabled_ || debugLogPath_.isEmpty())
            return;
'@ @'
        if ((!debugLoggingEnabled_ && !completeTestForceLogging_) || debugLogPath_.isEmpty())
            return;
'@ 'keep test diagnostics alive'

# Clear the forced logger whenever the restart/complete-test state is cleared.
Replace-Required @'
    void ClearRestartTestKeys()
    {
'@ @'
    void ClearRestartTestKeys()
    {
        completeTestForceLogging_ = false;
'@ 'clear forced test logger'

Replace-Required @'
    bool lowRowLatchSeenRelease_ = false;
'@ @'
    bool lowRowLatchSeenRelease_ = false;
    bool completeTestForceLogging_ = false;
'@ 'forced test logger member'

$s = $s.Replace('OBS UI Scale v3.23 DEBUG', 'OBS UI Scale v3.24 DEBUG')
$s = $s.Replace('OBS UI Scale v3.23 DEBUG LOG', 'OBS UI Scale v3.24 DEBUG LOG')
$s = $s.Replace('v3.23 DEBUG', 'v3.24 DEBUG')

Set-Content $path $s -Encoding utf8

$issPath = 'installer/ObsUiScale.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('3.23.0', '3.24.0')
$iss = $iss.Replace('OBS-UI-Scale-Debug-Setup-3.23.0', 'OBS-UI-Scale-Debug-Setup-3.24.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared OBS UI Scale v3.24 DEBUG low-row Apply conflict fix + vanilla-light diagnostics.'
