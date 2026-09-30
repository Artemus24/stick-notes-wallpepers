# Sticker editor. No Python. Windows PowerShell only.
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$port = 47831
$files = @{
  "/" = "index.html"
  "/index.html" = "index.html"
  "/compose" = "compose.html"
  "/compose.html" = "compose.html"
  "/thumbnail.png" = "thumbnail.png"
  "/LivelyInfo.json" = "LivelyInfo.json"
  "/LivelyProperties.json" = "LivelyProperties.json"
}
$types = @{
  ".html" = "text/html; charset=utf-8"
  ".json" = "application/json; charset=utf-8"
  ".png" = "image/png"
}
$results = New-Object System.Collections.Generic.List[object]
$seen = @{}

function Find-HeaderEnd([byte[]]$buf, [int]$count) {
  for ($i = 0; $i -le $count - 4; $i++) {
    if ($buf[$i] -eq 13 -and $buf[$i+1] -eq 10 -and $buf[$i+2] -eq 13 -and $buf[$i+3] -eq 10) {
      return $i + 4
    }
  }
  return -1
}

function Send-Bytes($stream, [int]$code, [string]$type, [byte[]]$body, [string]$extra) {
  if (-not $body) { $body = [byte[]]@() }
  $text = @{200="OK";204="No Content";400="Bad Request";404="Not Found";413="Payload Too Large"}[$code]
  if (-not $text) { $text = "OK" }
  $head = "HTTP/1.1 $code $text`r`nContent-Type: $type`r`nContent-Length: $($body.Length)`r`nCache-Control: no-store`r`nAccess-Control-Allow-Origin: *`r`nAccess-Control-Allow-Methods: GET, POST, OPTIONS`r`nAccess-Control-Allow-Headers: Content-Type`r`nAccess-Control-Allow-Private-Network: true`r`nConnection: close`r`n"
  if ($extra) { $head += $extra }
  $head += "`r`n"
  $hb = [Text.Encoding]::ASCII.GetBytes($head)
  $stream.Write($hb, 0, $hb.Length)
  if ($body.Length -gt 0) { $stream.Write($body, 0, $body.Length) }
}

function Send-Json($stream, [int]$code, $obj) {
  $json = if ($null -eq $obj) { "[]" } else { ConvertTo-Json -InputObject $obj -Compress -Depth 6 }
  if ($obj -is [System.Collections.IEnumerable] -and -not ($obj -is [string]) -and @($obj).Count -eq 0) { $json = "[]" }
  Send-Bytes $stream $code "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($json)) $null
}

function Read-Request($stream) {
  $acc = New-Object System.Collections.Generic.List[byte]
  $tmp = New-Object byte[] 8192
  $end = -1
  while ($end -lt 0 -and $acc.Count -lt 300000) {
    $n = $stream.Read($tmp, 0, $tmp.Length)
    if ($n -le 0) { return $null }
    for ($i = 0; $i -lt $n; $i++) { [void]$acc.Add($tmp[$i]) }
    $end = Find-HeaderEnd $acc.ToArray() $acc.Count
  }
  if ($end -lt 0) { return $null }
  $head = [Text.Encoding]::ASCII.GetString($acc.ToArray(), 0, $end - 4)
  $first = ($head -split "`r`n")[0]
  $parts = $first.Split(" ")
  $headers = @{}
  foreach ($line in ($head -split "`r`n") | Select-Object -Skip 1) {
    $p = $line.IndexOf(":")
    if ($p -gt 0) { $headers[$line.Substring(0, $p).Trim().ToLower()] = $line.Substring($p + 1).Trim() }
  }
  $need = 0
  if ($headers.ContainsKey("content-length")) { $need = [int]$headers["content-length"] }
  $have = $acc.Count - $end
  while ($have -lt $need -and $need -le 100000) {
    $n = $stream.Read($tmp, 0, $tmp.Length)
    if ($n -le 0) { break }
    for ($i = 0; $i -lt $n; $i++) { [void]$acc.Add($tmp[$i]) }
    $have += $n
  }
  $body = New-Object byte[] $need
  if ($need -gt 0) { [Array]::Copy($acc.ToArray(), $end, $body, 0, $need) }
  return @{ method = $parts[0]; url = $parts[1]; body = $body }
}

$listener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Parse("127.0.0.1")), $port
try { $listener.Start() }
catch {
  Write-Host "The editor is already running. Close this window."
  [void](Read-Host "Press Enter")
  exit 1
}
Write-Host "Sticker editor: http://127.0.0.1:$port"
Write-Host "Leave this window open while you edit the wallpaper."

while ($true) {
  $client = $listener.AcceptTcpClient()
  $stream = $client.GetStream()
  try {
    $stream.ReadTimeout = 8000
    $req = Read-Request $stream
    if (-not $req) { continue }
    $path = ($req.url -split "\?")[0]
    if ($req.method -eq "OPTIONS") {
      Send-Bytes $stream 204 "text/plain" ([byte[]]@()) $null
      continue
    }
    if ($req.method -eq "GET" -and $path -eq "/health") {
      Send-Json $stream 200 @{ ok = $true }
      continue
    }
    if ($req.method -eq "GET" -and $path -eq "/results") {
      if ($results.Count -eq 0) {
        $json = "[]"
      } else {
        $json = ConvertTo-Json -InputObject $results.ToArray() -Compress -Depth 6
        if ($results.Count -eq 1) { $json = "[$json]" }
      }
      Send-Bytes $stream 200 "application/json; charset=utf-8" ([Text.Encoding]::UTF8.GetBytes($json)) $null
      continue
    }
    if ($req.method -eq "GET" -and $path -eq "/Sticker-Board.zip") {
      $zip = Join-Path (Split-Path $root -Parent) "Sticker-Board.zip"
      if (-not (Test-Path $zip)) { Send-Json $stream 404 @{ error = "zip missing" }; continue }
      $bytes = [IO.File]::ReadAllBytes($zip)
      Send-Bytes $stream 200 "application/zip" $bytes "Content-Disposition: attachment; filename=`"Sticker-Board.zip`"`r`n"
      continue
    }
    if ($req.method -eq "GET" -and $files.ContainsKey($path)) {
      $name = $files[$path]
      $full = Join-Path $root $name
      $ext = [IO.Path]::GetExtension($full).ToLower()
      $type = $types[$ext]
      if (-not $type) { $type = "application/octet-stream" }
      Send-Bytes $stream 200 $type ([IO.File]::ReadAllBytes($full)) $null
      continue
    }
    if ($req.method -eq "POST" -and $path -eq "/commit") {
      if ($req.body.Length -gt 10000) { Send-Json $stream 413 @{ error = "too large" }; continue }
      $raw = [Text.Encoding]::UTF8.GetString($req.body)
      if (-not $raw) { $raw = "{}" }
      try { $payload = $raw | ConvertFrom-Json } catch { Send-Json $stream 400 @{ error = "bad json" }; continue }
      $token = [string]$payload.token
      $field = [string]$payload.field
      $status = [string]$payload.status
      if ($token -notmatch "^[A-Za-z0-9_-]{4,32}$" -or @("title","task","add") -notcontains $field -or @("commit","cancel") -notcontains $status) {
        Send-Json $stream 400 @{ error = "bad edit" }
        continue
      }
      if ($seen.ContainsKey($token)) { Send-Json $stream 200 @{ ok = $true; duplicate = $true }; continue }
      $text = ([string]$payload.text).Replace("`r", " ").Replace("`n", " ").Trim()
      if ($status -eq "commit" -and -not $text) { Send-Json $stream 400 @{ error = "empty" }; continue }
      if ($text.Length -gt 140) { $text = $text.Substring(0, 140) }
      $seen[$token] = $true
      [void]$results.Add([pscustomobject]@{
        token = $token
        noteId = [string]$payload.noteId
        taskId = [string]$payload.taskId
        field = $field
        status = $status
        text = $text
      })
      while ($results.Count -gt 40) { $results.RemoveAt(0) }
      Send-Json $stream 200 @{ ok = $true }
      continue
    }
    Send-Json $stream 404 @{ error = "not found" }
  } catch {
    Write-Host $_.Exception.Message
  } finally {
    $client.Close()
  }
}
