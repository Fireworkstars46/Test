$ErrorActionPreference = 'Stop'

# Start from v0.7, then fix submenu recursion and harden source-menu detection.
& ./build-v0.7.ps1

$pluginPath = "src/plugin-main.cpp"
$plugin = Get-Content $pluginPath -Raw
$plugin = $plugin.Replace('static constexpr const char *PLUGIN_VERSION = "0.7.0";', 'static constexpr const char *PLUGIN_VERSION = "0.8.0";')

$contextStartMarker = '    void MaybeAddSourceContextAction(QMenu *menu)'
$contextEndMarker = '    static void FrontendEvent(enum obs_frontend_event event, void *privateData)'
$contextStart = $plugin.IndexOf($contextStartMarker)
$contextEnd = $plugin.IndexOf($contextEndMarker, $contextStart)
if ($contextStart -lt 0 -or $contextEnd -lt 0) { throw "Could not locate v0.7 source context-menu function." }

$newContext = @'
    void MaybeAddSourceContextAction(QMenu *menu)
    {
        if (!menu || !sourceTree_)
            return;

        // Never process menus created by this plugin. This prevents the Visibility
        // submenu from being treated as another OBS source menu and recursively
        // generating Visibility -> Visibility -> Visibility forever.
        if (menu->property("sourceDockHideInternalMenu").toBool() ||
            menu->objectName() == QStringLiteral("sourceDockVisibilityMenu"))
            return;

        // A menu is handled once per popup instance.
        if (menu->property("sourceDockHideHandled").toBool())
            return;

        const QStringList selected = SelectedNames();
        if (selected.isEmpty())
            return;

        const auto actions = menu->actions();
        QAction *hideMixerAction = nullptr;
        bool hasAddSource = false;
        bool hasProperties = false;

        for (QAction *existingAction : actions) {
            if (!existingAction)
                continue;

            QString text = existingAction->text();
            text.remove(QLatin1Char('&'));

            if (text.compare(QStringLiteral("Add Source"), Qt::CaseInsensitive) == 0)
                hasAddSource = true;
            else if (text.compare(QStringLiteral("Properties"), Qt::CaseInsensitive) == 0)
                hasProperties = true;
            else if (text.compare(QStringLiteral("Hide in Mixer"), Qt::CaseInsensitive) == 0)
                hideMixerAction = existingAction;
        }

        // Only modify OBS's actual source-row context menu, not any of its submenus.
        // This still covers video, audio, capture cards, Source Clone, browser/media,
        // window/display capture, etc.
        if (!hasAddSource || !hasProperties || !hideMixerAction)
            return;

        menu->setProperty("sourceDockHideHandled", true);

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

        // Keep stock OBS top-level menu height: replace the existing Hide in Mixer
        // row with exactly one Visibility submenu row.
        auto *visibilityMenu = new QMenu(QStringLiteral("Visibility"), menu);
        visibilityMenu->setObjectName(QStringLiteral("sourceDockVisibilityMenu"));
        visibilityMenu->setProperty("sourceDockHideInternalMenu", true);
        QAction *visibilityMenuAction = visibilityMenu->menuAction();
        visibilityMenuAction->setObjectName(QStringLiteral("sourceDockVisibilityMenuAction"));

        menu->insertMenu(hideMixerAction, visibilityMenu);
        menu->removeAction(hideMixerAction);
        visibilityMenu->addAction(hideMixerAction);
        visibilityMenu->addAction(sourceHideAction);
    }

'@
$plugin = $plugin.Substring(0, $contextStart) + $newContext + $plugin.Substring($contextEnd)

# Mark the hidden-counter popup as internal as well, so the application-level
# event filter will always leave it alone.
$plugin = $plugin.Replace('        QMenu menu;\r\n        const QStringList hiddenNames = HiddenNames();', '        QMenu menu;\r\n        menu.setProperty("sourceDockHideInternalMenu", true);\r\n        const QStringList hiddenNames = HiddenNames();')
$plugin = $plugin.Replace('        QMenu menu;\n        const QStringList hiddenNames = HiddenNames();', '        QMenu menu;\n        menu.setProperty("sourceDockHideInternalMenu", true);\n        const QStringList hiddenNames = HiddenNames();')

Set-Content $pluginPath $plugin -Encoding utf8

$issPath = "installer/SourceDockHide.iss"
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace("0.7.0", "0.8.0")
Set-Content $issPath $iss -Encoding utf8
