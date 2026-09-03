$ErrorActionPreference = 'Stop'

# v2.8 builds on v2.7. v2.7 now restores the correct compact layout after a
# Studio Mode preview scene switch, but the trace shows stackedMixerArea still
# briefly changes from the scaled height (156 at 78%) to OBS's stock 197 before
# the queued repair puts it back. That is the one-frame/short visual jump the
# user still sees.
#
# v2.8 adds an optional persistent scene-row lock. It calculates the bottom dock
# row from the actual SceneTree row height at the current scale, defaults to 6
# visible scene rows, and pins only the Scenes dock plus OBS's internal mixer
# stack. Because those constraints are already in force before OBS's deferred
# mixer relayout runs, the temporary jump is prevented rather than repaired
# afterward. The row count is recalculated after every scale change, so 6 rows
# means 6 rows at 50%, 78%, 100%, etc.
& ./build-v2.7-debug.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v2.8 debug patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "2.7.0-debug";' 'static constexpr const char *PLUGIN_VERSION = "2.8.0-debug";' 'plugin version'

if (-not $s.Contains('#include <QListWidget>')) {
    $s = $s.Replace('#include <QListView>', "#include <QListView>`n#include <QListWidget>")
    if (-not $s.Contains('#include <QListWidget>')) {
        $s = $s.Replace('#include <QMainWindow>', "#include <QListWidget>`n#include <QMainWindow>")
    }
}
if (-not $s.Contains('#include <QSpinBox>')) {
    $s = $s.Replace('#include <QStackedWidget>', "#include <QSpinBox>`n#include <QStackedWidget>")
}

# Persist the new setting. Existing v2.7 users receive the requested default:
# enabled, six visible scene rows.
Replace-Required @'
        debugLoggingEnabled_ = settings_ ? settings_->value(QStringLiteral("debug/loggingEnabled"), false).toBool() : false;
'@ @'
        debugLoggingEnabled_ = settings_ ? settings_->value(QStringLiteral("debug/loggingEnabled"), false).toBool() : false;
        sceneRowLockEnabled_ = settings_ ? settings_->value(QStringLiteral("ui/sceneRowLockEnabled"), true).toBool() : true;
        sceneVisibleRows_ = settings_ ? settings_->value(QStringLiteral("ui/sceneVisibleRows"), 6).toInt() : 6;
        sceneVisibleRows_ = qBound(1, sceneVisibleRows_, 30);
'@ 'load scene row lock settings'

# Insert the row-lock implementation immediately before the existing mixer
# helper. It deliberately uses runtime geometry instead of hard-coded pixels.
$insertMarker = '    QStackedWidget *StackedMixerArea() const'
$insertPos = $s.IndexOf($insertMarker)
if ($insertPos -lt 0) { throw 'v2.8 could not locate StackedMixerArea insertion point' }

$helper = @'
    QDockWidget *ScenesDock() const
    {
        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
        return mainWindow ? mainWindow->findChild<QDockWidget *>(QStringLiteral("scenesDock"),
                                                                  Qt::FindChildrenRecursively)
                          : nullptr;
    }

    QListWidget *ScenesList() const
    {
        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
        return mainWindow ? mainWindow->findChild<QListWidget *>(QStringLiteral("scenes"),
                                                                  Qt::FindChildrenRecursively)
                          : nullptr;
    }

    int CurrentSceneRowHeight() const
    {
        QListWidget *scenes = ScenesList();
        if (!scenes)
            return 0;

        for (int row = 0; row < scenes->count(); ++row) {
            const int h = scenes->sizeHintForRow(row);
            if (h > 0)
                return h;
        }

        return qMax(1, scenes->fontMetrics().height() + 4);
    }

    int CalculateSceneDockHeightForRows() const
    {
        QDockWidget *dock = ScenesDock();
        QListWidget *scenes = ScenesList();
        if (!dock || !scenes || sceneVisibleRows_ <= 0)
            return 0;

        const int rowHeight = CurrentSceneRowHeight();
        if (rowHeight <= 0)
            return 0;

        // Keep all real scaled chrome (dock title, toolbar, margins, list frame)
        // and replace only the scrolling viewport height with N full rows.
        const int outsideList = qMax(0, dock->height() - scenes->height());
        const int listChrome = scenes->viewport() ? qMax(0, scenes->height() - scenes->viewport()->height()) : 0;
        int target = outsideList + listChrome + rowHeight * sceneVisibleRows_;
        target = qMax(target, dock->minimumSizeHint().height());
        return qMax(1, target);
    }

    void ReleaseSceneRowLockConstraints()
    {
        sceneRowLockApplying_ = true;

        if (QDockWidget *dock = ScenesDock()) {
            dock->setMaximumHeight(QWIDGETSIZE_MAX);
            dock->setMinimumHeight(0);
        }

        if (QStackedWidget *mixer = StackedMixerArea()) {
            mixer->setMaximumHeight(QWIDGETSIZE_MAX);
            mixer->setMinimumHeight(0);
        }

        lockedSceneDockHeight_ = 0;
        lockedMixerHeight_ = 0;
        sceneRowLockApplying_ = false;
    }

    void ReassertSceneRowLock()
    {
        if (!sceneRowLockEnabled_ || lockedSceneDockHeight_ <= 0 || lockedMixerHeight_ <= 0 ||
            sceneRowLockApplying_)
            return;

        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
        QDockWidget *sceneDock = ScenesDock();
        QStackedWidget *mixer = StackedMixerArea();
        if (!mainWindow || !sceneDock || !mixer)
            return;

        sceneRowLockApplying_ = true;

        // Lower minimum first in case OBS just tried to restore its 100% mixer
        // minimum, then restore the fixed target. This runs synchronously from
        // the resize filter, before the next paint, so there is no visible jump.
        mixer->setMinimumHeight(lockedMixerHeight_);
        mixer->setMaximumHeight(lockedMixerHeight_);
        if (mixer->height() != lockedMixerHeight_)
            mixer->resize(mixer->width(), lockedMixerHeight_);

        sceneDock->setMinimumHeight(lockedSceneDockHeight_);
        sceneDock->setMaximumHeight(lockedSceneDockHeight_);

        if (qAbs(sceneDock->height() - lockedSceneDockHeight_) > 1)
            mainWindow->resizeDocks({sceneDock}, {lockedSceneDockHeight_}, Qt::Vertical);

        sceneRowLockApplying_ = false;
    }

    void CaptureAndApplySceneRowLock()
    {
        if (!sceneRowLockEnabled_) {
            ReleaseSceneRowLockConstraints();
            return;
        }

        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
        QDockWidget *sceneDock = ScenesDock();
        QStackedWidget *mixer = StackedMixerArea();
        if (!mainWindow || !sceneDock || !mixer)
            return;

        // Calculate from an unconstrained settled layout so changing scale or
        // changing 6 -> 7 rows cannot inherit the previous fixed pixel height.
        sceneRowLockApplying_ = true;
        sceneDock->setMaximumHeight(QWIDGETSIZE_MAX);
        sceneDock->setMinimumHeight(0);
        mixer->setMaximumHeight(QWIDGETSIZE_MAX);
        mixer->setMinimumHeight(0);
        sceneRowLockApplying_ = false;

        const int currentDockHeight = sceneDock->height();
        const int currentMixerHeight = mixer->height();
        const int targetDockHeight = CalculateSceneDockHeightForRows();
        if (currentDockHeight <= 0 || currentMixerHeight <= 0 || targetDockHeight <= 0)
            return;

        const int delta = targetDockHeight - currentDockHeight;
        lockedSceneDockHeight_ = targetDockHeight;
        lockedMixerHeight_ = qMax(1, currentMixerHeight + delta);

        // v2.7's later mixer restore passes must agree with the row lock rather
        // than trying to restore the older pre-lock target.
        mixerMinHeightTarget_ = lockedMixerHeight_;

        sceneDock->installEventFilter(this);
        mixer->installEventFilter(this);
        ReassertSceneRowLock();

        // Ask QMainWindow once with the final target so all sibling docks in the
        // same bottom row settle to the same boundary. We do not permanently
        // cap the custom sibling docks themselves.
        mainWindow->resizeDocks({sceneDock}, {lockedSceneDockHeight_}, Qt::Vertical);
        ReassertSceneRowLock();

        DebugWrite(QStringLiteral("SCENE ROW LOCK captured rows=%1 rowH=%2 sceneDockH=%3 mixerH=%4")
                       .arg(sceneVisibleRows_)
                       .arg(CurrentSceneRowHeight())
                       .arg(lockedSceneDockHeight_)
                       .arg(lockedMixerHeight_));
    }

    void ScheduleSceneRowLockCapture(double uiPercent)
    {
        const int delays[] = {80, 220, 520};
        for (int delay : delays) {
            QTimer::singleShot(delay, this, [this, uiPercent]() {
                if (qAbs(currentUiPercent_ - uiPercent) < 0.01)
                    CaptureAndApplySceneRowLock();
            });
        }
    }

'@
$s = $s.Substring(0, $insertPos) + $helper + $s.Substring($insertPos)

# Release the old fixed pixel target before every scale operation. The new row
# count target is captured after the scaled widgets have settled.
Replace-Required @'
    void ApplyScale(double requestedUiPercent, double requestedTextPercent)
    {
        DebugWrite(QStringLiteral("APPLY START requested UI=%1 text=%2")
'@ @'
    void ApplyScale(double requestedUiPercent, double requestedTextPercent)
    {
        ReleaseSceneRowLockConstraints();
        DebugWrite(QStringLiteral("APPLY START requested UI=%1 text=%2")
'@ 'release row lock before Apply'

# Capture the row-count target after the normal mixer target has been captured.
Replace-Required @'
        ScheduleMixerTargetCapture(uiPercent);
'@ @'
        ScheduleMixerTargetCapture(uiPercent);
        ScheduleSceneRowLockCapture(uiPercent);
'@ 'schedule scene row lock after Apply'

# Restore 100% should still honor the user's scene-row preference ("any scale").
Replace-Required @'
    void Restore100()
    {
        if (!baselineReady_)
            return;
'@ @'
    void Restore100()
    {
        if (!baselineReady_)
            return;

        ReleaseSceneRowLockConstraints();
'@ 'release row lock before Restore100'

# Schedule a fresh 100% row calculation after the stock restore settles.
$restoreStart = $s.IndexOf('    void Restore100()')
if ($restoreStart -lt 0) { throw 'v2.8 could not locate Restore100' }
$saveSettingsMarker = '    void SaveSettings('
$restoreEnd = $s.IndexOf($saveSettingsMarker, $restoreStart)
if ($restoreEnd -lt 0) { throw 'v2.8 could not locate end of Restore100' }
$restoreBlock = $s.Substring($restoreStart, $restoreEnd - $restoreStart)
if (-not $restoreBlock.Contains('ScheduleSceneRowLockCapture(100.0);')) {
    $lastBrace = $restoreBlock.LastIndexOf("    }`n`n")
    if ($lastBrace -lt 0) { throw 'v2.8 could not locate Restore100 closing brace' }
    $restoreBlock = $restoreBlock.Substring(0, $lastBrace) + "        ScheduleSceneRowLockCapture(100.0);`n" + $restoreBlock.Substring($lastBrace)
    $s = $s.Substring(0, $restoreStart) + $restoreBlock + $s.Substring($restoreEnd)
}

# Every v2.7 mixer-repair pass also reasserts the persistent lock. The fixed
# constraint is already active before OBS's queued mixer update and the event
# filter below handles any resize synchronously, so the former 30ms flash does
# not reach a paint.
Replace-Required @'
                if (qAbs(currentUiPercent_ - uiPercent) < 0.01) {
                    RestoreMixerMinimumTarget();
                    RestoreStableDockTargets();
                }
'@ @'
                if (qAbs(currentUiPercent_ - uiPercent) < 0.01) {
                    ReassertSceneRowLock();
                    RestoreMixerMinimumTarget();
                    ReassertSceneRowLock();
                    RestoreStableDockTargets();
                    ReassertSceneRowLock();
                }
'@ 'reassert row lock during mixer restore passes'

# Catch OBS's attempted mixer/dock resize in the same event turn, before the
# screen repaints. This is what removes the visible temporary up/down movement.
Replace-Required @'
    bool eventFilter(QObject *watched, QEvent *event) override
    {
'@ @'
    bool eventFilter(QObject *watched, QEvent *event) override
    {
        if (sceneRowLockEnabled_ && !sceneRowLockApplying_ && event &&
            (event->type() == QEvent::Resize || event->type() == QEvent::LayoutRequest ||
             event->type() == QEvent::Show)) {
            if (watched == ScenesDock() || watched == StackedMixerArea())
                ReassertSceneRowLock();
        }

'@ 'synchronous row lock event filter'

# Save the two new settings with the existing scale settings.
Replace-Required @'
            settings_->setValue(QStringLiteral("ui/proportionalMode"), proportionalMode_);
            settings_->sync();
'@ @'
            settings_->setValue(QStringLiteral("ui/proportionalMode"), proportionalMode_);
            settings_->setValue(QStringLiteral("ui/sceneRowLockEnabled"), sceneRowLockEnabled_);
            settings_->setValue(QStringLiteral("ui/sceneVisibleRows"), sceneVisibleRows_);
            settings_->sync();
'@ 'persist scene row settings'

# Dialog control: checkbox + exact visible row count. Default is 6, as requested.
Replace-Required @'
        auto *uiRow = new QHBoxLayout();
'@ @'
        auto *sceneRowLayout = new QHBoxLayout();
        auto *sceneRowLock = new QCheckBox(QStringLiteral("Lock bottom dock height to scene rows"), &dialog);
        sceneRowLock->setChecked(sceneRowLockEnabled_);
        sceneRowLock->setToolTip(QStringLiteral(
            "Keeps the bottom dock boundary fixed and prevents scene changes from making it jump. "
            "The Scenes list shows exactly the selected number of full rows before scrolling."));
        sceneRowLayout->addWidget(sceneRowLock);
        sceneRowLayout->addSpacing(8);
        sceneRowLayout->addWidget(new QLabel(QStringLiteral("Visible scene rows:"), &dialog));
        auto *sceneRowsSpin = new QSpinBox(&dialog);
        sceneRowsSpin->setRange(1, 30);
        sceneRowsSpin->setValue(sceneVisibleRows_);
        sceneRowsSpin->setSingleStep(1);
        sceneRowsSpin->setKeyboardTracking(false);
        sceneRowsSpin->setEnabled(sceneRowLockEnabled_);
        sceneRowLayout->addWidget(sceneRowsSpin);
        sceneRowLayout->addStretch(1);
        QObject::connect(sceneRowLock, &QCheckBox::toggled, sceneRowsSpin, &QWidget::setEnabled);
        layout->addLayout(sceneRowLayout);

        auto *uiRow = new QHBoxLayout();
'@ 'add scene row lock dialog controls'

# Apply and Restore both remember the row setting. Restore100 changes only scale,
# not the requested six-row lock.
Replace-Required @'
                         [this, uiSpin, textSpin, proportional, safeTiny, autoApply, status]() {
                             proportionalMode_ = proportional->isChecked();
                             safeTinyMode_ = safeTiny->isChecked();
'@ @'
                         [this, uiSpin, textSpin, proportional, safeTiny, autoApply, sceneRowLock, sceneRowsSpin, status]() {
                             proportionalMode_ = proportional->isChecked();
                             safeTinyMode_ = safeTiny->isChecked();
                             sceneRowLockEnabled_ = sceneRowLock->isChecked();
                             sceneVisibleRows_ = sceneRowsSpin->value();
'@ 'apply lambda scene row values'

# There are now two identical-looking lambda prefixes only before patching; after
# the Apply replacement, patch the Restore lambda separately by its 100% lines.
Replace-Required @'
                         [this, uiSpin, textSpin, proportional, safeTiny, autoApply, status]() {
                             proportionalMode_ = proportional->isChecked();
                             safeTinyMode_ = safeTiny->isChecked();
                             uiSpin->setValue(100.0);
'@ @'
                         [this, uiSpin, textSpin, proportional, safeTiny, autoApply, sceneRowLock, sceneRowsSpin, status]() {
                             proportionalMode_ = proportional->isChecked();
                             safeTinyMode_ = safeTiny->isChecked();
                             sceneRowLockEnabled_ = sceneRowLock->isChecked();
                             sceneVisibleRows_ = sceneRowsSpin->value();
                             uiSpin->setValue(100.0);
'@ 'restore lambda scene row values'

# Give the extra control row enough room and update the self-identifying text.
$s = $s.Replace('dialog.resize(620, 430);', 'dialog.resize(660, 500);')
$s = $s.Replace('OBS UI Scale v2.7 DEBUG LOG', 'OBS UI Scale v2.8 DEBUG LOG')
Replace-Required 'dialog.setWindowTitle(QStringLiteral("OBS UI Scale v2.7 DEBUG"));' 'dialog.setWindowTitle(QStringLiteral("OBS UI Scale v2.8 DEBUG"));' 'dialog title'
$s = $s.Replace('v2.7 DEBUG applies the mixer + compact dock-row repair to both normal and Studio Mode preview scene changes. Debug logging remains optional.',
                'v2.8 DEBUG adds a persistent visible-scene-row lock (6 rows by default) so the bottom dock boundary cannot briefly jump during scene changes. Debug logging remains optional.')

# State members.
Replace-Required @'
    bool debugLoggingEnabled_ = false;
    int manualDockCaptureGeneration_ = 0;
'@ @'
    bool debugLoggingEnabled_ = false;
    int manualDockCaptureGeneration_ = 0;
    bool sceneRowLockEnabled_ = true;
    int sceneVisibleRows_ = 6;
    int lockedSceneDockHeight_ = 0;
    int lockedMixerHeight_ = 0;
    bool sceneRowLockApplying_ = false;
'@ 'scene row lock members'

Set-Content $path $s -Encoding utf8

$issPath = 'installer/ObsUiScale.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('2.7.0', '2.8.0')
$iss = $iss.Replace('OBS-UI-Scale-Debug-Setup-2.7.0', 'OBS-UI-Scale-Debug-Setup-2.8.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared OBS UI Scale v2.8 DEBUG persistent scene-row lock + no-flash mixer guard.'
