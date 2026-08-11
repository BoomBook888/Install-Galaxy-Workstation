# Install-Galaxy-Workstation

通过一条远程 PowerShell 命令部署银河搬砖工 Windows 工作环境。服务器自己从 GitHub 和官方下载源取得软件，不需要人工上传脚本或安装包。

## 软件来源

- 仓库内置软件：从本 GitHub 仓库的 `main` 分支取得。
- Google Chrome：每次从 Google 官方地址下载当前最新稳定版。
- 银河搬砖工：每次通过官网动态下载接口取得当前最新安装器。

Chrome 和银河搬砖工不在仓库内固定版本，也不使用旧安装包缓存。

## 服务器一键安装

以管理员身份打开 PowerShell，执行：

```powershell
$u='https://raw.githubusercontent.com/BoomBook888/Install-Galaxy-Workstation/main/Install-All.ps1'; $p="$env:TEMP\Install-All.ps1"; Invoke-WebRequest -UseBasicParsing -Uri $u -OutFile $p; powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $p
```

部署日志保存在：

```text
C:\ProgramData\GalaxyWorkstationDeploy\Logs
```

## 本地双击

将仓库下载到 Windows 后，可以双击 `Install-All.cmd`。

## 参数

```powershell
# 仅安装 Chrome 和银河搬砖工
.\Install-All.ps1 -SkipBundled

# 保留本次下载文件，便于调试
.\Install-All.ps1 -KeepDownloadedFiles
```

## 安全说明

每个安装包都会在执行前校验文件格式并记录 SHA256。`installers.json` 控制仓库内置软件的顺序、安静安装参数和启用状态。

`Activation utility` 会被部署到 Windows 公共桌面，但不在 SSH 无人值守会话中强制执行，避免图形窗口卡住整个部署流程。应只在持有有效软件授权时使用。
