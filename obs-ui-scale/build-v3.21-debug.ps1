$ErrorActionPreference = 'Stop'

# v3.21 DEBUG starts from v3.20 and fixes the remaining 1-row blocker.
# v3.20 relaxed sibling docks and removed the Scenes dock minimumSizeHint clamp,
# but the user's real OBS layout still stopped at about 4 visible rows. That means
# the remaining minimum is inside the Scenes dock content hierarchy itself
# (QListWidget/container/layout minimum hints), not another bottom-row dock.
#
# Relax only the vertical minimum/policy of the Scenes list and its parent content
# chain while the explicit scene-row minimum feature is enabled. Also remove the
# content layout's size constraint so Qt cannot rebuild a 4-row minimum from child
# size hints. Every original minimum/policy/layout constraint is restored when the
# feature is disabled. Re-apply the relaxation immediately after global UI metric
# scaling so Apply cannot briefly recreate the blocker. v3.20's real-Apply smooth
# guard and full combination matrix remain intact.
& ./build-v3.20-debug.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v3.21 debug patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "3.20.0-debug";' 'static constexpr const char *PLUGIN_VERSION = "3.21.0-debug";' 'plugin version'

Replace-Required @'
static constexpr const char *PROP_ROW_OLD_VPOLICY = "obsUiScaleRowOldVPolicy";
'@ @'
static constexpr const char *PROP_ROW_OLD_VPOLICY = "obsUiScaleRowOldVPolicy";
static constexpr const char *PROP_SCENE_OLD_MIN_H = "obsUiScaleSceneOldMinH";
static constexpr const char *PROP_SCENE_OLD_VPOLICY = "obsUiScaleSceneOldVPolicy";
static constexpr const char *PROP_SCENE_OLD_LAYOUT_CONSTRAINT = "obsUiScaleSceneOldLayoutConstraint";
'@ 'Scenes internal restoration properties'

# Insert internal Scenes helpers before the v3.20 sibling-dock helper.
$helperMarker = '    void RelaxBottomRowSiblingMinimums()'
$helperPos = $s.IndexOf($helperMarker)
if ($helperPos -lt 0) { throw 'v3.21 could not locate RelaxBottomRowSiblingMinimums insertion point' }
$helpers = @'
    void RelaxSceneDockInternalMinimums()
    {
        if (!sceneRowLockEnabled_)
            return;

        QDockWidget *dock = ScenesDock();
        QListWidget *scenes = ScenesList();
        if (!dock || !scenes)
            return;

        // Walk from the actual Scenes list through its content containers up to
        // (but not including) QDockWidget. QDockWidget itself keeps the explicit
        // row floor; only its internal content is allowed to compress to that floor.
        QWidget *w = scenes;
        while (w && w != dock) {
            if (!w->property(PROP_SCENE_OLD_MIN_H).isValid())
                w->setProperty(PROP_SCENE_OLD_MIN_H, w->minimumHeight());
            if (!w->property(PROP_SCENE_OLD_VPOLICY).isValid())
                w->setProperty(PROP_SCENE_OLD_VPOLICY,
                               static_cast<int>(w->sizePolicy().verticalPolicy()));

            w->setMinimumHeight(0);
            QSizePolicy policy = w->sizePolicy();
            policy.setVerticalPolicy(QSizePolicy::Ignored);
            w->setSizePolicy(policy);

            if (QLayout *layout = w->layout()) {
                if (!layout->property(PROP_SCENE_OLD_LAYOUT_CONSTRAINT).isValid())
                    layout->setProperty(PROP_SCENE_OLD_LAYOUT_CONSTRAINT,
                                        static_cast<int>(layout->sizeConstraint()));
                layout->setSizeConstraint(QLayout::SetNoConstraint);
                layout->invalidate();
                layout->activate();
            }
            w->updateGeometry();
            w = w->parentWidget();
        }

        // QAbstractScrollArea's viewport is not on the parent chain above, but a
        // stale viewport minimum can still feed the scroll area's minimum hint.
        if (QWidget *viewport = scenes->viewport()) {
            if (!viewport->property(PROP_SCENE_OLD_MIN_H).isValid())
                viewport->setProperty(PROP_SCENE_OLD_MIN_H, viewport->minimumHeight());
            if (!viewport->property(PROP_SCENE_OLD_VPOLICY).isValid())
                viewport->setProperty(PROP_SCENE_OLD_VPOLICY,
                                      static_cast<int>(viewport->sizePolicy().verticalPolicy()));
            viewport->setMinimumHeight(0);
            QSizePolicy policy = viewport->sizePolicy();
            policy.setVerticalPolicy(QSizePolicy::Ignored);
            viewport->setSizePolicy(policy);
            viewport->updateGeometry();
        }

        if (dock->widget())
            dock->widget()->updateGeometry();
        dock->updateGeometry();
    }

    void RestoreSceneDockInternalMinimums()
    {
        QDockWidget *dock = ScenesDock();
        QListWidget *scenes = ScenesList();
        if (!dock || !scenes)
            return;

        auto restoreWidget = [](QWidget *w) {
            if (!w)
                return;
            if (w->property(PROP_SCENE_OLD_MIN_H).isValid()) {
                w->setMinimumHeight(qMax(0, w->property(PROP_SCENE_OLD_MIN_H).toInt()));
                w->setProperty(PROP_SCENE_OLD_MIN_H, QVariant());
            }
            if (w->property(PROP_SCENE_OLD_VPOLICY).isValid()) {
                QSizePolicy policy = w->sizePolicy();
                policy.setVerticalPolicy(static_cast<QSizePolicy::Policy>(
                    w->property(PROP_SCENE_OLD_VPOLICY).toInt()));
                w->setSizePolicy(policy);
                w->setProperty(PROP_SCENE_OLD_VPOLICY, QVariant());
            }
            if (QLayout *layout = w->layout()) {
                if (layout->property(PROP_SCENE_OLD_LAYOUT_CONSTRAINT).isValid()) {
                    layout->setSizeConstraint(static_cast<QLayout::SizeConstraint>(
                        layout->property(PROP_SCENE_OLD_LAYOUT_CONSTRAINT).toInt()));
                    layout->setProperty(PROP_SCENE_OLD_LAYOUT_CONSTRAINT, QVariant());
                }
                layout->invalidate();
                layout->activate();
            }
            w->updateGeometry();
        };

        QWidget *w = scenes;
        while (w && w != dock) {
            QWidget *next = w->parentWidget();
            restoreWidget(w);
            w = next;
        }
        restoreWidget(scenes->viewport());
        dock->updateGeometry();
    }

    void LogSceneRowMinimumChain(const QString &tag)
    {
        QDockWidget *dock = ScenesDock();
        QListWidget *scenes = ScenesList();
        QWidget *content = dock ? dock->widget() : nullptr;
        QWidget *viewport = scenes ? scenes->viewport() : nullptr;
        DebugWrite(QStringLiteral(
            "ROW MIN CHAIN %1 dockH=%2 dockMin=%3 dockHint=%4 contentMin=%5 contentHint=%6 listMin=%7 listHint=%8 viewportMin=%9 viewportHint=%10 floor=%11 rows=%12 fullyVisible=%13")
                       .arg(tag)
                       .arg(dock ? dock->height() : -1)
                       .arg(dock ? dock->minimumHeight() : -1)
                       .arg(dock ? dock->minimumSizeHint().height() : -1)
                       .arg(content ? content->minimumHeight() : -1)
                       .arg(content ? content->minimumSizeHint().height() : -1)
                       .arg(scenes ? scenes->minimumHeight() : -1)
                       .arg(scenes ? scenes->minimumSizeHint().height() : -1)
                       .arg(viewport ? viewport->minimumHeight() : -1)
                       .arg(viewport ? viewport->minimumSizeHint().height() : -1)
                       .arg(lockedSceneDockHeight_)
                       .arg(sceneVisibleRows_)
                       .arg(CountFullyVisibleSceneRows()));
    }

'@
$s = $s.Substring(0, $helperPos) + $helpers.Replace("`r`n", "`n") + $s.Substring($helperPos)

# Whenever v3.20 relaxes sibling docks, also relax the Scenes dock's own internal
# content minimums. This covers row capture, reassertion and Scene-change repair.
$s = $s.Replace('        RelaxBottomRowSiblingMinimums();', "        RelaxBottomRowSiblingMinimums();`n        RelaxSceneDockInternalMinimums();")

# When the feature is disabled, restore both groups of original constraints.
Replace-Required @'
        if (!sceneRowLockEnabled_)
            RestoreBottomRowSiblingMinimums();
'@ @'
        if (!sceneRowLockEnabled_) {
            RestoreBottomRowSiblingMinimums();
            RestoreSceneDockInternalMinimums();
        }
'@ 'restore Scenes internal minima when row feature is disabled'

# Global ApplyCapturedWidgetMetrics() re-applies baseline minimum heights to every
# widget. Immediately undo only the Scenes-internal vertical minima while the row
# feature is enabled, before proportional dock geometry can use those stale hints.
Replace-Required @'
        ApplyCapturedWidgetMetrics(uiPercent);
'@ @'
        ApplyCapturedWidgetMetrics(uiPercent);
        if (sceneRowLockEnabled_) {
            RelaxBottomRowSiblingMinimums();
            RelaxSceneDockInternalMinimums();
        }
'@ 're-relax row blockers immediately after global metric scaling'

# Log the complete minimum chain after each row-floor capture so another blocker,
# if any, is visible immediately in the debug file instead of requiring guessing.
Replace-Required @'
        DebugWrite(QStringLiteral("SCENE ROW MINIMUM rows=%1 visualPitch=%2 sceneDockMinH=%3 mixerMinH=%4")
'@ @'
        LogSceneRowMinimumChain(QStringLiteral("POST-CAPTURE"));
        DebugWrite(QStringLiteral("SCENE ROW MINIMUM rows=%1 visualPitch=%2 sceneDockMinH=%3 mixerMinH=%4")
'@ 'log minimum chain after row capture'

# Make the 1-row preflight wait for the fully-relaxed hierarchy before deciding
# it failed. The existing physical row-count assertion remains authoritative.
$s = $s.Replace('OBS UI Scale v3.20 DEBUG LOG', 'OBS UI Scale v3.21 DEBUG LOG')
$s = $s.Replace('OBS UI Scale v3.20 DEBUG', 'OBS UI Scale v3.21 DEBUG')
$s = $s.Replace('OBS UI Scale v3.20 -', 'OBS UI Scale v3.21 -')

Set-Content $path $s -Encoding utf8

$issPath = 'installer/ObsUiScale.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('3.20.0', '3.21.0')
$iss = $iss.Replace('OBS-UI-Scale-Debug-Setup-3.21.0', 'OBS-UI-Scale-Debug-Setup-3.21.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared OBS UI Scale v3.21 DEBUG internal Scenes minimum + Apply smoothness build.'
