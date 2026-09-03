$ErrorActionPreference = 'Stop'

# Start from v1.8, intentionally dropping the later dock-height/state guards.
# The latest recording and OBS source show the real cause: AudioMixer::updateVolumeLayouts()
# calls stackedMixerArea->setMinimumSize(...) whenever scene audio controls change.
# That new minimum height forces QMainWindow's whole bottom dock row upward after Apply.
#
# v2.2 fixes that specific OBS minimum-size reset. It captures the scaled
# stackedMixerArea minimum height produced by Apply and reasserts only that
# minimum after AudioMixer's queued layout update. No dock max-height, resizeDocks,
# or saveState/restoreState tricks are used, so manual dock dragging remains native.
& ./build-v1.8.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v2.2 patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "1.8.0";' 'static constexpr const char *PLUGIN_VERSION = "2.2.0";' 'plugin version'

# Add targeted Audio Mixer helpers before the context-container helper.
$insertMarker = '    bool IsInsideContextContainer(QWidget *widget) const'
$insertPos = $s.IndexOf($insertMarker)
if ($insertPos -lt 0) { throw 'v2.2 could not locate helper insertion point' }

$helper = @'
    QWidget *StackedMixerArea() const
    {
        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
        if (!mainWindow)
            return nullptr;
        return mainWindow->findChild<QWidget *>(QStringLiteral("stackedMixerArea"),
                                                Qt::FindChildrenRecursively);
    }

    void CaptureMixerMinimumTarget(double uiPercent)
    {
        if (!proportionalMode_ || uiPercent >= 99.999) {
            mixerMinHeightTarget_ = -1;
            return;
        }

        QWidget *mixer = StackedMixerArea();
        if (!mixer)
            return;

        // ApplyCapturedWidgetMetrics() has already converted this explicit OBS
        // minimum to the requested UI scale. Keep only the vertical minimum as
        // the target; width remains fully controlled by OBS.
        mixerMinHeightTarget_ = qMax(0, mixer->minimumHeight());
    }

    void RestoreMixerMinimumTarget()
    {
        if (mixerMinHeightTarget_ < 0 || !proportionalMode_ || currentUiPercent_ >= 99.999)
            return;

        QWidget *mixer = StackedMixerArea();
        if (!mixer)
            return;

        if (mixer->minimumHeight() != mixerMinHeightTarget_) {
            mixer->setMinimumHeight(mixerMinHeightTarget_);
            mixer->updateGeometry();
        }
    }

    void ScheduleMixerMinimumRestore(double uiPercent)
    {
        // AudioMixer::queueLayoutUpdate() uses a zero-timeout QTimer and then
        // updateVolumeLayouts() resets stackedMixerArea's minimum size. These
        // passes run after that timer and reapply only our scaled minimum height.
        const int delays[] = {0, 10, 35, 90, 180};
        for (int delay : delays) {
            QTimer::singleShot(delay, this, [this, uiPercent]() {
                if (qAbs(currentUiPercent_ - uiPercent) < 0.01)
                    RestoreMixerMinimumTarget();
            });
        }
    }

    void ScheduleMixerTargetCapture(double uiPercent)
    {
        // Let ApplyScale's queued style/layout passes settle first, then capture
        // the exact scaled minimum produced by Apply. No dock geometry is saved.
        QTimer::singleShot(70, this, [this, uiPercent]() {
            if (qAbs(currentUiPercent_ - uiPercent) < 0.01)
                CaptureMixerMinimumTarget(uiPercent);
        });
        QTimer::singleShot(150, this, [this, uiPercent]() {
            if (qAbs(currentUiPercent_ - uiPercent) < 0.01) {
                CaptureMixerMinimumTarget(uiPercent);
                RestoreMixerMinimumTarget();
            }
        });
    }

'@
$s = $s.Substring(0, $insertPos) + $helper + $s.Substring($insertPos)

# Scene changes: preserve v1.8's context toolbar handling and also correct the
# Audio Mixer's explicit minimum after its own queued layout update.
Replace-Required @'
            self->ScheduleContextBarRescale(self->currentUiPercent_);
'@ @'
            self->ScheduleContextBarRescale(self->currentUiPercent_);
            self->ScheduleMixerMinimumRestore(self->currentUiPercent_);
'@ 'restore mixer minimum after scene change'

# Capture the correct scaled mixer minimum after every Apply/startup apply.
Replace-Required @'
        FitSourceDockHideCounter(uiPercent);
        ScheduleLatePluginWidgetFixes(uiPercent);
        ScheduleContextBarRescale(uiPercent);

        if (mainWindow) {
'@ @'
        FitSourceDockHideCounter(uiPercent);
        ScheduleLatePluginWidgetFixes(uiPercent);
        ScheduleContextBarRescale(uiPercent);
        ScheduleMixerTargetCapture(uiPercent);

        if (mainWindow) {
'@ 'capture mixer minimum after apply'

# At 100%, stop overriding OBS's natural mixer minimum.
Replace-Required @'
        currentUiPercent_ = 100.0;
        currentTextPercent_ = 100.0;
        ClearStableDockTargets();
'@ @'
        currentUiPercent_ = 100.0;
        currentTextPercent_ = 100.0;
        mixerMinHeightTarget_ = -1;
        ClearStableDockTargets();
'@ 'clear mixer target at 100 percent'

Replace-Required 'dialog.setWindowTitle(QStringLiteral("OBS UI Scale v1.8"));' 'dialog.setWindowTitle(QStringLiteral("OBS UI Scale v2.2"));' 'dialog title'
Replace-Required @'
            QStringLiteral("v1.8 keeps Source Dock Hide width ownership and fixes the remaining vertical jump. "
                           "OBS's dynamically rebuilt source context toolbar is scaled as it appears, so scene changes no longer undo the applied layout."),
'@ @'
            QStringLiteral("v2.2 fixes OBS Audio Mixer's scene-change minimum-size reset directly. "
                           "The scaled mixer minimum is preserved without locking dock heights, so Apply stays put and manual dock dragging remains native."),
'@ 'dialog intro'

Replace-Required @'
    bool contextScaleQueued_ = false;
'@ @'
    bool contextScaleQueued_ = false;
    int mixerMinHeightTarget_ = -1;
'@ 'mixer target member'

Set-Content $path $s -Encoding utf8

$issPath = 'installer/ObsUiScale.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('1.8.0', '2.2.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared OBS UI Scale v2.2 targeted Audio Mixer minimum-height preservation.'
