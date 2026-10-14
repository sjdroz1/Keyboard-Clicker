#Requires -Version 5.1
<#
.SYNOPSIS
    Taps a keyboard key on a timer while a game window is in the foreground.

.DESCRIPTION
    Sends the E key (by default) every 10 seconds using the Windows SendInput
    API with a hardware scan code, so fullscreen games receive a normal key tap.
    Starts paused. Focus FiveM, then press the toggle key.

.PARAMETER IntervalSeconds
    Seconds between taps. Default is 10.

.PARAMETER Key
    Letter to tap. Default is E.

.PARAMETER ToggleKey
    Key that turns tapping on and off. Default is F8.

.PARAMETER QuitKey
    Key that stops the script. Default is F9.

.PARAMETER AnyWindow
    Send taps to whatever window is in front. By default, taps are sent only
    while the foreground process name matches GameProcessPattern.

.PARAMETER GameProcessPattern
    Regular expression matched against the foreground process name.
    Default matches FiveM and GTA5 process names.
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 3600)]
    [int]$IntervalSeconds = 10,

    [ValidatePattern('^[A-Za-z]$')]
    [string]$Key = 'E',

    [ValidateNotNullOrEmpty()]
    [string]$ToggleKey = 'F8',

    [ValidateNotNullOrEmpty()]
    [string]$QuitKey = 'F9',

    [switch]$AnyWindow,

    [ValidateNotNullOrEmpty()]
    [string]$GameProcessPattern = 'FiveM|GTA5'
)

$ErrorActionPreference = 'Stop'

function ConvertTo-VirtualKey {
    param([string]$Name)

    # PowerShell's type name for a 16-bit unsigned integer is [uint16].
    # The C# name [ushort] is not a PowerShell type and stops the script.
    $normalized = $Name.ToUpperInvariant()
    if ($normalized -match '^F([1-9]|1[0-2])$') {
        return [uint16](0x70 + [int]$Matches[1] - 1)
    }
    if ($normalized -match '^[A-Z]$') {
        return [uint16][byte][char]$normalized
    }
    if ($normalized -eq 'END') { return [uint16]0x23 }
    if ($normalized -eq 'PAUSE') { return [uint16]0x13 }

    throw "Unsupported key '$Name'. Use a letter A-Z, F1-F12, End, or Pause."
}

if ([IntPtr]::Size -eq 8) {
    $inputStruct = @'
    [StructLayout(LayoutKind.Explicit, Size = 40)]
    public struct INPUT {
        [FieldOffset(0)] public uint type;
        [FieldOffset(8)] public KEYBDINPUT ki;
    }
'@
} else {
    $inputStruct = @'
    [StructLayout(LayoutKind.Explicit, Size = 28)]
    public struct INPUT {
        [FieldOffset(0)] public uint type;
        [FieldOffset(4)] public KEYBDINPUT ki;
    }
'@
}

$nativeSource = @"
using System;
using System.Runtime.InteropServices;

public static class EClickerNative {
    public const uint INPUT_KEYBOARD = 1;
    public const uint KEYEVENTF_KEYUP = 0x0002;
    public const uint KEYEVENTF_SCANCODE = 0x0008;

    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    $inputStruct

    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    [DllImport("user32.dll")]
    public static extern uint MapVirtualKey(uint uCode, uint uMapType);

    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int vKey);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    public static bool IsKeyDown(int vKey) {
        return (GetAsyncKeyState(vKey) & 0x8000) != 0;
    }

    public static string ForegroundProcessName() {
        IntPtr hwnd = GetForegroundWindow();
        if (hwnd == IntPtr.Zero) {
            return "";
        }

        uint pid;
        GetWindowThreadProcessId(hwnd, out pid);
        if (pid == 0) {
            return "";
        }

        try {
            return System.Diagnostics.Process.GetProcessById((int)pid).ProcessName;
        } catch {
            return "";
        }
    }

    public static uint PressScan(ushort vk, bool keyUp) {
        ushort scan = (ushort)MapVirtualKey(vk, 0);
        if (scan == 0) {
            return 0;
        }

        INPUT input = new INPUT();
        input.type = INPUT_KEYBOARD;
        input.ki.wVk = 0;
        input.ki.wScan = scan;
        input.ki.dwFlags = KEYEVENTF_SCANCODE;
        if (keyUp) {
            input.ki.dwFlags |= KEYEVENTF_KEYUP;
        }
        input.ki.time = 0;
        input.ki.dwExtraInfo = IntPtr.Zero;

        INPUT[] inputs = new INPUT[1];
        inputs[0] = input;
        return SendInput(1, inputs, Marshal.SizeOf(typeof(INPUT)));
    }

    public static string LastInputError() {
        return new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error()).Message;
    }
}
"@

if (-not ('EClickerNative' -as [type])) {
    Add-Type -TypeDefinition $nativeSource -Language CSharp
}

$tapVirtualKey = ConvertTo-VirtualKey $Key
$toggleVirtualKey = ConvertTo-VirtualKey $ToggleKey
$quitVirtualKey = ConvertTo-VirtualKey $QuitKey

if ($tapVirtualKey -eq $toggleVirtualKey -or $tapVirtualKey -eq $quitVirtualKey -or $toggleVirtualKey -eq $quitVirtualKey) {
    throw 'Key, ToggleKey, and QuitKey must be three different keys.'
}

$script:tapVirtualKey = $tapVirtualKey
$script:inputReady = $true

function Release-TapKey {
    if ($script:inputReady) {
        [void][EClickerNative]::PressScan([uint16]$script:tapVirtualKey, $true)
    }
}

function Send-KeyTap {
    $downCount = [EClickerNative]::PressScan([uint16]$script:tapVirtualKey, $false)
    Start-Sleep -Milliseconds 80
    $upCount = [EClickerNative]::PressScan([uint16]$script:tapVirtualKey, $true)
    if ($downCount -eq 1 -and $upCount -eq 1) {
        return 'sent'
    }

    $errorText = [EClickerNative]::LastInputError()
    return "SendInput failed ($errorText)"
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

$enabled = $false
$nextPress = [datetime]::MaxValue
$lastPress = $null
$lastResult = ''
$focusName = ''
$toggleWasDown = [EClickerNative]::IsKeyDown($toggleVirtualKey)
$quitWasDown = [EClickerNative]::IsKeyDown($quitVirtualKey)
$lastSignature = ''

function Show-Status {
    try {
        Clear-Host
    } catch {
        # Non-console hosts may not support clearing the screen.
    }
    Write-Host 'E Clicker'
    Write-Host "Tap:          $Key every $IntervalSeconds seconds"
    Write-Host "Toggle:       $ToggleKey"
    Write-Host "Quit:         $QuitKey"
    if ($AnyWindow) {
        Write-Host 'Sends to whatever window is in the foreground.'
    } else {
        Write-Host "Sends only while the foreground process matches: $GameProcessPattern"
    }
    Write-Host ''

    if ($enabled) {
        Write-Host 'Status: RUNNING' -ForegroundColor Green
        if ($lastResult -like 'waiting *') {
            Write-Host $lastResult -ForegroundColor Yellow
        } else {
            $remaining = [math]::Max(0, [int][math]::Ceiling(($nextPress - (Get-Date)).TotalSeconds))
            Write-Host "Next $Key in $remaining s"
            if ($focusName) {
                Write-Host "Foreground: $focusName"
            }
        }
    } else {
        Write-Host 'Status: PAUSED' -ForegroundColor Yellow
        Write-Host "Focus the game, then press $ToggleKey."
    }

    if ($lastPress) {
        Write-Host ("Last press: {0:HH:mm:ss}" -f $lastPress)
    }
    if ($lastResult -and $lastResult -notlike 'waiting *' -and $lastResult -ne 'paused') {
        Write-Host "Last result: $lastResult"
    }

    if (-not $isAdmin) {
        Write-Host ''
        Write-Host 'This window is not running as Administrator.' -ForegroundColor DarkYellow
        Write-Host 'If the game ignores the key, right-click Start-E-Clicker.bat and choose Run as administrator.' -ForegroundColor DarkYellow
    }
}

try {
    while ($true) {
        $toggleDown = [EClickerNative]::IsKeyDown($toggleVirtualKey)
        $quitDown = [EClickerNative]::IsKeyDown($quitVirtualKey)

        if ($quitDown -and -not $quitWasDown) {
            break
        }
        $quitWasDown = $quitDown

        if ($toggleDown -and -not $toggleWasDown) {
            $enabled = -not $enabled
            if ($enabled) {
                $nextPress = Get-Date
            } else {
                Release-TapKey
                $lastResult = 'paused'
            }
        }
        $toggleWasDown = $toggleDown

        if ($enabled -and (Get-Date) -ge $nextPress) {
            $focusName = [EClickerNative]::ForegroundProcessName()
            $gameFocused = $AnyWindow -or ($focusName -match $GameProcessPattern)

            if ($gameFocused) {
                $lastResult = Send-KeyTap
                $lastPress = Get-Date
                $nextPress = $lastPress.AddSeconds($IntervalSeconds)
            } else {
                $shownFocus = $focusName
                if (-not $shownFocus) { $shownFocus = '(none)' }
                $lastResult = "waiting for the game window (foreground: $shownFocus)"
                $nextPress = (Get-Date).AddSeconds(1)
            }
        } elseif ($enabled) {
            $focusName = [EClickerNative]::ForegroundProcessName()
        }

        $remaining = 0
        if ($enabled -and $lastResult -notlike 'waiting *') {
            $remaining = [math]::Max(0, [int][math]::Ceiling(($nextPress - (Get-Date)).TotalSeconds))
        }
        $signature = "$enabled|$remaining|$lastResult|$focusName"
        if ($signature -ne $lastSignature) {
            Show-Status
            $lastSignature = $signature
            $stateWord = 'PAUSED'
            if ($enabled) { $stateWord = 'ON' }
            try {
                $Host.UI.RawUI.WindowTitle = "E Clicker $stateWord"
            } catch {
                # Some hosts do not expose a console title.
            }
        }

        Start-Sleep -Milliseconds 50
    }
} finally {
    Release-TapKey
    Write-Host ''
    Write-Host 'Stopped.'
}
