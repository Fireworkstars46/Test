$ErrorActionPreference = 'Stop'

# v3.30 DEBUG
# v3.29 fixed the automatic UP timing: the matrix now correctly expects 279px.
# The remaining failure is purely Apply smoothness:
#   expected/live/saved = 279/279/279, but excursions=2 because Apply briefly
#   shrinks the row to 99px before restoring 279px.
#
# Root cause: v3.29 pins the bottom row before Apply, but
# ApplyCapturedWidgetMetrics() subsequently reapplies baseline widget minimums.
# v3.21 then relaxes row minimum blockers. That temporarily removes the 279px
# pin, and ApplyProportionalDockGeometry() is allowed to resize the row to its
# scaled baseline (~99px), which the smooth guard catches and repairs.
#
# Fix: after metric scaling + row-minimum relaxation, but BEFORE proportional
# dock geometry, re-pin the live bottom row to the exact preserved Apply height.
# This keeps Apply at one height for the whole same-turn layout path.
& ./build-v3.29-debug.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v3.30 debug patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "3.29.0-debug";' 'static constexpr const char *PLUGIN_VERSION = "3.30.0-debug";' 'plugin version'

Replace-Required @'
        ApplyCapturedWidgetMetrics(uiPercent);
        if (sceneRowLockEnabled_) {
            RelaxBottomRowSiblingMinimums();
            RelaxSceneDockInternalMinimums();
        }
        ApplyProportionalDockGeometry(uiPercent);
'@ @'
        ApplyCapturedWidgetMetrics(uiPercent);
        if (sceneRowLockEnabled_) {
            RelaxBottomRowSiblingMinimums();
            RelaxSceneDockInternalMinimums();
        }

        // Metric scaling above reapplies captured minimum sizes and the low-row
        // relaxation intentionally drops sibling minima. During a REAL Apply,
        // immediately restore the temporary exact-height pin before proportional
        // dock geometry gets a chance to collapse a taller manual row.
        if (suppressManualDockCapture_ && applyPreservedSceneDockHeight_ > 0) {
            SetApplyBottomRowCeiling(applyPreservedSceneDockHeight_);
            DebugWrite(QStringLiteral(
                "APPLY ROW REPIN BEFORE PROPORTIONAL GEOMETRY target=%1 live=%2")
                           .arg(applyPreservedSceneDockHeight_)
                           .arg(ScenesDock() ? ScenesDock()->height() : -1));
        }

        ApplyProportionalDockGeometry(uiPercent);
'@ 're-pin Apply row after metric scaling and before proportional geometry'

$s = $s.Replace('OBS UI Scale v3.29 DEBUG', 'OBS UI Scale v3.30 DEBUG')
$s = $s.Replace('OBS UI Scale v3.29 DEBUG LOG', 'OBS UI Scale v3.30 DEBUG LOG')
$s = $s.Replace('v3.29 DEBUG', 'v3.30 DEBUG')

Set-Content $path $s -Encoding utf8

$issPath = 'installer/ObsUiScale.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('3.29.0', '3.30.0')
$iss = $iss.Replace('OBS-UI-Scale-Debug-Setup-3.29.0', 'OBS-UI-Scale-Debug-Setup-3.30.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared OBS UI Scale v3.30 DEBUG same-turn Apply row re-pin before proportional geometry.'
