[CmdletBinding()]
param(
    [string]$Repository = "BoomBook888/Install-Galaxy-Workstation",
    [string]$Branch = "main",
    [string]$ChromeDownloadUrl = "https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi",
    [string]$ChromeFallbackDownloadUrl = "https://dl.google.com/chrome/install/ChromeStandaloneSetup64.exe",
    [string]$GalaxyDownloadUrl = "https://galaxy-bricklayer.xyz/api/download/pro",
    [string]$GalaxyFallbackDownloadUrl = "https://galaxy-bricklayer.xyz/downloads/GalaxyBricklayer-latest-win-x64-Setup.exe",
    [switch]$SkipBundled,
    [switch]$SkipChrome,
    [switch]$SkipGalaxy,
    [switch]$Force,
    [switch]$KeepDownloadedFiles
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Root = Join-Path $env:ProgramData "GalaxyWorkstationDeploy"
$RunId = Get-Date -Format "yyyyMMdd-HHmmss"
$RunDirectory = Join-Path $Root $RunId
$LogDirectory = Join-Path $Root "Logs"
$MarkerDirectory = Join-Path $Root "Installed"
$LogPath = Join-Path $LogDirectory ("deploy-{0}.log" -f $RunId)
New-Item -ItemType Directory -Force -Path $RunDirectory, $LogDirectory, $MarkerDirectory | Out-Null
$script:UninstallDisplayNames = $null
$script:BundledManifestCache = $null

function Write-Step {
    param([string]$Message)
    Write-Host ("[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $Message) -ForegroundColor Cyan
}

function Write-Phase {
    param(
        [int]$Current,
        [int]$Total,
        [string]$Message
    )
    Write-Host ""
    Write-Host ("========== [{0}/{1}] {2} ==========" -f $Current, $Total, $Message) -ForegroundColor Yellow
}

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "请使用管理员权限运行 PowerShell。"
    }
    Write-Step "管理员权限检查通过"
}

function Get-UninstallDisplayNames {
    if ($null -ne $script:UninstallDisplayNames) {
        return $script:UninstallDisplayNames
    }

    $registryPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    $detectedNames = foreach ($registryPath in $registryPaths) {
        Get-ItemProperty -Path $registryPath -ErrorAction SilentlyContinue |
            ForEach-Object {
                $displayNameProperty = $_.PSObject.Properties["DisplayName"]
                if ($displayNameProperty -and -not [string]::IsNullOrWhiteSpace([string]$displayNameProperty.Value)) {
                    [string]$displayNameProperty.Value
                }
            }
    }
    $script:UninstallDisplayNames = @($detectedNames | Sort-Object -Unique)
    return $script:UninstallDisplayNames
}

function Test-DetectionGroup {
    param([Parameter(Mandatory = $true)]$Group)

    $displayNames = Get-UninstallDisplayNames
    foreach ($pattern in @($Group.displayNamePatterns)) {
        if ($displayNames | Where-Object { $_ -like $pattern } | Select-Object -First 1) {
            return $true
        }
    }

    foreach ($pathPattern in @($Group.filePaths)) {
        $expandedPath = [Environment]::ExpandEnvironmentVariables($pathPattern)
        if (Test-Path -Path $expandedPath) {
            return $true
        }
    }

    return $false
}

function Test-BundledPackageInstalled {
    param([Parameter(Mandatory = $true)]$Package)

    $marker = Join-Path $MarkerDirectory ("{0}.json" -f $Package.id)
    if (Test-Path $marker) {
        return $true
    }

    $groups = @($Package.detectGroups)
    if ($groups.Count -eq 0) {
        return $false
    }

    foreach ($group in $groups) {
        if (-not (Test-DetectionGroup -Group $group)) {
            return $false
        }
    }

    return $true
}

function Write-InstallationMarker {
    param(
        [Parameter(Mandatory = $true)]$Package,
        [Parameter(Mandatory = $true)][string]$SourcePath
    )

    $marker = Join-Path $MarkerDirectory ("{0}.json" -f $Package.id)
    [ordered]@{
        id = $Package.id
        name = $Package.name
        installedAt = (Get-Date).ToString("o")
        sourceSha256 = (Get-FileHash -Path $SourcePath -Algorithm SHA256).Hash
    } | ConvertTo-Json | Set-Content -Path $marker -Encoding UTF8
}

function Invoke-Download {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Destination,
        [int64]$MinimumBytes = 1MB
    )

    $lastError = $null
    foreach ($attempt in 1..4) {
        $partial = "$Destination.partial-$PID-$attempt"
        try {
            Remove-Item $partial -Force -ErrorAction SilentlyContinue
            Write-Step "正在下载（第 $attempt/4 次）：$Url"
            Invoke-WebRequest `
                -Uri $Url `
                -OutFile $partial `
                -UseBasicParsing `
                -MaximumRedirection 10 `
                -Headers @{
                    "User-Agent" = "GalaxyWorkstationDeploy/1.0"
                    "Cache-Control" = "no-cache"
                }

            $file = Get-Item $partial
            if ($file.Length -lt $MinimumBytes) {
                throw "下载文件过小：$($file.Length) 字节"
            }

            Move-Item -Path $partial -Destination $Destination -Force
            if ($file.Length -lt 1MB) {
                $sizeText = "{0} KB" -f [Math]::Round($file.Length / 1KB, 2)
            }
            else {
                $sizeText = "{0} MB" -f [Math]::Round($file.Length / 1MB, 2)
            }
            Write-Step "下载完成：$([IO.Path]::GetFileName($Destination))，大小 $sizeText"
            return
        }
        catch {
            $lastError = $_
            Write-Warning "下载失败：$($_.Exception.Message)"
            if ($attempt -lt 4) {
                Start-Sleep -Seconds (3 * $attempt)
            }
        }
        finally {
            Remove-Item $partial -Force -ErrorAction SilentlyContinue
        }
    }

    throw "下载重试4次后仍失败：$($lastError.Exception.Message)"
}

function Assert-Package {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet("Exe", "Msi", "Zip")][string]$Type
    )

    $expectedLength = if ($Type -eq "Exe") { 2 } else { 8 }
    $stream = [IO.File]::OpenRead($Path)
    try {
        $signature = New-Object byte[] $expectedLength
        $readCount = $stream.Read($signature, 0, $signature.Length)
    }
    finally {
        $stream.Dispose()
    }

    if ($readCount -lt $expectedLength) {
        throw "安装包文件头不完整：$Path"
    }

    switch ($Type) {
        "Exe" {
            $valid = ($signature[0] -eq 0x4D -and $signature[1] -eq 0x5A)
        }
        "Msi" {
            $expected = @(0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1)
            $valid = $true
            foreach ($index in 0..7) {
                if ($signature[$index] -ne $expected[$index]) {
                    $valid = $false
                    break
                }
            }
        }
        "Zip" {
            $valid = ($signature[0] -eq 0x50 -and $signature[1] -eq 0x4B)
        }
    }

    if (-not $valid) {
        throw "安装包格式无效（$Type）：$Path"
    }

    $hash = (Get-FileHash -Path $Path -Algorithm SHA256).Hash
    Write-Step "文件校验通过：$([IO.Path]::GetFileName($Path))"
    Write-Step "SHA256：$hash"
}

function Invoke-Installer {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Path,
        [ValidateSet("Exe", "Msi")][string]$Type = "Exe",
        [string]$Arguments = "",
        [int]$TimeoutSeconds = 1800
    )

    Assert-Package -Path $Path -Type $Type
    Write-Step "开始安装：$Name"

    if ($Type -eq "Msi") {
        $process = Start-Process `
            -FilePath "msiexec.exe" `
            -ArgumentList "/i `"$Path`" $Arguments" `
            -PassThru
    }
    else {
        $process = Start-Process `
            -FilePath $Path `
            -ArgumentList $Arguments `
            -PassThru
    }

    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        throw "$Name 安装超时（$TimeoutSeconds 秒）"
    }

    if ($process.ExitCode -notin @(0, 1641, 3010)) {
        throw "$Name 安装失败，退出码：$($process.ExitCode)"
    }

    Write-Step "安装完成：$Name"
}

function Get-BundledPackageManifest {
    if ($null -ne $script:BundledManifestCache) {
        return $script:BundledManifestCache
    }

    $manifestUrl = "https://raw.githubusercontent.com/$Repository/$Branch/installers.json"
    $remoteManifestPath = Join-Path $RunDirectory "installers.json"
    Write-Step "正在获取 GitHub 软件清单"
    Invoke-Download -Url $manifestUrl -Destination $remoteManifestPath -MinimumBytes 100
    $manifestText = Get-Content -Path $remoteManifestPath -Raw -Encoding UTF8
    $parsedManifest = ConvertFrom-Json -InputObject $manifestText
    $script:BundledManifestCache = @(
        foreach ($manifestItem in $parsedManifest) {
            $manifestItem
        }
    )
    Write-Step "软件清单已加载，共 $($script:BundledManifestCache.Count) 项"
    return $script:BundledManifestCache
}

function Install-BundledPackages {
    $packages = @(Get-BundledPackageManifest)

    $pendingPackages = @()
    foreach ($package in $packages) {
        if ($package.enabled -eq $false) {
            Write-Step "已禁用，跳过：$($package.name)"
            continue
        }

        Write-Step "检查是否已部署：$($package.name)"
        if (-not $Force.IsPresent -and (Test-BundledPackageInstalled -Package $package)) {
            Write-Step "已安装，无需重复处理：$($package.name)"
            continue
        }
        $pendingPackages += $package
    }

    if ($pendingPackages.Count -eq 0) {
        Write-Step "GitHub 内置软件均已安装，不下载仓库大包"
        return
    }

    Write-Step "有 $($pendingPackages.Count) 项软件需要部署，开始下载 GitHub 仓库"
    $archiveUrl = "https://github.com/$Repository/archive/refs/heads/$Branch.zip"
    $archivePath = Join-Path $RunDirectory "repository.zip"
    $extractPath = Join-Path $RunDirectory "repository"

    Invoke-Download -Url $archiveUrl -Destination $archivePath -MinimumBytes 1MB
    Assert-Package -Path $archivePath -Type "Zip"
    Write-Step "正在解压 GitHub 软件包"
    Expand-Archive -Path $archivePath -DestinationPath $extractPath -Force

    $manifestPath = Get-ChildItem -Path $extractPath -Filter "installers.json" -Recurse |
        Select-Object -First 1 -ExpandProperty FullName
    if (-not $manifestPath) {
        throw "GitHub 仓库压缩包中未找到 installers.json"
    }

    $repositoryRoot = Split-Path $manifestPath -Parent
    foreach ($package in $pendingPackages) {
        $packagePath = Join-Path $repositoryRoot $package.file
        if (-not (Test-Path $packagePath)) {
            throw "未找到内置安装包：$($package.file)"
        }

        if ($package.action -eq "CopyToPublicDesktop") {
            $publicDesktop = [Environment]::GetFolderPath("CommonDesktopDirectory")
            $destination = Join-Path $publicDesktop ([IO.Path]::GetFileName($packagePath))
            Copy-Item -Path $packagePath -Destination $destination -Force
            Write-InstallationMarker -Package $package -SourcePath $packagePath
            Write-Step "已复制到 Windows 公共桌面：$($package.name)"
            Write-Host "5. $($package.name) 安装成功。" -ForegroundColor Green
            continue
        }

        try {
            Invoke-Installer `
                -Name $package.name `
                -Path $packagePath `
                -Type $package.type `
                -Arguments $package.arguments `
                -TimeoutSeconds $package.timeoutSeconds
            Write-InstallationMarker -Package $package -SourcePath $packagePath
            Write-Host "5. $($package.name) 安装成功。" -ForegroundColor Green
        }
        catch {
            Write-Host "4. $($package.name) 安装失败，已跳过。" -ForegroundColor Yellow
            Write-Warning $_.Exception.Message
        }
    }
}

function Find-ChromeExecutable {
    $candidates = @(
        "C:\Program Files\Google\Chrome\Application\chrome.exe",
        "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
        (Join-Path $env:LOCALAPPDATA "Google\Chrome\Application\chrome.exe")
    )

    foreach ($registryPath in @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe"
    )) {
        if (Test-Path $registryPath) {
            $registeredPath = (Get-Item -Path $registryPath -ErrorAction SilentlyContinue).GetValue("")
            if ($registeredPath) {
                $candidates += $registeredPath
            }
        }
    }

    $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
}

function Install-LatestChrome {
    $installedChrome = Find-ChromeExecutable
    if (-not $Force.IsPresent -and $installedChrome) {
        $version = (Get-Item $installedChrome).VersionInfo.ProductVersion
        Write-Step "Google Chrome 已安装，版本 $version，直接跳过"
        return
    }

    Write-Step "未检测到 Google Chrome，将从 Google 官网获取最新稳定版"
    $path = Join-Path $RunDirectory "GoogleChromeStandaloneEnterprise64.msi"
    $msiLogPath = Join-Path $LogDirectory ("chrome-msi-{0}.log" -f $RunId)
    Invoke-Download -Url $ChromeDownloadUrl -Destination $path -MinimumBytes 10MB
    try {
        Invoke-Installer `
            -Name "Google Chrome (latest stable)" `
            -Path $path `
            -Type "Msi" `
            -Arguments "/qn /norestart /L*v `"$msiLogPath`""
    }
    catch {
        $installedAfterAttempt = Find-ChromeExecutable
        if ($installedAfterAttempt) {
            $version = (Get-Item $installedAfterAttempt).VersionInfo.ProductVersion
            Write-Warning "Chrome MSI 返回异常，但已检测到 Chrome $version，继续部署。"
            return
        }

        Write-Warning "Chrome MSI 安装失败，正在尝试 Google 官方独立 EXE 安装器。"
        Write-Step "Chrome MSI 详细日志：$msiLogPath"
        $fallbackPath = Join-Path $RunDirectory "ChromeStandaloneSetup64.exe"
        Invoke-Download -Url $ChromeFallbackDownloadUrl -Destination $fallbackPath -MinimumBytes 10MB
        Invoke-Installer `
            -Name "Google Chrome standalone fallback" `
            -Path $fallbackPath `
            -Type "Exe" `
            -Arguments "/silent /install"

        foreach ($attempt in 1..12) {
            $installedAfterAttempt = Find-ChromeExecutable
            if ($installedAfterAttempt) {
                $version = (Get-Item $installedAfterAttempt).VersionInfo.ProductVersion
                Write-Step "Google Chrome 安装验证通过，版本：$version"
                return
            }
            Start-Sleep -Seconds 5
        }
        throw "Chrome 安装器已结束，但未找到 chrome.exe。MSI 日志：$msiLogPath"
    }
}

function Find-GalaxyExecutable {
    $registryPath = "HKCU:\Software\GalaxyBricklayer"
    if (Test-Path $registryPath) {
        $installDirectory = (Get-Item -Path $registryPath -ErrorAction SilentlyContinue).GetValue("InstallDir")
        if ($installDirectory) {
            $registeredExecutable = Join-Path $installDirectory "FastBet.exe"
            if (Test-Path $registeredExecutable) {
                return $registeredExecutable
            }
        }
    }

    $defaultExecutable = Join-Path $env:LOCALAPPDATA "Programs\GalaxyBricklayer\FastBet.exe"
    if (Test-Path $defaultExecutable) {
        return $defaultExecutable
    }
    return $null
}

function Install-LatestGalaxy {
    $installedGalaxy = Find-GalaxyExecutable
    if (-not $Force.IsPresent -and $installedGalaxy) {
        $version = (Get-Item $installedGalaxy).VersionInfo.ProductVersion
        Write-Step "银河搬砖工已安装，版本 $version，直接跳过"
        return
    }

    Write-Step "未检测到银河搬砖工，将从官网获取最新安装器"
    $path = Join-Path $RunDirectory "GalaxyBricklayer-latest-Setup.exe"
    try {
        Invoke-Download -Url $GalaxyDownloadUrl -Destination $path -MinimumBytes 10MB
    }
    catch {
        if ([string]::IsNullOrWhiteSpace($GalaxyFallbackDownloadUrl)) {
            throw
        }
        Write-Warning "官网动态下载接口暂不可用，正在改用官网最新版安装包地址"
        Invoke-Download -Url $GalaxyFallbackDownloadUrl -Destination $path -MinimumBytes 10MB
    }
    Get-Process -Name "FastBet" -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Invoke-Installer -Name "Galaxy Bricklayer (latest official)" -Path $path -Type "Exe" -Arguments "/S"
}

function Get-DeploymentStatus {
    param([array]$BundledPackages)

    $installedNames = @()
    $missingNames = @()

    if (-not $SkipChrome.IsPresent) {
        if (Find-ChromeExecutable) {
            $installedNames += "Google Chrome"
        }
        else {
            $missingNames += "Google Chrome"
        }
    }

    if (-not $SkipBundled.IsPresent) {
        foreach ($package in @($BundledPackages)) {
            if ($package.enabled -eq $false) {
                continue
            }
            if (Test-BundledPackageInstalled -Package $package) {
                $installedNames += $package.name
            }
            else {
                $missingNames += $package.name
            }
        }
    }

    if (-not $SkipGalaxy.IsPresent) {
        if (Find-GalaxyExecutable) {
            $installedNames += "银河搬砖工"
        }
        else {
            $missingNames += "银河搬砖工"
        }
    }

    return [PSCustomObject]@{
        Installed = @($installedNames)
        Missing = @($missingNames)
    }
}

$transcriptStarted = $false
try {
    Start-Transcript -Path $LogPath -Append | Out-Null
    $transcriptStarted = $true
    Write-Host "1. 环境检查中。" -ForegroundColor Cyan
    Assert-Administrator
    Write-Host ""
    Write-Host "银河搬砖工 Windows 工作环境一键部署" -ForegroundColor Green
    Write-Step "部署任务已启动，运行编号：$RunId"
    Write-Step "工作目录：$RunDirectory"
    Write-Step ("部署选项：Chrome={0}，GitHub内置软件={1}，银河搬砖工={2}，强制重装={3}" -f `
        (-not $SkipChrome.IsPresent), `
        (-not $SkipBundled.IsPresent), `
        (-not $SkipGalaxy.IsPresent), `
        $Force.IsPresent)

    $bundledPackages = @()
    if (-not $SkipBundled.IsPresent) {
        $bundledPackages = @(Get-BundledPackageManifest)
        if ($bundledPackages.Count -eq 0) {
            throw "GitHub 内置软件清单为空，无法继续检测。"
        }
        Write-Step "已进入 GitHub 内置软件检测，清单数量：$($bundledPackages.Count)"
    }
    else {
        Write-Step "已根据参数跳过 GitHub 内置软件"
    }

    $statusBefore = Get-DeploymentStatus -BundledPackages $bundledPackages
    $installedBeforeSummary = if (@($statusBefore.Installed).Count -gt 0) { $statusBefore.Installed -join " / " } else { "无" }
    Write-Host "2. 已检测到已安装：$installedBeforeSummary。" -ForegroundColor Green
    if (@($statusBefore.Missing).Count -gt 0) {
        Write-Host ("2. 检测到未安装：{0}。" -f ($statusBefore.Missing -join " / ")) -ForegroundColor Yellow
    }
    else {
        Write-Host "2. 检测完成，所有软件均已安装。" -ForegroundColor Green
    }

    $installationTargets = @(
        if ($Force.IsPresent) {
            @($statusBefore.Installed) + @($statusBefore.Missing)
        }
        else {
            @($statusBefore.Missing)
        }
    )

    if (@($installationTargets).Count -gt 0) {
        Write-Host ("3. 现在开始安装：{0}。" -f ($installationTargets -join " / ")) -ForegroundColor Cyan
    }
    else {
        Write-Host "3. 没有需要安装的软件。" -ForegroundColor Green
    }

    if (-not $SkipChrome.IsPresent -and ($Force.IsPresent -or ($statusBefore.Missing -contains "Google Chrome"))) {
        try {
            Install-LatestChrome
            Write-Host "5. Google Chrome 安装成功。" -ForegroundColor Green
        }
        catch {
            Write-Host "4. Google Chrome 安装失败，已跳过。" -ForegroundColor Yellow
            Write-Warning $_.Exception.Message
        }
    }

    $missingBundledNames = @($statusBefore.Missing | Where-Object { $_ -notin @("Google Chrome", "银河搬砖工") })
    if (-not $SkipBundled.IsPresent -and ($Force.IsPresent -or ($missingBundledNames.Count -gt 0))) {
        try {
            Install-BundledPackages
        }
        catch {
            Write-Warning "GitHub 内置软件部署流程异常：$($_.Exception.Message)"
            foreach ($package in $bundledPackages) {
                if ($package.enabled -and ($Force.IsPresent -or -not (Test-BundledPackageInstalled -Package $package))) {
                    Write-Host "4. $($package.name) 安装失败，已跳过。" -ForegroundColor Yellow
                }
            }
        }
    }

    if (-not $SkipGalaxy.IsPresent -and ($Force.IsPresent -or ($statusBefore.Missing -contains "银河搬砖工"))) {
        try {
            Install-LatestGalaxy
            Write-Host "5. 银河搬砖工安装成功。" -ForegroundColor Green
        }
        catch {
            Write-Host "4. 银河搬砖工安装失败，已跳过。" -ForegroundColor Yellow
            Write-Warning $_.Exception.Message
        }
    }

    $statusAfter = Get-DeploymentStatus -BundledPackages $bundledPackages
    $installedSummary = if (@($statusAfter.Installed).Count -gt 0) { $statusAfter.Installed -join " / " } else { "无" }
    $missingSummary = if (@($statusAfter.Missing).Count -gt 0) { $statusAfter.Missing -join " / " } else { "无" }
    $summaryColor = if (@($statusAfter.Missing).Count -gt 0) { "Yellow" } else { "Green" }
    Write-Host ""
    Write-Host "6. 运行完成：已安装 $installedSummary；未安装 $missingSummary。" -ForegroundColor $summaryColor
    Write-Host "详细日志：$LogPath" -ForegroundColor Green
}
catch {
    Write-Host ""
    Write-Host "部署失败：$($_.Exception.Message)" -ForegroundColor Red
    Write-Host "详细日志：$LogPath" -ForegroundColor Yellow
    exit 1
}
finally {
    if ($transcriptStarted) {
        Stop-Transcript | Out-Null
    }
    if (-not $KeepDownloadedFiles.IsPresent) {
        Remove-Item $RunDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}
