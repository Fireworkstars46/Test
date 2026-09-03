$ErrorActionPreference = 'Stop'

# The v2.8 implementation is correct, but its first lambda replacement matches
# both Apply and Restore (PowerShell String.Replace replaces every occurrence).
# Therefore the later Restore-only replacement is redundant and its required
# pattern is already gone. Run the same v2.8 script with that redundant block
# removed.
$sourcePath = Join-Path $PSScriptRoot 'build-v2.8-debug.ps1'
$source = Get-Content $sourcePath -Raw
$source = $source.Replace("`r`n", "`n")

$startMarker = '# There are now two identical-looking lambda prefixes only before patching; after'
$endMarker = '# Give the extra control row enough room and update the self-identifying text.'
$start = $source.IndexOf($startMarker)
$end = $source.IndexOf($endMarker)
if ($start -lt 0 -or $end -lt 0 -or $end -le $start) {
    throw 'Could not locate the redundant v2.8 Restore-lambda patch block.'
}

$source = $source.Substring(0, $start) + $source.Substring($end)
$tempPath = Join-Path $PSScriptRoot '_build-v2.8-run.ps1'
Set-Content $tempPath $source -Encoding utf8
try {
    & $tempPath
} finally {
    Remove-Item $tempPath -Force -ErrorAction SilentlyContinue
}
