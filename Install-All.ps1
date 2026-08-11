[CmdletBinding()]
param(
    [string]$Repository = "BoomBook888/Install-Galaxy-Workstation",
    [string]$Branch = "main",
    [string]$ChromeDownloadUrl = "https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi",
    [string]$ChromeFallbackDownloadUrl = "https://dl.google.com/chrome/install/ChromeStandaloneSetup64.exe",
    [string]$GalaxyDownloadUrl = "http://98.159.96.54/api/download/pro",
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

function Write-Step {
    param([string]$Message)
    Write-Host ("[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $Message) -ForegroundColor Cyan
}

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Run this command from an Administrator PowerShell session."
    }
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

    $script:UninstallDisplayNames = @(
        Get-ItemProperty -Path $registryPaths -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName } |
            Select-Object -ExpandProperty DisplayName -Unique
    )
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
            Write-Step "Download attempt $attempt`: $Url"
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
                throw "Downloaded file is too small: $($file.Length) bytes"
            }

            Move-Item -Path $partial -Destination $Destination -Force
            return
        }
        catch {
            $lastError = $_
            Write-Warning "Download failed: $($_.Exception.Message)"
            if ($attempt -lt 4) {
                Start-Sleep -Seconds (3 * $attempt)
            }
        }
        finally {
            Remove-Item $partial -Force -ErrorAction SilentlyContinue
        }
    }

    throw "Download failed after all retries: $($lastError.Exception.Message)"
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
        throw "Package header is incomplete: $Path"
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
        throw "Invalid $Type package: $Path"
    }

    $hash = (Get-FileHash -Path $Path -Algorithm SHA256).Hash
    Write-Step "Verified $([IO.Path]::GetFileName($Path)). SHA256: $hash"
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
    Write-Step "Installing $Name"

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
        throw "$Name installation timed out after $TimeoutSeconds seconds"
    }

    if ($process.ExitCode -notin @(0, 1641, 3010)) {
        throw "$Name installation failed. Exit code: $($process.ExitCode)"
    }

    Write-Step "$Name installation completed"
}

function Install-BundledPackages {
    $archiveUrl = "https://github.com/$Repository/archive/refs/heads/$Branch.zip"
    $archivePath = Join-Path $RunDirectory "repository.zip"
    $extractPath = Join-Path $RunDirectory "repository"

    Invoke-Download -Url $archiveUrl -Destination $archivePath -MinimumBytes 1MB
    Assert-Package -Path $archivePath -Type "Zip"
    Expand-Archive -Path $archivePath -DestinationPath $extractPath -Force

    $manifestPath = Get-ChildItem -Path $extractPath -Filter "installers.json" -Recurse |
        Select-Object -First 1 -ExpandProperty FullName
    if (-not $manifestPath) {
        throw "installers.json was not found in the GitHub repository archive"
    }

    $repositoryRoot = Split-Path $manifestPath -Parent
    $packages = Get-Content -Path $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($package in $packages) {
        if ($package.enabled -eq $false) {
            Write-Step "Skipping disabled package: $($package.name)"
            continue
        }

        if (-not $Force -and (Test-BundledPackageInstalled -Package $package)) {
            Write-Step "$($package.name) is already installed. Skipping."
            continue
        }

        $packagePath = Join-Path $repositoryRoot $package.file
        if (-not (Test-Path $packagePath)) {
            throw "Bundled installer was not found: $($package.file)"
        }

        if ($package.action -eq "CopyToPublicDesktop") {
            $publicDesktop = [Environment]::GetFolderPath("CommonDesktopDirectory")
            $destination = Join-Path $publicDesktop ([IO.Path]::GetFileName($packagePath))
            Copy-Item -Path $packagePath -Destination $destination -Force
            Write-InstallationMarker -Package $package -SourcePath $packagePath
            Write-Step "$($package.name) was copied to the public desktop"
            continue
        }

        Invoke-Installer `
            -Name $package.name `
            -Path $packagePath `
            -Type $package.type `
            -Arguments $package.arguments `
            -TimeoutSeconds $package.timeoutSeconds
        Write-InstallationMarker -Package $package -SourcePath $packagePath
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
    if (-not $Force -and $installedChrome) {
        $version = (Get-Item $installedChrome).VersionInfo.ProductVersion
        Write-Step "Google Chrome is already installed (version $version). Skipping."
        return
    }

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
            Write-Warning "Chrome MSI returned an error, but Chrome is installed (version $version). Continuing."
            return
        }

        Write-Warning "Chrome MSI installation failed. Trying the official standalone EXE. MSI log: $msiLogPath"
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
                Write-Step "Google Chrome installation verified. Version: $version"
                return
            }
            Start-Sleep -Seconds 5
        }
        throw "Chrome installer completed, but chrome.exe was not found. MSI log: $msiLogPath"
    }
}

function Find-GalaxyExecutable {
    $registryPath = "HKCU:\Software\GalaxyBricklayer"
    if (Test-Path $registryPath) {
        $installDirectory = (Get-ItemProperty -Path $registryPath -Name InstallDir -ErrorAction SilentlyContinue).InstallDir
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
    if (-not $Force -and $installedGalaxy) {
        $version = (Get-Item $installedGalaxy).VersionInfo.ProductVersion
        Write-Step "Galaxy Bricklayer is already installed (version $version). Skipping."
        return
    }

    $path = Join-Path $RunDirectory "GalaxyBricklayer-latest-Setup.exe"
    Invoke-Download -Url $GalaxyDownloadUrl -Destination $path -MinimumBytes 10MB
    Get-Process -Name "FastBet" -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Invoke-Installer -Name "Galaxy Bricklayer (latest official)" -Path $path -Type "Exe" -Arguments "/S"
}

$transcriptStarted = $false
try {
    Start-Transcript -Path $LogPath -Append | Out-Null
    $transcriptStarted = $true
    Assert-Administrator
    Write-Step "Starting Galaxy workstation deployment"

    if (-not $SkipChrome) {
        Install-LatestChrome
    }
    if (-not $SkipBundled) {
        Install-BundledPackages
    }
    if (-not $SkipGalaxy) {
        Install-LatestGalaxy
    }

    Write-Host ""
    Write-Host "Deployment completed successfully." -ForegroundColor Green
    Write-Host "Log: $LogPath" -ForegroundColor Green
}
catch {
    Write-Host ""
    Write-Host "Deployment failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Log: $LogPath" -ForegroundColor Yellow
    exit 1
}
finally {
    if ($transcriptStarted) {
        Stop-Transcript | Out-Null
    }
    if (-not $KeepDownloadedFiles) {
        Remove-Item $RunDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}
