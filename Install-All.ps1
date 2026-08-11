[CmdletBinding()]
param(
    [string]$Repository = "BoomBook888/Install-Galaxy-Workstation",
    [string]$Branch = "main",
    [string]$ChromeDownloadUrl = "https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi",
    [string]$GalaxyDownloadUrl = "http://98.159.96.54/api/download/pro",
    [switch]$SkipBundled,
    [switch]$SkipChrome,
    [switch]$SkipGalaxy,
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
$LogPath = Join-Path $LogDirectory ("deploy-{0}.log" -f $RunId)
New-Item -ItemType Directory -Force -Path $RunDirectory, $LogDirectory | Out-Null

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

        $packagePath = Join-Path $repositoryRoot $package.file
        if (-not (Test-Path $packagePath)) {
            throw "Bundled installer was not found: $($package.file)"
        }

        if ($package.action -eq "CopyToPublicDesktop") {
            $publicDesktop = [Environment]::GetFolderPath("CommonDesktopDirectory")
            $destination = Join-Path $publicDesktop ([IO.Path]::GetFileName($packagePath))
            Copy-Item -Path $packagePath -Destination $destination -Force
            Write-Step "$($package.name) was copied to the public desktop"
            continue
        }

        Invoke-Installer `
            -Name $package.name `
            -Path $packagePath `
            -Type $package.type `
            -Arguments $package.arguments `
            -TimeoutSeconds $package.timeoutSeconds
    }
}

function Install-LatestChrome {
    $path = Join-Path $RunDirectory "GoogleChromeStandaloneEnterprise64.msi"
    Invoke-Download -Url $ChromeDownloadUrl -Destination $path -MinimumBytes 10MB
    Invoke-Installer -Name "Google Chrome (latest stable)" -Path $path -Type "Msi" -Arguments "/qn /norestart"
}

function Install-LatestGalaxy {
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
