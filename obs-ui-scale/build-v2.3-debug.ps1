$ErrorActionPreference = 'Stop'

# Diagnostic build based on v2.2. Do not add another layout workaround here.
# The goal is to record the exact Qt widget that changes size/minimum and the
# ordering around Apply and scene changes so the next fix can target the real
# cause with evidence from the user's machine.
& ./build-v2.2.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v2.3 debug patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "2.2.0";' 'static constexpr const char *PLUGIN_VERSION = "2.3.0-debug";' 'plugin version'

# Debug-only includes.
if (-not $s.Contains('#include <QDateTime>')) {
    $s = $s.Replace('#include <QDialogButtonBox>', "#include <QDateTime>`n#include <QDialogButtonBox>")
}
if (-not $s.Contains('#include <QFile>')) {
    $s = $s.Replace('#include <QFileInfo>', "#include <QFile>`n#include <QFileInfo>")
}
if (-not $s.Contains('#include <QStandardPaths>')) {
    $s = $s.Replace('#include <QSettings>', "#include <QSettings>`n#include <QStandardPaths>")
}

# Start a fresh Desktop log every OBS launch.
Replace-Required @'
    ObsUiScaleController()
    {
        char *configPath = obs_module_config_path("obs-ui-scale.ini");
'@ @'
    ObsUiScaleController()
    {
        InitializeDebugLog();
        DebugWrite(QStringLiteral("CONSTRUCTOR: OBS UI Scale debug controller starting"));

        char *configPath = obs_module_config_path("obs-ui-scale.ini");
'@ 'initialize debug log in constructor'

# Insert diagnostics before the v2.2 Audio Mixer helper block.
$insertMarker = '    QWidget *StackedMixerArea() const'
$insertPos = $s.IndexOf($insertMarker)
if ($insertPos -lt 0) { throw 'v2.3 debug could not locate StackedMixerArea helper' }

$helper = @'
    void InitializeDebugLog()
    {
        QString folder = QStandardPaths::writableLocation(QStandardPaths::DesktopLocation);
        if (folder.isEmpty())
            folder = QDir::homePath();

        debugLogPath_ = QDir(folder).filePath(QStringLiteral("OBS-UI-Scale-Debug.txt"));
        QFile file(debugLogPath_);
        if (file.open(QIODevice::WriteOnly | QIODevice::Truncate | QIODevice::Text)) {
            const QString header = QStringLiteral(
                "OBS UI Scale v2.3 DEBUG LOG\r\n"
                "Started: %1\r\n"
                "This file records only OBS/Qt UI geometry, scale values, event names, and scene names.\r\n"
                "Log path: %2\r\n"
                "============================================================\r\n")
                .arg(QDateTime::currentDateTime().toString(Qt::ISODateWithMs), debugLogPath_);
            file.write(header.toUtf8());
            file.flush();
        }
        blog(LOG_INFO, "[%s] debug log path: %s", PLUGIN_NAME, debugLogPath_.toUtf8().constData());
    }

    void DebugWrite(const QString &message)
    {
        if (debugLogPath_.isEmpty())
            return;

        QFile file(debugLogPath_);
        if (!file.open(QIODevice::WriteOnly | QIODevice::Append | QIODevice::Text))
            return;

        const QString line = QStringLiteral("[%1] %2\r\n")
                                 .arg(QDateTime::currentDateTime().toString(QStringLiteral("HH:mm:ss.zzz")), message);
        file.write(line.toUtf8());
        file.flush();
    }

    QString DebugSceneName() const
    {
        obs_source_t *scene = obs_frontend_get_current_scene();
        if (!scene)
            return QStringLiteral("<none>");
        const char *name = obs_source_get_name(scene);
        const QString result = name ? QString::fromUtf8(name) : QStringLiteral("<unnamed>");
        obs_source_release(scene);
        return result;
    }

    static QString DebugSize(const QSize &size)
    {
        return QStringLiteral("%1x%2").arg(size.width()).arg(size.height());
    }

    static QString DebugRect(const QRect &rect)
    {
        return QStringLiteral("%1,%2 %3x%4")
            .arg(rect.x()).arg(rect.y()).arg(rect.width()).arg(rect.height());
    }

    QString DebugWidgetSummary(QWidget *widget) const
    {
        if (!widget)
            return QStringLiteral("<null>");

        const QSize sizeHint = widget->sizeHint();
        const QSize minHint = widget->minimumSizeHint();
        const QSizePolicy policy = widget->sizePolicy();
        QString result = QStringLiteral(
            "%1 obj='%2' geom=[%3] size=%4 min=%5 max=%6 sizeHint=%7 minHint=%8 visible=%9 enabled=%10 policy=%11/%12")
            .arg(QString::fromLatin1(widget->metaObject()->className()),
                 widget->objectName(),
                 DebugRect(widget->geometry()),
                 DebugSize(widget->size()),
                 DebugSize(widget->minimumSize()),
                 DebugSize(widget->maximumSize()),
                 DebugSize(sizeHint),
                 DebugSize(minHint))
            .arg(widget->isVisible() ? 1 : 0)
            .arg(widget->isEnabled() ? 1 : 0)
            .arg(static_cast<int>(policy.horizontalPolicy()))
            .arg(static_cast<int>(policy.verticalPolicy()));

        if (QLayout *layout = widget->layout()) {
            result += QStringLiteral(" layoutMin=%1 layoutHint=%2 margins=%3,%4,%5,%6 spacing=%7")
                          .arg(DebugSize(layout->minimumSize()), DebugSize(layout->sizeHint()))
                          .arg(layout->contentsMargins().left())
                          .arg(layout->contentsMargins().top())
                          .arg(layout->contentsMargins().right())
                          .arg(layout->contentsMargins().bottom())
                          .arg(layout->spacing());
        }
        return result;
    }

    QDockWidget *DebugMixerDock() const
    {
        QWidget *mixer = StackedMixerArea();
        for (QWidget *w = mixer; w; w = w->parentWidget()) {
            if (auto *dock = qobject_cast<QDockWidget *>(w))
                return dock;
        }
        return nullptr;
    }

    QString DebugDockAreaName(Qt::DockWidgetArea area) const
    {
        switch (area) {
        case Qt::LeftDockWidgetArea: return QStringLiteral("Left");
        case Qt::RightDockWidgetArea: return QStringLiteral("Right");
        case Qt::TopDockWidgetArea: return QStringLiteral("Top");
        case Qt::BottomDockWidgetArea: return QStringLiteral("Bottom");
        default: return QStringLiteral("None");
        }
    }

    void DebugSnapshot(const QString &label)
    {
        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
        DebugWrite(QStringLiteral("========== SNAPSHOT %1 | scene='%2' | UI=%3 text=%4 ==========")
                       .arg(label, DebugSceneName())
                       .arg(currentUiPercent_, 0, 'f', 2)
                       .arg(currentTextPercent_, 0, 'f', 2));

        if (!mainWindow) {
            DebugWrite(QStringLiteral("MAIN WINDOW: <null>"));
            return;
        }

        DebugWrite(QStringLiteral("MAIN: %1").arg(DebugWidgetSummary(mainWindow)));

        QWidget *mixer = StackedMixerArea();
        DebugWrite(QStringLiteral("STACKED MIXER: %1 | targetMinH=%2")
                       .arg(DebugWidgetSummary(mixer))
                       .arg(mixerMinHeightTarget_));

        if (mixer) {
            int depth = 0;
            for (QWidget *p = mixer->parentWidget(); p && depth < 6; p = p->parentWidget(), ++depth)
                DebugWrite(QStringLiteral("MIXER PARENT[%1]: %2").arg(depth).arg(DebugWidgetSummary(p)));
        }

        QWidget *context = mainWindow->findChild<QWidget *>(QStringLiteral("contextContainer"),
                                                             Qt::FindChildrenRecursively);
        DebugWrite(QStringLiteral("CONTEXT: %1").arg(DebugWidgetSummary(context)));

        const auto docks = mainWindow->findChildren<QDockWidget *>(QString(), Qt::FindDirectChildrenOnly);
        for (QDockWidget *dock : docks) {
            if (!dock)
                continue;
            DebugWrite(QStringLiteral("DOCK area=%1 title='%2': %3")
                           .arg(DebugDockAreaName(mainWindow->dockWidgetArea(dock)), dock->windowTitle(),
                                DebugWidgetSummary(dock)));
        }
    }

    QString DebugEventName(QEvent::Type type) const
    {
        switch (type) {
        case QEvent::Resize: return QStringLiteral("Resize");
        case QEvent::Move: return QStringLiteral("Move");
        case QEvent::LayoutRequest: return QStringLiteral("LayoutRequest");
        case QEvent::Show: return QStringLiteral("Show");
        case QEvent::Hide: return QStringLiteral("Hide");
        case QEvent::Polish: return QStringLiteral("Polish");
        case QEvent::StyleChange: return QStringLiteral("StyleChange");
        case QEvent::FontChange: return QStringLiteral("FontChange");
        case QEvent::ChildAdded: return QStringLiteral("ChildAdded");
        case QEvent::ChildRemoved: return QStringLiteral("ChildRemoved");
        default: return QStringLiteral("Event%1").arg(static_cast<int>(type));
        }
    }

    bool DebugInterestingEvent(QEvent::Type type) const
    {
        return type == QEvent::Resize || type == QEvent::Move || type == QEvent::LayoutRequest ||
               type == QEvent::Show || type == QEvent::Hide || type == QEvent::Polish ||
               type == QEvent::StyleChange || type == QEvent::FontChange ||
               type == QEvent::ChildAdded || type == QEvent::ChildRemoved;
    }

    bool DebugTrackedWidget(QWidget *widget) const
    {
        if (!widget)
            return false;

        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
        if (widget == mainWindow || qobject_cast<QDockWidget *>(widget))
            return true;

        const QString name = widget->objectName();
        if (name == QStringLiteral("stackedMixerArea") ||
            name == QStringLiteral("hMixerScrollArea") ||
            name == QStringLiteral("vMixerScrollArea") ||
            name == QStringLiteral("hVolumeWidgets") ||
            name == QStringLiteral("vVolumeWidgets") ||
            name == QStringLiteral("contextContainer"))
            return true;

        QWidget *mixer = StackedMixerArea();
        for (QWidget *p = mixer; p; p = p->parentWidget()) {
            if (p == widget)
                return true;
        }
        return false;
    }

    void DebugWidgetEvent(QWidget *widget, QEvent::Type type)
    {
        DebugWrite(QStringLiteral("QT EVENT %1: %2")
                       .arg(DebugEventName(type), DebugWidgetSummary(widget)));

        if (!debugPostSnapshotQueued_) {
            debugPostSnapshotQueued_ = true;
            QTimer::singleShot(0, this, [this]() {
                debugPostSnapshotQueued_ = false;
                DebugSnapshot(QStringLiteral("post Qt-event batch"));
            });
        }
    }

    QString DebugFrontendEventName(enum obs_frontend_event event) const
    {
        switch (event) {
        case OBS_FRONTEND_EVENT_FINISHED_LOADING: return QStringLiteral("FINISHED_LOADING");
        case OBS_FRONTEND_EVENT_SCENE_CHANGED: return QStringLiteral("SCENE_CHANGED");
        case OBS_FRONTEND_EVENT_PREVIEW_SCENE_CHANGED: return QStringLiteral("PREVIEW_SCENE_CHANGED");
        case OBS_FRONTEND_EVENT_STUDIO_MODE_ENABLED: return QStringLiteral("STUDIO_MODE_ENABLED");
        case OBS_FRONTEND_EVENT_STUDIO_MODE_DISABLED: return QStringLiteral("STUDIO_MODE_DISABLED");
        case OBS_FRONTEND_EVENT_EXIT: return QStringLiteral("EXIT");
        default: return QStringLiteral("FRONTEND_%1").arg(static_cast<int>(event));
        }
    }

    void DebugFrontendEvent(enum obs_frontend_event event)
    {
        const QString eventName = DebugFrontendEventName(event);
        DebugWrite(QStringLiteral("FRONTEND EVENT %1 scene='%2'").arg(eventName, DebugSceneName()));

        if (event == OBS_FRONTEND_EVENT_SCENE_CHANGED ||
            event == OBS_FRONTEND_EVENT_PREVIEW_SCENE_CHANGED) {
            DebugSnapshot(QStringLiteral("scene event immediate"));
            const int delays[] = {0, 5, 15, 30, 60, 100, 180, 300, 500, 800, 1200};
            for (int delay : delays) {
                QTimer::singleShot(delay, this, [this, eventName, delay]() {
                    DebugSnapshot(QStringLiteral("%1 +%2ms").arg(eventName).arg(delay));
                });
            }
        }
    }

    void DebugScheduleApplySnapshots(const QString &prefix)
    {
        const int delays[] = {0, 5, 15, 35, 70, 100, 150, 220, 350, 500, 800, 1200};
        for (int delay : delays) {
            QTimer::singleShot(delay, this, [this, prefix, delay]() {
                DebugSnapshot(QStringLiteral("%1 +%2ms").arg(prefix).arg(delay));
            });
        }
    }

'@
$s = $s.Substring(0, $insertPos) + $helper + $s.Substring($insertPos)

# Log every frontend event before existing handling.
Replace-Required @'
        auto *self = static_cast<ObsUiScaleController *>(privateData);
        if (!self)
            return;

        if (event == OBS_FRONTEND_EVENT_FINISHED_LOADING) {
'@ @'
        auto *self = static_cast<ObsUiScaleController *>(privateData);
        if (!self)
            return;

        self->DebugFrontendEvent(event);

        if (event == OBS_FRONTEND_EVENT_FINISHED_LOADING) {
'@ 'frontend debug hook'

# Log Apply in detail without changing the scaling behavior.
Replace-Required @'
    void ApplyScale(double requestedUiPercent, double requestedTextPercent)
    {
        CaptureBaselineIfNeeded();
'@ @'
    void ApplyScale(double requestedUiPercent, double requestedTextPercent)
    {
        DebugWrite(QStringLiteral("APPLY START requested UI=%1 text=%2")
                       .arg(requestedUiPercent, 0, 'f', 2)
                       .arg(requestedTextPercent, 0, 'f', 2));
        DebugSnapshot(QStringLiteral("Apply BEFORE"));
        CaptureBaselineIfNeeded();
'@ 'apply start diagnostics'

Replace-Required @'
        blog(LOG_INFO, "[%s] applied requested UI/text %.2f%%/%.2f%% (effective %.2f%%/%.2f%%, proportional=%d, safe tiny=%d)",
             PLUGIN_NAME, requestedUi, requestedText, uiPercent, textPercent,
             proportionalMode_ ? 1 : 0, safeTinyMode_ ? 1 : 0);
'@ @'
        DebugWrite(QStringLiteral("APPLY IMMEDIATE COMPLETE effective UI=%1 text=%2")
                       .arg(uiPercent, 0, 'f', 2)
                       .arg(textPercent, 0, 'f', 2));
        DebugSnapshot(QStringLiteral("Apply immediate AFTER"));
        DebugScheduleApplySnapshots(QStringLiteral("Apply settle"));

        blog(LOG_INFO, "[%s] applied requested UI/text %.2f%%/%.2f%% (effective %.2f%%/%.2f%%, proportional=%d, safe tiny=%d)",
             PLUGIN_NAME, requestedUi, requestedText, uiPercent, textPercent,
             proportionalMode_ ? 1 : 0, safeTinyMode_ ? 1 : 0);
'@ 'apply completion diagnostics'

# Log the exact minimum target captured by v2.2 and every time it actually has to
# undo an OBS reset.
Replace-Required @'
        mixerMinHeightTarget_ = qMax(0, mixer->minimumHeight());
'@ @'
        mixerMinHeightTarget_ = qMax(0, mixer->minimumHeight());
        DebugWrite(QStringLiteral("MIXER TARGET CAPTURE minH=%1 current=%2 min=%3 sizeHint=%4 minHint=%5")
                       .arg(mixerMinHeightTarget_)
                       .arg(DebugSize(mixer->size()))
                       .arg(DebugSize(mixer->minimumSize()))
                       .arg(DebugSize(mixer->sizeHint()))
                       .arg(DebugSize(mixer->minimumSizeHint())));
'@ 'mixer target capture diagnostics'

Replace-Required @'
        if (mixer->minimumHeight() != mixerMinHeightTarget_) {
            mixer->setMinimumHeight(mixerMinHeightTarget_);
            mixer->updateGeometry();
        }
'@ @'
        if (mixer->minimumHeight() != mixerMinHeightTarget_) {
            const int before = mixer->minimumHeight();
            DebugWrite(QStringLiteral("MIXER MIN RESET DETECTED: before=%1 target=%2 | %3")
                           .arg(before)
                           .arg(mixerMinHeightTarget_)
                           .arg(DebugWidgetSummary(mixer)));
            mixer->setMinimumHeight(mixerMinHeightTarget_);
            mixer->updateGeometry();
            DebugWrite(QStringLiteral("MIXER MIN RESTORED: after=%1 | %2")
                           .arg(mixer->minimumHeight())
                           .arg(DebugWidgetSummary(mixer)));
        }
'@ 'mixer restore diagnostics'

# Extend the existing application event filter with tracked geometry events.
Replace-Required @'
    bool eventFilter(QObject *watched, QEvent *event) override
    {
        if (event && (event->type() == QEvent::Polish || event->type() == QEvent::Show)) {
'@ @'
    bool eventFilter(QObject *watched, QEvent *event) override
    {
        if (event && DebugInterestingEvent(event->type())) {
            if (auto *debugWidget = qobject_cast<QWidget *>(watched)) {
                if (DebugTrackedWidget(debugWidget))
                    DebugWidgetEvent(debugWidget, event->type());
            }
        }

        if (event && (event->type() == QEvent::Polish || event->type() == QEvent::Show)) {
'@ 'Qt event diagnostics'

# Make the dialog unmistakably diagnostic and tell the user where the log is.
Replace-Required 'dialog.setWindowTitle(QStringLiteral("OBS UI Scale v2.2"));' 'dialog.setWindowTitle(QStringLiteral("OBS UI Scale v2.3 DEBUG"));' 'debug dialog title'
Replace-Required @'
            QStringLiteral("v2.2 fixes OBS Audio Mixer's scene-change minimum-size reset directly. "
                           "The scaled mixer minimum is preserved without locking dock heights, so Apply stays put and manual dock dragging remains native."),
'@ @'
            QStringLiteral("v2.3 DEBUG keeps the v2.2 behavior and records detailed dock/mixer geometry while you reproduce the jump. "
                           "After reproducing it once, send the OBS-UI-Scale-Debug.txt file from your Desktop."),
'@ 'debug intro'

Replace-Required @'
        intro->setWordWrap(true);
        layout->addWidget(intro);
'@ @'
        intro->setWordWrap(true);
        layout->addWidget(intro);

        auto *debugPathLabel = new QLabel(QStringLiteral("Debug log: %1").arg(debugLogPath_), &dialog);
        debugPathLabel->setWordWrap(true);
        layout->addWidget(debugPathLabel);
'@ 'show debug log path'

# Debug state members.
Replace-Required @'
    bool contextScaleQueued_ = false;
    int mixerMinHeightTarget_ = -1;
'@ @'
    bool contextScaleQueued_ = false;
    int mixerMinHeightTarget_ = -1;
    QString debugLogPath_;
    bool debugPostSnapshotQueued_ = false;
'@ 'debug members'

Set-Content $path $s -Encoding utf8

# Installer branding/output for the diagnostic build.
$issPath = 'installer/ObsUiScale.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('2.2.0', '2.3.0')
$iss = $iss.Replace('OBS-UI-Scale-Setup-2.3.0', 'OBS-UI-Scale-Debug-Setup-2.3.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared OBS UI Scale v2.3 DEBUG geometry/event logger.'
