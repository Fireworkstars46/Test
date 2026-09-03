$ErrorActionPreference = 'Stop'

# Keep v1.2's persistent proportional dock geometry, but also scale widgets that
# OBS creates lazily when a scene is first selected (especially Audio Mixer meter
# widgets). Those late widgets can carry 100%-sized minimums and force the whole
# bottom dock row taller again after the initial 78% layout.
& ./build-v1.2.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v1.3 patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "1.2.0";' 'static constexpr const char *PLUGIN_VERSION = "1.3.0";' 'plugin version'

# Add a batched pass for lazily-created scene widgets. Existing widgets keep
# their stored 100% baseline properties, while only newly-created widgets get
# captured now. Applying the stored metrics again is idempotent for old widgets.
$marker = '    void ApplyProportionalDockGeometry(double uiPercent)'
$pos = $s.IndexOf($marker)
if ($pos -lt 0) { throw 'v1.3 could not locate ApplyProportionalDockGeometry' }

$helper = @'
    void ScaleLateCreatedWidgetsAndDock(double uiPercent)
    {
        if (!baselineReady_ || qAbs(currentUiPercent_ - uiPercent) >= 0.01)
            return;

        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
        if (mainWindow)
            mainWindow->setUpdatesEnabled(false);

        // Capture baseline metrics only for widgets/layouts that did not exist
        // during the original scale pass, then scale all captured metrics from
        // their stored baseline. This catches lazy Audio Mixer/source controls.
        CaptureExistingWidgetMetrics();
        ApplyCapturedWidgetMetrics(uiPercent);
        ApplyProportionalDockGeometry(uiPercent);
        FitSourceDockHideCounter(uiPercent);

        if (mainWindow) {
            if (QLayout *layout = mainWindow->layout()) {
                layout->invalidate();
                layout->activate();
            }
            mainWindow->setUpdatesEnabled(true);
            mainWindow->updateGeometry();
            mainWindow->update();
        }
    }

    void ScheduleLateSceneWidgetScale(double uiPercent)
    {
        // OBS builds some mixer controls immediately and some on the following
        // event-loop turns. Two quiet passes catch both without continuously
        // rescanning/repainting the interface.
        const int delays[] = {0, 90};
        for (int delay : delays) {
            QTimer::singleShot(delay, this, [this, uiPercent]() {
                ScaleLateCreatedWidgetsAndDock(uiPercent);
            });
        }
    }

'@
$s = $s.Substring(0, $pos) + $helper + $s.Substring($pos)

# Replace v1.2's geometry-only scene-change retries with the late-widget scale
# pass. This is the key difference: resizeDocks alone cannot shrink below a new
# child widget's unscaled minimumSizeHint/minimumHeight.
Replace-Required @'
            // OBS can relayout its dock area while changing scenes. Reassert only
            // the already-scaled dock geometry, rather than reapplying the whole
            // theme/widget tree. The zero-delay pass normally lands before paint;
            // the short follow-up catches late QMainWindow layout work.
            const double ui = self->currentUiPercent_;
            QTimer::singleShot(0, self, [self, ui]() {
                if (qAbs(self->currentUiPercent_ - ui) < 0.01)
                    self->ApplyProportionalDockGeometry(ui);
            });
            QTimer::singleShot(45, self, [self, ui]() {
                if (qAbs(self->currentUiPercent_ - ui) < 0.01)
                    self->ApplyProportionalDockGeometry(ui);
            });
'@ @'
            // Scene changes can create fresh Audio Mixer/source widgets with
            // their stock (100%) explicit minimum sizes. Scale those new widgets
            // before reasserting the proportional dock geometry.
            const double ui = self->currentUiPercent_;
            self->ScheduleLateSceneWidgetScale(ui);
'@ 'scale lazy widgets after scene changes'

Replace-Required 'dialog.setWindowTitle(QStringLiteral("OBS UI Scale v1.2"));' 'dialog.setWindowTitle(QStringLiteral("OBS UI Scale v1.3"));' 'dialog title'

Set-Content $path $s -Encoding utf8

$issPath = 'installer/ObsUiScale.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('1.2.0', '1.3.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared OBS UI Scale v1.3 late-created widget scaling + stable dock geometry.'
