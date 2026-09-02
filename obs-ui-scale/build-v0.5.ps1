$ErrorActionPreference = 'Stop'

# Start from the known-good v0.4 transformation, then add v0.5's
# component-level minimum sizes for the controls that still collapse at
# extreme tiny scale values.
& "$PSScriptRoot/build-v0.4.ps1"

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v0.5 patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "0.4.0";' 'static constexpr const char *PLUGIN_VERSION = "0.5.0";' 'plugin version'

# The screenshot from v0.4 showed that 25%/40% was still low enough for
# Controls and Scene Transitions to squash their button/field text. Use a
# slightly higher safe floor only when safe tiny mode is enabled.
Replace-Required 'return safeTinyMode_ ? qMax(25, requested) : requested;' 'return safeTinyMode_ ? qMax(35, requested) : requested;' 'safe UI floor'
Replace-Required 'return safeTinyMode_ ? qMax(40, requested) : requested;' 'return safeTinyMode_ ? qMax(50, requested) : requested;' 'safe text floor'

Replace-Required @'
        const int itemV = qMax(1, ScaledLength(2, uiPercent));
        const int itemH = qMax(1, ScaledLength(4, uiPercent));

        double basePoint = originalFont_.pointSizeF();
'@ @'
        const int itemV = qMax(1, ScaledLength(2, uiPercent));
        const int itemH = qMax(1, ScaledLength(4, uiPercent));

        // Several OBS docks use controls whose normal height comes from the
        // platform/theme rather than layout margins. At extreme tiny values
        // Qt can therefore leave the widget alive but make its label overlap.
        // Safe tiny mode gives those widgets a small readable floor; normal
        // and large scale values are unaffected because these are minimums.
        const int menuMinH = safeTinyMode_ ? 12 : 0;
        const int buttonMinH = safeTinyMode_ ? 14 : 0;
        const int toolMinH = safeTinyMode_ ? 12 : 0;
        const int fieldMinH = safeTinyMode_ ? 14 : 0;
        const int itemMinH = safeTinyMode_ ? 12 : 0;
        const int dockTitleMinH = safeTinyMode_ ? 12 : 0;

        double basePoint = originalFont_.pointSizeF();
'@ 'tiny control minimum declarations'

Replace-Required @'
                   "\n/* OBS UI Scale v0.4 runtime overrides */\n"
                   "* { font-size: %1pt; }\n"
                   "QMenu, QMenu::item, QMenuBar, QMenuBar::item { font-size: %1pt; }\n"
                   "QMenu::item { padding: %2px %3px; }\n"
                   "QMenuBar::item { padding: %4px %5px; }\n"
                   "QPushButton { padding: %6px %7px; }\n"
                   "QToolButton { padding: %6px %6px; }\n"
                   "QComboBox, QLineEdit, QSpinBox, QDoubleSpinBox { padding: %8px %9px; }\n"
                   "QAbstractItemView::item, QHeaderView::section { padding: %8px %9px; }\n"
                   "QTabBar::tab { padding: %6px %7px; }\n"
                   "QDockWidget::title { padding: %8px %9px; }\n")
            .arg(QString::number(scaledPoint, 'f', 2))
            .arg(menuV)
            .arg(menuH)
            .arg(barV)
            .arg(barH)
            .arg(buttonV)
            .arg(buttonH)
            .arg(itemV)
            .arg(itemH);
'@ @'
                   "\n/* OBS UI Scale v0.5 runtime overrides */\n"
                   "* { font-size: %1pt; }\n"
                   "QMenu, QMenu::item, QMenuBar, QMenuBar::item { font-size: %1pt; }\n"
                   "QMenuBar { min-height: %10px; }\n"
                   "QMenu::item { padding: %2px %3px; min-height: %10px; }\n"
                   "QMenuBar::item { padding: %4px %5px; min-height: %10px; }\n"
                   "QPushButton { padding: %6px %7px; min-height: %11px; }\n"
                   "QToolButton { padding: %6px %6px; min-height: %12px; min-width: %12px; }\n"
                   "QComboBox, QLineEdit, QSpinBox, QDoubleSpinBox { padding: %8px %9px; min-height: %13px; }\n"
                   "QAbstractItemView::item, QHeaderView::section { padding: %8px %9px; min-height: %14px; }\n"
                   "QTabBar::tab { padding: %6px %7px; min-height: %14px; }\n"
                   "QDockWidget::title { padding: %8px %9px; min-height: %15px; }\n")
            .arg(QString::number(scaledPoint, 'f', 2))
            .arg(menuV)
            .arg(menuH)
            .arg(barV)
            .arg(barH)
            .arg(buttonV)
            .arg(buttonH)
            .arg(itemV)
            .arg(itemH)
            .arg(menuMinH)
            .arg(buttonMinH)
            .arg(toolMinH)
            .arg(fieldMinH)
            .arg(itemMinH)
            .arg(dockTitleMinH);
'@ 'component minimum QSS'

Replace-Required 'dialog.setWindowTitle(QStringLiteral("OBS UI Scale v0.4"));' 'dialog.setWindowTitle(QStringLiteral("OBS UI Scale v0.5"));' 'dialog title'

Replace-Required @'
                           "v0.4 also smooths extreme tiny values so menus and labels do not collapse into each other."),
'@ @'
                           "v0.5 also protects buttons, fields, dock titles, and list rows from collapsing at extreme tiny values."),
'@ 'dialog intro'

Replace-Required @'
            QStringLiteral("Keep extreme tiny values usable (recommended: 1-24% UI renders at 25%; 1-39% text renders at 40%)"),
'@ @'
            QStringLiteral("Keep extreme tiny values usable (recommended: 1-34% UI renders at 35%; 1-49% text renders at 50%)"),
'@ 'safe tiny checkbox text'

Replace-Required @'
            QStringLiteral("Range: 1% to 1000% in 1% steps. Safe tiny mode prevents Qt's minimum font/padding limits from making 1% look broken. "
'@ @'
            QStringLiteral("Range: 1% to 1000% in 1% steps. Safe tiny mode also keeps OBS buttons, fields, dock titles, and list rows readable at very low values. "
'@ 'safe tiny note'

Set-Content $path $s -Encoding utf8
Write-Host 'Prepared OBS UI Scale v0.5 component-level tiny-scale fixes.'
