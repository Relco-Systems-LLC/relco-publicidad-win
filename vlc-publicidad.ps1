#Requires -Version 5.0
<#
.SYNOPSIS
    Lanza VLC en bucle y pantalla completa en la pantalla secundaria.
    Primera vez: ejecutar con -Setup para crear los accesos directos.

.EXAMPLE
    .\vlc-publicidad.ps1 -Setup    # Crea accesos directos y lanza VLC
    .\vlc-publicidad.ps1            # Solo lanza VLC (lo usan los accesos directos)
#>
param(
    [switch]$Setup
)

# ── Configuracion ──────────────────────────────────────────────────────────────
$MediaFolder     = "$env:PUBLIC\relco_videos"
$ImageDuration   = 10       # segundos que se muestra cada imagen (jpg/png)
$SecondaryScreen = 1        # 0 = pantalla primaria, 1 = secundaria
$ShortcutName    = "Publicidad RELCO"

# ── Localizar VLC ──────────────────────────────────────────────────────────────
$VlcCandidates = @(
    "${env:ProgramFiles}\VideoLAN\VLC\vlc.exe",
    "${env:ProgramFiles(x86)}\VideoLAN\VLC\vlc.exe"
)
$VlcExe = $VlcCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $VlcExe) {
    [System.Windows.Forms.MessageBox]::Show("VLC no encontrado. Instale VLC Media Player.", "Error") | Out-Null
    exit 1
}

# ── Crear accesos directos (modo -Setup) ───────────────────────────────────────
if ($Setup) {
    $ScriptPath = $MyInvocation.MyCommand.Path
    if (-not $ScriptPath) {
        Write-Error "Ejecute el script desde un archivo .ps1 guardado en disco, no pegado en consola."
        exit 1
    }

    # Auto-instalar el script en C:\Users\Public si no esta ya ahi
    $InstallPath = "$env:PUBLIC\vlc-publicidad.ps1"
    if ((Resolve-Path $ScriptPath).Path -ne (Resolve-Path $InstallPath -ErrorAction SilentlyContinue).Path) {
        Copy-Item -Path $ScriptPath -Destination $InstallPath -Force
        Write-Host "Script instalado en: $InstallPath"
    }
    $ScriptPath = $InstallPath

    $PsExe  = Join-Path $PSHOME "powershell.exe"
    $PsArgs = "-WindowStyle Hidden -ExecutionPolicy Bypass -NonInteractive -File `"$ScriptPath`""
    $WorkDir = $env:PUBLIC

    $Wsh = New-Object -ComObject WScript.Shell

    # Acceso directo en Inicio automatico (solo usuario actual, sin necesidad de admin)
    $StartupDir = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
    $StartupLnk = Join-Path $StartupDir "$ShortcutName.lnk"
    $sc = $Wsh.CreateShortcut($StartupLnk)
    $sc.TargetPath       = $PsExe
    $sc.Arguments        = $PsArgs
    $sc.WorkingDirectory = $WorkDir
    $sc.IconLocation     = "$VlcExe,0"
    $sc.Description      = "Inicia publicidad en VLC al arrancar Windows"
    $sc.Save()
    Write-Host "Acceso directo inicio automatico: $StartupLnk"

    # Acceso directo en Escritorio
    $DesktopLnk = Join-Path ([Environment]::GetFolderPath('Desktop')) "$ShortcutName.lnk"
    $sc = $Wsh.CreateShortcut($DesktopLnk)
    $sc.TargetPath       = $PsExe
    $sc.Arguments        = $PsArgs
    $sc.WorkingDirectory = $WorkDir
    $sc.IconLocation     = "$VlcExe,0"
    $sc.Description      = "Inicia publicidad en VLC"
    $sc.Save()
    Write-Host "Acceso directo escritorio: $DesktopLnk"

    Write-Host ""
    Write-Host "Listo. Lanzando VLC ahora..."
}

# ── Buscar archivos multimedia ─────────────────────────────────────────────────
if (-not (Test-Path $MediaFolder)) {
    New-Item -ItemType Directory -Path $MediaFolder -Force | Out-Null
    Write-Host "Carpeta creada: $MediaFolder"
    Write-Host "Coloca archivos .mp4 / .jpg / .png en esa carpeta y vuelve a ejecutar."
    exit 0
}

$MediaFiles = Get-ChildItem -Path $MediaFolder -File |
    Where-Object { $_.Extension -imatch '\.(mp4|jpg|jpeg|png)$' } |
    Sort-Object Name

if ($MediaFiles.Count -eq 0) {
    Write-Host "No se encontraron archivos mp4/jpg/png en: $MediaFolder"
    exit 0
}

Write-Host "Archivos encontrados ($($MediaFiles.Count)):"
$MediaFiles | ForEach-Object { Write-Host "  $($_.Name)" }

# ── Lanzar VLC ─────────────────────────────────────────────────────────────────
$VlcArgs = @(
    "--fullscreen"
    "--loop"
    "--qt-fullscreen-screennumber=$SecondaryScreen"
    "--no-video-title-show"
    "--no-osd"
    "--image-duration=$ImageDuration"
) + ($MediaFiles | ForEach-Object { "`"$($_.FullName)`"" })

Write-Host "VLC: $VlcExe"
Write-Host "Args: $($VlcArgs -join ' ')"
$Proc = Start-Process -FilePath $VlcExe -ArgumentList $VlcArgs -PassThru

# Esperar a que VLC cree su ventana (maximo 15 segundos)
$Deadline = (Get-Date).AddSeconds(15)
do {
    Start-Sleep -Milliseconds 500
    $Proc.Refresh()
} until ($Proc.MainWindowHandle -ne 0 -or (Get-Date) -gt $Deadline)

# ── Ocultar icono de la barra de tareas ────────────────────────────────────────
# Se aplica WS_EX_TOOLWINDOW (ventana de herramienta, invisible en taskbar)
# y se quita WS_EX_APPWINDOW (que fuerza aparicion en taskbar).
if ($Proc.MainWindowHandle -ne 0) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class TaskbarHider {
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWndProc f, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern int  GetWindowLong(IntPtr h, int idx);
    [DllImport("user32.dll")] static extern int  SetWindowLong(IntPtr h, int idx, int val);

    delegate bool EnumWndProc(IntPtr h, IntPtr l);
    const int GWL_EXSTYLE      = -20;
    const int WS_EX_TOOLWINDOW = 0x00000080;
    const int WS_EX_APPWINDOW  = 0x00040000;

    public static void Hide(int processId) {
        EnumWindows((h, l) => {
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            if ((int)pid == processId && IsWindowVisible(h)) {
                int ex = GetWindowLong(h, GWL_EXSTYLE);
                SetWindowLong(h, GWL_EXSTYLE, (ex | WS_EX_TOOLWINDOW) & ~WS_EX_APPWINDOW);
            }
            return true;
        }, IntPtr.Zero);
    }
}
'@ -ErrorAction SilentlyContinue

    [TaskbarHider]::Hide($Proc.Id)
}
