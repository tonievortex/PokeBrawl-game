# Builds PokeBrawl.exe (the launcher) with the C# compiler that ships with Windows: nothing to
# install. Output: export\PokeBrawl-Launcher\PokeBrawl.exe (export\ is not committed).
#   powershell -ExecutionPolicy Bypass -File launcher\build.ps1
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
$out = Join-Path $root "export\PokeBrawl-Launcher"
New-Item -ItemType Directory -Force $out | Out-Null
$csc = Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) {
	throw "The C# compiler was not found: $csc"
}
& $csc /nologo /target:winexe /optimize+ "/out:$out\PokeBrawl.exe" "/win32icon:$root\game\icon.ico" `
	/r:System.Windows.Forms.dll /r:System.Drawing.dll /r:System.IO.Compression.dll /r:System.IO.Compression.FileSystem.dll `
	"$here\Launcher.cs"
if ($LASTEXITCODE -ne 0) {
	throw "The build failed"
}
Write-Host "Built $out\PokeBrawl.exe" -ForegroundColor Green

