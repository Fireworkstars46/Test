$ErrorActionPreference = 'Stop'

# Start from v2.4 DEBUG, but remove the low-level per-QEvent diagnostics that can
# re-enter Qt layout code while OBS is already processing Resize/LayoutRequest.
# v2.5 keeps the logging checkbox and only takes quiet timed snapshots around
# Apply and frontend scene-change events. Snapshot summaries also avoid calling
# sizeHint()/minimumSizeHint()/layout sizeHint(), which can trigger layout work.
& ./build-v2.4-debug.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function Replace-Required([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v2.5 debug patch pattern not found: $label" }
    $script:s = $script:s.Replace($old, $new)
}

Replace-Required 'static constexpr const char *PLUGIN_VERSION = "2.4.0-debug";' 'static constexpr const char *PLUGIN_VERSION = "2.5.0-debug";' 'plugin version'

# Make widget summaries read-only/simple: actual geometry + explicit constraints.
$summaryStart = $s.IndexOf('    QString DebugWidgetSummary(QWidget *widget) const')
$summaryEnd = $s.IndexOf('    QDockWidget *DebugMixerDock() const', $summaryStart)
if ($summaryStart -lt 0 -or $summaryEnd -lt 0) { throw 'v2.5 could not locate DebugWidgetSummary block' }
$newSummary = @'
    QString DebugWidgetSummary(QWidget *widget) const
    {
        if (!widget)
            return QStringLiteral("<null>");

        const QSizePolicy policy = widget->sizePolicy();
        QString result = QStringLiteral(
            "%1 obj='%2' geom=[%3] size=%4 min=%5 max=%6 visible=%7 enabled=%8 policy=%9/%10")
            .arg(QString::fromLatin1(widget->metaObject()->className()),
                 widget->objectName(),
                 DebugRect(widget->geometry()),
                 DebugSize(widget->size()),
                 DebugSize(widget->minimumSize()),
                 DebugSize(widget->maximumSize()))
            .arg(widget->isVisible() ? 1 : 0)
            .arg(widget->isEnabled() ? 1 : 0)
            .arg(static_cast<int>(policy.horizontalPolicy()))
            .arg(static_cast<int>(policy.verticalPolicy()));

        if (QLayout *layout = widget->layout()) {
            const QMargins margins = layout->contentsMargins();
            result += QStringLiteral(" margins=%1,%2,%3,%4 spacing=%5")
                          .arg(margins.left())
                          .arg(margins.top())
                          .arg(margins.right())
                          .arg(margins.bottom())
                          .arg(layout->spacing());
        }
        return result;
    }

'@
$s = $s.Substring(0, $summaryStart) + $newSummary + $s.Substring($summaryEnd)

# Remove debug tracing from the application event filter entirely. The event
# filter itself remains because v1.8 uses it for safe context-toolbar scaling.
Replace-Required @'
        if (debugLoggingEnabled_ && event && DebugInterestingEvent(event->type())) {
            if (auto *debugWidget = qobject_cast<QWidget *>(watched)) {
                if (DebugTrackedWidget(debugWidget))
                    DebugWidgetEvent(debugWidget, event->type());
            }
        }

'@ @'
        // v2.5 deliberately does not log from Qt's low-level event filter.
        // Logging from Resize/LayoutRequest can re-enter layout calculations.

'@ 'remove low-level Qt event logging'

# Enabling logging should return from the checkbox signal first, then snapshot.
Replace-Required @'
            InitializeDebugLog();
            DebugWrite(QStringLiteral("DEBUG LOGGING ENABLED BY USER"));
            DebugSnapshot(QStringLiteral("logging enabled"));
'@ @'
            InitializeDebugLog();
            DebugWrite(QStringLiteral("DEBUG LOGGING ENABLED BY USER"));
            QTimer::singleShot(0, this, [this]() {
                if (debugLoggingEnabled_)
                    DebugSnapshot(QStringLiteral("logging enabled"));
            });
'@ 'defer initial snapshot'

Replace-Required 'dialog.setWindowTitle(QStringLiteral("OBS UI Scale v2.4 DEBUG"));' 'dialog.setWindowTitle(QStringLiteral("OBS UI Scale v2.5 DEBUG"));' 'dialog title'
$s = $s.Replace('v2.4 DEBUG keeps the v2.2 behavior and adds optional dock/mixer diagnostics. Use Enable debug logging only when you need a trace.',
                'v2.5 DEBUG keeps the v2.2 behavior with safer optional diagnostics. Logging uses timed Apply/scene snapshots only, not low-level Qt resize events.')

Set-Content $path $s -Encoding utf8

$issPath = 'installer/ObsUiScale.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('2.4.0', '2.5.0')
$iss = $iss.Replace('OBS-UI-Scale-Debug-Setup-2.4.0', 'OBS-UI-Scale-Debug-Setup-2.5.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared OBS UI Scale v2.5 DEBUG safe timed snapshots only.'
