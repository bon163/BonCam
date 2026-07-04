$ErrorActionPreference = 'Stop'
$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($currentIdentity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Machine install needs an Administrator PowerShell window.'
}

$sourceDll = Join-Path $PSScriptRoot 'bin\iphone_camera_source.dll'
if (-not (Test-Path $sourceDll)) {
    & (Join-Path $PSScriptRoot 'build.ps1')
}
if (-not (Test-Path $sourceDll)) {
    throw "Source DLL does not exist: $sourceDll"
}

$installDir = Join-Path $env:ProgramData 'IPhoneCameraStreaming'
New-Item -ItemType Directory -Force -Path $installDir | Out-Null
$targetDll = Join-Path $installDir 'iphone_camera_source.dll'

# The Camera Frame Server service keeps the source DLL mapped after any camera
# session, which blocks the copy. It is demand-start and restarts on next use.
foreach ($serviceName in 'FrameServerMonitor', 'FrameServer') {
    $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if ($service -and $service.Status -eq 'Running') {
        Write-Host "Stopping $serviceName to release the DLL..."
        Stop-Service -Name $serviceName -Force
    }
}

Copy-Item -Force -LiteralPath $sourceDll -Destination $targetDll

$acl = Get-Acl $installDir
$readRule = [System.Security.AccessControl.FileSystemAccessRule]::new('Users', 'ReadAndExecute', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
$writeRule = [System.Security.AccessControl.FileSystemAccessRule]::new('Users', 'Modify', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
$acl.SetAccessRule($readRule)
$acl.SetAccessRule($writeRule)
Set-Acl -Path $installDir -AclObject $acl

$clsid = '{7F812B6A-CA0B-4E6E-8E01-7A2D767C1F24}'
$base = "Registry::HKEY_LOCAL_MACHINE\Software\Classes\CLSID\$clsid"
$inproc = Join-Path $base 'InprocServer32'
New-Item -Force -Path $base | Out-Null
New-Item -Force -Path $inproc | Out-Null
Set-ItemProperty -Path $base -Name '(default)' -Value 'iPhone Camera Source'
Set-ItemProperty -Path $inproc -Name '(default)' -Value $targetDll
Set-ItemProperty -Path $inproc -Name 'ThreadingModel' -Value 'Both'

Write-Host 'Installed and registered machine-wide source DLL:' -ForegroundColor Green
Write-Host "  $targetDll"
