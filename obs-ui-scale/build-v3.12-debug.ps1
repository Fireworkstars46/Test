$ErrorActionPreference = 'Stop'

# v3.12 fixes the single failure exposed by v3.11's Full Self-Test.
# v3.10 correctly snapshots/restores the CURRENT visible Scenes dock height for
# a normal Apply, but v3.8's later Audio Mixer floor calibration still chose the
# persisted manual height as its post-calibration resize target. That late pass
# could therefore undo the v3.10 restore (example: Apply snapshot/restored 254px,
# then calibration moved it back to saved 268px).
#
# Keep a short-lived calibration target copied from the exact Apply-preserved
# height. Startup Apply already snapshots the saved manual height, so the same
# mechanism works for both paths: normal Apply calibrates back to the current
# visible height; startup Apply calibrates back to the persisted manual height.
# The target is cleared immediately after the scheduled calibration pass and is
# never written to the persisted manual-height setting.
& ./build-v3.11-debug.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v3.12 debug patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "3.11.0-debug";' 'static constexpr const char *PLUGIN_VERSION = "3.12.0-debug";' 'plugin version'

# Capture the exact Apply-owned destination before Apply releases the scene-row
# constraints. On normal Apply this is the live visible height; on startup Apply
# v3.10 has already substituted the persisted manual height.
Replace-Required @'
        ReleaseSceneRowLockConstraints();
        if (applyPreservedSceneDockHeight_ > 0)
            SetApplyBottomRowCeiling(applyPreservedSceneDockHeight_);
'@ @'
        pendingCalibrationSceneDockHeight_ = applyPreservedSceneDockHeight_;
        DebugWrite(QStringLiteral("APPLY CALIBRATION TARGET CAPTURED height=%1")
                       .arg(pendingCalibrationSceneDockHeight_));

        ReleaseSceneRowLockConstraints();
        if (applyPreservedSceneDockHeight_ > 0)
            SetApplyBottomRowCeiling(applyPreservedSceneDockHeight_);
'@ 'carry exact Apply target into late mixer calibration'

# The old v3.8 calibration preferred the persisted manual height unconditionally.
# During an Apply-owned calibration, prefer the exact height captured for that
# Apply. Outside that narrow window, retain the original saved-manual fallback.
Replace-Required @'
        int desiredHeight = sceneFloor;
        if (savedManualSceneDockHeight_ > 0)
            desiredHeight = qMax(sceneFloor, savedManualSceneDockHeight_);
'@ @'
        int desiredHeight = sceneFloor;
        if (pendingCalibrationSceneDockHeight_ > 0)
            desiredHeight = qMax(sceneFloor, pendingCalibrationSceneDockHeight_);
        else if (savedManualSceneDockHeight_ > 0)
            desiredHeight = qMax(sceneFloor, savedManualSceneDockHeight_);
'@ 'late mixer calibration preserves the same Apply destination'

# Clear the transient target as soon as its scheduled calibration opportunity is
# over, including when calibration decides no correction is needed.
Replace-Required @'
        QTimer::singleShot(350, this, [this, generation]() {
            if (generation != mixerFloorCalibrationGeneration_)
                return;
            CalibrateMixerFloorToSceneMinimum();
        });
'@ @'
        QTimer::singleShot(350, this, [this, generation]() {
            if (generation != mixerFloorCalibrationGeneration_)
                return;
            CalibrateMixerFloorToSceneMinimum();
            DebugWrite(QStringLiteral("APPLY CALIBRATION TARGET RELEASED height=%1")
                           .arg(pendingCalibrationSceneDockHeight_));
            pendingCalibrationSceneDockHeight_ = -1;
        });
'@ 'release transient calibration target after the late pass'

Replace-Required @'
    int mixerFloorCalibrationGeneration_ = 0;
'@ @'
    int mixerFloorCalibrationGeneration_ = 0;
    int pendingCalibrationSceneDockHeight_ = -1;
'@ 'transient Apply calibration target member'

$s = $s.Replace('OBS UI Scale v3.11 DEBUG', 'OBS UI Scale v3.12 DEBUG')
$s = $s.Replace('OBS UI Scale v3.11 DEBUG LOG', 'OBS UI Scale v3.12 DEBUG LOG')
$s = $s.Replace('v3.11 DEBUG keeps the v3.10 Apply fix and adds a one-click Full Self-Test for current-height Apply preservation, exact scene-row floor, Audio Mixer blocking, persistence isolation, and simulated startup restoration. Debug logging remains optional.',
                'v3.12 DEBUG keeps the v3.11 Full Self-Test and fixes its discovered late Audio Mixer calibration regression so normal Apply preserves the exact current visible dock height through the entire settle/calibration sequence. Debug logging remains optional.')

Set-Content $path $s -Encoding utf8

$issPath = 'installer/ObsUiScale.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('3.11.0', '3.12.0')
$iss = $iss.Replace('OBS-UI-Scale-Debug-Setup-3.11.0', 'OBS-UI-Scale-Debug-Setup-3.12.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared OBS UI Scale v3.12 DEBUG late-calibration Apply-height preservation fix.'
