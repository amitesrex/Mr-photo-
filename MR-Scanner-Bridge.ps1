# MR Scanner Bridge  -  browser (MR Photo app) ko Windows scanner (WIA) se jodta hai.
# Sirf aapke apne computer par (localhost) chalta hai, internet par kuch nahi bhejta.
param(
  [int]$Port = 8765,
  [string]$MockImage = ''      # sirf testing ke liye: scanner ke bina is JPG ko "scan" ki tarah bhejta hai
)
$ErrorActionPreference = 'Stop'
$JpegId = '{B96B3CAE-0728-11D3-9D7B-0000F81EF32E}'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path

# ---- pairing code: ek baar banta hai, token.txt me save rehta hai ----
$TokenFile = Join-Path $Here 'token.txt'
if (Test-Path $TokenFile) { $Token = (Get-Content $TokenFile -Raw).Trim() }
if (-not $Token) {
  $Token = (Get-Random -Minimum 100000 -Maximum 999999).ToString()
  Set-Content -Path $TokenFile -Value $Token
}

function Get-Scanners {
  $dm = New-Object -ComObject WIA.DeviceManager
  $list = @()
  foreach ($di in $dm.DeviceInfos) {
    if ($di.Type -eq 1) {
      $name = ''
      try { $name = [string]$di.Properties.Item('Name').Value } catch {}
      $list += @{ id = [string]$di.DeviceID; name = $name }
    }
  }
  return ,$list
}

function Set-WiaProp($item, [int]$id, $value) {
  try { $item.Properties.Item($id).Value = $value; return $true } catch { return $false }
}
# DPI jaisi value: scanner ki list / range me se sabse nazdeek manya value set karta hai, aur jo set hui wo lautata hai (0 = set nahi hua)
function Set-WiaNearest($item, [int]$id, [int]$want) {
  try {
    $p = $item.Properties.Item($id)
    $cands = @()
    if ($p.SubType -eq 2) { foreach ($v in $p.SubTypeValues) { $cands += [int]$v } }
    if ($cands.Count -gt 0) { $want = [int](($cands | Sort-Object { [math]::Abs($_ - $want) } | Select-Object -First 1)) }
    elseif ($p.SubType -eq 1) { $want = [int][math]::Max([int]$p.SubTypeMin, [math]::Min([int]$p.SubTypeMax, $want)) }
    $p.Value = $want
    return $want
  } catch { return 0 }
}
function Get-WiaMax($item, [int]$id) {
  try { $m = [int]$item.Properties.Item($id).SubTypeMax; if ($m -gt 0) { return $m } } catch {}
  return 0
}

function Invoke-Scan([string]$devId, [int]$dpi, [int]$color, [string]$area) {
  $dm = New-Object -ComObject WIA.DeviceManager
  $target = $null
  foreach ($di in $dm.DeviceInfos) {
    if ($di.Type -ne 1) { continue }
    if ($devId -eq '' -or [string]$di.DeviceID -eq $devId) { $target = $di; break }
  }
  if ($target -eq $null) { throw 'Scanner nahi mila. USB / WiFi aur power check karein.' }
  $dev = $target.Connect()
  $item = $dev.Items.Item(1)
  # WIA property IDs: 6146 intent (1 color, 2 gray), 4103 data type (3 color, 2 gray), 6147/6148 dpi, 6149/6150 start, 6151/6152 extent, 6154/6155 brightness/contrast
  [void](Set-WiaProp $item 6146 $color)
  [void](Set-WiaProp $item 4103 $(if ($color -eq 2) { 2 } else { 3 }))
  [void](Set-WiaProp $item 6154 0)
  [void](Set-WiaProp $item 6155 0)
  $dpiX = Set-WiaNearest $item 6147 $dpi
  $dpiY = Set-WiaNearest $item 6148 $dpi
  if ($dpiX -le 0) { $dpiX = $dpi }
  if ($dpiY -le 0) { $dpiY = $dpiX }
  if ($dpiX -ne $dpi) { Write-Host ('  (scanner {0} dpi nahi deta, {1} dpi par scan ho raha hai)' -f $dpi, $dpiX) }
  $mm = switch ($area) { 'A4' { @(210, 297) } 'A5' { @(148, 210) } '4x6' { @(101.6, 152.4) } default { $null } }
  if ($mm -ne $null) {
    [void](Set-WiaProp $item 6149 0)
    [void](Set-WiaProp $item 6150 0)
    $w = [int][math]::Round($mm[0] / 25.4 * $dpiX)
    $h = [int][math]::Round($mm[1] / 25.4 * $dpiY)
    $maxW = Get-WiaMax $item 6151
    $maxH = Get-WiaMax $item 6152
    if ($maxW -gt 0 -and $w -gt $maxW) { $w = $maxW }   # scanner ka bed chhota ho to uske andar hi rakhein
    if ($maxH -gt 0 -and $h -gt $maxH) { $h = $maxH }
    $okW = Set-WiaProp $item 6151 $w
    $okH = Set-WiaProp $item 6152 $h
    if (-not ($okW -and $okH)) { Write-Host '  (scan area scanner ne manya nahi, poora bed scan ho raha hai)' }
  }
  $img = $item.Transfer($JpegId)
  if ($img.FormatID -ne $JpegId) {
    $ip = New-Object -ComObject WIA.ImageProcess
    [void]$ip.Filters.Add($ip.FilterInfos.Item('Convert').FilterID)
    $ip.Filters.Item(1).Properties.Item('FormatID').Value = $JpegId
    $ip.Filters.Item(1).Properties.Item('Quality').Value = 92
    $img = $ip.Apply($img)
  }
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ('mrscan_' + [guid]::NewGuid().ToString('N') + '.jpg')
  try { $img.SaveFile($tmp); return [IO.File]::ReadAllBytes($tmp) } finally { if (Test-Path $tmp) { Remove-Item $tmp -Force } }
}

function Send-Bytes($ctx, [int]$code, [string]$type, [byte[]]$bytes) {
  $r = $ctx.Response
  $r.StatusCode = $code
  $r.ContentType = $type
  $r.Headers.Add('Access-Control-Allow-Origin', '*')
  $r.Headers.Add('Access-Control-Allow-Methods', 'GET, OPTIONS')
  $r.Headers.Add('Access-Control-Allow-Headers', '*')
  $r.Headers.Add('Access-Control-Allow-Private-Network', 'true')
  $r.Headers.Add('Access-Control-Max-Age', '600')
  $r.Headers.Add('Cache-Control', 'no-store')
  $r.ContentLength64 = $bytes.Length
  if ($bytes.Length -gt 0) { $r.OutputStream.Write($bytes, 0, $bytes.Length) }
  $r.OutputStream.Close()
}
function Send-Json($ctx, [int]$code, $obj) {
  $json = ConvertTo-Json -InputObject $obj -Depth 5 -Compress
  Send-Bytes $ctx $code 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($json))
}
function Get-Q($url, [string]$name) {
  $q = $url.Query.TrimStart('?')
  foreach ($p in $q.Split('&')) {
    $kv = $p.Split('=', 2)
    if ($kv[0] -eq $name -and $kv.Length -eq 2) { return [Uri]::UnescapeDataString($kv[1].Replace('+', ' ')) }
  }
  return ''
}

$listener = New-Object System.Net.HttpListener
$bound = $false
foreach ($host_ in @('localhost', '127.0.0.1')) {
  try {
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add("http://${host_}:$Port/")
    $listener.Start(); $bound = $true; break
  } catch { Write-Host ("  {0} par start nahi hua: {1}" -f $host_, $_.Exception.Message) }
}
if (-not $bound) { Write-Host 'Server start nahi ho paya. Port band hai? (Dusra Bridge chal raha ho to use band karein)'; exit 1 }

Write-Host ''
Write-Host '=============================================='
Write-Host '  MR Scanner Bridge chalu hai'
Write-Host ('  Pairing CODE :  ' + $Token)
Write-Host '  (MR Photo app me pehli baar yahi code dalna hai)'
if ($MockImage) { Write-Host '  TEST MODE: asli scanner use nahi ho raha' }
Write-Host '  Is window ko KHULA rakhein. Band karne par scan band.'
Write-Host '=============================================='
Write-Host ''

while ($listener.IsListening) {
  $ctx = $listener.GetContext()
  try {
    $req = $ctx.Request
    $path = $req.Url.AbsolutePath
    if ($req.HttpMethod -eq 'OPTIONS') { Send-Bytes $ctx 204 'text/plain' ([byte[]]@()); continue }
    if ($path -eq '/ping') { Send-Json $ctx 200 @{ ok = $true; name = 'MR Scanner Bridge'; version = 2; mock = [bool]$MockImage }; continue }
    if ((Get-Q $req.Url 't') -ne $Token) { Send-Json $ctx 403 @{ ok = $false; error = 'code galat hai' }; continue }
    if ($path -eq '/devices') {
      if ($MockImage) { $devs = @(@{ id = 'mock'; name = 'Test scanner (nakli)' }) } else { $devs = Get-Scanners }
      Send-Json $ctx 200 @{ ok = $true; devices = @($devs) }; continue
    }
    if ($path -eq '/scan') {
      $dpi = 300; [void][int]::TryParse((Get-Q $req.Url 'dpi'), [ref]$dpi)
      $color = 1; [void][int]::TryParse((Get-Q $req.Url 'color'), [ref]$color)
      $dpi = [math]::Max(75, [math]::Min(1200, $dpi)); if ($color -ne 2) { $color = 1 }
      $area = Get-Q $req.Url 'area'; $dev = Get-Q $req.Url 'dev'
      Write-Host ("[{0}] scan: {1} dpi, area {2}" -f (Get-Date -Format 'HH:mm:ss'), $dpi, $area)
      if ($MockImage) { $bytes = [IO.File]::ReadAllBytes($MockImage) } else { $bytes = Invoke-Scan $dev $dpi $color $area }
      Send-Bytes $ctx 200 'image/jpeg' $bytes
      Write-Host '  scan ho gaya, app ko bhej diya.'
      continue
    }
    Send-Json $ctx 404 @{ ok = $false; error = 'not found' }
  } catch {
    Write-Host ('  ERROR: ' + $_.Exception.Message)
    try { Send-Json $ctx 500 @{ ok = $false; error = [string]$_.Exception.Message } } catch {}
  }
}
