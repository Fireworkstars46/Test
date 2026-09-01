$ErrorActionPreference = 'Stop'

$pluginPath = "src/plugin-main.cpp"
$plugin = Get-Content $pluginPath -Raw
$plugin = $plugin.Replace("QABstractItemModel", "QAbstractItemModel")
$plugin = $plugin.Replace('#include <QToolButton>', "#include <QEvent>`r`n#include <QToolBar>`r`n#include <QToolButton>")
$plugin = $plugin.Replace('static constexpr const char *PLUGIN_VERSION = "0.4.0";', 'static constexpr const char *PLUGIN_VERSION = "0.6.0";')

$plugin = $plugin.Replace(
    '        obs_frontend_add_event_callback(&SourceDockHideController::FrontendEvent, this);',
    "        obs_frontend_add_event_callback(&SourceDockHideController::FrontendEvent, this);`r`n        if (qApp)`r`n            qApp->installEventFilter(this);")
$plugin = $plugin.Replace(
    '        obs_frontend_remove_event_callback(&SourceDockHideController::FrontendEvent, this);',
    "        if (qApp)`r`n            qApp->removeEventFilter(this);`r`n        obs_frontend_remove_event_callback(&SourceDockHideController::FrontendEvent, this);")

$startMarker = '    QBoxLayout *FindSourcesButtonLayout(QDockWidget *sourcesDock) const'
$endMarker = '    QString ItemName(const QModelIndex &index) const'
$start = $plugin.IndexOf($startMarker)
$end = $plugin.IndexOf($endMarker, $start)
if ($start -lt 0 -or $end -lt 0) { throw "Could not locate old toolbar-placement block." }

$toolbarReplacement = @'
    void EnsureHiddenCountButton()
    {
        if (!sourceTree_)
            return;

        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
        if (!mainWindow)
            return;

        QToolBar *sourcesToolbar = mainWindow->findChild<QToolBar *>("sourcesToolbar");
        if (!sourcesToolbar) {
            if (auto *sourcesDock = mainWindow->findChild<QDockWidget *>("sourcesDock"))
                sourcesToolbar = sourcesDock->findChild<QToolBar *>("sourcesToolbar");
        }
        if (!sourcesToolbar)
            return;

        if (!hiddenCountButton_) {
            hiddenCountButton_ = new QToolButton(sourcesToolbar);
            hiddenCountButton_->setObjectName("sourceDockHiddenCountButton");
            hiddenCountButton_->setText("0 hidden");
            hiddenCountButton_->setToolButtonStyle(Qt::ToolButtonTextOnly);
            hiddenCountButton_->setAutoRaise(true);
            hiddenCountButton_->setCheckable(true);
            hiddenCountButton_->setMinimumWidth(72);
            hiddenCountButton_->setToolTip("0 hidden sources");
            hiddenCountButton_->setAccessibleName("Show or hide sources hidden from the Sources list");

            QObject::connect(hiddenCountButton_, &QToolButton::clicked, this, [this]() {
                const int hiddenCount = HiddenCountInCurrentModel();
                if (hiddenCount <= 0) {
                    showHiddenRows_ = false;
                    UpdateHiddenCountButton();
                    return;
                }
                showHiddenRows_ = !showHiddenRows_;
                ScheduleApply();
            });

            sourcesToolbar->addWidget(hiddenCountButton_);
        } else if (hiddenCountButton_->parentWidget() != sourcesToolbar) {
            hiddenCountButton_->deleteLater();
            hiddenCountButton_.clear();
            QTimer::singleShot(0, this, [this]() {
                EnsureHiddenCountButton();
                UpdateHiddenCountButton();
            });
            return;
        }

        hiddenCountButton_->show();
    }

'@
$plugin = $plugin.Substring(0, $start) + $toolbarReplacement + $plugin.Substring($end)

$contextMarker = '    static void FrontendEvent(enum obs_frontend_event event, void *privateData)'
$contextPos = $plugin.IndexOf($contextMarker)
if ($contextPos -lt 0) { throw "Could not locate FrontendEvent insertion point." }

$contextCode = @'
    bool eventFilter(QObject *watched, QEvent *event) override
    {
        if (event && event->type() == QEvent::Show) {
            if (auto *menu = qobject_cast<QMenu *>(watched))
                MaybeAddSourceContextAction(menu);
        }
        return QObject::eventFilter(watched, event);
    }

    void MaybeAddSourceContextAction(QMenu *menu)
    {
        if (!menu || !sourceTree_)
            return;

        const QStringList selected = SelectedNames();
        if (selected.isEmpty())
            return;

        const auto actions = menu->actions();
        int hideMixerIndex = -1;
        for (int i = 0; i < actions.size(); ++i) {
            QAction *existingAction = actions.at(i);
            if (!existingAction)
                continue;

            if (existingAction->objectName() == QStringLiteral("sourceDockHideContextAction"))
                return;

            QString text = existingAction->text();
            text.remove(QLatin1Char('&'));
            if (text.compare(QStringLiteral("Hide in Mixer"), Qt::CaseInsensitive) == 0) {
                hideMixerIndex = i;
                break;
            }
        }

        if (hideMixerIndex < 0)
            return;

        QSet<QString> hidden;
        for (const QString &name : HiddenNames())
            hidden.insert(name);

        bool allSelectedAreHidden = true;
        for (const QString &name : selected) {
            if (!hidden.contains(name)) {
                allSelectedAreHidden = false;
                break;
            }
        }

        auto *sourceHideAction = new QAction(allSelectedAreHidden ? QStringLiteral("Unhide from Sources")
                                                                   : QStringLiteral("Hide in Sources"),
                                             menu);
        sourceHideAction->setObjectName(QStringLiteral("sourceDockHideContextAction"));

        if (allSelectedAreHidden) {
            QObject::connect(sourceHideAction, &QAction::triggered, this,
                             [this]() { UnhideSelectedRows(); });
        } else {
            QObject::connect(sourceHideAction, &QAction::triggered, this,
                             [this]() { HideSelectedRows(); });
        }

        QAction *before = (hideMixerIndex + 1 < actions.size()) ? actions.at(hideMixerIndex + 1) : nullptr;
        menu->insertAction(before, sourceHideAction);
    }

'@
$plugin = $plugin.Substring(0, $contextPos) + $contextCode + $plugin.Substring($contextPos)

$plugin = $plugin.Replace('"0 hidden sources\nRight-click to hide the currently selected source(s)"', '"0 hidden sources"')
$plugin = $plugin.Replace('Click to hide them again\nRight-click for options', 'Click to hide them again')
$plugin = $plugin.Replace('Click to show them temporarily\nRight-click for options', 'Click to show them temporarily')

Set-Content $pluginPath $plugin -Encoding utf8

$issPath = "installer/SourceDockHide.iss"
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace("0.4.0", "0.6.0")
Set-Content $issPath $iss -Encoding utf8
