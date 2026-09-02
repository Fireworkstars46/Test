$ErrorActionPreference = 'Stop'

# Start from v0.6, then add a proportional mode that keeps OBS looking like
# the default layout, just smaller. It links text + controls and also resizes
# the dock regions themselves instead of only shrinking their child controls.
& "$PSScriptRoot/build-v0.6.ps1"

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v0.7 patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "0.6.0";' 'static constexpr const char *PLUGIN_VERSION = "0.7.0";' 'plugin version'

Replace-Required '#include <QDialogButtonBox>' "#include <QDialogButtonBox>`n#include <QDockWidget>" 'QDockWidget include'
Replace-Required '#include <QAction>' "#include <QAction>`n#include <QAbstractButton>" 'QAbstractButton include'

Replace-Required @'
static constexpr const char *PROP_MIN_W = "obsUiScaleBaseMinW";
static constexpr const char *PROP_MIN_H = "obsUiScaleBaseMinH";
'@ @'
static constexpr const char *PROP_MIN_W = "obsUiScaleBaseMinW";
static constexpr const char *PROP_MIN_H = "obsUiScaleBaseMinH";
static constexpr const char *PROP_BASE_W = "obsUiScaleBaseActualW";
static constexpr const char *PROP_BASE_H = "obsUiScaleBaseActualH";
static constexpr const char *PROP_ICON_W = "obsUiScaleBaseIconW";
static constexpr const char *PROP_ICON_H = "obsUiScaleBaseIconH";
'@ 'baseline size properties'

Replace-Required @'
        safeTinyMode_ = settings_ ? settings_->value(QStringLiteral("ui/safeTinyMode"), true).toBool() : true;
'@ @'
        safeTinyMode_ = settings_ ? settings_->value(QStringLiteral("ui/safeTinyMode"), true).toBool() : true;
        proportionalMode_ = settings_ ? settings_->value(QStringLiteral("ui/proportionalMode"), true).toBool() : true;
'@ 'proportional setting load'

Replace-Required @'
            if (!widget->property(PROP_MIN_W).isValid()) {
                widget->setProperty(PROP_MIN_W, widget->minimumWidth());
                widget->setProperty(PROP_MIN_H, widget->minimumHeight());
            }

            QLayout *layout = widget->layout();
'@ @'
            if (!widget->property(PROP_MIN_W).isValid()) {
                widget->setProperty(PROP_MIN_W, widget->minimumWidth());
                widget->setProperty(PROP_MIN_H, widget->minimumHeight());
            }

            if (!widget->property(PROP_BASE_W).isValid()) {
                widget->setProperty(PROP_BASE_W, widget->width());
                widget->setProperty(PROP_BASE_H, widget->height());
            }

            if (auto *button = qobject_cast<QAbstractButton *>(widget)) {
                if (!button->property(PROP_ICON_W).isValid()) {
                    button->setProperty(PROP_ICON_W, button->iconSize().width());
                    button->setProperty(PROP_ICON_H, button->iconSize().height());
                }
            }

            QLayout *layout = widget->layout();
'@ 'capture actual and icon sizes'

Replace-Required @'
                widget->setMinimumSize(targetW, targetH);
            }

            QLayout *layout = widget->layout();
'@ @'
                widget->setMinimumSize(targetW, targetH);
            }

            if (auto *button = qobject_cast<QAbstractButton *>(widget)) {
                if (button->property(PROP_ICON_W).isValid()) {
                    const int baseIconW = button->property(PROP_ICON_W).toInt();
                    const int baseIconH = button->property(PROP_ICON_H).toInt();
                    if (baseIconW > 0 && baseIconH > 0)
                        button->setIconSize(QSize(qMax(1, ScaledLength(baseIconW, uiPercent)),
                                                  qMax(1, ScaledLength(baseIconH, uiPercent))));
                }
            }

            QLayout *layout = widget->layout();
'@ 'scale button icons'

Replace-Required @'
    QFont ScaledFont(int textPercent) const
'@ @'
    void ApplyProportionalDockGeometry(int uiPercent)
    {
        if (!proportionalMode_)
            return;

        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
        if (!mainWindow)
            return;

        QList<QDockWidget *> verticalDocks;
        QList<int> verticalSizes;
        QList<QDockWidget *> horizontalDocks;
        QList<int> horizontalSizes;

        const auto docks = mainWindow->findChildren<QDockWidget *>(QString(), Qt::FindDirectChildrenOnly);
        for (QDockWidget *dock : docks) {
            if (!dock || !dock->isVisible() || dock->isFloating() || !dock->property(PROP_BASE_W).isValid())
                continue;

            const int baseW = dock->property(PROP_BASE_W).toInt();
            const int baseH = dock->property(PROP_BASE_H).toInt();
            const Qt::DockWidgetArea area = mainWindow->dockWidgetArea(dock);

            if (area == Qt::BottomDockWidgetArea || area == Qt::TopDockWidgetArea) {
                verticalDocks.push_back(dock);
                verticalSizes.push_back(qMax(dock->minimumHeight(), ScaledLength(baseH, uiPercent)));
            } else if (area == Qt::LeftDockWidgetArea || area == Qt::RightDockWidgetArea) {
                horizontalDocks.push_back(dock);
                horizontalSizes.push_back(qMax(dock->minimumWidth(), ScaledLength(baseW, uiPercent)));
            }
        }

        if (!verticalDocks.isEmpty())
            mainWindow->resizeDocks(verticalDocks, verticalSizes, Qt::Vertical);
        if (!horizontalDocks.isEmpty())
            mainWindow->resizeDocks(horizontalDocks, horizontalSizes, Qt::Horizontal);
    }

    QFont ScaledFont(int textPercent) const
'@ 'proportional dock geometry helper'

Replace-Required @'
        const int requestedUi = qBound(1, requestedUiPercent, 1000);
        const int requestedText = qBound(1, requestedTextPercent, 1000);
        const int uiPercent = EffectiveUiPercent(requestedUi);
        const int textPercent = EffectiveTextPercent(requestedText);

        if (requestedUi == 100 && requestedText == 100) {
'@ @'
        const int requestedUi = qBound(1, requestedUiPercent, 1000);
        const int requestedText = qBound(1, requestedTextPercent, 1000);

        int uiPercent = EffectiveUiPercent(requestedUi);
        int textPercent = EffectiveTextPercent(requestedText);

        // Proportional mode is the "same as default, just smaller" mode. A single
        // scale is used for fonts, controls, icons, spacing, and dock-region size.
        // Safe tiny mode floors uniform scaling at 50%, because below that Qt's
        // native widget and font minimums stop behaving proportionally.
        if (proportionalMode_) {
            const int uniformPercent = safeTinyMode_ ? qMax(50, requestedUi) : requestedUi;
            uiPercent = uniformPercent;
            textPercent = uniformPercent;
        }

        if (requestedUi == 100 && (!proportionalMode_ ? requestedText == 100 : true)) {
'@ 'uniform proportional effective scale'

Replace-Required @'
        ApplyCapturedWidgetMetrics(uiPercent);

        currentUiPercent_ = uiPercent;
'@ @'
        ApplyCapturedWidgetMetrics(uiPercent);
        ApplyProportionalDockGeometry(uiPercent);

        currentUiPercent_ = uiPercent;
'@ 'apply dock geometry immediately'

Replace-Required @'
        QTimer::singleShot(0, this, [this]() { RefreshWidgets(); });
        QTimer::singleShot(120, this, [this]() { RefreshWidgets(); });
        QTimer::singleShot(450, this, [this]() { RefreshWidgets(); });
'@ @'
        QTimer::singleShot(0, this, [this, uiPercent]() {
            RefreshWidgets();
            ApplyProportionalDockGeometry(uiPercent);
        });
        QTimer::singleShot(120, this, [this, uiPercent]() {
            RefreshWidgets();
            ApplyProportionalDockGeometry(uiPercent);
        });
        QTimer::singleShot(450, this, [this, uiPercent]() {
            RefreshWidgets();
            ApplyProportionalDockGeometry(uiPercent);
        });
'@ 'keep dock geometry after layout refresh'

Replace-Required @'
        blog(LOG_INFO, "[%s] applied requested UI/text %d%%/%d%% (effective %d%%/%d%%, safe tiny=%d)",
             PLUGIN_NAME, requestedUi, requestedText, uiPercent, textPercent, safeTinyMode_ ? 1 : 0);
'@ @'
        blog(LOG_INFO, "[%s] applied requested UI/text %d%%/%d%% (effective %d%%/%d%%, proportional=%d, safe tiny=%d)",
             PLUGIN_NAME, requestedUi, requestedText, uiPercent, textPercent,
             proportionalMode_ ? 1 : 0, safeTinyMode_ ? 1 : 0);
'@ 'proportional logging'

Replace-Required @'
        QApplication::setFont(originalFont_);
        ApplyCapturedWidgetMetrics(100);
        currentUiPercent_ = 100;
'@ @'
        QApplication::setFont(originalFont_);
        ApplyCapturedWidgetMetrics(100);
        ApplyProportionalDockGeometry(100);
        currentUiPercent_ = 100;
'@ 'restore dock geometry'

Replace-Required 'dialog.setWindowTitle(QStringLiteral("OBS UI Scale v0.6"));' 'dialog.setWindowTitle(QStringLiteral("OBS UI Scale v0.7"));' 'dialog title'

Replace-Required @'
                           "v0.6 also makes button/field height follow the chosen text size, so large text is not clipped by a tiny UI value."),
'@ @'
                           "v0.7 adds proportional mode: OBS keeps the default proportions while fonts, controls, icons, spacing, and dock regions get smaller together."),
'@ 'dialog intro'

Replace-Required @'
        auto *safeTiny = new QCheckBox(
'@ @'
        auto *proportional = new QCheckBox(
            QStringLiteral("Proportional mode - same as default, just smaller (recommended)"), &dialog);
        proportional->setChecked(proportionalMode_);
        layout->addWidget(proportional);

        auto *safeTiny = new QCheckBox(
'@ 'proportional checkbox'

Replace-Required @'
        safeTiny->setChecked(safeTinyMode_);
        layout->addWidget(safeTiny);

        auto *autoApply = new QCheckBox(QStringLiteral("Apply these values automatically whenever OBS starts"), &dialog);
'@ @'
        safeTiny->setChecked(safeTinyMode_);
        layout->addWidget(safeTiny);

        auto syncTextEnabled = [proportional, uiSpin, textSpin]() {
            const bool linked = proportional->isChecked();
            textSpin->setEnabled(!linked);
            if (linked)
                textSpin->setValue(uiSpin->value());
        };
        QObject::connect(proportional, &QCheckBox::toggled, &dialog,
                         [syncTextEnabled](bool) mutable { syncTextEnabled(); });
        QObject::connect(uiSpin, qOverload<int>(&QSpinBox::valueChanged), &dialog,
                         [proportional, textSpin](int value) {
                             if (proportional->isChecked())
                                 textSpin->setValue(value);
                         });
        syncTextEnabled();

        auto *autoApply = new QCheckBox(QStringLiteral("Apply these values automatically whenever OBS starts"), &dialog);
'@ 'link text control in proportional mode'

Replace-Required @'
            QStringLiteral("Range: 1% to 1000% in 1% steps. Safe tiny mode now also makes controls tall enough for the selected text size, so UI 1% + Text 100% stays readable. "
'@ @'
            QStringLiteral("Range: 1% to 1000% in 1% steps. Proportional mode is the recommended way to get the default OBS layout uniformly smaller without the bottom docks being clipped. "
                           "With safe tiny mode on, proportional values 1-49% render at a stable 50% while keeping the requested value saved. "
'@ 'proportional note'

Replace-Required @'
                         [this, uiSpin, textSpin, safeTiny, autoApply, status]() {
                             safeTinyMode_ = safeTiny->isChecked();
'@ @'
                         [this, uiSpin, textSpin, proportional, safeTiny, autoApply, status]() {
                             proportionalMode_ = proportional->isChecked();
                             if (settings_)
                                 settings_->setValue(QStringLiteral("ui/proportionalMode"), proportionalMode_);
                             safeTinyMode_ = safeTiny->isChecked();
'@ 'save proportional on apply'

Replace-Required @'
                         [this, uiSpin, textSpin, safeTiny, autoApply, status]() {
                             safeTinyMode_ = safeTiny->isChecked();
'@ @'
                         [this, uiSpin, textSpin, proportional, safeTiny, autoApply, status]() {
                             proportionalMode_ = proportional->isChecked();
                             if (settings_)
                                 settings_->setValue(QStringLiteral("ui/proportionalMode"), proportionalMode_);
                             safeTinyMode_ = safeTiny->isChecked();
'@ 'save proportional on restore'

Replace-Required @'
    bool autoApply_ = true;
    bool safeTinyMode_ = true;
'@ @'
    bool autoApply_ = true;
    bool safeTinyMode_ = true;
    bool proportionalMode_ = true;
'@ 'proportional member'

Set-Content $path $s -Encoding utf8
Write-Host 'Prepared OBS UI Scale v0.7 proportional layout scaling.'
