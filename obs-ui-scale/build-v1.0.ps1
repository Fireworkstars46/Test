$ErrorActionPreference = 'Stop'

# Keep all v0.9 behavior, then fix plugin widgets that are created after the
# initial OBS scale pass. This is especially important for Source Dock Hide's
# bottom "0 hidden" counter, which can appear after UI Scale has already applied.
& ./build-v0.9.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v1.0 patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "0.9.0";' 'static constexpr const char *PLUGIN_VERSION = "1.0.0";' 'plugin version'

# Add a very cheap targeted compatibility pass for custom plugin widgets that
# can be created later than OBS's core docks. It does not rescan/repaint all
# widgets, so it keeps v0.9's smoother apply behavior.
$insertMarker = '    void ApplyCapturedWidgetMetrics(double uiPercent)'
$insertPos = $s.IndexOf($insertMarker)
if ($insertPos -lt 0) { throw 'v1.0 could not locate ApplyCapturedWidgetMetrics insertion point' }

$helper = @'
    void FitSourceDockHideCounter(double uiPercent)
    {
        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
        if (!mainWindow)
            return;

        auto *button = mainWindow->findChild<QAbstractButton *>(QStringLiteral("sourceDockHiddenCountButton"),
                                                                 Qt::FindChildrenRecursively);
        if (!button)
            return;

        // Reserve enough width for the label at the CURRENT scaled font. Using
        // a representative multi-digit label avoids another resize when the
        // hidden count changes, while remaining close to the stock 72px width
        // at 100% and shrinking proportionally at smaller scales.
        const QFontMetrics metrics(button->font());
        const int currentTextW = metrics.horizontalAdvance(button->text());
        const int reserveTextW = metrics.horizontalAdvance(QStringLiteral("9999 hidden"));
        const int padding = qMax(4, ScaledLength(12, uiPercent));
        const int wantedW = qMax(currentTextW, reserveTextW) + padding;

        button->setMinimumWidth(wantedW);
        button->setMaximumWidth(wantedW);
        button->updateGeometry();

        if (QWidget *parent = button->parentWidget()) {
            if (QLayout *layout = parent->layout()) {
                layout->invalidate();
                layout->activate();
            }
            parent->updateGeometry();
            parent->update();
        }
    }

    void ScheduleLatePluginWidgetFixes(double uiPercent)
    {
        // Source Dock Hide may create its toolbar widget after UI Scale's startup
        // pass depending on plugin load order. These targeted retries are tiny:
        // one findChild + geometry update, not a whole-OBS widget walk.
        const int delays[] = {0, 60, 180, 500, 1200};
        for (int delay : delays) {
            QTimer::singleShot(delay, this, [this, uiPercent]() {
                if (qAbs(currentUiPercent_ - uiPercent) < 0.01)
                    FitSourceDockHideCounter(uiPercent);
            });
        }
    }

'@
$s = $s.Substring(0, $insertPos) + $helper + $s.Substring($insertPos)

# After the normal apply, immediately fit the counter if it already exists and
# schedule targeted retries for late plugin load order.
Replace-Required @'
        currentUiPercent_ = uiPercent;
        currentTextPercent_ = textPercent;

        if (mainWindow) {
'@ @'
        currentUiPercent_ = uiPercent;
        currentTextPercent_ = textPercent;

        FitSourceDockHideCounter(uiPercent);
        ScheduleLatePluginWidgetFixes(uiPercent);

        if (mainWindow) {
'@ 'late plugin widget fit after apply'

# Keep the counter correct when restoring 100% too.
Replace-Required @'
        currentUiPercent_ = 100.0;
        currentTextPercent_ = 100.0;

        QTimer::singleShot(24, this, [this]() { RefreshWidgets(); });
'@ @'
        currentUiPercent_ = 100.0;
        currentTextPercent_ = 100.0;

        FitSourceDockHideCounter(100.0);
        ScheduleLatePluginWidgetFixes(100.0);
        QTimer::singleShot(24, this, [this]() { RefreshWidgets(); });
'@ 'restore source counter fit'

Replace-Required 'dialog.setWindowTitle(QStringLiteral("OBS UI Scale v0.9"));' 'dialog.setWindowTitle(QStringLiteral("OBS UI Scale v1.0"));' 'dialog title'
Replace-Required @'
            QStringLiteral("v0.9 keeps UI and text independent with 0.01% precision, fixes scaling for the Source Dock Hide counter, "
                           "and batches redraw/layout work so applying a scale is smoother and lighter."),
'@ @'
            QStringLiteral("v1.0 keeps the smooth v0.9 scaling path and now also catches plugin controls that appear after startup. "
                           "The Source Dock Hide counter is fitted after scaling without doing expensive whole-OBS refresh loops."),
'@ 'dialog intro'

Set-Content $path $s -Encoding utf8

$issPath = 'installer/ObsUiScale.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('0.9.0', '1.0.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared OBS UI Scale v1.0 late-plugin-widget compatibility build.'
