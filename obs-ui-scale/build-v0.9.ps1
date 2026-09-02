$ErrorActionPreference = 'Stop'

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v0.9 patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "0.8.0";' 'static constexpr const char *PLUGIN_VERSION = "0.9.0";' 'plugin version'

# Avoid applying the saved scale twice during OBS startup. Depending on load order,
# both the fallback timer and FINISHED_LOADING can fire.
Replace-Required @'
        QTimer::singleShot(900, this, [this]() {
            CaptureBaselineIfNeeded();
            EnsureEmergencyShortcut();
            if (autoApply_)
                ApplyScale(uiPercent_, textPercent_);
        });
'@ @'
        QTimer::singleShot(900, this, [this]() {
            if (startupApplyDone_)
                return;
            startupApplyDone_ = true;
            CaptureBaselineIfNeeded();
            EnsureEmergencyShortcut();
            if (autoApply_)
                ApplyScale(uiPercent_, textPercent_);
        });
'@ 'startup fallback guard'

Replace-Required @'
            QTimer::singleShot(150, self, [self]() {
                self->CaptureBaselineIfNeeded();
                self->EnsureEmergencyShortcut();
                if (self->autoApply_)
                    self->ApplyScale(self->uiPercent_, self->textPercent_);
            });
'@ @'
            QTimer::singleShot(150, self, [self]() {
                if (self->startupApplyDone_)
                    return;
                self->startupApplyDone_ = true;
                self->CaptureBaselineIfNeeded();
                self->EnsureEmergencyShortcut();
                if (self->autoApply_)
                    self->ApplyScale(self->uiPercent_, self->textPercent_);
            });
'@ 'finished loading startup guard'

# The Source Dock Hide counter is a text-only tool button. Make its minimum width
# follow the currently scaled font so "0 hidden" does not become "0...n".
Replace-Required @'
                widget->setMinimumSize(targetW, targetH);
'@ @'
                if (widget->objectName() == QStringLiteral("sourceDockHiddenCountButton")) {
                    if (auto *textButton = qobject_cast<QAbstractButton *>(widget)) {
                        const int textW = textButton->fontMetrics().horizontalAdvance(textButton->text());
                        const int textPad = qMax(6, ScaledLength(14, uiPercent));
                        targetW = qMax(targetW, textW + textPad);
                    }
                }

                widget->setMinimumSize(targetW, targetH);
'@ 'source hide counter text fit'

# The old refresh walked every QWidget three additional times after every Apply.
# Qt already republishes StyleChange/FontChange for the application stylesheet,
# so only relayout/repaint the main OBS window here.
$refreshStart = $s.IndexOf('    void RefreshWidgets()')
$refreshEnd = $s.IndexOf('    void ApplyScale(double requestedUiPercent, double requestedTextPercent)', $refreshStart)
if ($refreshStart -lt 0 -or $refreshEnd -lt 0) { throw 'v0.9 could not locate RefreshWidgets block' }
$newRefresh = @'
    void RefreshWidgets()
    {
        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
        if (!mainWindow)
            return;

        if (QLayout *layout = mainWindow->layout()) {
            layout->invalidate();
            layout->activate();
        }
        mainWindow->updateGeometry();
        mainWindow->update();
    }

'@
$s = $s.Substring(0, $refreshStart) + $newRefresh + $s.Substring($refreshEnd)

# Batch the expensive stylesheet/font/widget metric update while the main OBS
# window is not repainting, then do one lightweight follow-up layout pass.
$applyStartMarker = '        QString scaledStyleSheet = TransformStyleSheet(originalStyleSheet_, uiPercent, textPercent);'
$applyEndMarker = '        blog(LOG_INFO, "[%s] applied requested UI/text %.2f%%/%.2f%% (effective %.2f%%/%.2f%%, proportional=%d, safe tiny=%d)",'
$applyStart = $s.IndexOf($applyStartMarker)
$applyEnd = $s.IndexOf($applyEndMarker, $applyStart)
if ($applyStart -lt 0 -or $applyEnd -lt 0) { throw 'v0.9 could not locate ApplyScale update block' }
$newApply = @'
        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
        if (mainWindow)
            mainWindow->setUpdatesEnabled(false);

        QString scaledStyleSheet = TransformStyleSheet(originalStyleSheet_, uiPercent, textPercent);
        scaledStyleSheet += BuildScaleOverrides(uiPercent, textPercent);

        qApp->setStyleSheet(scaledStyleSheet);
        qApp->setFont(ScaledFont(textPercent));
        ApplyCapturedWidgetMetrics(uiPercent);
        ApplyProportionalDockGeometry(uiPercent);

        currentUiPercent_ = uiPercent;
        currentTextPercent_ = textPercent;

        if (mainWindow) {
            mainWindow->setUpdatesEnabled(true);
            if (QLayout *layout = mainWindow->layout()) {
                layout->invalidate();
                layout->activate();
            }
            mainWindow->update();
        }

        QTimer::singleShot(24, this, [this, uiPercent]() {
            RefreshWidgets();
            ApplyProportionalDockGeometry(uiPercent);
        });

'@
$s = $s.Substring(0, $applyStart) + $newApply + $s.Substring($applyEnd)

# Restore also only needs one lightweight post-layout pass.
Replace-Required @'
        QTimer::singleShot(0, this, [this]() { RefreshWidgets(); });
        QTimer::singleShot(150, this, [this]() { RefreshWidgets(); });
'@ @'
        QTimer::singleShot(24, this, [this]() { RefreshWidgets(); });
'@ 'restore refresh coalescing'

Replace-Required 'dialog.setWindowTitle(QStringLiteral("OBS UI Scale v0.8"));' 'dialog.setWindowTitle(QStringLiteral("OBS UI Scale v0.9"));' 'dialog title'
Replace-Required @'
            QStringLiteral("v0.8 keeps the improved proportional OBS layout from v0.7, but UI and text are independent again. "
                           "Both values now support hundredths of a percent; the arrow buttons move in 0.25% steps."),
'@ @'
            QStringLiteral("v0.9 keeps UI and text independent with 0.01% precision, fixes scaling for the Source Dock Hide counter, "
                           "and batches redraw/layout work so applying a scale is smoother and lighter."),
'@ 'dialog intro'

Replace-Required @'
    bool autoApply_ = true;
    bool safeTinyMode_ = true;
    bool proportionalMode_ = true;
'@ @'
    bool autoApply_ = true;
    bool safeTinyMode_ = true;
    bool proportionalMode_ = true;
    bool startupApplyDone_ = false;
'@ 'startup guard member'

Set-Content $path $s -Encoding utf8
Write-Host 'Prepared OBS UI Scale v0.9 smoother apply + Source Dock Hide compatibility.'
