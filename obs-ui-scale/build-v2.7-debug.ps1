$ErrorActionPreference = 'Stop'

# v2.7 is based on v2.6. The user's v2.6 trace exposed that the actual repair
# path only handled OBS_FRONTEND_EVENT_SCENE_CHANGED, while their Studio Mode /
# preview clicks emit OBS_FRONTEND_EVENT_PREVIEW_SCENE_CHANGED. Diagnostics
# already watched both, which is why the trace showed the bug clearly.
#
# Result in v2.6: the compact 223px row was captured correctly, a preview scene
# switch expanded it to 264px, and because the real guard never armed, the quiet
# resize watcher misclassified that OBS-driven expansion as a manual drag.
#
# v2.7 routes BOTH normal and preview scene changes through the same mixer + dock
# repair path. It also extends the mixer/row repair passes through the full
# deferred OBS relayout window and updates the debug header/version text.
& ./build-v2.6-debug.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v2.7 debug patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "2.6.0-debug";' 'static constexpr const char *PLUGIN_VERSION = "2.7.0-debug";' 'plugin version'

# The real fix: make the production repair handler run for Studio Mode preview
# changes too. DebugFrontendEvent already handles both, but that was logging only.
$oldSceneCondition = 'if (event == OBS_FRONTEND_EVENT_SCENE_CHANGED) {'
$newSceneCondition = @'
if (event == OBS_FRONTEND_EVENT_SCENE_CHANGED ||
            event == OBS_FRONTEND_EVENT_PREVIEW_SCENE_CHANGED) {
'@
if (-not $s.Contains($oldSceneCondition)) {
    throw 'v2.7 could not locate the production SCENE_CHANGED handler condition'
}
$s = $s.Replace($oldSceneCondition, $newSceneCondition)

# OBS can defer the actual QMainWindow row expansion for several hundred ms.
# Keep correcting both the mixer minimum and row through that entire window.
Replace-Required @'
        const int delays[] = {0, 10, 35, 90, 180};
        for (int delay : delays) {
            QTimer::singleShot(delay, this, [this, uiPercent]() {
                if (qAbs(currentUiPercent_ - uiPercent) < 0.01) {
                    RestoreMixerMinimumTarget();
                    RestoreStableDockTargets();
                }
            });
        }
'@ @'
        const int delays[] = {0, 10, 35, 90, 180, 350, 550, 800, 1200};
        for (int delay : delays) {
            QTimer::singleShot(delay, this, [this, uiPercent]() {
                if (qAbs(currentUiPercent_ - uiPercent) < 0.01) {
                    RestoreMixerMinimumTarget();
                    RestoreStableDockTargets();
                }
            });
        }
'@ 'extend mixer and row repair through deferred relayout'

# Make it obvious in the optional log that the real repair path armed for both
# scene event types, not merely the diagnostic snapshot path.
Replace-Required @'
            self->ScheduleContextBarRescale(self->currentUiPercent_);
            self->ScheduleMixerMinimumRestore(self->currentUiPercent_);
            self->ArmSceneDockGuard();
'@ @'
            self->DebugWrite(QStringLiteral("SCENE REPAIR ARMED event=%1")
                                 .arg(self->DebugFrontendEventName(event)));
            self->ScheduleContextBarRescale(self->currentUiPercent_);
            self->ScheduleMixerMinimumRestore(self->currentUiPercent_);
            self->ArmSceneDockGuard();
'@ 'log real scene repair path'

# Keep the debug file self-identifying instead of retaining the old v2.3 header.
$s = $s.Replace('OBS UI Scale v2.3 DEBUG LOG', 'OBS UI Scale v2.7 DEBUG LOG')
Replace-Required 'dialog.setWindowTitle(QStringLiteral("OBS UI Scale v2.6 DEBUG"));' 'dialog.setWindowTitle(QStringLiteral("OBS UI Scale v2.7 DEBUG"));' 'dialog title'
$s = $s.Replace('v2.6 DEBUG uses the trace-proven fix: restore the scaled mixer minimum, then restore the compact dock row. Debug logging remains optional.',
                'v2.7 DEBUG applies the mixer + compact dock-row repair to both normal and Studio Mode preview scene changes. Debug logging remains optional.')

Set-Content $path $s -Encoding utf8

$issPath = 'installer/ObsUiScale.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('2.6.0', '2.7.0')
$iss = $iss.Replace('OBS-UI-Scale-Debug-Setup-2.6.0', 'OBS-UI-Scale-Debug-Setup-2.7.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared OBS UI Scale v2.7 DEBUG preview + normal scene repair.'
