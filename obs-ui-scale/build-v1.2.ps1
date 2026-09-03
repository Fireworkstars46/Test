$ErrorActionPreference = 'Stop'

# Keep v1.1 behavior, but keep the proportional bottom-dock geometry after OBS
# switches scenes. OBS can re-run QMainWindow dock layout on scene changes and
# expand the dock area back toward its unscaled size. Reassert only dock geometry
# (not the whole stylesheet/widget tree) so the fix is lightweight and avoids UI flicker.
& ./build-v1.1.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v1.2 patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "1.1.0";' 'static constexpr const char *PLUGIN_VERSION = "1.2.0";' 'plugin version'

Replace-Required @'
        if (event == OBS_FRONTEND_EVENT_FINISHED_LOADING) {
            QTimer::singleShot(150, self, [self]() {
                if (self->startupApplyDone_)
                    return;
                self->startupApplyDone_ = true;
                self->CaptureBaselineIfNeeded();
                self->EnsureEmergencyShortcut();
                if (self->autoApply_)
                    self->ApplyScale(self->uiPercent_, self->textPercent_);
            });
        }
    }

    static int ScaledLength(int value, double percent)
'@ @'
        if (event == OBS_FRONTEND_EVENT_FINISHED_LOADING) {
            QTimer::singleShot(150, self, [self]() {
                if (self->startupApplyDone_)
                    return;
                self->startupApplyDone_ = true;
                self->CaptureBaselineIfNeeded();
                self->EnsureEmergencyShortcut();
                if (self->autoApply_)
                    self->ApplyScale(self->uiPercent_, self->textPercent_);
            });
            return;
        }

        if (event == OBS_FRONTEND_EVENT_SCENE_CHANGED ||
            event == OBS_FRONTEND_EVENT_SCENE_LIST_CHANGED ||
            event == OBS_FRONTEND_EVENT_SCENE_COLLECTION_CHANGED) {
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
        }
    }

    static int ScaledLength(int value, double percent)
'@ 'persist dock geometry after scene changes'

Replace-Required 'dialog.setWindowTitle(QStringLiteral("OBS UI Scale v1.1"));' 'dialog.setWindowTitle(QStringLiteral("OBS UI Scale v1.2"));' 'dialog title'

Set-Content $path $s -Encoding utf8

$issPath = 'installer/ObsUiScale.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('1.1.0', '1.2.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared OBS UI Scale v1.2 persistent proportional dock geometry.'
