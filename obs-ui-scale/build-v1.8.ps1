$ErrorActionPreference = 'Stop'

# Start from v1.7. The remaining vertical jump is not the dock row itself: OBS
# destroys/recreates the selected-source context toolbar (contextContainer /
# SourceToolbar) when a scene/source changes. Those late-created controls never
# existed during the original metric capture, so their stock 100% minimum sizes
# can push the whole dock area up/down after Apply.
#
# v1.8 scales ONLY newly-created context-toolbar widgets as they are polished/
# shown. It does not re-walk all of OBS and it no longer arms the scene dock-row
# resize guard. This makes the 78/78 layout remain where Apply left it.
& ./build-v1.7.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v1.8 patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "1.7.0";' 'static constexpr const char *PLUGIN_VERSION = "1.8.0";' 'plugin version'

# Watch Qt polish/show events so OBS's dynamically-created source context toolbar
# is scaled before it gets a chance to establish a stock 100% minimum height.
Replace-Required @'
        obs_frontend_add_event_callback(&ObsUiScaleController::FrontendEvent, this);

        QTimer::singleShot(900, this, [this]() {
'@ @'
        obs_frontend_add_event_callback(&ObsUiScaleController::FrontendEvent, this);
        if (qApp)
            qApp->installEventFilter(this);

        QTimer::singleShot(900, this, [this]() {
'@ 'install application event filter'

Replace-Required @'
        obs_frontend_remove_event_callback(&ObsUiScaleController::FrontendEvent, this);
        Restore100();
'@ @'
        if (qApp)
            qApp->removeEventFilter(this);
        obs_frontend_remove_event_callback(&ObsUiScaleController::FrontendEvent, this);
        Restore100();
'@ 'remove application event filter'

# Insert targeted context-toolbar metric capture/scaling before v1.6's old late
# widget helper. Existing widgets reuse the normal captured baseline properties;
# brand-new SourceToolbar children capture their own stock minimums/margins once.
$insertMarker = '    void ClearStableDockTargets()'
$insertPos = $s.IndexOf($insertMarker)
if ($insertPos -lt 0) { throw 'v1.8 could not locate helper insertion point' }

$helper = @'
    bool IsInsideContextContainer(QWidget *widget) const
    {
        for (QWidget *w = widget; w; w = w->parentWidget()) {
            if (w->objectName() == QStringLiteral("contextContainer"))
                return true;
        }
        return false;
    }

    void CaptureAndScaleContextWidget(QWidget *widget, double uiPercent)
    {
        if (!widget)
            return;

        if (!widget->property(PROP_MIN_W).isValid()) {
            widget->setProperty(PROP_MIN_W, widget->minimumWidth());
            widget->setProperty(PROP_MIN_H, widget->minimumHeight());
        }

        if (!widget->property(PROP_BASE_W).isValid()) {
            widget->setProperty(PROP_BASE_W, widget->width());
            widget->setProperty(PROP_BASE_H, widget->height());
        }

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
            if (!button->property(PROP_ICON_W).isValid()) {
                button->setProperty(PROP_ICON_W, button->iconSize().width());
                button->setProperty(PROP_ICON_H, button->iconSize().height());
            }
            const int baseIconW = button->property(PROP_ICON_W).toInt();
            const int baseIconH = button->property(PROP_ICON_H).toInt();
            if (baseIconW > 0 && baseIconH > 0) {
                button->setIconSize(QSize(qMax(1, ScaledLength(baseIconW, uiPercent)),
                                          qMax(1, ScaledLength(baseIconH, uiPercent))));
            }
        }

        QLayout *layout = widget->layout();
        if (layout) {
            if (!layout->property(PROP_LAYOUT_CAPTURED).toBool()) {
                const QMargins margins = layout->contentsMargins();
                layout->setProperty(PROP_LAYOUT_CAPTURED, true);
                layout->setProperty(PROP_LAYOUT_L, margins.left());
                layout->setProperty(PROP_LAYOUT_T, margins.top());
                layout->setProperty(PROP_LAYOUT_R, margins.right());
                layout->setProperty(PROP_LAYOUT_B, margins.bottom());
                layout->setProperty(PROP_LAYOUT_SPACING, layout->spacing());
            }

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

    void ScaleContextBarTree(double uiPercent)
    {
        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
        if (!mainWindow)
            return;

        QWidget *context = mainWindow->findChild<QWidget *>(QStringLiteral("contextContainer"),
                                                             Qt::FindChildrenRecursively);
        if (!context || !context->isVisible())
            return;

        CaptureAndScaleContextWidget(context, uiPercent);
        const auto children = context->findChildren<QWidget *>(QString(), Qt::FindChildrenRecursively);
        for (QWidget *child : children)
            CaptureAndScaleContextWidget(child, uiPercent);

        if (QLayout *layout = context->layout()) {
            layout->invalidate();
            layout->activate();
        }
        context->updateGeometry();
    }

    void ScheduleContextBarRescale(double uiPercent)
    {
        if (contextScaleQueued_)
            return;
        contextScaleQueued_ = true;

        // OBS queues UpdateContextBar(), then constructs a source-specific toolbar.
        // A few small targeted passes cover that lifecycle without touching the
        // rest of the interface or resizing the dock row.
        QTimer::singleShot(0, this, [this, uiPercent]() {
            contextScaleQueued_ = false;
            if (qAbs(currentUiPercent_ - uiPercent) < 0.01)
                ScaleContextBarTree(uiPercent);
        });
        const int delays[] = {20, 60, 140};
        for (int delay : delays) {
            QTimer::singleShot(delay, this, [this, uiPercent]() {
                if (qAbs(currentUiPercent_ - uiPercent) < 0.01)
                    ScaleContextBarTree(uiPercent);
            });
        }
    }

'@
$s = $s.Substring(0, $insertPos) + $helper + $s.Substring($insertPos)

# The old scene guard calls resizeDocks repeatedly. With the real cause now
# handled at contextContainer, those calls are what make the UI visibly move up
# and down. Scene changes now only scale the newly-created context toolbar.
Replace-Required @'
            // Preserve the exact compact dock-row height captured after Apply.
            // Do not rescan/repaint the whole OBS widget tree on a scene click.
            self->ArmSceneDockGuard();
'@ @'
            // OBS rebuilds contextContainer/SourceToolbar for the new selection.
            // Scale that small dynamic subtree only; do not resize the dock row.
            self->ScheduleContextBarRescale(self->currentUiPercent_);
'@ 'replace scene dock guard with context toolbar rescale'

# Scale whatever context toolbar exists during a normal Apply too. This is the
# state that should persist when the user subsequently clicks other scenes.
Replace-Required @'
        FitSourceDockHideCounter(uiPercent);
        ScheduleLatePluginWidgetFixes(uiPercent);

        if (mainWindow) {
'@ @'
        FitSourceDockHideCounter(uiPercent);
        ScheduleLatePluginWidgetFixes(uiPercent);
        ScheduleContextBarRescale(uiPercent);

        if (mainWindow) {
'@ 'scale context toolbar during Apply'

# Extend the existing event filter. Polish/Show happens before a newly-created
# SourceToolbar becomes visually established, so scale it immediately and avoid
# the one-frame height jump where possible. The old dock-guard branch remains
# harmless but is no longer armed by scene changes.
Replace-Required @'
    bool eventFilter(QObject *watched, QEvent *event) override
    {
        if (event && sceneDockGuardActive_ && !restoringDockTargets_ &&
            event->type() == QEvent::Resize) {
'@ @'
    bool eventFilter(QObject *watched, QEvent *event) override
    {
        if (event && (event->type() == QEvent::Polish || event->type() == QEvent::Show)) {
            if (auto *widget = qobject_cast<QWidget *>(watched)) {
                if (IsInsideContextContainer(widget) && currentUiPercent_ > 0.0) {
                    CaptureAndScaleContextWidget(widget, currentUiPercent_);
                }
            }
        }

        if (event && sceneDockGuardActive_ && !restoringDockTargets_ &&
            event->type() == QEvent::Resize) {
'@ 'target late context widgets in event filter'

Replace-Required 'dialog.setWindowTitle(QStringLiteral("OBS UI Scale v1.7"));' 'dialog.setWindowTitle(QStringLiteral("OBS UI Scale v1.8"));' 'dialog title'
Replace-Required @'
            QStringLiteral("v1.7 keeps the 78%-style proportional scaling and compact dock-row guard from v1.6. "
                           "Source Dock Hide now owns its counter width completely, so source selection cannot make UI Scale squeeze that button."),
'@ @'
            QStringLiteral("v1.8 keeps Source Dock Hide width ownership and fixes the remaining vertical jump. "
                           "OBS's dynamically rebuilt source context toolbar is scaled as it appears, so scene changes no longer undo the applied layout."),
'@ 'dialog intro'

Replace-Required @'
    bool sceneDockGuardActive_ = false;
    int sceneDockGuardGeneration_ = 0;
'@ @'
    bool sceneDockGuardActive_ = false;
    int sceneDockGuardGeneration_ = 0;
    bool contextScaleQueued_ = false;
'@ 'context scale queue member'

Set-Content $path $s -Encoding utf8

$issPath = 'installer/ObsUiScale.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('1.7.0', '1.8.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared OBS UI Scale v1.8 targeted dynamic context-toolbar scaling.'
