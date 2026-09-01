$ErrorActionPreference = 'Stop'

# Start from v0.8 so we keep the fixed hidden counter menu and recursion protection.
& ./build-v0.8.ps1

$pluginPath = "src/plugin-main.cpp"
$plugin = Get-Content $pluginPath -Raw
$plugin = $plugin.Replace('static constexpr const char *PLUGIN_VERSION = "0.8.0";', 'static constexpr const char *PLUGIN_VERSION = "0.9.0";')

$contextStartMarker = '    void MaybeAddSourceContextAction(QMenu *menu)'
$contextEndMarker = '    static void FrontendEvent(enum obs_frontend_event event, void *privateData)'
$contextStart = $plugin.IndexOf($contextStartMarker)
$contextEnd = $plugin.IndexOf($contextEndMarker, $contextStart)
if ($contextStart -lt 0 -or $contextEnd -lt 0) { throw "Could not locate v0.8 source context-menu function." }

$newContext = @'
    void MaybeAddSourceContextAction(QMenu *menu)
    {
        if (!menu || !sourceTree_)
            return;

        // Ignore plugin-owned popup menus, and only handle each OBS source popup once.
        if (menu->property("sourceDockHideInternalMenu").toBool() ||
            menu->property("sourceDockHideHandled").toBool())
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

        // Only modify OBS's real source-row context menu. This covers all normal source
        // types: audio, capture cards, window/display capture, Source Clone, browser,
        // media, images, game capture, etc.
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

        // Keep OBS's original Hide in Mixer row and add Hide in Sources directly below it.
        // We do not force menu direction/position; Qt/OBS decides whether the popup opens
        // upward or downward based on the available screen space.
        QAction *before = nullptr;
        const int hideMixerIndex = actions.indexOf(hideMixerAction);
        if (hideMixerIndex >= 0 && hideMixerIndex + 1 < actions.size())
            before = actions.at(hideMixerIndex + 1);
        menu->insertAction(before, sourceHideAction);
    }

'@
$plugin = $plugin.Substring(0, $contextStart) + $newContext + $plugin.Substring($contextEnd)

Set-Content $pluginPath $plugin -Encoding utf8

$issPath = "installer/SourceDockHide.iss"
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace("0.8.0", "0.9.0")
Set-Content $issPath $iss -Encoding utf8
