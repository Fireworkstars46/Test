$ErrorActionPreference = 'Stop'

# Start from v0.5, then make low UI scaling respect the actual text height.
# This prevents 100% text from being clipped inside 35%-effective buttons/fields.
& "$PSScriptRoot/build-v0.5.ps1"

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v0.6 patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "0.5.0";' 'static constexpr const char *PLUGIN_VERSION = "0.6.0";' 'plugin version'

# Replace the fixed tiny-mode minima with minima derived from the scaled font.
Replace-Required @'
        const int menuMinH = safeTinyMode_ ? 12 : 0;
        const int buttonMinH = safeTinyMode_ ? 14 : 0;
        const int toolMinH = safeTinyMode_ ? 12 : 0;
        const int fieldMinH = safeTinyMode_ ? 14 : 0;
        const int itemMinH = safeTinyMode_ ? 12 : 0;
        const int dockTitleMinH = safeTinyMode_ ? 12 : 0;

        double basePoint = originalFont_.pointSizeF();
'@ @'
        const QFont scaledFontForMetrics = ScaledFont(textPercent);
        const QFontMetrics scaledMetrics(scaledFontForMetrics);
        const int textLineH = qMax(1, scaledMetrics.height());
        const int menuMinH = safeTinyMode_ ? qMax(12, textLineH + 4) : 0;
        const int buttonMinH = safeTinyMode_ ? qMax(14, textLineH + 8) : 0;
        const int toolMinH = safeTinyMode_ ? qMax(12, textLineH + 6) : 0;
        const int fieldMinH = safeTinyMode_ ? qMax(14, textLineH + 8) : 0;
        const int itemMinH = safeTinyMode_ ? qMax(12, textLineH + 4) : 0;
        const int dockTitleMinH = safeTinyMode_ ? qMax(12, textLineH + 4) : 0;

        double basePoint = originalFont_.pointSizeF();
'@ 'font-aware QSS minimum heights'

# Also enforce readable heights directly on existing OBS widgets after the
# stylesheet has been applied. This bypasses more-specific OBS theme selectors.
Replace-Required @'
            if (widget->property(PROP_MIN_W).isValid()) {
                const int baseW = widget->property(PROP_MIN_W).toInt();
                const int baseH = widget->property(PROP_MIN_H).toInt();
                widget->setMinimumSize(ScaledLength(baseW, uiPercent), ScaledLength(baseH, uiPercent));
            }
'@ @'
            if (widget->property(PROP_MIN_W).isValid()) {
                const int baseW = widget->property(PROP_MIN_W).toInt();
                const int baseH = widget->property(PROP_MIN_H).toInt();
                int targetW = ScaledLength(baseW, uiPercent);
                int targetH = ScaledLength(baseH, uiPercent);

                if (safeTinyMode_) {
                    const int lineH = qMax(1, widget->fontMetrics().height());
                    int readableH = 0;
                    if (widget->inherits("QPushButton"))
                        readableH = lineH + 8;
                    else if (widget->inherits("QToolButton"))
                        readableH = lineH + 6;
                    else if (widget->inherits("QComboBox") || widget->inherits("QLineEdit") ||
                             widget->inherits("QSpinBox") || widget->inherits("QDoubleSpinBox"))
                        readableH = lineH + 8;
                    else if (widget->inherits("QTabBar"))
                        readableH = lineH + 6;

                    if (readableH > 0)
                        targetH = qMax(targetH, readableH);
                }

                widget->setMinimumSize(targetW, targetH);
            }
'@ 'direct text-aware widget minimums'

Replace-Required 'dialog.setWindowTitle(QStringLiteral("OBS UI Scale v0.5"));' 'dialog.setWindowTitle(QStringLiteral("OBS UI Scale v0.6"));' 'dialog title'

Replace-Required @'
                           "v0.5 also protects buttons, fields, dock titles, and list rows from collapsing at extreme tiny values."),
'@ @'
                           "v0.6 also makes button/field height follow the chosen text size, so large text is not clipped by a tiny UI value."),
'@ 'dialog intro'

Replace-Required @'
            QStringLiteral("Range: 1% to 1000% in 1% steps. Safe tiny mode also keeps OBS buttons, fields, dock titles, and list rows readable at very low values. "
'@ @'
            QStringLiteral("Range: 1% to 1000% in 1% steps. Safe tiny mode now also makes controls tall enough for the selected text size, so UI 1% + Text 100% stays readable. "
'@ 'safe tiny note'

Set-Content $path $s -Encoding utf8
Write-Host 'Prepared OBS UI Scale v0.6 text-aware control sizing.'
