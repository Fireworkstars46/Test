#include <obs-module.h>
#include <obs-frontend-api.h>
#include <util/bmem.h>

#include <QAction>
#include <QApplication>
#include <QCheckBox>
#include <QDialog>
#include <QDialogButtonBox>
#include <QDir>
#include <QFileInfo>
#include <QFont>
#include <QHBoxLayout>
#include <QLabel>
#include <QLayout>
#include <QMainWindow>
#include <QPushButton>
#include <QRegularExpression>
#include <QSettings>
#include <QShortcut>
#include <QSpinBox>
#include <QTimer>
#include <QVBoxLayout>
#include <QWidget>
#include <QtMath>

#include <memory>

OBS_DECLARE_MODULE()
OBS_MODULE_AUTHOR("OBS UI Scale community plugin")

static constexpr const char *PLUGIN_NAME = "OBS UI Scale";
static constexpr const char *PLUGIN_VERSION = "0.3.0";

static constexpr const char *PROP_MIN_W = "obsUiScaleBaseMinW";
static constexpr const char *PROP_MIN_H = "obsUiScaleBaseMinH";
static constexpr const char *PROP_LAYOUT_CAPTURED = "obsUiScaleLayoutCaptured";
static constexpr const char *PROP_LAYOUT_L = "obsUiScaleLayoutL";
static constexpr const char *PROP_LAYOUT_T = "obsUiScaleLayoutT";
static constexpr const char *PROP_LAYOUT_R = "obsUiScaleLayoutR";
static constexpr const char *PROP_LAYOUT_B = "obsUiScaleLayoutB";
static constexpr const char *PROP_LAYOUT_SPACING = "obsUiScaleLayoutSpacing";

const char *obs_module_description(void)
{
    return "Scales OBS Studio's Qt interface with separate UI/control and text scaling, without changing Windows display scaling or requiring a launcher.";
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

        const int oldPercent = settings_ ? settings_->value(QStringLiteral("ui/percent"), 198).toInt() : 198;
        uiPercent_ = settings_ ? settings_->value(QStringLiteral("ui/controlPercent"), oldPercent).toInt() : oldPercent;
        textPercent_ = settings_ ? settings_->value(QStringLiteral("ui/textPercent"), oldPercent).toInt() : oldPercent;
        uiPercent_ = qBound(1, uiPercent_, 1000);
        textPercent_ = qBound(1, textPercent_, 1000);
        autoApply_ = settings_ ? settings_->value(QStringLiteral("ui/autoApply"), true).toBool() : true;

        toolsAction_ = static_cast<QAction *>(obs_frontend_add_tools_menu_qaction("OBS UI Scale..."));
        if (toolsAction_)
            QObject::connect(toolsAction_, &QAction::triggered, this, [this]() { ShowDialog(); });

        obs_frontend_add_event_callback(&ObsUiScaleController::FrontendEvent, this);

        // Do not capture/apply until OBS has had time to load its theme. Capturing the
        // finished theme is important because OBS uses Qt style sheets and they can
        // override a plain QApplication::setFont/QProxyStyle approach.
        QTimer::singleShot(900, this, [this]() {
            CaptureBaselineIfNeeded();
            EnsureEmergencyShortcut();
            if (autoApply_)
                ApplyScale(uiPercent_, textPercent_);
        });

        blog(LOG_INFO, "[%s] loaded v%s (saved UI %d%%, text %d%%)",
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

    static int ScaledLength(int value, int percent)
    {
        if (value <= 0)
            return value;
        const double scaled = static_cast<double>(value) * static_cast<double>(percent) / 100.0;
        if (scaled < 0.5)
            return 0;
        return qMax(1, qRound(scaled));
    }

    void CaptureBaselineIfNeeded()
    {
        if (baselineReady_)
            return;

        originalFont_ = QApplication::font();
        originalStyleSheet_ = QApplication::styleSheet();
        CaptureExistingWidgetMetrics();
        baselineReady_ = true;

        blog(LOG_INFO, "[%s] captured OBS Qt baseline (stylesheet chars=%d)",
             PLUGIN_NAME, originalStyleSheet_.size());
    }

    void CaptureExistingWidgetMetrics()
    {
        const auto widgets = QApplication::allWidgets();
        for (QWidget *widget : widgets) {
            if (!widget)
                continue;

            if (!widget->property(PROP_MIN_W).isValid()) {
                widget->setProperty(PROP_MIN_W, widget->minimumWidth());
                widget->setProperty(PROP_MIN_H, widget->minimumHeight());
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

    void ApplyCapturedWidgetMetrics(int uiPercent)
    {
        const auto widgets = QApplication::allWidgets();
        for (QWidget *widget : widgets) {
            if (!widget)
                continue;

            if (widget->property(PROP_MIN_W).isValid()) {
                const int baseW = widget->property(PROP_MIN_W).toInt();
                const int baseH = widget->property(PROP_MIN_H).toInt();
                widget->setMinimumSize(ScaledLength(baseW, uiPercent), ScaledLength(baseH, uiPercent));
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

    QFont ScaledFont(int textPercent) const
    {
        QFont font = originalFont_;
        const double factor = static_cast<double>(textPercent) / 100.0;

        if (font.pointSizeF() > 0.0)
            font.setPointSizeF(qMax(1.0, font.pointSizeF() * factor));
        else if (font.pixelSize() > 0)
            font.setPixelSize(qMax(1, qRound(static_cast<double>(font.pixelSize()) * factor)));

        return font;
    }

    QString TransformStyleSheet(const QString &source, int uiPercent, int textPercent) const
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

            // Determine the CSS/QSS property containing this numeric value. Font
            // declarations follow Text Scale; everything else follows UI/Control Scale.
            qsizetype scan = match.capturedStart() - 1;
            while (scan >= 0) {
                const QChar c = source.at(scan);
                if (c == QLatin1Char(';') || c == QLatin1Char('{') || c == QLatin1Char('}'))
                    break;
                --scan;
            }
            const QString propertyText = source.mid(scan + 1, match.capturedStart() - scan - 1).toLower();
            const bool isFontValue = propertyText.contains(QStringLiteral("font"));
            const int percent = isFontValue ? textPercent : uiPercent;
            double scaled = originalValue * static_cast<double>(percent) / 100.0;

            if (originalValue > 0.0) {
                if (isFontValue)
                    scaled = qMax(1.0, scaled);
                else if (scaled < 0.5)
                    scaled = 0.0;
            }

            if (qAbs(scaled - qRound(scaled)) < 0.01)
                out += QString::number(qRound(scaled));
            else
                out += QString::number(scaled, 'f', 1);
            out += unit;
            last = match.capturedEnd();
        }

        out += source.mid(last);
        return out;
    }

    QString BuildScaleOverrides(int uiPercent, int textPercent) const
    {
        const int menuV = ScaledLength(4, uiPercent);
        const int menuH = ScaledLength(18, uiPercent);
        const int barV = ScaledLength(3, uiPercent);
        const int barH = ScaledLength(7, uiPercent);
        const int buttonV = ScaledLength(4, uiPercent);
        const int buttonH = ScaledLength(8, uiPercent);
        const int itemV = ScaledLength(2, uiPercent);
        const int itemH = ScaledLength(4, uiPercent);

        double basePoint = originalFont_.pointSizeF();
        if (basePoint <= 0.0)
            basePoint = 9.0;
        const double scaledPoint = qMax(1.0, basePoint * static_cast<double>(textPercent) / 100.0);

        // These overrides cover widgets whose dimensions normally come from the
        // platform style instead of explicit px values in OBS's theme stylesheet.
        // They are deliberately geometry-only; OBS's colors/theme remain untouched.
        return QStringLiteral(
                   "\n/* OBS UI Scale v0.3 runtime overrides */\n"
                   "* { font-size: %1pt; }\n"
                   "QMenu::item { padding: %2px %3px; }\n"
                   "QMenuBar::item { padding: %4px %5px; }\n"
                   "QPushButton { padding: %6px %7px; }\n"
                   "QToolButton { padding: %6px %6px; }\n"
                   "QComboBox, QLineEdit, QSpinBox, QDoubleSpinBox { padding: %8px %9px; }\n"
                   "QAbstractItemView::item, QHeaderView::section { padding: %8px %9px; }\n"
                   "QTabBar::tab { padding: %6px %7px; }\n")
            .arg(QString::number(scaledPoint, 'f', 2))
            .arg(menuV)
            .arg(menuH)
            .arg(barV)
            .arg(barH)
            .arg(buttonV)
            .arg(buttonH)
            .arg(itemV)
            .arg(itemH);
    }

    void RefreshWidgets()
    {
        const auto widgets = QApplication::allWidgets();
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

    void ApplyScale(int requestedUiPercent, int requestedTextPercent)
    {
        CaptureBaselineIfNeeded();

        const int uiPercent = qBound(1, requestedUiPercent, 1000);
        const int textPercent = qBound(1, requestedTextPercent, 1000);

        if (uiPercent == 100 && textPercent == 100) {
            Restore100();
            return;
        }

        QString scaledStyleSheet = TransformStyleSheet(originalStyleSheet_, uiPercent, textPercent);
        scaledStyleSheet += BuildScaleOverrides(uiPercent, textPercent);

        QApplication::setStyleSheet(scaledStyleSheet);
        QApplication::setFont(ScaledFont(textPercent));
        ApplyCapturedWidgetMetrics(uiPercent);

        currentUiPercent_ = uiPercent;
        currentTextPercent_ = textPercent;

        QTimer::singleShot(0, this, [this]() { RefreshWidgets(); });
        QTimer::singleShot(120, this, [this]() { RefreshWidgets(); });
        QTimer::singleShot(450, this, [this]() { RefreshWidgets(); });

        blog(LOG_INFO, "[%s] applied UI/control %d%%, text %d%%", PLUGIN_NAME, uiPercent, textPercent);
    }

    void Restore100()
    {
        if (!baselineReady_)
            return;

        QApplication::setStyleSheet(originalStyleSheet_);
        QApplication::setFont(originalFont_);
        ApplyCapturedWidgetMetrics(100);
        currentUiPercent_ = 100;
        currentTextPercent_ = 100;

        QTimer::singleShot(0, this, [this]() { RefreshWidgets(); });
        QTimer::singleShot(150, this, [this]() { RefreshWidgets(); });
    }

    void SaveSettings(int uiPercent, int textPercent, bool autoApply)
    {
        uiPercent_ = qBound(1, uiPercent, 1000);
        textPercent_ = qBound(1, textPercent, 1000);
        autoApply_ = autoApply;

        if (settings_) {
            settings_->setValue(QStringLiteral("ui/controlPercent"), uiPercent_);
            settings_->setValue(QStringLiteral("ui/textPercent"), textPercent_);
            settings_->setValue(QStringLiteral("ui/percent"), uiPercent_); // compatibility with v0.1/v0.2
            settings_->setValue(QStringLiteral("ui/autoApply"), autoApply_);
            settings_->sync();
        }
    }

    void EmergencyReset()
    {
        SaveSettings(100, 100, autoApply_);
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

    static QPushButton *AddPresetButton(QHBoxLayout *row, const QString &text, int value,
                                        QSpinBox *target, QWidget *parent)
    {
        auto *button = new QPushButton(text, parent);
        QObject::connect(button, &QPushButton::clicked, target, [target, value]() { target->setValue(value); });
        row->addWidget(button);
        return button;
    }

    void ShowDialog()
    {
        CaptureBaselineIfNeeded();
        EnsureEmergencyShortcut();

        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
        QDialog dialog(mainWindow);
        dialog.setWindowTitle(QStringLiteral("OBS UI Scale v0.3"));
        dialog.setModal(true);
        dialog.resize(560, 360);

        auto *layout = new QVBoxLayout(&dialog);

        auto *intro = new QLabel(
            QStringLiteral("Scale OBS itself without changing Windows, your taskbar, or your OBS canvas/output resolution. "
                           "v0.3 separates control/layout size from text size and scales OBS's loaded Qt theme directly."),
            &dialog);
        intro->setWordWrap(true);
        layout->addWidget(intro);

        auto *uiRow = new QHBoxLayout();
        auto *uiLabel = new QLabel(QStringLiteral("UI / controls:"), &dialog);
        auto *uiSpin = new QSpinBox(&dialog);
        uiSpin->setRange(1, 1000);
        uiSpin->setSingleStep(1);
        uiSpin->setSuffix(QStringLiteral("%"));
        uiSpin->setValue(uiPercent_);
        uiRow->addWidget(uiLabel);
        uiRow->addWidget(uiSpin);
        uiRow->addStretch(1);
        layout->addLayout(uiRow);

        auto *uiPresets = new QHBoxLayout();
        uiPresets->addWidget(new QLabel(QStringLiteral("UI presets:"), &dialog));
        for (int value : {25, 50, 75, 100, 150, 198, 200, 250})
            AddPresetButton(uiPresets, QString::number(value), value, uiSpin, &dialog);
        uiPresets->addStretch(1);
        layout->addLayout(uiPresets);

        auto *textRow = new QHBoxLayout();
        auto *textLabel = new QLabel(QStringLiteral("Text:"), &dialog);
        auto *textSpin = new QSpinBox(&dialog);
        textSpin->setRange(1, 1000);
        textSpin->setSingleStep(1);
        textSpin->setSuffix(QStringLiteral("%"));
        textSpin->setValue(textPercent_);
        textRow->addWidget(textLabel);
        textRow->addWidget(textSpin);
        textRow->addStretch(1);
        layout->addLayout(textRow);

        auto *textPresets = new QHBoxLayout();
        textPresets->addWidget(new QLabel(QStringLiteral("Text presets:"), &dialog));
        for (int value : {25, 50, 75, 100, 150, 198, 200, 250})
            AddPresetButton(textPresets, QString::number(value), value, textSpin, &dialog);
        textPresets->addStretch(1);
        layout->addLayout(textPresets);

        auto *matchButton = new QPushButton(QStringLiteral("Match text to UI value"), &dialog);
        QObject::connect(matchButton, &QPushButton::clicked, &dialog,
                         [uiSpin, textSpin]() { textSpin->setValue(uiSpin->value()); });
        layout->addWidget(matchButton);

        auto *autoApply = new QCheckBox(QStringLiteral("Apply these values automatically whenever OBS starts"), &dialog);
        autoApply->setChecked(autoApply_);
        layout->addWidget(autoApply);

        auto *note = new QLabel(
            QStringLiteral("Range: 1% to 1000% in 1% steps. Very low/high values can make OBS hard to use. "
                           "Emergency reset: Ctrl+Alt+0 returns both values to 100%. The Windows title bar and embedded browser/third-party dock content may not follow this scale."),
            &dialog);
        note->setWordWrap(true);
        layout->addWidget(note);

        auto *status = new QLabel(
            QStringLiteral("Current: UI %1% / Text %2%").arg(currentUiPercent_).arg(currentTextPercent_), &dialog);
        status->setWordWrap(true);
        layout->addWidget(status);

        auto *buttons = new QDialogButtonBox(&dialog);
        auto *apply = buttons->addButton(QStringLiteral("Apply"), QDialogButtonBox::ApplyRole);
        auto *restore = buttons->addButton(QStringLiteral("Restore 100% / 100%"), QDialogButtonBox::ResetRole);
        auto *close = buttons->addButton(QDialogButtonBox::Close);
        layout->addWidget(buttons);

        QObject::connect(apply, &QPushButton::clicked, &dialog,
                         [this, uiSpin, textSpin, autoApply, status]() {
                             SaveSettings(uiSpin->value(), textSpin->value(), autoApply->isChecked());
                             ApplyScale(uiPercent_, textPercent_);
                             status->setText(QStringLiteral("Current: UI %1% / Text %2% (saved)")
                                                 .arg(currentUiPercent_)
                                                 .arg(currentTextPercent_));
                         });

        QObject::connect(restore, &QPushButton::clicked, &dialog,
                         [this, uiSpin, textSpin, autoApply, status]() {
                             uiSpin->setValue(100);
                             textSpin->setValue(100);
                             SaveSettings(100, 100, autoApply->isChecked());
                             Restore100();
                             status->setText(QStringLiteral("Current: UI 100% / Text 100% (saved)"));
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

    int uiPercent_ = 198;
    int textPercent_ = 198;
    int currentUiPercent_ = 100;
    int currentTextPercent_ = 100;
    bool autoApply_ = true;
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
