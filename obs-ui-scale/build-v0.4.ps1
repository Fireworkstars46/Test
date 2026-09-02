$ErrorActionPreference = 'Stop'
$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v0.4 patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "0.3.0";' 'static constexpr const char *PLUGIN_VERSION = "0.4.0";' 'plugin version'

Replace-Required @'
        autoApply_ = settings_ ? settings_->value(QStringLiteral("ui/autoApply"), true).toBool() : true;
'@ @'
        autoApply_ = settings_ ? settings_->value(QStringLiteral("ui/autoApply"), true).toBool() : true;
        safeTinyMode_ = settings_ ? settings_->value(QStringLiteral("ui/safeTinyMode"), true).toBool() : true;
'@ 'safe tiny setting load'

Replace-Required @'
private:
    static void FrontendEvent(enum obs_frontend_event event, void *privateData)
'@ @'
private:
    int EffectiveUiPercent(int requested) const
    {
        requested = qBound(1, requested, 1000);
        return safeTinyMode_ ? qMax(25, requested) : requested;
    }

    int EffectiveTextPercent(int requested) const
    {
        requested = qBound(1, requested, 1000);
        return safeTinyMode_ ? qMax(40, requested) : requested;
    }

    static void FrontendEvent(enum obs_frontend_event event, void *privateData)
'@ 'effective tiny scale helpers'

Replace-Required @'
        const int menuV = ScaledLength(4, uiPercent);
        const int menuH = ScaledLength(18, uiPercent);
        const int barV = ScaledLength(3, uiPercent);
        const int barH = ScaledLength(7, uiPercent);
        const int buttonV = ScaledLength(4, uiPercent);
        const int buttonH = ScaledLength(8, uiPercent);
        const int itemV = ScaledLength(2, uiPercent);
        const int itemH = ScaledLength(4, uiPercent);
'@ @'
        const int menuV = qMax(1, ScaledLength(4, uiPercent));
        const int menuH = qMax(2, ScaledLength(18, uiPercent));
        const int barV = qMax(1, ScaledLength(3, uiPercent));
        const int barH = qMax(1, ScaledLength(7, uiPercent));
        const int buttonV = qMax(1, ScaledLength(4, uiPercent));
        const int buttonH = qMax(2, ScaledLength(8, uiPercent));
        const int itemV = qMax(1, ScaledLength(2, uiPercent));
        const int itemH = qMax(1, ScaledLength(4, uiPercent));
'@ 'minimum compact paddings'

Replace-Required @'
                   "\n/* OBS UI Scale v0.3 runtime overrides */\n"
                   "* { font-size: %1pt; }\n"
                   "QMenu::item { padding: %2px %3px; }\n"
                   "QMenuBar::item { padding: %4px %5px; }\n"
                   "QPushButton { padding: %6px %7px; }\n"
                   "QToolButton { padding: %6px %6px; }\n"
                   "QComboBox, QLineEdit, QSpinBox, QDoubleSpinBox { padding: %8px %9px; }\n"
                   "QAbstractItemView::item, QHeaderView::section { padding: %8px %9px; }\n"
                   "QTabBar::tab { padding: %6px %7px; }\n")
'@ @'
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
'@ 'explicit tiny menu font and dock title spacing'

Replace-Required @'
        const int uiPercent = qBound(1, requestedUiPercent, 1000);
        const int textPercent = qBound(1, requestedTextPercent, 1000);

        if (uiPercent == 100 && textPercent == 100) {
'@ @'
        const int requestedUi = qBound(1, requestedUiPercent, 1000);
        const int requestedText = qBound(1, requestedTextPercent, 1000);
        const int uiPercent = EffectiveUiPercent(requestedUi);
        const int textPercent = EffectiveTextPercent(requestedText);

        if (requestedUi == 100 && requestedText == 100) {
'@ 'effective scale application'

Replace-Required @'
        blog(LOG_INFO, "[%s] applied UI/control %d%%, text %d%%", PLUGIN_NAME, uiPercent, textPercent);
'@ @'
        blog(LOG_INFO, "[%s] applied requested UI/text %d%%/%d%% (effective %d%%/%d%%, safe tiny=%d)",
             PLUGIN_NAME, requestedUi, requestedText, uiPercent, textPercent, safeTinyMode_ ? 1 : 0);
'@ 'scale logging'

Replace-Required @'
        dialog.setWindowTitle(QStringLiteral("OBS UI Scale v0.3"));
'@ @'
        dialog.setWindowTitle(QStringLiteral("OBS UI Scale v0.4"));
'@ 'dialog title'

Replace-Required @'
                           "v0.3 separates control/layout size from text size and scales OBS's loaded Qt theme directly."),
'@ @'
                           "v0.4 also smooths extreme tiny values so menus and labels do not collapse into each other."),
'@ 'dialog intro'

Replace-Required @'
        auto *autoApply = new QCheckBox(QStringLiteral("Apply these values automatically whenever OBS starts"), &dialog);
'@ @'
        auto *safeTiny = new QCheckBox(
            QStringLiteral("Keep extreme tiny values usable (recommended: 1-24% UI renders at 25%; 1-39% text renders at 40%)"),
            &dialog);
        safeTiny->setChecked(safeTinyMode_);
        layout->addWidget(safeTiny);

        auto *autoApply = new QCheckBox(QStringLiteral("Apply these values automatically whenever OBS starts"), &dialog);
'@ 'safe tiny checkbox'

Replace-Required @'
            QStringLiteral("Range: 1% to 1000% in 1% steps. Very low/high values can make OBS hard to use. "
                           "Emergency reset: Ctrl+Alt+0 returns both values to 100%. The Windows title bar and embedded browser/third-party dock content may not follow this scale."),
'@ @'
            QStringLiteral("Range: 1% to 1000% in 1% steps. Safe tiny mode prevents Qt's minimum font/padding limits from making 1% look broken. "
                           "Turn it off only if you want the raw extreme value. Emergency reset: Ctrl+Alt+0 returns both values to 100%. "
                           "The Windows title bar and embedded browser/third-party dock content may not follow this scale."),
'@ 'tiny mode note'

Replace-Required @'
                         [this, uiSpin, textSpin, autoApply, status]() {
                             SaveSettings(uiSpin->value(), textSpin->value(), autoApply->isChecked());
'@ @'
                         [this, uiSpin, textSpin, safeTiny, autoApply, status]() {
                             safeTinyMode_ = safeTiny->isChecked();
                             if (settings_)
                                 settings_->setValue(QStringLiteral("ui/safeTinyMode"), safeTinyMode_);
                             SaveSettings(uiSpin->value(), textSpin->value(), autoApply->isChecked());
'@ 'apply safe tiny setting'

Replace-Required @'
                         [this, uiSpin, textSpin, autoApply, status]() {
                             uiSpin->setValue(100);
'@ @'
                         [this, uiSpin, textSpin, safeTiny, autoApply, status]() {
                             safeTinyMode_ = safeTiny->isChecked();
                             if (settings_)
                                 settings_->setValue(QStringLiteral("ui/safeTinyMode"), safeTinyMode_);
                             uiSpin->setValue(100);
'@ 'restore safe tiny setting'

Replace-Required @'
    bool autoApply_ = true;
'@ @'
    bool autoApply_ = true;
    bool safeTinyMode_ = true;
'@ 'safe tiny member'

Set-Content $path $s -Encoding utf8
Write-Host 'Prepared OBS UI Scale v0.4 tiny-scale smoothing source.'
