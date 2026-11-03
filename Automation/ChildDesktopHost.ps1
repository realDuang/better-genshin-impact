param(
    [Parameter(Mandatory = $true)][string]$RunDirectory,
    [int]$Width = 1920,
    [int]$Height = 1080
)
$ErrorActionPreference = 'Stop'
$null = New-Item -ItemType Directory -Path $RunDirectory -Force
$statusPath = Join-Path $RunDirectory 'child-host-status.json'
$stopPath = Join-Path $RunDirectory 'child-host.stop'
$eventsPath = Join-Path $RunDirectory 'rdp-events.log'

Add-Type -AssemblyName System.Windows.Forms,System.Drawing
Add-Type -Path (Join-Path $PSScriptRoot 'DesktopSession.cs') -ReferencedAssemblies System.dll,System.Core.dll,System.Windows.Forms.dll,System.Drawing.dll
Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public class QuietDesktopForm : Form
{
    protected override bool ShowWithoutActivation { get { return true; } }
}

[ComImport, Guid("302D8188-0052-4807-806A-362B628F9AC5"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface RdpChildSettings
{
    void set_Property([In, MarshalAs(UnmanagedType.BStr)] string name,
        [In, MarshalAs(UnmanagedType.Struct)] ref object value);
    [return: MarshalAs(UnmanagedType.Struct)]
    object get_Property([In, MarshalAs(UnmanagedType.BStr)] string name);
}

public static class ChildDesktopNative
{
    [DllImport("wtsapi32.dll", SetLastError = true)]
    public static extern bool WTSGetChildSessionId(out uint session);
    [DllImport("wtsapi32.dll", SetLastError = true)]
    public static extern bool WTSLogoffSession(IntPtr server, uint session, bool wait);

    public static void SelectChild(object client)
    {
        object enabled = true;
        ((RdpChildSettings)client).set_Property("ConnectToChildSession", ref enabled);
    }
}
'@

function Get-ComProperty($target, [string]$name) {
    $target.GetType().InvokeMember($name, [Reflection.BindingFlags]::GetProperty, $null, $target, $null)
}

function Set-ComProperty($target, [string]$name, $value) {
    $null = $target.GetType().InvokeMember($name, [Reflection.BindingFlags]::SetProperty, $null, $target, @($value))
}

function Invoke-ComMethod($target, [string]$name) {
    $null = $target.GetType().InvokeMember($name, [Reflection.BindingFlags]::InvokeMethod, $null, $target, $null)
}

function Write-Status([string]$state, [string]$message = '') {
    [pscustomobject]@{
        Time = (Get-Date).ToString('o')
        State = $state
        Message = $message
        HostPid = $PID
        ParentSession = $parentId
        ChildSession = $script:ownedChild
        Width = $Width
        Height = $Height
        LoginCompleted = $control.Logon.LoginCompleted
        LastLogonCode = $control.Logon.LastLogonCode
    } | ConvertTo-Json -Compress | Set-Content -LiteralPath $statusPath -Encoding UTF8
}

$script:ownedChild = $null
$script:client = $null
$script:failed = $false
$parentId = [Diagnostics.Process]::GetCurrentProcess().SessionId
$parent = [DesktopSessions]::Find($parentId)
if ($null -eq $parent -or $parent.Id -le 0 -or $parent.State -ne 0 -or -not $parent.User) {
    throw 'The parent Windows session must be active before creating a child desktop'
}
[uint32]$existing = 0
if ([ChildDesktopNative]::WTSGetChildSessionId([ref]$existing) -and $existing -ne [uint32]::MaxValue) {
    throw "A child session already exists: $existing"
}

$clientKey = 'HKCU:\Software\Microsoft\Terminal Server Client'
$suppressName = 'RemoteDesktop_SuppressWhenMinimized'
$oldSuppression = Get-ItemProperty -LiteralPath $clientKey -Name $suppressName -ErrorAction SilentlyContinue
$hadSuppression = $null -ne $oldSuppression
$null = New-Item -Path $clientKey -Force
$null = New-ItemProperty -LiteralPath $clientKey -Name $suppressName -PropertyType DWord -Value 2 -Force

[System.Windows.Forms.Application]::EnableVisualStyles()
$form = New-Object QuietDesktopForm
$form.Text = 'BetterGI task desktop'
$form.ClientSize = New-Object System.Drawing.Size(1280,720)
$form.ShowInTaskbar = $false
$form.Opacity = 0.0
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$form.Location = New-Object System.Drawing.Point(0,0)
$control = New-Object ChildDesktopAx
$control.Dock = [System.Windows.Forms.DockStyle]::Fill
$form.Controls.Add($control)
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000

$form.add_Shown({
    try {
        if (Test-Path -LiteralPath $stopPath) { $form.Close(); return }
        $script:client = $control.Client
        Set-ComProperty $script:client 'Server' 'localhost'
        Set-ComProperty $script:client 'DesktopWidth' $Width
        Set-ComProperty $script:client 'DesktopHeight' $Height
        Set-ComProperty $script:client 'ColorDepth' 32
        $advanced = Get-ComProperty $script:client 'AdvancedSettings7'
        $port = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp').PortNumber
        Set-ComProperty $advanced 'RDPPort' $port
        Set-ComProperty $advanced 'EnableCredSspSupport' $true
        Set-ComProperty $advanced 'SmartSizing' $true
        Set-ComProperty $advanced 'EnableWindowsKey' 1
        # 2 disables remote audio on the parent desktop.
        $secured = Get-ComProperty $script:client 'SecuredSettings2'
        Set-ComProperty $secured 'AudioRedirectionMode' 2
        if ((Get-ComProperty $secured 'AudioRedirectionMode') -ne 2) {
            throw 'The child desktop audio could not be muted'
        }
        Add-Content -LiteralPath $eventsPath -Value 'AudioRedirectionMode=2' -Encoding UTF8
        [ChildDesktopNative]::SelectChild($script:client)
        Invoke-ComMethod $script:client 'Connect'
        Write-Status 'connecting'
        $timer.Start()
    } catch {
        $script:failed = $true
        Write-Status 'failed' $_.Exception.Message
        $form.Close()
    }
})

$timer.add_Tick({
    try {
        # Capture the session once; never adopt a later replacement session.
        if ($null -eq $script:ownedChild) {
            [uint32]$child = 0
            if ([ChildDesktopNative]::WTSGetChildSessionId([ref]$child) -and $child -ne [uint32]::MaxValue) {
                if ($child -eq 0 -or $child -eq $parentId) { throw 'Invalid child session identity' }
                $script:ownedChild = $child
            }
        }
        foreach ($entry in $control.Logon.DrainEvents()) {
            Add-Content -LiteralPath $eventsPath -Value $entry -Encoding UTF8
        }
        $childInfo = if ($null -ne $script:ownedChild) { [DesktopSessions]::Find([int]$script:ownedChild) } else { $null }
        if ((Test-Path -LiteralPath $stopPath) -or ($null -ne $script:ownedChild -and $null -eq $childInfo)) {
            $form.Close()
            return
        }
        if ($control.Logon.Failure) { throw $control.Logon.Failure }
        $state = [int](Get-ComProperty $script:client 'Connected')
        if ($state -eq 1 -and $control.Logon.IsReady($childInfo, $parent.User)) {
            if ($childInfo.Domain -ne $parent.Domain) { throw 'The child session belongs to an unexpected domain' }
            # Keep the transparent RDP control visible so child-session updates continue.
            Write-Status 'ready'
        } elseif ($state -eq 1) {
            Write-Status 'authenticating' 'RDP transport connected; waiting for Windows logon completion'
        }
    } catch {
        $script:failed = $true
        Write-Status 'failed' $_.Exception.Message
        $form.Close()
    }
})

try {
    Write-Status 'starting'
    [System.Windows.Forms.Application]::Run($form)
} finally {
    $timer.Stop()
    if ($null -ne $script:ownedChild -and $null -ne [DesktopSessions]::Find([int]$script:ownedChild)) {
        $loggedOff = [ChildDesktopNative]::WTSLogoffSession([IntPtr]::Zero, [uint32]$script:ownedChild, $false)
        if (-not $loggedOff) {
            $script:failed = $true
            Write-Status 'cleanup-required' ('Child logoff failed: ' + [Runtime.InteropServices.Marshal]::GetLastWin32Error())
        }
    }
    # AxHost can release its RCW during Form.Close; avoid COM equality checks.
    try { Invoke-ComMethod $script:client 'Disconnect' } catch {}
    try { $control.Dispose() } catch {}
    try { $form.Dispose() } catch {}
    if ($hadSuppression) {
        Set-ItemProperty -LiteralPath $clientKey -Name $suppressName -Value $oldSuppression.$suppressName
    } else {
        Remove-ItemProperty -LiteralPath $clientKey -Name $suppressName -ErrorAction SilentlyContinue
    }
    if (-not $script:failed) { Write-Status 'closed' 'Desktop host closed; the runner must verify child-session teardown.' }
}
if ($script:failed) { exit 1 }
