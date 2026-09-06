$ErrorActionPreference = 'Stop'

# v3.20 DEBUG starts from the 39/39-tested v3.19 stable build and fixes two
# remaining real-world edges:
#   1) very small scene-row minimums (especially 1 row) can still be blocked by
#      minimum-size hints/policies from sibling docks in the same Bottom row;
#   2) a genuine manual drag immediately followed by the first real Apply can
#      occasionally use the previous saved height if Qt's final drag geometry
#      lands after the last gesture-qualified Resize.
#
# The low-row fix temporarily relaxes only the vertical minimum/policy of sibling
# docks in the SAME live Bottom row while the scene-row minimum feature is on.
# Their exact original minimum and vertical QSizePolicy are restored when the
# feature is disabled. The Scenes dock remains the authoritative row floor.
#
# The Apply fix finalizes the exact live manual height at the real Apply click,
# before SaveSettings/ApplyScale, and arms a synchronous smoothness guard so an
# Apply-owned resize cannot visibly jump away from that target. The complete
# combination matrix gains a physical 1-row preflight and treats any Apply
# transient excursion as a test failure.
& ./build-v3.19-stable.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v3.20 debug patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "3.19.0";' 'static constexpr const char *PLUGIN_VERSION = "3.20.0-debug";' 'plugin version'

if (-not $s.Contains('#include <QSizePolicy>')) {
    if ($s.Contains('#include <QSpinBox>')) {
        $s = $s.Replace('#include <QSpinBox>', "#include <QSpinBox>`n#include <QSizePolicy>")
    } else {
        $s = $s.Replace('#include <QStackedWidget>', "#include <QSizePolicy>`n#include <QStackedWidget>")
    }
}

Replace-Required @'
static constexpr const char *PROP_APPLY_OLD_MAX_H = "obsUiScaleApplyOldMaxH";
'@ @'
static constexpr const char *PROP_APPLY_OLD_MAX_H = "obsUiScaleApplyOldMaxH";
static constexpr const char *PROP_ROW_OLD_MIN_H = "obsUiScaleRowOldMinH";
static constexpr const char *PROP_ROW_OLD_VPOLICY = "obsUiScaleRowOldVPolicy";
'@ 'bottom-row sibling restoration properties'

# A row-count floor must be based on the requested visible rows, not on another
# dock/widget's generic minimumSizeHint. That hint is exactly what can turn a
# requested 1-row floor into roughly 4 visible rows.
Replace-Required @'
        int target = outsideViewport + targetViewportHeight;
        target = qMax(target, dock->minimumSizeHint().height());
        return qMax(1, target);
'@ @'
        // The explicit scene-row feature is the minimum authority. Do not clamp
        // back up to QDockWidget::minimumSizeHint(), because sibling/content
        // hints can represent several rows even when the user explicitly asks
        // for only one. Same-row siblings are relaxed separately while the
        // feature is enabled.
        const int target = outsideViewport + targetViewportHeight;
        return qMax(1, target);
'@ 'remove generic minimumSizeHint blocker from exact row floor'

# Insert helpers immediately before ReleaseSceneRowLockConstraints so all later
# row-lock paths can use them.
$releaseMarker = '    void ReleaseSceneRowLockConstraints()'
$releasePos = $s.IndexOf($releaseMarker)
if ($releasePos -lt 0) { throw 'v3.20 could not locate ReleaseSceneRowLockConstraints' }
$rowHelpers = @'
    int CountFullyVisibleSceneRows() const
    {
        QListWidget *scenes = ScenesList();
        QWidget *viewport = scenes ? scenes->viewport() : nullptr;
        if (!scenes || !viewport)
            return 0;

        const QRect vr = viewport->rect();
        int count = 0;
        for (int row = 0; row < scenes->count(); ++row) {
            QListWidgetItem *item = scenes->item(row);
            if (!item || item->isHidden())
                continue;
            const QRect r = scenes->visualItemRect(item);
            if (!r.isValid() || r.height() <= 0)
                continue;
            if (r.top() >= vr.top() && r.bottom() <= vr.bottom())
                ++count;
        }
        return count;
    }

    void RelaxBottomRowSiblingMinimums()
    {
        if (!sceneRowLockEnabled_)
            return;

        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
        QDockWidget *sceneDock = ScenesDock();
        if (!mainWindow || !sceneDock || sceneDock->isFloating())
            return;
        if (mainWindow->dockWidgetArea(sceneDock) != Qt::BottomDockWidgetArea)
            return;

        const int rowY = sceneDock->y();
        const auto docks = mainWindow->findChildren<QDockWidget *>(QString(), Qt::FindDirectChildrenOnly);
        for (QDockWidget *dock : docks) {
            if (!dock || dock == sceneDock || !dock->isVisible() || dock->isFloating())
                continue;
            if (mainWindow->dockWidgetArea(dock) != Qt::BottomDockWidgetArea)
                continue;
            if (qAbs(dock->y() - rowY) > 4)
                continue;

            if (!dock->property(PROP_ROW_OLD_MIN_H).isValid())
                dock->setProperty(PROP_ROW_OLD_MIN_H, dock->minimumHeight());
            if (!dock->property(PROP_ROW_OLD_VPOLICY).isValid())
                dock->setProperty(PROP_ROW_OLD_VPOLICY,
                                  static_cast<int>(dock->sizePolicy().verticalPolicy()));

            dock->setMinimumHeight(0);
            QSizePolicy policy = dock->sizePolicy();
            policy.setVerticalPolicy(QSizePolicy::Ignored);
            dock->setSizePolicy(policy);
            dock->updateGeometry();
        }
    }

    void RestoreBottomRowSiblingMinimums()
    {
        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
        if (!mainWindow)
            return;

        const auto docks = mainWindow->findChildren<QDockWidget *>(QString(), Qt::FindDirectChildrenOnly);
        for (QDockWidget *dock : docks) {
            if (!dock || !dock->property(PROP_ROW_OLD_MIN_H).isValid())
                continue;

            const int oldMin = dock->property(PROP_ROW_OLD_MIN_H).toInt();
            dock->setMinimumHeight(qMax(0, oldMin));
            dock->setProperty(PROP_ROW_OLD_MIN_H, QVariant());

            if (dock->property(PROP_ROW_OLD_VPOLICY).isValid()) {
                QSizePolicy policy = dock->sizePolicy();
                policy.setVerticalPolicy(static_cast<QSizePolicy::Policy>(
                    dock->property(PROP_ROW_OLD_VPOLICY).toInt()));
                dock->setSizePolicy(policy);
                dock->setProperty(PROP_ROW_OLD_VPOLICY, QVariant());
            }
            dock->updateGeometry();
        }
    }

'@
$s = $s.Substring(0, $releasePos) + $rowHelpers.Replace("`r`n", "`n") + $s.Substring($releasePos)

# Restore relaxed sibling constraints only when the feature is actually being
# turned off. Apply/Restore100 temporarily release the pixel floor while the
# preference remains enabled; restoring sibling minima there would recreate the
# visible jump/blocker during the Apply window.
Replace-Required @'
        lockedSceneDockHeight_ = 0;
        lockedMixerHeight_ = 0;
        sceneRowLockApplying_ = false;
'@ @'
        lockedSceneDockHeight_ = 0;
        lockedMixerHeight_ = 0;
        if (!sceneRowLockEnabled_)
            RestoreBottomRowSiblingMinimums();
        sceneRowLockApplying_ = false;
'@ 'restore sibling minima only when row feature is disabled'

# Relax the other docks before calculating/enforcing a new row floor.
$captureStart = $s.IndexOf('    void CaptureAndApplySceneRowLock()')
$captureEnd = $s.IndexOf('    void ScheduleSceneRowLockCapture(double uiPercent)', $captureStart)
if ($captureStart -lt 0 -or $captureEnd -lt 0) { throw 'v3.20 could not isolate CaptureAndApplySceneRowLock' }
$captureBlock = $s.Substring($captureStart, $captureEnd - $captureStart)
$captureNeedle = '        sceneRowLockApplying_ = true;'
if (-not $captureBlock.Contains($captureNeedle)) { throw 'v3.20 capture block apply marker missing' }
$captureBlock = $captureBlock.Replace($captureNeedle, "        RelaxBottomRowSiblingMinimums();`n`n$captureNeedle")
$s = $s.Substring(0, $captureStart) + $captureBlock + $s.Substring($captureEnd)

$reassertStart = $s.IndexOf('    void ReassertSceneRowLock()')
$reassertEnd = $s.IndexOf('    void CaptureAndApplySceneRowLock()', $reassertStart)
if ($reassertStart -lt 0 -or $reassertEnd -lt 0) { throw 'v3.20 could not isolate ReassertSceneRowLock' }
$reassertBlock = $s.Substring($reassertStart, $reassertEnd - $reassertStart)
$reassertNeedle = '        sceneRowLockApplying_ = true;'
if (-not $reassertBlock.Contains($reassertNeedle)) { throw 'v3.20 reassert apply marker missing' }
$reassertBlock = $reassertBlock.Replace($reassertNeedle, "$reassertNeedle`n        RelaxBottomRowSiblingMinimums();")
$s = $s.Substring(0, $reassertStart) + $reassertBlock + $s.Substring($reassertEnd)

# Scene changes must keep the same relaxed same-row sibling constraints before
# asking QMainWindow to restore the authoritative manual Scenes height.
$authStart = $s.IndexOf('    void RestoreAuthoritativeSceneDockTarget()')
$authEnd = $s.IndexOf('    void ArmSceneDockGuard()', $authStart)
if ($authStart -lt 0 -or $authEnd -lt 0) { throw 'v3.20 could not isolate authoritative Scene restore' }
$authBlock = $s.Substring($authStart, $authEnd - $authStart)
$authNeedle = '        QStackedWidget *mixer = StackedMixerArea();'
if (-not $authBlock.Contains($authNeedle)) { throw 'v3.20 authoritative mixer marker missing' }
$authBlock = $authBlock.Replace($authNeedle, "        RelaxBottomRowSiblingMinimums();`n`n$authNeedle")
$s = $s.Substring(0, $authStart) + $authBlock + $s.Substring($authEnd)

# Real Apply stabilization. A real manual drag can finish with one last Qt dock
# geometry update after the gesture-qualified resize. At the instant the user
# clicks the REAL Apply button, finalize the exact visible height before the
# existing persisted-height Apply code reads it. Also arm a short guard that
# rejects any Apply-owned excursion before the next paint.
$applyScaleMarker = '    void ApplyScale(double requestedUiPercent, double requestedTextPercent)'
$applyScalePos = $s.IndexOf($applyScaleMarker)
if ($applyScalePos -lt 0) { throw 'v3.20 could not locate ApplyScale insertion point' }
$applyHelper = @'
    void PrepareForRealApplyButton()
    {
        QDockWidget *sceneDock = ScenesDock();
        if (!sceneDock || !sceneDock->isVisible())
            return;

        const int floor = (sceneRowLockEnabled_ && lockedSceneDockHeight_ > 0)
                              ? qMax(1, lockedSceneDockHeight_) : 1;
        const bool newerManualDrag = manualResizeSerial_ > lastRealApplyManualSerial_;

        if (newerManualDrag) {
            const int exactLive = qMax(floor, sceneDock->height());
            savedManualSceneDockHeight_ = exactLive;
            lastImmediateManualSceneDockHeight_ = exactLive;
            if (settings_) {
                settings_->setValue(QStringLiteral("ui/manualSceneDockHeight"), exactLive);
                settings_->sync();
            }
            ++manualDockCaptureGeneration_;
            DebugWrite(QStringLiteral(
                "REAL APPLY FINALIZED LIVE MANUAL HEIGHT height=%1 dragSerial=%2 previousSavedSuperseded=1")
                           .arg(exactLive).arg(manualResizeSerial_));
        }
        lastRealApplyManualSerial_ = manualResizeSerial_;

        const int target = savedManualSceneDockHeight_ > 0
                               ? qMax(floor, savedManualSceneDockHeight_)
                               : qMax(floor, sceneDock->height());
        realApplySmoothExpectedHeight_ = target;
        lastRealApplySmoothExcursions_ = 0;
        realApplySmoothGuardActive_ = true;
        const int generation = ++realApplySmoothGuardGeneration_;
        DebugWrite(QStringLiteral("REAL APPLY SMOOTH GUARD ARMED expected=%1 live=%2")
                       .arg(target).arg(sceneDock->height()));

        QTimer::singleShot(3600, this, [this, generation]() {
            if (generation != realApplySmoothGuardGeneration_)
                return;
            QDockWidget *dock = ScenesDock();
            DebugWrite(QStringLiteral(
                "REAL APPLY SMOOTH GUARD COMPLETE expected=%1 live=%2 excursions=%3")
                           .arg(realApplySmoothExpectedHeight_)
                           .arg(dock ? dock->height() : -1)
                           .arg(lastRealApplySmoothExcursions_));
            realApplySmoothGuardActive_ = false;
            realApplySmoothExpectedHeight_ = -1;
        });
    }

'@
$s = $s.Substring(0, $applyScalePos) + $applyHelper.Replace("`r`n", "`n") + $s.Substring($applyScalePos)

# This is the normal settings dialog's genuine Apply-button handler. Prepare the
# exact manual height BEFORE SaveSettings and ApplyScale run.
Replace-Required @'
                             ++completeApplyCounter_;
                             DebugWrite(QStringLiteral("REAL SETTINGS APPLY BUTTON CLICKED serial=%1")
'@ @'
                             PrepareForRealApplyButton();
                             ++completeApplyCounter_;
                             DebugWrite(QStringLiteral("REAL SETTINGS APPLY BUTTON CLICKED serial=%1")
'@ 'real Apply button finalizes live manual height first'

# Synchronous guard at the start of the event filter. If Apply itself tries to
# move the Scenes row away from the intended target, repair it in the same event
# turn. The test records every attempted excursion, even if repaired before paint.
$eventMarker = @'
    bool eventFilter(QObject *watched, QEvent *event) override
    {
'@
Replace-Required $eventMarker @'
    bool eventFilter(QObject *watched, QEvent *event) override
    {
        if (event && event->type() == QEvent::Resize && realApplySmoothGuardActive_ &&
            suppressManualDockCapture_ && !restoringDockTargets_ && watched == ScenesDock()) {
            QDockWidget *dock = ScenesDock();
            auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
            if (dock && mainWindow && realApplySmoothExpectedHeight_ > 0) {
                const int floor = (sceneRowLockEnabled_ && lockedSceneDockHeight_ > 0)
                                      ? qMax(1, lockedSceneDockHeight_) : 1;
                const int expected = qMax(floor, realApplySmoothExpectedHeight_);
                if (qAbs(dock->height() - expected) > 2) {
                    ++lastRealApplySmoothExcursions_;
                    DebugWrite(QStringLiteral(
                        "REAL APPLY TRANSIENT EXCURSION actual=%1 expected=%2 count=%3 - repaired synchronously")
                                   .arg(dock->height()).arg(expected).arg(lastRealApplySmoothExcursions_));
                    restoringDockTargets_ = true;
                    mainWindow->resizeDocks({dock}, {expected}, Qt::Vertical);
                    restoringDockTargets_ = false;
                    ReassertSceneRowLock();
                }
            }
        }

'@ 'real Apply same-turn smoothness guard'

# State for real-Apply finalization/smoothness.
Replace-Required @'
    int completeApplyCounter_ = 0;
    int lastImmediateManualSceneDockHeight_ = -1;
'@ @'
    int completeApplyCounter_ = 0;
    int lastRealApplyManualSerial_ = 0;
    int realApplySmoothExpectedHeight_ = -1;
    int lastRealApplySmoothExcursions_ = 0;
    int realApplySmoothGuardGeneration_ = 0;
    bool realApplySmoothGuardActive_ = false;
    int lastImmediateManualSceneDockHeight_ = -1;
'@ 'real Apply smoothness members'

# Every matrix Apply must be not only correct after settle but internally smooth:
# any attempted transient movement is a failure, even if the guard repaired it.
$matrixOk = 'const bool ok = d && qAbs(actual - *expected) <= 3 && qAbs(savedManualSceneDockHeight_ - *expected) <= 3;'
$matrixOkCount = ([regex]::Matches($s, [regex]::Escape($matrixOk))).Count
if ($matrixOkCount -ne 4) { throw "v3.20 expected 4 matrix Apply result checks, found $matrixOkCount" }
$s = $s.Replace($matrixOk,
    'const bool ok = d && qAbs(actual - *expected) <= 3 && qAbs(savedManualSceneDockHeight_ - *expected) <= 3 && lastRealApplySmoothExcursions_ == 0;')

# Add a physical 1-row reachability preflight to the existing manual matrix.
Replace-Required '        auto stage = std::make_shared<int>(0);' '        auto stage = std::make_shared<int>(-1);' 'prepend low-row matrix preflight stage'

Replace-Required @'
        auto *buttons = new QDialogButtonBox(panel);
        auto *continueButton = buttons->addButton(QStringLiteral("Continue"), QDialogButtonBox::AcceptRole);
        layout->addWidget(buttons);

        instructions->setText(QStringLiteral(
            "Matrix 1/12 - DOWN -> IMMEDIATE SCENE\n\n"
            "Drag the bottom-row separator DOWN to the configured minimum, RELEASE it, then IMMEDIATELY click a different Scene. Then click Continue.\n\n"
            "If already at minimum, drag up first and then down. Minimum=%1 px.").arg(floorAtStart));
'@ @'
        auto *buttons = new QDialogButtonBox(panel);
        auto *openSettingsButton = buttons->addButton(QStringLiteral("Open Settings for 1-Row Test"), QDialogButtonBox::ActionRole);
        auto *continueButton = buttons->addButton(QStringLiteral("Continue"), QDialogButtonBox::AcceptRole);
        layout->addWidget(buttons);

        QObject::connect(openSettingsButton, &QPushButton::clicked, panel, [this]() {
            ShowDialog();
        });

        instructions->setText(QStringLiteral(
            "LOW-ROW PREFLIGHT - PHYSICAL 1-ROW REACHABILITY\n\n"
            "1. Click 'Open Settings for 1-Row Test'.\n"
            "2. Make sure 'Set minimum visible scene rows' is ON and set Minimum scene rows to 1.\n"
            "3. Click the REAL Apply button once, then Close the settings window.\n"
            "4. Drag the bottom-row separator all the way DOWN until it physically stops. If already at the stop, drag up first and then back down.\n"
            "5. Click Continue. The test requires exactly ONE fully visible Scene row and the real dock to be at the calculated 1-row floor."));
'@ 'manual matrix starts with physical 1-row preflight'

$stageZeroMarker = '            if (*stage == 0) {'
$stageZeroPos = $s.IndexOf($stageZeroMarker)
if ($stageZeroPos -lt 0) { throw 'v3.20 could not locate matrix stage 0' }
$lowRowStage = @'
            if (*stage == -1) {
                const int fullRows = CountFullyVisibleSceneRows();
                const bool oneRowSetting = sceneRowLockEnabled_ && sceneVisibleRows_ == 1;
                const bool reachedFloor = oneRowSetting && qAbs(live - floor) <= 3;
                const bool genuineDrag = manualResizeSerial_ > *dragBase;
                const bool exactlyOneVisible = fullRows == 1;

                if (!oneRowSetting || !reachedFloor || !genuineDrag || !exactlyOneVisible) {
                    status->setText(QStringLiteral(
                        "1-row preflight not passed yet. Setting rows=%1 lock=%2 live=%3 floor=%4 fullyVisibleRows=%5 dragSerialDelta=%6. "
                        "Set rows=1 + Apply, then drag UP and back DOWN to the physical stop and Continue again.")
                        .arg(sceneVisibleRows_)
                        .arg(sceneRowLockEnabled_ ? 1 : 0)
                        .arg(live).arg(floor).arg(fullRows)
                        .arg(manualResizeSerial_ - *dragBase));
                    return;
                }

                RestartTestRecord(true, QStringLiteral("Physical 1-row minimum reachability"),
                                  QStringLiteral("Rows=1 physically reached floor=%1 px with exactly %2 fully visible row; live/saved=%3/%4.")
                                      .arg(floor).arg(fullRows).arg(live).arg(savedManualSceneDockHeight_));
                settings_->setValue(QStringLiteral("debug/restartTestProbeSceneRows"), 1);
                settings_->sync();

                *stage = 0;
                *dragBase = manualResizeSerial_;
                *sceneBase = eventsNow;
                instructions->setText(QStringLiteral(
                    "Matrix 1/12 - DOWN -> IMMEDIATE SCENE\n\n"
                    "Keep the 1-row minimum. Drag UP first, then DOWN to the 1-row stop, RELEASE it, and IMMEDIATELY click a different Scene. Then Continue.\n\n"
                    "Minimum=%1 px.").arg(floor));
                status->setText(QStringLiteral("1-row floor passed. Waiting for Matrix 1 DOWN -> immediate Scene..."));
                return;
            }

'@
$s = $s.Substring(0, $stageZeroPos) + $lowRowStage.Replace("`r`n", "`n") + $s.Substring($stageZeroPos)

# Restore sibling policies when the controller is actually destroyed/unloaded.
$destructorStart = $s.IndexOf('    ~ObsUiScaleController() override')
$destructorEnd = $s.IndexOf('private:', $destructorStart)
if ($destructorStart -ge 0 -and $destructorEnd -gt $destructorStart) {
    $destructorBlock = $s.Substring($destructorStart, $destructorEnd - $destructorStart)
    if ($destructorBlock.Contains('        Restore100();') -and -not $destructorBlock.Contains('RestoreBottomRowSiblingMinimums();')) {
        $destructorBlock = $destructorBlock.Replace('        Restore100();', "        Restore100();`n        RestoreBottomRowSiblingMinimums();")
        $s = $s.Substring(0, $destructorStart) + $destructorBlock + $s.Substring($destructorEnd)
    }
}

# Debug identity. Keep all diagnostics/tests available.
$s = $s.Replace('OBS UI Scale v3.19 LOG', 'OBS UI Scale v3.20 DEBUG LOG')
$s = $s.Replace('OBS UI Scale v3.19', 'OBS UI Scale v3.20 DEBUG')
$s = $s.Replace('v3.19', 'v3.20 DEBUG')

Set-Content $path $s -Encoding utf8

$issPath = 'installer/ObsUiScale.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('3.19.0', '3.20.0')
$iss = $iss.Replace('OBS-UI-Scale-Setup-3.20.0', 'OBS-UI-Scale-Debug-Setup-3.20.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared OBS UI Scale v3.20 DEBUG physical 1-row floor + first-Apply smoothness fix.'
