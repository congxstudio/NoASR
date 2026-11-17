param([string]$Python = "", [string]$Node = "node")
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
if (-not $Python) { $Python = Join-Path $root '.venv\Scripts\python.exe' }
if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'installer\node_modules\electron-builder\package.json'))) { throw '请先在 windows/installer 目录执行 npm ci，安装 NSIS 构建工具。' }
$metadataScript = @'
import ast,json,pathlib,sys
tree=ast.parse(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
values={n.targets[0].id:ast.literal_eval(n.value) for n in tree.body if isinstance(n,ast.Assign) and isinstance(n.targets[0],ast.Name) and n.targets[0].id in ("APP_NAME","APP_VERSION")}
print(json.dumps(values))
'@
$metadata = $metadataScript | & $Python - (Join-Path $PSScriptRoot 'config.py')
if ($LASTEXITCODE -ne 0) { throw '读取版本信息失败' }
$metadata = $metadata | ConvertFrom-Json
& $Python -m unittest discover -s (Join-Path $PSScriptRoot 'tests') -v
if ($LASTEXITCODE -ne 0) { throw '逻辑测试失败' }
& $Python -m PyInstaller --noconfirm --distpath (Join-Path $root 'dist\windows') --workpath (Join-Path $root 'build\windows') (Join-Path $PSScriptRoot 'NoASR.spec')
if ($LASTEXITCODE -ne 0) { throw '应用打包失败' }
$appDir = Join-Path $root 'dist\windows\NoASR'
$checkDir = Join-Path $root ('build\package-check-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $checkDir | Out-Null
$report = Join-Path $checkDir 'report.json'
$oldLocalAppData = $env:LOCALAPPDATA
try {
    $env:LOCALAPPDATA = $checkDir
    $check = Start-Process -FilePath (Join-Path $appDir 'NoASR.exe') -ArgumentList '--packaging-check', ('"' + $report + '"') -PassThru -WindowStyle Hidden
    if (-not $check.WaitForExit(60000)) { $check.Kill(); throw '安装包无设备自检超时' }
    if ($check.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $report)) { throw "安装包自检失败，报告位置：$report" }
    $result = Get-Content -LiteralPath $report -Raw | ConvertFrom-Json
    if (-not $result.ok) { throw "安装包自检失败：$($result.error)" }
    if ($result.version -ne $metadata.APP_VERSION) { throw '安装包版本不一致' }
} finally {
    $env:LOCALAPPDATA = $oldLocalAppData
}
& $Node (Join-Path $PSScriptRoot 'installer\build-installer.cjs') $appDir $metadata.APP_VERSION
if ($LASTEXITCODE -ne 0) { throw '安装包生成失败' }
$installer = Join-Path $root ('dist\release\NoASR-' + $metadata.APP_VERSION + '-windows-x64-setup.exe')
$digest = Get-FileHash -LiteralPath $installer -Algorithm SHA256
[IO.File]::WriteAllText(($installer + '.sha256'), ($digest.Hash.ToLowerInvariant() + '  ' + [IO.Path]::GetFileName($installer) + [Environment]::NewLine), [Text.Encoding]::ASCII)
Write-Output "安装包：$installer"
Write-Output "SHA256：$($digest.Hash)"
Write-Output "无设备自检报告：$report"
