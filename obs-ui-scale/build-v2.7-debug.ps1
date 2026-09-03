$ErrorActionPreference = 'Stop'

# v2.7 is based on v2.6. The user's v2.6 trace exposed that the actual repair
# path only handled normal program-scene changes, while their Studio Mode /
# preview clicks emit OBS_FRONTEND_EVENT_PREVIEW_SCENE_CHANGED. Diagnostics
# already watched both, which is why the trace showed the mismatch clearly.
#
# Result in v2.6: the compact 223px row was captured correctly, a preview scene
# switch expanded it to 264px, and because the real guard never armed, the quiet
# resize watcher misclassified that OBS-driven expansion as a manual drag.
#
# v2.7 adds a dedicated preview-scene repair path alongside the existing normal
# scene path. It also extends mixer/row repair through OBS's deferred relayout
# window and updates the debug header/version text.
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

# The diagnostics hook is guaranteed to exist in v2.6. Add the missing preview
# repair immediately after it. This does not disturb the existing normal scene
# handler and avoids depending on its exact formatting.
Replace-Required @'
        self->DebugFrontendEvent(event);

        if (event == OBS_FRONTEND_EVENT_FINISHED_LOADING) {
'@ @'
        self->DebugFrontendEvent(event);

        if (event == OBS_FRONTEND_EVENT_PREVIEW_SCENE_CHANGED) {
            self->DebugWrite(QStringLiteral("PREVIEW SCENE REPAIR ARMED"));
            self->ScheduleContextBarRescale(self->currentUiPercent_);
            self->ScheduleMixerMinimumRestore(self->currentUiPercent_);
            self->ArmSceneDockGuard();
        }

        if (event == OBS_FRONTEND_EVENT_FINISHED_LOADING) {
'@ 'add preview scene repair path'

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
