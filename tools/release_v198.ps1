$ErrorActionPreference = 'Continue'
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class CredMan3 {
  [DllImport("advapi32.dll", EntryPoint="CredReadW", CharSet=CharSet.Unicode, SetLastError=true)]
  public static extern bool CredRead(string target, int type, int flags, out IntPtr credPtr);
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct CREDENTIAL {
    public int Flags; public int Type; public string TargetName; public string Comment;
    public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
    public int CredentialBlobSize; public IntPtr CredentialBlob; public int Persist;
    public int AttributeCount; public IntPtr Attributes; public string TargetAlias; public string UserName;
  }
}
"@
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ptr = [IntPtr]::Zero
$ok = [CredMan3]::CredRead('git:https://github.com', 1, 0, [ref]$ptr)
if (-not $ok -or $ptr -eq [IntPtr]::Zero) { throw 'CRED_READ_FAIL' }
$cred = [Runtime.InteropServices.Marshal]::PtrToStructure($ptr, [type][CredMan3+CREDENTIAL])
$bytes = New-Object byte[] $cred.CredentialBlobSize
[Runtime.InteropServices.Marshal]::Copy($cred.CredentialBlob, $bytes, 0, $cred.CredentialBlobSize)
$pat = $null
if ($bytes.Length -ge 2 -and $bytes[1] -eq 0) { $pat = [Text.Encoding]::Unicode.GetString($bytes) } else { $pat = [Text.Encoding]::UTF8.GetString($bytes) }
$pat = $pat.Trim()
Write-Output ('PAT_LEN=' + $pat.Length)
Set-Location D:\test\honor_scheduler_unlock
git add -A
git commit -m 'v1.9.8: camera QR-scan fix (qr_fix switch, bind-mount QRFUSION mask off) + VoLTE wording generalized' 2>&1 | ForEach-Object { "$_" }
git push origin main 2>&1 | ForEach-Object { "$_" }
$headers = @{ Authorization = "token $pat"; "User-Agent" = 'hcu-publisher' }
$bodyObj = @{ tag_name = 'v1.9.8'; target_commitish = 'main'; name = 'v1.9.8'; body = 'New switch: camera QR-scan fix (qr_fix, default on). Binds the module copy of odm facemaskconfig.xml (QRFUSION algo-slot-5 entry removed) over /odm/etc/camera/airaw/facemaskconfig.xml at post-fs-data: the ROM runs a 6-frame RAW fusion for the QR/document scene, and with the stock AF hunting between focus peaks on high-contrast QR patterns the fused burst ghost-blurs captures (repeat zoom-in/out before a scan succeeds). No partition write, dm-verity untouched, off = plain umount, reopen camera to apply. VoLTE switch wording generalized: the ims-APN inserter is carrier-agnostic (adds a type=ims row for any inserted SIM missing one, CN or overseas). AI-generated module, tested on LDY-AN00 (Dimensity 9500 / MagicOS 10).'; draft = $false; prerelease = $false }
$json = $bodyObj | ConvertTo-Json
try {
  $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/mengwuzhuanshou/HonorSchedulerUnlock/releases' -Method Post -Headers $headers -Body ([System.Text.Encoding]::UTF8.GetBytes($json)) -ContentType 'application/json; charset=utf-8'
  Write-Output ('RELEASE_CREATED=' + $rel.id)
  $asset = Invoke-RestMethod -Uri ('https://uploads.github.com/repos/mengwuzhuanshou/HonorSchedulerUnlock/releases/' + $rel.id + '/assets?name=HonorSchedulerUnlock-v1.9.8.zip') -Method Post -Headers $headers -ContentType 'application/zip' -InFile 'D:\test\honor_scheduler_unlock\dist\HonorSchedulerUnlock-v1.9.8.zip'
  Write-Output ('ASSET_UPLOADED=' + $asset.name)
} catch {
  $em = "$($_.ErrorDetails.Message)"
  Write-Output ('RELEASE_FAIL: ' + $em.Substring(0, [Math]::Min(300, [Math]::Max(1, $em.Length))))
}
Write-Output 'ALL_DONE'
