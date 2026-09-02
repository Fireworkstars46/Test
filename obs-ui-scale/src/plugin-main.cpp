#include <obs-module.h>
#include <obs-frontend-api.h>
#include <util/bmem.h>

#include <QAbstractButton>
#include <QAction>
#include <QApplication>
#include <QCheckBox>
#include <QDialog>
#include <QDialogButtonBox>
#include <QDir>
#include <QDockWidget>
#include <QDoubleSpinBox>
#include <QFileInfo>
#include <QFont>
#include <QFontMetrics>
#include <QHBoxLayout>
#include <QLabel>
#include <QLayout>
#include <QMainWindow>
#include <QPushButton>
#include <QRegularExpression>
#include <QSettings>
#include <QShortcut>
#include <QSize>
#include <QTimer>
#include <QVBoxLayout>
#include <QWidget>
#include <QtMath>

#include <memory>

OBS_DECLARE_MODULE()
OBS_MODULE_AUTHOR("OBS UI Scale community plugin")

static constexpr const char *PLUGIN_NAME = "OBS UI Scale";
static constexpr const char *PLUGIN_VERSION = "0.8.0";

static constexpr const char *PROP_MIN_W = "obsUiScaleBaseMinW";
static constexpr const char *PROP_MIN_H = "obsUiScaleBaseMinH";
static constexpr const char *PROP_BASE_W = "obsUiScaleBaseActualW";
static constexpr const char *PROP_BASE_H = "obsUiScaleBaseActualH";
static constexpr const char *PROP_ICON_W = "obsUiScaleBaseIconW";
static constexpr const char *PROP_ICON_H = "obsUiScaleBaseIconH";
static constexpr const char *PROP_LAYOUT_CAPTURED = "obsUiScaleLayoutCaptured";
static constexpr const char *PROP_LAYOUT_L = "obsUiScaleLayoutL";
static constexpr const char *PROP_LAYOUT_T = "obsUiScaleLayoutT";
static constexpr const char *PROP_LAYOUT_R = "obsUiScaleLayoutR";
static constexpr const char *PROP_LAYOUT_B = "obsUiScaleLayoutB";
static constexpr const char *PROP_LAYOUT_SPACING = "obsUiScaleLayoutSpacing";

const char *obs_module_description(void)
{
    return "Scales OBS Studio's Qt interface with separate fine-grained UI/control and text scaling, without changing Windows display scaling or requiring a launcher.";
}

class ObsUiScaleController final : public QObject {
public:
    ObsUiScaleController()
    {
        char *configPath = obs_module_config_path("obs-ui-scale.ini");
        if (configPath) {
            const QString path = QString::fromUtf8(configPath);
            QFileInfo info(path);
            QDir().mkpath(info.absolutePath());
            settings_ = std::make_unique<QSettings>(path, QSettings::IniFormat);
            bfree(configPath);
        }

        const double oldPercent = settings_ ? settings_->value(QStringLiteral("ui/percent"), 198.0).toDouble() : 198.0;
        uiPercent_ = settings_ ? settings_->value(QStringLiteral("ui/controlPercent"), oldPercent).toDouble() : oldPercent;
        textPercent_ = settings_ ? settings_->value(QStringLiteral("ui/textPercent"), oldPercent).toDouble() : oldPercent;
        uiPercent_ = qBound(1.0, uiPercent_, 1000.0);
        textPercent_ = qBound(1.0, textPercent_, 1000.0);
        autoApply_ = settings_ ? settings_->value(QStringLiteral("ui/autoApply"), true).toBool() : true;
        safeTinyMode_ = settings_ ? settings_->value(QStringLiteral("ui/safeTinyMode"), true).toBool() : true;
        proportionalMode_ = settings_ ? settings_->value(QStringLiteral("ui/proportionalMode"), true).toBool() : true;

        toolsAction_ = static_cast<QAction *>(obs_frontend_add_tools_menu_qaction("OBS UI Scale..."));
        if (toolsAction_)
            QObject::connect(toolsAction_, &QAction::triggered, this, [this]() { ShowDialog(); });

        obs_frontend_add_event_callback(&ObsUiScaleController::FrontendEvent, this);

        QTimer::singleShot(900, this, [this]() {
            CaptureBaselineIfNeeded();
            EnsureEmergencyShortcut();
            if (autoApply_)
                ApplyScale(uiPercent_, textPercent_);
        });

        blog(LOG_INFO, "[%s] loaded v%s (saved UI %.2f%%, text %.2f%%)",
             PLUGIN_NAME, PLUGIN_VERSION, uiPercent_, textPercent_);
    }

    ~ObsUiScaleController() override
    {
        obs_frontend_remove_event_callback(&ObsUiScaleController::FrontendEvent, this);
        Restore100();
        if (settings_)
            settings_->sync();
        blog(LOG_INFO, "[%s] unloaded", PLUGIN_NAME);
    }

private:
    double EffectiveUiPercent(double requested) const
    {
        requested = qBound(1.0, requested, 1000.0);
        if (!safeTinyMode_)
            return requested;
        return proportionalMode_ ? qMax(50.0, requested) : qMax(35.0, requested);
    }

    double EffectiveTextPercent(double requested) const
    {
        requested = qBound(1.0, requested, 1000.0);
        return safeTinyMode_ ? qMax(50.0, requested) : requested;
    }

    static void FrontendEvent(enum obs_frontend_event event, void *privateData)
    {
        auto *self = static_cast<ObsUiScaleController *>(privateData);
        if (!self)
            return;

        if (event == OBS_FRONTEND_EVENT_FINISHED_LOADING) {
            QTimer::singleShot(150, self, [self]() {
                self->CaptureBaselineIfNeeded();
                self->EnsureEmergencyShortcut();
                if (self->autoApply_)
                    self->ApplyScale(self->uiPercent_, self->textPercent_);
            });
        }
    }

    static int ScaledLength(int value, double percent)
    {
        if (value <= 0)
            return value;
        const double scaled = static_cast<double>(value) * percent / 100.0;
        if (scaled < 0.5)
            return 0;
        return qMax(1, qRound(scaled));
    }

    static QString PercentText(double value)
    {
        return QString::number(value, 'f', 2);
    }

    void CaptureBaselineIfNeeded()
    {
        if (baselineReady_)
            return;

        originalFont_ = qApp->font();
        originalStyleSheet_ = qApp->styleSheet();
        CaptureExistingWidgetMetrics();
        baselineReady_ = true;

        blog(LOG_INFO, "[%s] captured OBS Qt baseline (stylesheet chars=%d)",
             PLUGIN_NAME, originalStyleSheet_.size());
    }

    void CaptureExistingWidgetMetrics()
    {
        const auto widgets = qApp->allWidgets();
        for (QWidget *widget : widgets) {
            if (!widget)
                continue;

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
            if (!layout || layout->property(PROP_LAYOUT_CAPTURED).toBool())
                continue;

            const QMargins margins = layout->contentsMargins();
            layout->setProperty(PROP_LAYOUT_CAPTURED, true);
            layout->setProperty(PROP_LAYOUT_L, margins.left());
            layout->setProperty(PROP_LAYOUT_T, margins.top());
            layout->setProperty(PROP_LAYOUT_R, margins.right());
            layout->setProperty(PROP_LAYOUT_B, margins.bottom());
            layout->setProperty(PROP_LAYOUT_SPACING, layout->spacing());
        }
    }

    void ApplyCapturedWidgetMetrics(double uiPercent)
    {
        const auto widgets = qApp->allWidgets();
        for (QWidget *widget : widgets) {
            if (!widget)
                continue;

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
            if (!layout || !layout->property(PROP_LAYOUT_CAPTURED).toBool())
                continue;

            const int left = layout->property(PROP_LAYOUT_L).toInt();
            const int top = layout->property(PROP_LAYOUT_T).toInt();
            const int right = layout->property(PROP_LAYOUT_R).toInt();
            const int bottom = layout->property(PROP_LAYOUT_B).toInt();
            layout->setContentsMargins(ScaledLength(left, uiPercent), ScaledLength(top, uiPercent),
                                       ScaledLength(right, uiPercent), ScaledLength(bottom, uiPercent));

            const int spacing = layout->property(PROP_LAYOUT_SPACING).toInt();
            if (spacing >= 0)
                layout->setSpacing(ScaledLength(spacing, uiPercent));
        }
    }

    void ApplyProportionalDockGeometry(double uiPercent)
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

    QFont ScaledFont(double textPercent) const
    {
        QFont font = originalFont_;
        const double factor = textPercent / 100.0;

        if (font.pointSizeF() > 0.0)
            font.setPointSizeF(qMax(1.0, font.pointSizeF() * factor));
        else if (font.pixelSize() > 0)
            font.setPixelSize(qMax(1, qRound(static_cast<double>(font.pixelSize()) * factor)));

        return font;
    }

    QString TransformStyleSheet(const QString &source, double uiPercent, double textPercent) const
    {
        if (source.isEmpty())
            return source;

        const QRegularExpression numberUnit(QStringLiteral("(\\d+(?:\\.\\d+)?)\\s*(px|pt)"));
        QRegularExpressionMatchIterator iterator = numberUnit.globalMatch(source);

        QString out;
        out.reserve(source.size() + 2048);
        qsizetype last = 0;

        while (iterator.hasNext()) {
            const QRegularExpressionMatch match = iterator.next();
            out += source.mid(last, match.capturedStart() - last);

            const double originalValue = match.captured(1).toDouble();
            const QString unit = match.captured(2);

            qsizetype scan = match.capturedStart() - 1;
            while (scan >= 0) {
                const QChar c = source.at(scan);
                if (c == QLatin1Char(';') || c == QLatin1Char('{') || c == QLatin1Char('}'))
                    break;
                --scan;
            }
            const QString propertyText = source.mid(scan + 1, match.capturedStart() - scan - 1).toLower();
            const bool isFontValue = propertyText.contains(QStringLiteral("font"));
            const double percent = isFontValue ? textPercent : uiPercent;
            double scaled = originalValue * percent / 100.0;

            if (originalValue > 0.0) {
                if (isFontValue)
                    scaled = qMax(1.0, scaled);
                else if (scaled < 0.01)
                    scaled = 0.0;
            }

            if (qAbs(scaled - qRound(scaled)) < 0.001)
                out += QString::number(qRound(scaled));
            else
                out += QString::number(scaled, 'f', 2);
            out += unit;
            last = match.capturedEnd();
        }

        out += source.mid(last);
        return out;
    }

    QString BuildScaleOverrides(double uiPercent, double textPercent) const
    {
        const int menuV = qMax(1, ScaledLength(4, uiPercent));
        const int menuH = qMax(2, ScaledLength(18, uiPercent));
        const int barV = qMax(1, ScaledLength(3, uiPercent));
        const int barH = qMax(1, ScaledLength(7, uiPercent));
        const int buttonV = qMax(1, ScaledLength(4, uiPercent));
        const int buttonH = qMax(2, ScaledLength(8, uiPercent));
        const int itemV = qMax(1, ScaledLength(2, uiPercent));
        const int itemH = qMax(1, ScaledLength(4, uiPercent));

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
        if (basePoint <= 0.0)
            basePoint = 9.0;
        const double scaledPoint = qMax(1.0, basePoint * textPercent / 100.0);

        return QStringLiteral(
                   "\n/* OBS UI Scale v0.8 runtime overrides */\n"
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
    }

    void RefreshWidgets()
    {
        const auto widgets = qApp->allWidgets();
        for (QWidget *widget : widgets) {
            if (!widget)
                continue;
            if (QLayout *layout = widget->layout()) {
                layout->invalidate();
                layout->activate();
            }
            widget->updateGeometry();
            widget->update();
        }
    }

    void ApplyScale(double requestedUiPercent, double requestedTextPercent)
    {
        CaptureBaselineIfNeeded();

        const double requestedUi = qBound(1.0, requestedUiPercent, 1000.0);
        const double requestedText = qBound(1.0, requestedTextPercent, 1000.0);
        const double uiPercent = EffectiveUiPercent(requestedUi);
        const double textPercent = EffectiveTextPercent(requestedText);

        if (qAbs(requestedUi - 100.0) < 0.001 && qAbs(requestedText - 100.0) < 0.001) {
            Restore100();
            return;
        }

        QString scaledStyleSheet = TransformStyleSheet(originalStyleSheet_, uiPercent, textPercent);
        scaledStyleSheet += BuildScaleOverrides(uiPercent, textPercent);

        qApp->setStyleSheet(scaledStyleSheet);
        qApp->setFont(ScaledFont(textPercent));
        ApplyCapturedWidgetMetrics(uiPercent);
        ApplyProportionalDockGeometry(uiPercent);

        currentUiPercent_ = uiPercent;
        currentTextPercent_ = textPercent;

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

        blog(LOG_INFO, "[%s] applied requested UI/text %.2f%%/%.2f%% (effective %.2f%%/%.2f%%, proportional=%d, safe tiny=%d)",
             PLUGIN_NAME, requestedUi, requestedText, uiPercent, textPercent,
             proportionalMode_ ? 1 : 0, safeTinyMode_ ? 1 : 0);
    }

    void Restore100()
    {
        if (!baselineReady_)
            return;

        qApp->setStyleSheet(originalStyleSheet_);
        qApp->setFont(originalFont_);
        ApplyCapturedWidgetMetrics(100.0);
        ApplyProportionalDockGeometry(100.0);
        currentUiPercent_ = 100.0;
        currentTextPercent_ = 100.0;

        QTimer::singleShot(0, this, [this]() { RefreshWidgets(); });
        QTimer::singleShot(150, this, [this]() { RefreshWidgets(); });
    }

    void SaveSettings(double uiPercent, double textPercent, bool autoApply)
    {
        uiPercent_ = qBound(1.0, uiPercent, 1000.0);
        textPercent_ = qBound(1.0, textPercent, 1000.0);
        autoApply_ = autoApply;

        if (settings_) {
            settings_->setValue(QStringLiteral("ui/controlPercent"), uiPercent_);
            settings_->setValue(QStringLiteral("ui/textPercent"), textPercent_);
            settings_->setValue(QStringLiteral("ui/percent"), uiPercent_);
            settings_->setValue(QStringLiteral("ui/autoApply"), autoApply_);
            settings_->setValue(QStringLiteral("ui/safeTinyMode"), safeTinyMode_);
            settings_->setValue(QStringLiteral("ui/proportionalMode"), proportionalMode_);
            settings_->sync();
        }
    }

    void EmergencyReset()
    {
        SaveSettings(100.0, 100.0, autoApply_);
        Restore100();
        blog(LOG_INFO, "[%s] emergency reset to 100%%", PLUGIN_NAME);
    }

    void EnsureEmergencyShortcut()
    {
        if (resetShortcut_)
            return;

        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
        if (!mainWindow)
            return;

        resetShortcut_ = new QShortcut(QKeySequence(QStringLiteral("Ctrl+Alt+0")), mainWindow);
        resetShortcut_->setContext(Qt::ApplicationShortcut);
        QObject::connect(resetShortcut_, &QShortcut::activated, this, [this]() { EmergencyReset(); });
    }

    static QPushButton *AddPresetButton(QHBoxLayout *row, const QString &text, double value,
                                        QDoubleSpinBox *target, QWidget *parent)
    {
        auto *button = new QPushButton(text, parent);
        QObject::connect(button, &QPushButton::clicked, target, [target, value]() { target->setValue(value); });
        row->addWidget(button);
        return button;
    }

    static QDoubleSpinBox *MakeFineSpin(QWidget *parent, double value)
    {
        auto *spin = new QDoubleSpinBox(parent);
        spin->setRange(1.0, 1000.0);
        spin->setDecimals(2);
        spin->setSingleStep(0.25);
        spin->setSuffix(QStringLiteral("%"));
        spin->setValue(value);
        spin->setKeyboardTracking(false);
        return spin;
    }

    void ShowDialog()
    {
        CaptureBaselineIfNeeded();
        EnsureEmergencyShortcut();

        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
        QDialog dialog(mainWindow);
        dialog.setWindowTitle(QStringLiteral("OBS UI Scale v0.8"));
        dialog.setModal(true);
        dialog.resize(620, 430);

        auto *layout = new QVBoxLayout(&dialog);

        auto *intro = new QLabel(
            QStringLiteral("v0.8 keeps the improved proportional OBS layout from v0.7, but UI and text are independent again. "
                           "Both values now support hundredths of a percent; the arrow buttons move in 0.25% steps."),
            &dialog);
        intro->setWordWrap(true);
        layout->addWidget(intro);

        auto *uiRow = new QHBoxLayout();
        uiRow->addWidget(new QLabel(QStringLiteral("UI / controls:"), &dialog));
        auto *uiSpin = MakeFineSpin(&dialog, uiPercent_);
        uiRow->addWidget(uiSpin);
        uiRow->addWidget(new QLabel(QStringLiteral("(type e.g. 72.25%)"), &dialog));
        uiRow->addStretch(1);
        layout->addLayout(uiRow);

        auto *uiPresets = new QHBoxLayout();
        uiPresets->addWidget(new QLabel(QStringLiteral("UI presets:"), &dialog));
        for (double value : {25.0, 50.0, 75.0, 100.0, 150.0, 198.0, 200.0, 250.0})
            AddPresetButton(uiPresets, QString::number(value, 'f', 0), value, uiSpin, &dialog);
        uiPresets->addStretch(1);
        layout->addLayout(uiPresets);

        auto *textRow = new QHBoxLayout();
        textRow->addWidget(new QLabel(QStringLiteral("Text:"), &dialog));
        auto *textSpin = MakeFineSpin(&dialog, textPercent_);
        textRow->addWidget(textSpin);
        textRow->addWidget(new QLabel(QStringLiteral("(independent from UI)"), &dialog));
        textRow->addStretch(1);
        layout->addLayout(textRow);

        auto *textPresets = new QHBoxLayout();
        textPresets->addWidget(new QLabel(QStringLiteral("Text presets:"), &dialog));
        for (double value : {25.0, 50.0, 75.0, 100.0, 150.0, 198.0, 200.0, 250.0})
            AddPresetButton(textPresets, QString::number(value, 'f', 0), value, textSpin, &dialog);
        textPresets->addStretch(1);
        layout->addLayout(textPresets);

        auto *matchButton = new QPushButton(QStringLiteral("Match text to UI value"), &dialog);
        QObject::connect(matchButton, &QPushButton::clicked, &dialog,
                         [uiSpin, textSpin]() { textSpin->setValue(uiSpin->value()); });
        layout->addWidget(matchButton);

        auto *proportional = new QCheckBox(
            QStringLiteral("Keep default OBS dock proportions while UI size changes (recommended)"), &dialog);
        proportional->setChecked(proportionalMode_);
        layout->addWidget(proportional);

        auto *safeTiny = new QCheckBox(
            QStringLiteral("Keep extreme tiny values usable (recommended)"), &dialog);
        safeTiny->setChecked(safeTinyMode_);
        layout->addWidget(safeTiny);

        auto *autoApply = new QCheckBox(QStringLiteral("Apply these values automatically whenever OBS starts"), &dialog);
        autoApply->setChecked(autoApply_);
        layout->addWidget(autoApply);

        auto *note = new QLabel(
            QStringLiteral("Precision: you can type values to 0.01%, and the arrows use 0.25% steps. Theme values can therefore land on fractional px sizes, while actual Qt widget positions/heights still round to whole device-independent pixels when Qt requires it. "
                           "With safe tiny mode on, very low UI/text values use stability floors so OBS stays readable. Turn it off for raw extreme values. Ctrl+Alt+0 resets both to 100%."),
            &dialog);
        note->setWordWrap(true);
        layout->addWidget(note);

        auto *status = new QLabel(
            QStringLiteral("Current effective: UI %1% / Text %2%")
                .arg(PercentText(currentUiPercent_))
                .arg(PercentText(currentTextPercent_)), &dialog);
        status->setWordWrap(true);
        layout->addWidget(status);

        auto *buttons = new QDialogButtonBox(&dialog);
        auto *apply = buttons->addButton(QStringLiteral("Apply"), QDialogButtonBox::ApplyRole);
        auto *restore = buttons->addButton(QStringLiteral("Restore 100% / 100%"), QDialogButtonBox::ResetRole);
        auto *close = buttons->addButton(QDialogButtonBox::Close);
        layout->addWidget(buttons);

        QObject::connect(apply, &QPushButton::clicked, &dialog,
                         [this, uiSpin, textSpin, proportional, safeTiny, autoApply, status]() {
                             proportionalMode_ = proportional->isChecked();
                             safeTinyMode_ = safeTiny->isChecked();
                             SaveSettings(uiSpin->value(), textSpin->value(), autoApply->isChecked());
                             ApplyScale(uiPercent_, textPercent_);
                             status->setText(QStringLiteral("Current effective: UI %1% / Text %2% (saved)")
                                                 .arg(PercentText(currentUiPercent_))
                                                 .arg(PercentText(currentTextPercent_)));
                         });

        QObject::connect(restore, &QPushButton::clicked, &dialog,
                         [this, uiSpin, textSpin, proportional, safeTiny, autoApply, status]() {
                             proportionalMode_ = proportional->isChecked();
                             safeTinyMode_ = safeTiny->isChecked();
                             uiSpin->setValue(100.0);
                             textSpin->setValue(100.0);
                             SaveSettings(100.0, 100.0, autoApply->isChecked());
                             Restore100();
                             status->setText(QStringLiteral("Current effective: UI 100.00% / Text 100.00% (saved)"));
                         });

        QObject::connect(close, &QPushButton::clicked, &dialog, &QDialog::accept);
        dialog.exec();
    }

    std::unique_ptr<QSettings> settings_;
    QAction *toolsAction_ = nullptr;
    QShortcut *resetShortcut_ = nullptr;

    QFont originalFont_;
    QString originalStyleSheet_;
    bool baselineReady_ = false;

    double uiPercent_ = 198.0;
    double textPercent_ = 198.0;
    double currentUiPercent_ = 100.0;
    double currentTextPercent_ = 100.0;
    bool autoApply_ = true;
    bool safeTinyMode_ = true;
    bool proportionalMode_ = true;
};

static ObsUiScaleController *g_controller = nullptr;

bool obs_module_load(void)
{
    g_controller = new ObsUiScaleController();
    return true;
}

void obs_module_unload(void)
{
    delete g_controller;
    g_controller = nullptr;
}
