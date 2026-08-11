@echo off
setlocal
chcp 65001 >nul

net session >nul 2>&1
if not "%errorlevel%"=="0" (
    echo Requesting administrator privileges...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-All.ps1"
set "deploy_exit=%errorlevel%"
echo.
if "%deploy_exit%"=="0" (
    echo Deployment completed successfully.
) else (
    echo Deployment failed. Review the log under C:\ProgramData\GalaxyWorkstationDeploy\Logs.
)
pause
exit /b %deploy_exit%
