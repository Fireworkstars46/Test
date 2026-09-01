$ErrorActionPreference = 'Stop'

# Start from the working v0.6 transformation, then apply the v0.7 UI changes.
& ./build-v0.6.ps1

$pluginPath = "src/plugin-main.cpp"
$plugin = Get-Content $pluginPath -Raw
$plugin = $plugin.Replace('#include <QDialog>', "#include <QCursor>`r`n#include <QDialog>")
$plugin = $plugin.Replace('static constexpr const char *PLUGIN_VERSION = "0.6.0";', 'static constexpr const char *PLUGIN_VERSION = "0.7.0";')

# Restore a right-click menu on the bottom hidden counter.
$oldAccessible = '            hiddenCountButton_->setAccessibleName("Show or hide sources hidden from the Sources list");'
$newAccessible = @'
            hiddenCountButton_->setAccessibleName("Show or hide sources hidden from the Sources list");
            hiddenCountButton_->setContextMenuPolicy(Qt::CustomContextMenu);
            QObject::connect(hiddenCountButton_, &QWidget::customContextMenuRequested, this,
                             [this](const QPoint &) { ShowHiddenButtonMenu(); });
'@
if (-not $plugin.Contains($oldAccessible)) { throw "Could not locate hidden-counter setup." }
$plugin = $plugin.Replace($oldAccessible, $newAccessible.TrimEnd())

# Replace the source context-menu hook.  Instead of adding an extra top-level row,
# replace OBS's one "Hide in Mixer" row with one "Visibility" submenu.  This keeps
# long Window Capture menus the same top-level height as stock OBS.
$contextStartMarker = '    void MaybeAddSourceContextAction(QMenu *menu)'
$contextEndMarker = '    static void FrontendEvent(enum obs_frontend_event event, void *privateData)'
$contextStart = $plugin.IndexOf($contextStartMarker)
$contextEnd = $plugin.IndexOf($contextEndMarker, $contextStart)
if ($contextStart -lt 0 -or $contextEnd -lt 0) { throw "Could not locate v0.6 source context-menu function." }

$newContext = @'
    void MaybeAddSourceContextAction(QMenu *menu)
    {
        if (!menu || !sourceTree_)
            return;

        const QStringList selected = SelectedNames();
        if (selected.isEmpty())
            return;

        const auto actions = menu->actions();
        QAction *hideMixerAction = nullptr;
        for (QAction *existingAction : actions) {
            if (!existingAction)
                continue;

            if (existingAction->objectName() == QStringLiteral("sourceDockVisibilityMenuAction") ||
                existingAction->objectName() == QStringLiteral("sourceDockHideContextAction"))
                return;

            QString text = existingAction->text();
            text.remove(QLatin1Char('&'));
            if (text.compare(QStringLiteral("Hide in Mixer"), Qt::CaseInsensitive) == 0) {
                hideMixerAction = existingAction;
                break;
            }
        }

        // Only alter OBS's real source menu. Audio sources, capture cards, display/window
        // captures, clones, browser/media sources, etc. all use this source tree/menu path.
        if (!hideMixerAction)
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

        // Keep the top-level menu no taller than stock OBS: one Visibility row replaces
        // the original one Hide in Mixer row, with both choices inside the submenu.
        auto *visibilityMenu = new QMenu(QStringLiteral("Visibility"), menu);
        visibilityMenu->setObjectName(QStringLiteral("sourceDockVisibilityMenu"));
        QAction *visibilityMenuAction = visibilityMenu->menuAction();
        visibilityMenuAction->setObjectName(QStringLiteral("sourceDockVisibilityMenuAction"));

        menu->insertMenu(hideMixerAction, visibilityMenu);
        menu->removeAction(hideMixerAction);
        visibilityMenu->addAction(hideMixerAction);
        visibilityMenu->addAction(sourceHideAction);
    }

'@
$plugin = $plugin.Substring(0, $contextStart) + $newContext + $plugin.Substring($contextEnd)

# Replace the old hidden-counter right-click menu with direct per-source unhide + Unhide All.
$buttonMenuStartMarker = '    void ShowHiddenButtonMenu()'
$buttonMenuEndMarker = '    void ShowManager()'
$buttonMenuStart = $plugin.IndexOf($buttonMenuStartMarker)
$buttonMenuEnd = $plugin.IndexOf($buttonMenuEndMarker, $buttonMenuStart)
if ($buttonMenuStart -lt 0 -or $buttonMenuEnd -lt 0) { throw "Could not locate hidden-counter menu function." }

$newButtonMenu = @'
    void ShowHiddenButtonMenu()
    {
        if (!hiddenCountButton_)
            return;

        QMenu menu;
        const QStringList hiddenNames = HiddenNames();

        QMenu *unhideMenu = menu.addMenu(QStringLiteral("Unhide Source"));
        if (hiddenNames.isEmpty()) {
            QAction *none = unhideMenu->addAction(QStringLiteral("No hidden sources"));
            none->setEnabled(false);
        } else {
            for (const QString &name : hiddenNames) {
                QAction *item = unhideMenu->addAction(name);
                QObject::connect(item, &QAction::triggered, this, [this, name]() {
                    QStringList names = HiddenNames();
                    names.removeAll(name);
                    SaveHiddenNames(names);
                    if (names.isEmpty())
                        showHiddenRows_ = false;
                    ScheduleApply();
                });
            }
        }

        QAction *unhideAll = menu.addAction(QStringLiteral("Unhide All"));
        unhideAll->setEnabled(!hiddenNames.isEmpty());
        QObject::connect(unhideAll, &QAction::triggered, this, [this]() {
            SaveHiddenNames({});
            showHiddenRows_ = false;
            ScheduleApply();
        });

        menu.addSeparator();
        QAction *manage = menu.addAction(QStringLiteral("Manage Hidden Sources..."));
        QObject::connect(manage, &QAction::triggered, this, [this]() { ShowManager(); });

        menu.exec(QCursor::pos());
    }

'@
$plugin = $plugin.Substring(0, $buttonMenuStart) + $newButtonMenu + $plugin.Substring($buttonMenuEnd)

Set-Content $pluginPath $plugin -Encoding utf8

$issPath = "installer/SourceDockHide.iss"
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace("0.6.0", "0.7.0")
Set-Content $issPath $iss -Encoding utf8
