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
#include <QGroupBox>
#include <QHBoxLayout>
#include <QLabel>
#include <QLayout>
#include <QMainWindow>
#include <QPointer>
#include <QProxyStyle>
#include <QPushButton>
#include <QSettings>
#include <QSizePolicy>
#include <QSpinBox>
#include <QStyleFactory>
#include <QStyleOption>
#include <QTimer>
#include <QVBoxLayout>
#include <QWidget>
#include <QtMath>

#include <memory>

OBS_DECLARE_MODULE()
OBS_MODULE_AUTHOR("OBS UI Scale community plugin")

static constexpr const char *PLUGIN_NAME = "OBS UI Scale";
static constexpr const char *PLUGIN_VERSION = "0.1.0";

const char *obs_module_description(void)
{
    return "Scales the OBS Studio Qt interface without changing Windows display scaling or requiring a special launcher.";
}

class ScaledProxyStyle final : public QProxyStyle {
public:
    ScaledProxyStyle(QStyle *baseStyle, double factor) : QProxyStyle(baseStyle), factor_(factor)
    {
        setObjectName(QStringLiteral("obsUiScaleProxyStyle"));
    }

    int pixelMetric(PixelMetric metric, const QStyleOption *option = nullptr,
                    const QWidget *widget = nullptr) const override
    {
        const int value = QProxyStyle::pixelMetric(metric, option, widget);
        if (value <= 0 || qFuzzyCompare(factor_, 1.0))
            return value;

        return qMax(1, qRound(static_cast<double>(value) * factor_));
    }

    int layoutSpacing(QSizePolicy::ControlType control1, QSizePolicy::ControlType control2,
                      Qt::Orientation orientation, const QStyleOption *option = nullptr,
                      const QWidget *widget = nullptr) const override
    {
        const int value = QProxyStyle::layoutSpacing(control1, control2, orientation, option, widget);
        if (value <= 0 || qFuzzyCompare(factor_, 1.0))
            return value;

        return qMax(1, qRound(static_cast<double>(value) * factor_));
    }

    double factor() const { return factor_; }

private:
    double factor_ = 1.0;
};

class ObsUiScaleController final : public QObject {
public:
    ObsUiScaleController()
    {
        originalFont_ = QApplication::font();
        styleKey_ = QApplication::style() ? QApplication::style()->objectName() : QString();
        if (styleKey_.isEmpty())
            styleKey_ = QStringLiteral("Fusion");

        char *configPath = obs_module_config_path("obs-ui-scale.ini");
        if (configPath) {
            const QString path = QString::fromUtf8(configPath);
            QFileInfo info(path);
            QDir().mkpath(info.absolutePath());
            settings_ = std::make_unique<QSettings>(path, QSettings::IniFormat);
            bfree(configPath);
        }

        percent_ = settings_ ? settings_->value(QStringLiteral("ui/percent"), 198).toInt() : 198;
        percent_ = qBound(100, percent_, 250);
        autoApply_ = settings_ ? settings_->value(QStringLiteral("ui/autoApply"), true).toBool() : true;

        toolsAction_ = static_cast<QAction *>(obs_frontend_add_tools_menu_qaction("OBS UI Scale..."));
        if (toolsAction_)
            QObject::connect(toolsAction_, &QAction::triggered, this, [this]() { ShowDialog(); });

        obs_frontend_add_event_callback(&ObsUiScaleController::FrontendEvent, this);

        // Apply once as soon as the plugin loads, then again after OBS announces that
        // the frontend is finished. This lets the user open OBS normally while still
        // making the saved scale take effect automatically.
        if (autoApply_) {
            QTimer::singleShot(0, this, [this]() { ApplyScale(percent_); });
            QTimer::singleShot(500, this, [this]() { ApplyScale(percent_); });
        }

        blog(LOG_INFO, "[%s] loaded v%s (saved scale %d%%)", PLUGIN_NAME, PLUGIN_VERSION, percent_);
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

        if (event == OBS_FRONTEND_EVENT_FINISHED_LOADING && self->autoApply_) {
            QTimer::singleShot(0, self, [self]() { self->ApplyScale(self->percent_); });
            QTimer::singleShot(350, self, [self]() { self->ApplyScale(self->percent_); });
        }
    }

    QStyle *CreateBaseStyle() const
    {
        QStyle *base = QStyleFactory::create(styleKey_);
        if (!base)
            base = QStyleFactory::create(QStringLiteral("Fusion"));
        return base;
    }

    QFont ScaledFont(int percent) const
    {
        QFont font = originalFont_;
        const double factor = static_cast<double>(percent) / 100.0;

        if (font.pointSizeF() > 0.0)
            font.setPointSizeF(font.pointSizeF() * factor);
        else if (font.pixelSize() > 0)
            font.setPixelSize(qMax(1, qRound(static_cast<double>(font.pixelSize()) * factor)));

        return font;
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

    void ApplyScale(int requestedPercent)
    {
        const int percent = qBound(100, requestedPercent, 250);
        const double factor = static_cast<double>(percent) / 100.0;

        if (percent == 100) {
            Restore100();
            currentPercent_ = 100;
            return;
        }

        QStyle *base = CreateBaseStyle();
        if (!base) {
            blog(LOG_WARNING, "[%s] could not create a Qt base style", PLUGIN_NAME);
            return;
        }

        QApplication::setStyle(new ScaledProxyStyle(base, factor));
        QApplication::setFont(ScaledFont(percent));
        currentPercent_ = percent;

        QTimer::singleShot(0, this, [this]() { RefreshWidgets(); });
        QTimer::singleShot(100, this, [this]() { RefreshWidgets(); });

        blog(LOG_INFO, "[%s] applied %d%% UI scale", PLUGIN_NAME, percent);
    }

    void Restore100()
    {
        QStyle *base = CreateBaseStyle();
        if (base)
            QApplication::setStyle(base);
        QApplication::setFont(originalFont_);
        currentPercent_ = 100;
        QTimer::singleShot(0, this, [this]() { RefreshWidgets(); });
    }

    void SaveSettings(int percent, bool autoApply)
    {
        percent_ = qBound(100, percent, 250);
        autoApply_ = autoApply;
        if (settings_) {
            settings_->setValue(QStringLiteral("ui/percent"), percent_);
            settings_->setValue(QStringLiteral("ui/autoApply"), autoApply_);
            settings_->sync();
        }
    }

    void ShowDialog()
    {
        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
        QDialog dialog(mainWindow);
        dialog.setWindowTitle(QStringLiteral("OBS UI Scale"));
        dialog.setModal(true);

        auto *layout = new QVBoxLayout(&dialog);

        auto *intro = new QLabel(
            QStringLiteral("Scale OBS itself while Windows, the taskbar, Start/Search, and other apps stay at their normal size."),
            &dialog);
        intro->setWordWrap(true);
        layout->addWidget(intro);

        auto *group = new QGroupBox(QStringLiteral("OBS interface scale"), &dialog);
        auto *groupLayout = new QVBoxLayout(group);

        auto *row = new QHBoxLayout();
        auto *label = new QLabel(QStringLiteral("Scale:"), group);
        auto *spin = new QSpinBox(group);
        spin->setRange(100, 250);
        spin->setSingleStep(1);
        spin->setSuffix(QStringLiteral("%"));
        spin->setValue(percent_);
        spin->setToolTip(QStringLiteral("198% is the starting value chosen for this setup."));
        row->addWidget(label);
        row->addWidget(spin);
        row->addStretch(1);
        groupLayout->addLayout(row);

        auto *autoApply = new QCheckBox(QStringLiteral("Apply this scale automatically whenever OBS starts"), group);
        autoApply->setChecked(autoApply_);
        groupLayout->addWidget(autoApply);

        auto *note = new QLabel(
            QStringLiteral("This is a Qt UI-style scale, so it changes OBS menus, docks, controls, text, spacing, and icons. "
                           "It does not change your canvas/output resolution. Some browser or third-party dock content may keep its own scale."),
            group);
        note->setWordWrap(true);
        groupLayout->addWidget(note);
        layout->addWidget(group);

        auto *status = new QLabel(QStringLiteral("Current OBS UI scale: %1%").arg(currentPercent_), &dialog);
        status->setWordWrap(true);
        layout->addWidget(status);

        auto *buttons = new QDialogButtonBox(&dialog);
        auto *apply = buttons->addButton(QStringLiteral("Apply"), QDialogButtonBox::ApplyRole);
        auto *restore = buttons->addButton(QStringLiteral("Restore 100%"), QDialogButtonBox::ResetRole);
        auto *close = buttons->addButton(QDialogButtonBox::Close);
        layout->addWidget(buttons);

        QObject::connect(apply, &QPushButton::clicked, &dialog, [this, spin, autoApply, status]() {
            SaveSettings(spin->value(), autoApply->isChecked());
            ApplyScale(percent_);
            status->setText(QStringLiteral("Current OBS UI scale: %1% (saved)").arg(currentPercent_));
        });

        QObject::connect(restore, &QPushButton::clicked, &dialog, [this, spin, autoApply, status]() {
            spin->setValue(100);
            SaveSettings(100, autoApply->isChecked());
            Restore100();
            status->setText(QStringLiteral("Current OBS UI scale: 100% (saved)"));
        });

        QObject::connect(close, &QPushButton::clicked, &dialog, &QDialog::accept);

        dialog.exec();
    }

    std::unique_ptr<QSettings> settings_;
    QAction *toolsAction_ = nullptr;
    QFont originalFont_;
    QString styleKey_;
    int percent_ = 198;
    int currentPercent_ = 100;
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
