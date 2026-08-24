<#
.SYNOPSIS
    Neovide + Neovim (LazyVim) 一键环境配置脚本
.DESCRIPTION
    自动安装和配置以下组件:
      1. Neovim (nightly/stable)
      2. Neovide (GPU-accelerated frontend)
      3. JetBrainsMono Nerd Font + Cascadia Mono (guifont)
      4. 外部工具: ripgrep, fd, fzf, yazi, stylua, git, python3, LLVM/clangd
      5. lldb-dap DAP 调试适配器 (随 LLVM 安装, 无需单独下载)
      6. Lazy.nvim 插件同步
      7. CapsLock→Esc 映射注册 (可选)
    运行: 以管理员权限打开 PowerShell, 执行:
      Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
      .\setup.ps1
.NOTES
    Windows 10/11 only. 需要网络连接.
#>

param(
    [switch]$SkipFonts,
    [switch]$SkipCapslock,
    [switch]$SkipPlugins,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# ────────────────────────────────────────────────
# Helpers
# ────────────────────────────────────────────────

function Write-Step { param([string]$msg) Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok   { param([string]$msg) Write-Host "  [OK] $msg" -ForegroundColor Green }
function Write-Skip { param([string]$msg) Write-Host "  [SKIP] $msg" -ForegroundColor Yellow }
function Write-Err  { param([string]$msg) Write-Host "  [ERR] $msg" -ForegroundColor Red }

function Test-Command {
    param([string]$Name)
    $null = Get-Command $Name -ErrorAction SilentlyContinue
    return $?
}

function Ensure-WinGet {
    if (Test-Command "winget") { return $true }
    Write-Err "winget 未找到。请确保你运行的是 Windows 10 1809+ 并已安装 App Installer"
    Write-Host "  下载地址: https://aka.ms/getwinget" -ForegroundColor Yellow
    return $false
}

function Install-WinGetPackage {
    param(
        [string]$Id,
        [string]$Name,
        [string]$TestCmd = ""
    )
    if ($TestCmd -and (Test-Command $TestCmd) -and (-not $Force)) {
        Write-Skip "$Name 已安装 ($TestCmd)"
        return
    }
    Write-Host "  安装 $Name ($Id) ..."
    winget install --id $Id --accept-package-agreements --accept-source-agreements --silent
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "$Name 安装完成"
    } else {
        Write-Err "$Name 安装失败 (exit code $LASTEXITCODE), 请手动安装"
    }
}

function Refresh-Path {
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("Path", "User")
}

# ────────────────────────────────────────────────
# 0. 前置检查
# ────────────────────────────────────────────────

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════╗" -ForegroundColor Magenta
Write-Host "║   Neovide + Neovim (LazyVim) 一键环境配置           ║" -ForegroundColor Magenta
Write-Host "╚══════════════════════════════════════════════════════╝" -ForegroundColor Magenta
Write-Host ""

$configDir = "$env:LOCALAPPDATA\nvim"
if (-not (Test-Path "$configDir\init.lua")) {
    Write-Err "未找到 nvim 配置目录: $configDir\init.lua"
    Write-Host "  请先 clone 配置仓库:" -ForegroundColor Yellow
    Write-Host "  git clone <YOUR_NVIM_CONFIG_REPO> `"$configDir`"" -ForegroundColor White
    exit 1
}

if (-not (Ensure-WinGet)) { exit 1 }

# ────────────────────────────────────────────────
# 1. 核心编辑器: Neovim + Neovide
# ────────────────────────────────────────────────

Write-Step "1. 安装核心编辑器"

Install-WinGetPackage -Id "Neovim.Neovim" -Name "Neovim" -TestCmd "nvim"
Install-WinGetPackage -Id "Neovide.Neovide" -Name "Neovide" -TestCmd "neovide"

Refresh-Path

# ────────────────────────────────────────────────
# 2. 字体: JetBrainsMono Nerd Font + Cascadia Mono
# ────────────────────────────────────────────────

Write-Step "2. 安装字体"

if ($SkipFonts) {
    Write-Skip "字体安装已跳过 (-SkipFonts)"
} else {
    $fontDir = "$env:LOCALAPPDATA\Microsoft\Windows\Fonts"
    $jbInstalled = Get-ChildItem -Path $fontDir -Filter "JetBrainsMono*Nerd*" -ErrorAction SilentlyContinue
    $sysFontDir = Join-Path $env:SystemRoot "Fonts"
    $sysJbInstalled = Get-ChildItem -Path $sysFontDir -Filter "JetBrainsMono*Nerd*" -ErrorAction SilentlyContinue

    if (($jbInstalled -or $sysJbInstalled) -and (-not $Force)) {
        Write-Skip "JetBrainsMono Nerd Font 已安装"
    } else {
        Write-Host "  下载 JetBrainsMono Nerd Font ..."
        $nfUrl = "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.zip"
        $nfZip = "$env:TEMP\JetBrainsMono_NF.zip"
        $nfExtract = "$env:TEMP\JetBrainsMono_NF"

        try {
            Invoke-WebRequest -Uri $nfUrl -OutFile $nfZip -UseBasicParsing
            Expand-Archive -Path $nfZip -DestinationPath $nfExtract -Force

            $shellApp = New-Object -ComObject Shell.Application
            $fontsFolder = $shellApp.Namespace(0x14)  # CSIDL_FONTS
            Get-ChildItem -Path $nfExtract -Filter "*.ttf" | ForEach-Object {
                $fontsFolder.CopyHere($_.FullName, 0x10)  # 0x10 = overwrite
            }
            Write-Ok "JetBrainsMono Nerd Font 安装完成"
        } catch {
            Write-Err "字体安装失败: $($_.Exception.Message)"
            Write-Host "  请手动下载: $nfUrl" -ForegroundColor Yellow
        } finally {
            Remove-Item -Path $nfZip -Force -ErrorAction SilentlyContinue
            Remove-Item -Path $nfExtract -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # Cascadia Mono 通常随 Windows Terminal 预装
    $cascadiaInstalled = Get-ChildItem -Path (Join-Path $env:SystemRoot "Fonts") -Filter "CascadiaMono*" -ErrorAction SilentlyContinue
    if ($cascadiaInstalled) {
        Write-Skip "Cascadia Mono 已安装 (随 Windows Terminal 预装)"
    } else {
        Install-WinGetPackage -Id "Microsoft.CascadiaCode" -Name "Cascadia Code/Mono"
    }
}

# ────────────────────────────────────────────────
# 3. 必备外部工具
# ────────────────────────────────────────────────

Write-Step "3. 安装外部工具"

# Git (yazi needs Git/usr/bin for MIME detection)
Install-WinGetPackage -Id "Git.Git" -Name "Git" -TestCmd "git"

# ripgrep (snacks.picker / grep)
Install-WinGetPackage -Id "BurntSushi.ripgrep.MSVC" -Name "ripgrep" -TestCmd "rg"

# fd (snacks.picker / file finder)
Install-WinGetPackage -Id "sharkdp.fd" -Name "fd" -TestCmd "fd"

# fzf (fuzzy finder, optional but useful)
Install-WinGetPackage -Id "junegunn.fzf" -Name "fzf" -TestCmd "fzf"

# yazi (file manager, used by <leader>e keybinding)
Install-WinGetPackage -Id "sxyazi.yazi" -Name "yazi" -TestCmd "yazi"

# stylua (Lua formatter, referenced in stylua.toml)
Install-WinGetPackage -Id "JohnnyMorganz.StyLua" -Name "StyLua" -TestCmd "stylua"

# Python 3 (needed by capslock_to_esc.pyw and DAP test scripts)
Install-WinGetPackage -Id "Python.Python.3.12" -Name "Python 3.12" -TestCmd "python3"

# Node.js (some Mason LSP servers may need it)
Install-WinGetPackage -Id "OpenJS.NodeJS.LTS" -Name "Node.js LTS" -TestCmd "node"

Refresh-Path

# ────────────────────────────────────────────────
# 4. LLVM / clangd (UE C++ LSP)
# ────────────────────────────────────────────────

Write-Step "4. 安装 LLVM (clangd + clang-format)"

$llvmDir = Join-Path $env:ProgramFiles "LLVM\bin"
if ((Test-Path (Join-Path $llvmDir "clangd.exe")) -and (-not $Force)) {
    Write-Skip "LLVM/clangd 已安装 ($(Join-Path $llvmDir 'clangd.exe'))"
} else {
    Install-WinGetPackage -Id "LLVM.LLVM" -Name "LLVM (clangd, clang-format)"
    Refresh-Path

    # 确保 LLVM\bin 在 PATH 中
    $userPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
    if ($userPath -notlike "*LLVM\bin*") {
        [System.Environment]::SetEnvironmentVariable(
            "Path",
            "$userPath;$llvmDir",
            "User"
        )
        $env:Path += ";$llvmDir"
        Write-Ok "已将 LLVM\bin 添加到 PATH"
    }
}

# ────────────────────────────────────────────────
# 5. lldb-dap DAP 调试适配器 (随 LLVM 安装, 无需单独下载)
# ────────────────────────────────────────────────

Write-Step "5. 校验 lldb-dap (DAP 调试适配器)"

$lldbDapCandidates = @(
    (Join-Path $llvmDir "lldb-dap.exe"),
    (Join-Path $llvmDir "lldb-dap-18.exe"),
    (Join-Path $llvmDir "lldb-dap-19.exe"),
    (Join-Path $llvmDir "lldb-dap-20.exe"),
    (Join-Path $llvmDir "lldb-dap-21.exe"),
    (Join-Path $llvmDir "lldb-dap-22.exe")
)
$lldbDap = $lldbDapCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($lldbDap) {
    Write-Ok "lldb-dap: $lldbDap"
} else {
    Write-Err "lldb-dap 未在 $llvmDir 找到 (LLVM 18+ 才自带; 当前安装可能过旧)"
    Write-Host "  检查 LLVM 版本: & '$llvmDir\clang.exe' --version" -ForegroundColor Yellow
    Write-Host "  如需升级: winget upgrade --id LLVM.LLVM" -ForegroundColor Yellow
}

# Python (用于 lldb-dap 的 Python script bridge & UE4 data formatter)
# Python 3.12 已在 step 3 安装。lldb-dap 会自己 discover。

# ────────────────────────────────────────────────
# 6. Lazy.nvim 插件同步
# ────────────────────────────────────────────────

Write-Step "6. 同步 Lazy.nvim 插件"

if ($SkipPlugins) {
    Write-Skip "插件同步已跳过 (-SkipPlugins)"
} else {
    Write-Host "  运行 nvim --headless '+Lazy! restore' +qa ..."
    $nvimExe = Get-Command "nvim" -ErrorAction SilentlyContinue
    if ($nvimExe) {
        # Lazy! restore 根据 lazy-lock.json 精确还原所有插件版本
        & nvim --headless "+Lazy! restore" +qa 2>&1 | ForEach-Object { Write-Host "  $_" }
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "Lazy.nvim 插件同步完成"
        } else {
            Write-Err "插件同步可能有问题 (exit code $LASTEXITCODE)"
            Write-Host "  请手动打开 nvim 运行 :Lazy restore 检查" -ForegroundColor Yellow
        }

        # 安装 treesitter parsers
        Write-Host "  安装 TreeSitter parsers (cpp, lua, python, json, yaml, markdown) ..."
        & nvim --headless "+TSInstallSync! cpp lua python json yaml markdown vimdoc" +qa 2>&1 | ForEach-Object { Write-Host "  $_" }
        Write-Ok "TreeSitter parsers 安装完成"
    } else {
        Write-Err "nvim 不在 PATH 中, 请手动运行 :Lazy restore"
    }
}

# ────────────────────────────────────────────────
# 7. CapsLock → Esc 映射 (可选)
# ────────────────────────────────────────────────

Write-Step "7. CapsLock → Esc 映射工具"

if ($SkipCapslock) {
    Write-Skip "CapsLock 映射已跳过 (-SkipCapslock)"
} else {
    $capsTool = "$configDir\tools\capslock_to_esc.pyw"
    $capsStart = "$configDir\tools\capslock_to_esc_start.cmd"

    if (-not (Test-Path $capsTool)) {
        Write-Skip "capslock_to_esc.pyw 未找到, 跳过"
    } else {
        Write-Ok "CapsLock→Esc 工具已存在: $capsTool"

        # 创建开机自启快捷方式
        $startupDir = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
        $shortcutPath = "$startupDir\CapsLock2Esc.lnk"

        if ((Test-Path $shortcutPath) -and (-not $Force)) {
            Write-Skip "开机自启快捷方式已存在"
        } else {
            $answer = Read-Host "  是否创建开机自启快捷方式? (Y/n)"
            if ($answer -eq "" -or $answer -match "^[Yy]") {
                try {
                    $WshShell = New-Object -ComObject WScript.Shell
                    $shortcut = $WshShell.CreateShortcut($shortcutPath)
                    $shortcut.TargetPath = $capsStart
                    $shortcut.WorkingDirectory = "$configDir\tools"
                    $shortcut.WindowStyle = 7  # Minimized
                    $shortcut.Description = "CapsLock to Esc remap for Neovim"
                    $shortcut.Save()
                    Write-Ok "开机自启快捷方式已创建: $shortcutPath"
                } catch {
                    Write-Err "快捷方式创建失败: $($_.Exception.Message)"
                }
            } else {
                Write-Skip "开机自启快捷方式已跳过"
            }
        }

        # 启动 capslock_to_esc (如果未运行)
        $capsRunning = Get-Process -Name "pythonw*","pyw*" -ErrorAction SilentlyContinue |
            Where-Object { $_.MainModule.FileName -like "*capslock*" -or $_.CommandLine -like "*capslock*" }
        if (-not $capsRunning) {
            $startIt = Read-Host "  是否现在启动 CapsLock→Esc? (Y/n)"
            if ($startIt -eq "" -or $startIt -match "^[Yy]") {
                Start-Process -FilePath $capsStart -WorkingDirectory "$configDir\tools" -WindowStyle Hidden
                Write-Ok "CapsLock→Esc 已启动"
            }
        } else {
            Write-Skip "CapsLock→Esc 已在运行"
        }
    }
}

# ────────────────────────────────────────────────
# 8. 最终检查
# ────────────────────────────────────────────────

Write-Step "8. 环境检查"

Refresh-Path

$checks = @(
    @{ Name = "nvim";      Cmd = "nvim";      Required = $true  },
    @{ Name = "neovide";   Cmd = "neovide";   Required = $true  },
    @{ Name = "git";       Cmd = "git";       Required = $true  },
    @{ Name = "rg";        Cmd = "rg";        Required = $true  },
    @{ Name = "fd";        Cmd = "fd";        Required = $true  },
    @{ Name = "fzf";       Cmd = "fzf";       Required = $false },
    @{ Name = "yazi";      Cmd = "yazi";      Required = $true  },
    @{ Name = "stylua";    Cmd = "stylua";    Required = $false },
    @{ Name = "clangd";    Cmd = "clangd";    Required = $true  },
    @{ Name = "clang-format"; Cmd = "clang-format"; Required = $true },
    @{ Name = "node";      Cmd = "node";      Required = $false },
    @{ Name = "python3";   Cmd = "python3";   Required = $false }
)

$allGood = $true
foreach ($c in $checks) {
    if (Test-Command $c.Cmd) {
        $ver = ""
        try { $ver = (& $c.Cmd --version 2>&1 | Select-Object -First 1) } catch {}
        Write-Ok "$($c.Name): $ver"
    } else {
        if ($c.Required) {
            Write-Err "$($c.Name): 未找到 [必需]"
            $allGood = $false
        } else {
            Write-Host "  [WARN] $($c.Name): 未找到 [可选]" -ForegroundColor Yellow
        }
    }
}

# 检查 lldb-dap (随 LLVM 自带)
$lldbDapCheck = $null
foreach ($cand in @("lldb-dap.exe","lldb-dap-18.exe","lldb-dap-19.exe","lldb-dap-20.exe","lldb-dap-21.exe","lldb-dap-22.exe")) {
    $p = Join-Path $llvmDir $cand
    if (Test-Path $p) { $lldbDapCheck = $p; break }
}
if ($lldbDapCheck) {
    Write-Ok "lldb-dap: $lldbDapCheck"
} else {
    Write-Err "lldb-dap: 未在 LLVM\bin 找到 (需要 LLVM 18+)"
    $allGood = $false
}

# 检查字体
$jbCheck = Get-ChildItem -Path "$env:LOCALAPPDATA\Microsoft\Windows\Fonts",(Join-Path $env:SystemRoot "Fonts") -Filter "JetBrainsMono*Nerd*" -ErrorAction SilentlyContinue
if ($jbCheck) {
    Write-Ok "JetBrainsMono Nerd Font: 已安装"
} else {
    Write-Host "  [WARN] JetBrainsMono Nerd Font: 未找到" -ForegroundColor Yellow
}

# ────────────────────────────────────────────────
# 完成
# ────────────────────────────────────────────────

Write-Host ""
if ($allGood) {
    Write-Host "╔══════════════════════════════════════════════════════╗" -ForegroundColor Green
    Write-Host "║   ✓ 所有必需组件安装完成!                           ║" -ForegroundColor Green
    Write-Host "╚══════════════════════════════════════════════════════╝" -ForegroundColor Green
} else {
    Write-Host "╔══════════════════════════════════════════════════════╗" -ForegroundColor Yellow
    Write-Host "║   ⚠ 部分组件缺失, 请检查上方 [ERR] 项目            ║" -ForegroundColor Yellow
    Write-Host "╚══════════════════════════════════════════════════════╝" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "启动方式:" -ForegroundColor White
Write-Host "  neovide                      # 打开 Neovide" -ForegroundColor Gray
Write-Host "  neovide -- --cmd 'cd <YOUR_PROJECT>'    # 打开指定项目" -ForegroundColor Gray
Write-Host ""
Write-Host "首次启动说明:" -ForegroundColor White
Write-Host "  1. Lazy.nvim 会自动下载所有插件 (如未运行 restore)" -ForegroundColor Gray
Write-Host "  2. Mason 会自动安装 LSP 服务器 (lua_ls 等)" -ForegroundColor Gray
Write-Host "  3. clangd 使用 LLVM 全局安装版 (UE 项目推荐)" -ForegroundColor Gray
Write-Host "  4. 如需 Android DAP, 需额外安装 Android NDK lldb-server (arm64)" -ForegroundColor Gray
Write-Host "     路径配置: ~/.config/nvim 中 ue.config dap.android_lldb_server" -ForegroundColor Gray
Write-Host ""
