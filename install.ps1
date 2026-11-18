# Windows entry point: the install logic lives in install.sh and runs on omp's built-in shell.
$ErrorActionPreference = 'Stop'
if (-not (Get-Command omp -ErrorAction SilentlyContinue)) {
    Write-Error 'omp not found. Install omp first.'
}
omp sh "$PSScriptRoot/install.sh"
exit $LASTEXITCODE
