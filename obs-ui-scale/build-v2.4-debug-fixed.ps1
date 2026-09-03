$ErrorActionPreference = 'Stop'

& ./build-v2.3-debug.ps1

$path = 'src/plugin-main.cpp'
$s = Get-Content $path -Raw
$s = $s.Replace("`r`n", "`n")

function MustReplace([string]$old, [string]$new, [string]$label) {
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if (-not $script:s.Contains($old)) { throw "v2.4 fixed patch missing: $label" }
    $script:s = $script:s.Replace($old, $new)
}

MustReplace 'static constexpr const char *PLUGIN_VERSION = "2.3.0-debug";' 'static constexpr const char *PLUGIN_VERSION = "2.4.0-debug";' 'version'

MustReplace @'
    ObsUiScaleController()
    {
        InitializeDebugLog();
        DebugWrite(QStringLiteral("CONSTRUCTOR: OBS UI Scale debug controller starting"));

        char *configPath = obs_module_config_path("obs-ui-scale.ini");
'@ @'
    ObsUiScaleController()
    {
        char *configPath = obs_module_config_path("obs-ui-scale.ini");
'@ 'constructor unconditional log'

MustReplace @'
        proportionalMode_ = settings_ ? settings_->value(QStringLiteral("ui/proportionalMode"), true).toBool() : true;
'@ @'
        proportionalMode_ = settings_ ? settings_->value(QStringLiteral("ui/proportionalMode"), true).toBool() : true;
        debugLoggingEnabled_ = settings_ ? settings_->value(QStringLiteral("debug/loggingEnabled"), false).toBool() : false;
        if (debugLoggingEnabled_) {
            InitializeDebugLog();
            DebugWrite(QStringLiteral("CONSTRUCTOR: debug logging enabled from saved setting"));
        }
'@ 'load debug setting'

MustReplace @'
    void InitializeDebugLog()
    {
        QString folder = QStandardPaths::writableLocation(QStandardPaths::DesktopLocation);
'@ @'
    void InitializeDebugLog()
    {
        if (!debugLoggingEnabled_)
            return;
        QString folder = QStandardPaths::writableLocation(QStandardPaths::DesktopLocation);
'@ 'log init guard'

MustReplace @'
    void DebugWrite(const QString &message)
    {
        if (debugLogPath_.isEmpty())
            return;
'@ @'
    void DebugWrite(const QString &message)
    {
        if (!debugLoggingEnabled_ || debugLogPath_.isEmpty())
            return;
'@ 'write guard'

MustReplace @'
    void DebugSnapshot(const QString &label)
    {
        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
'@ @'
    void DebugSnapshot(const QString &label)
    {
        if (!debugLoggingEnabled_)
            return;
        auto *mainWindow = static_cast<QMainWindow *>(obs_frontend_get_main_window());
'@ 'snapshot guard'

MustReplace @'
    void DebugWidgetEvent(QWidget *widget, QEvent::Type type)
    {
        DebugWrite(QStringLiteral("QT EVENT %1: %2")
'@ @'
    void DebugWidgetEvent(QWidget *widget, QEvent::Type type)
    {
        if (!debugLoggingEnabled_)
            return;
        DebugWrite(QStringLiteral("QT EVENT %1: %2")
'@ 'widget guard'

MustReplace @'
    void DebugFrontendEvent(enum obs_frontend_event event)
    {
        const QString eventName = DebugFrontendEventName(event);
'@ @'
    void DebugFrontendEvent(enum obs_frontend_event event)
    {
        if (!debugLoggingEnabled_)
            return;
        const QString eventName = DebugFrontendEventName(event);
'@ 'frontend guard'

MustReplace @'
    void DebugScheduleApplySnapshots(const QString &prefix)
    {
        const int delays[] = {0, 5, 15, 35, 70, 100, 150, 220, 350, 500, 800, 1200};
'@ @'
    void DebugScheduleApplySnapshots(const QString &prefix)
    {
        if (!debugLoggingEnabled_)
            return;
        const int delays[] = {0, 5, 15, 35, 70, 100, 150, 220, 350, 500, 800, 1200};
'@ 'apply schedule guard'

$marker = '    QString DebugSceneName() const'
$pos = $s.IndexOf($marker)
if ($pos -lt 0) { throw 'v2.4 fixed missing DebugSceneName marker' }
$helper = @'
    void SetDebugLoggingEnabled(bool enabled)
    {
        if (debugLoggingEnabled_ == enabled)
            return;

        if (enabled) {
            debugLoggingEnabled_ = true;
            debugLogPath_.clear();
            InitializeDebugLog();
            DebugWrite(QStringLiteral("DEBUG LOGGING ENABLED BY USER"));
            DebugSnapshot(QStringLiteral("logging enabled"));
        } else {
            DebugWrite(QStringLiteral("DEBUG LOGGING DISABLED BY USER"));
            debugLoggingEnabled_ = false;
        }

        if (settings_) {
            settings_->setValue(QStringLiteral("debug/loggingEnabled"), debugLoggingEnabled_);
            settings_->sync();
        }
        blog(LOG_INFO, "[%s] diagnostic logging %s", PLUGIN_NAME,
             debugLoggingEnabled_ ? "enabled" : "disabled");
    }

'@
$s = $s.Substring(0, $pos) + $helper + $s.Substring($pos)

MustReplace '        if (event && DebugInterestingEvent(event->type())) {' '        if (debugLoggingEnabled_ && event && DebugInterestingEvent(event->type())) {' 'event guard'

# Insert the checkbox immediately before the first UI controls row. This is more
# robust than depending on v2.3's changed intro text/layout.
$uiMarker = '        auto *uiRow = new QHBoxLayout();'
$uiPos = $s.IndexOf($uiMarker)
if ($uiPos -lt 0) { throw 'v2.4 fixed missing uiRow marker' }
$checkbox = @'
        auto *debugLogging = new QCheckBox(QStringLiteral("Enable debug logging"), &dialog);
        debugLogging->setChecked(debugLoggingEnabled_);
        debugLogging->setToolTip(QStringLiteral(
            "When enabled, writes OBS/Qt layout diagnostics to OBS-UI-Scale-Debug.txt on the Desktop. "
            "Turning this off stops diagnostic writes immediately."));
        QObject::connect(debugLogging, &QCheckBox::toggled, &dialog,
                         [this](bool enabled) { SetDebugLoggingEnabled(enabled); });
        layout->addWidget(debugLogging);

'@
$s = $s.Substring(0, $uiPos) + $checkbox + $s.Substring($uiPos)

MustReplace 'dialog.setWindowTitle(QStringLiteral("OBS UI Scale v2.3 DEBUG"));' 'dialog.setWindowTitle(QStringLiteral("OBS UI Scale v2.4 DEBUG"));' 'dialog title'

$s = $s.Replace('v2.3 DEBUG keeps the v2.2 behavior and records detailed dock/mixer geometry while you reproduce the jump.',
                'v2.4 DEBUG keeps the v2.2 behavior and adds optional dock/mixer diagnostics. Enable logging only when you need a trace.')
$s = $s.Replace('The log is written automatically to OBS-UI-Scale-Debug.txt on your Desktop.',
                'When enabled, the log is written to OBS-UI-Scale-Debug.txt on your Desktop.')

MustReplace @'
    QString debugLogPath_;
    bool debugPostSnapshotQueued_ = false;
'@ @'
    QString debugLogPath_;
    bool debugPostSnapshotQueued_ = false;
    bool debugLoggingEnabled_ = false;
'@ 'member'

Set-Content $path $s -Encoding utf8

$issPath = 'installer/ObsUiScale.iss'
$iss = Get-Content $issPath -Raw
$iss = $iss.Replace('2.3.0', '2.4.0')
$iss = $iss.Replace('OBS-UI-Scale-Debug-Setup-2.3.0', 'OBS-UI-Scale-Debug-Setup-2.4.0')
Set-Content $issPath $iss -Encoding utf8

Write-Host 'Prepared OBS UI Scale v2.4 DEBUG with toggleable persistent logging (default off).'
