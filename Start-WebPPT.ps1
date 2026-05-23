param(
  [int]$Port = 8080,
  [ValidateSet("Auto", "Python", "Node", "PowerShell")]
  [string]$Mode = "Auto",
  [switch]$NoBrowser,
  [switch]$SelfTest
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path

function Test-PortFree {
  param([int]$Candidate)
  $listener = $null
  try {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Parse("127.0.0.1"), $Candidate)
    $listener.Start()
    return $true
  } catch {
    return $false
  } finally {
    if ($listener) { $listener.Stop() }
  }
}

while (-not (Test-PortFree $Port)) {
  $Port += 1
}

$Url = "http://127.0.0.1:$Port/"

function Wait-Server {
  param([string]$TargetUrl)
  for ($i = 0; $i -lt 40; $i++) {
    try {
      Invoke-WebRequest -UseBasicParsing -Uri $TargetUrl -Method Head -TimeoutSec 1 | Out-Null
      return $true
    } catch {
      Start-Sleep -Milliseconds 250
    }
  }
  return $false
}

function Start-BackgroundServer {
  param(
    [string]$Name,
    [scriptblock]$Script,
    [object[]]$ArgumentList
  )
  Write-Host "Trying $Name..."
  $job = Start-Job -Name "WebPPT-$Name" -ScriptBlock $Script -ArgumentList $ArgumentList
  if (Wait-Server $Url) {
    return $job
  }
  Receive-Job $job -Keep -ErrorAction SilentlyContinue | Out-Host
  Remove-Job $job -Force -ErrorAction SilentlyContinue
  return $null
}

function Invoke-StartupSelfTest {
  param(
    [string]$Name,
    [string]$TargetUrl
  )
  $index = Invoke-WebRequest -UseBasicParsing -Uri $TargetUrl -TimeoutSec 5
  if ($index.StatusCode -lt 200 -or $index.StatusCode -ge 300) {
    throw "$Name index request failed with status $($index.StatusCode)."
  }

  $asset = Get-ChildItem -LiteralPath (Join-Path $Root "assets") -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -match "^\.(js|css|webp|png|jpg|jpeg|svg|mp4|glb|wasm)$" } |
    Sort-Object Length |
    Select-Object -First 1
  if ($asset) {
    $rootFull = [System.IO.Path]::GetFullPath($Root)
    if (-not $rootFull.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
      $rootFull += [System.IO.Path]::DirectorySeparatorChar
    }
    $assetFull = [System.IO.Path]::GetFullPath($asset.FullName)
    $relative = $assetFull.Substring($rootFull.Length).Replace("\", "/")
    $assetUrl = "$TargetUrl$relative"
    $assetResponse = Invoke-WebRequest -UseBasicParsing -Uri $assetUrl -Method Head -TimeoutSec 5
    if ($assetResponse.StatusCode -lt 200 -or $assetResponse.StatusCode -ge 300) {
      throw "$Name asset request failed with status $($assetResponse.StatusCode)."
    }
  }

  if ($Name -ne "Python") {
    $media = Get-ChildItem -LiteralPath (Join-Path $Root "assets") -Recurse -File -ErrorAction SilentlyContinue |
      Where-Object { $_.Extension -match "^\.(mp4|webm)$" } |
      Sort-Object Length |
      Select-Object -First 1
    if ($media) {
      $rootFull = [System.IO.Path]::GetFullPath($Root)
      if (-not $rootFull.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $rootFull += [System.IO.Path]::DirectorySeparatorChar
      }
      $mediaFull = [System.IO.Path]::GetFullPath($media.FullName)
      $mediaRelative = $mediaFull.Substring($rootFull.Length).Replace("\", "/")
      $rangeRequest = [System.Net.HttpWebRequest]::Create("$TargetUrl$mediaRelative")
      $rangeRequest.Timeout = 5000
      $rangeRequest.AddRange(0, 15)
      $rangeResponse = $rangeRequest.GetResponse()
      try {
        if ([int]$rangeResponse.StatusCode -ne 206) {
          throw "$Name range request failed with status $([int]$rangeResponse.StatusCode)."
        }
      } finally {
        $rangeResponse.Close()
      }
    }
  }

  Write-Host "$Name self-test passed: $TargetUrl"
}

function Finish-Server {
  param(
    $Job,
    [string]$Name
  )
  if ($SelfTest) {
    try {
      Invoke-StartupSelfTest $Name $Url
    } finally {
      Remove-Job $Job -Force -ErrorAction SilentlyContinue
      if ($script:NodeTempFile -and (Test-Path -LiteralPath $script:NodeTempFile)) {
        Remove-Item -LiteralPath $script:NodeTempFile -Force -ErrorAction SilentlyContinue
      }
    }
    exit 0
  }

  Write-Host ""
  Write-Host "WebPPT is running with $Name."
  Write-Host "Open: $Url"
  Write-Host "Close this window to stop the local server."
  if (-not $NoBrowser) {
    Start-Process $Url
  }
  try {
    while ($true) {
      if ($Job.State -ne "Running") {
        Receive-Job $Job -Keep | Out-Host
        throw "$Name server stopped."
      }
      Start-Sleep -Seconds 2
    }
  } finally {
    Remove-Job $Job -Force -ErrorAction SilentlyContinue
    if ($script:NodeTempFile -and (Test-Path -LiteralPath $script:NodeTempFile)) {
      Remove-Item -LiteralPath $script:NodeTempFile -Force -ErrorAction SilentlyContinue
    }
  }
}

function Start-PythonServer {
  $commands = @()
  $py = Get-Command py -ErrorAction SilentlyContinue
  if ($py) {
    $commands += [pscustomobject]@{ Label = "Python py"; Exe = $py.Source; Launcher = "py" }
  }
  foreach ($pythonName in @("python", "python3")) {
    $python = Get-Command $pythonName -ErrorAction SilentlyContinue
    if ($python) {
      $commands += [pscustomobject]@{ Label = "Python $pythonName"; Exe = $python.Source; Launcher = "python" }
    }
  }

  foreach ($command in $commands) {
    $job = Start-BackgroundServer $command.Label {
      param($Root, $Exe, $Launcher, $Port)
      Set-Location -LiteralPath $Root
      if ($Launcher -eq "py") {
        & $Exe -3 -m http.server $Port --bind 127.0.0.1
      } else {
        & $Exe -m http.server $Port --bind 127.0.0.1
      }
    } @($Root, $command.Exe, $command.Launcher, $Port)
    if ($job) { return $job }
  }
  return $null
}

$NodeServerCode = @'
const http = require("http");
const fs = require("fs");
const path = require("path");
const root = path.resolve(process.argv[2]);
const port = Number(process.argv[3]);
const mime = {
  ".html": "text/html; charset=utf-8",
  ".js": "application/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".webp": "image/webp",
  ".svg": "image/svg+xml",
  ".mp4": "video/mp4",
  ".webm": "video/webm",
  ".glb": "model/gltf-binary",
  ".wasm": "application/wasm"
};
function sendFile(req, res, file) {
  const stat = fs.statSync(file);
  const type = mime[path.extname(file).toLowerCase()] || "application/octet-stream";
  const range = req.headers.range;
  res.setHeader("Accept-Ranges", "bytes");
  res.setHeader("Content-Type", type);
  if (range) {
    const m = /^bytes=(\d*)-(\d*)$/.exec(range);
    if (m) {
      const start = m[1] ? Number(m[1]) : 0;
      const end = m[2] ? Number(m[2]) : stat.size - 1;
      if (start <= end && end < stat.size) {
        res.writeHead(206, {
          "Content-Range": `bytes ${start}-${end}/${stat.size}`,
          "Content-Length": end - start + 1
        });
        if (req.method === "HEAD") {
          res.end();
        } else {
          fs.createReadStream(file, { start, end }).pipe(res);
        }
        return;
      }
    }
  }
  res.writeHead(200, { "Content-Length": stat.size });
  if (req.method === "HEAD") {
    res.end();
  } else {
    fs.createReadStream(file).pipe(res);
  }
}
http.createServer((req, res) => {
  try {
    const urlPath = decodeURIComponent(new URL(req.url, "http://127.0.0.1").pathname);
    const rel = urlPath === "/" ? "index.html" : urlPath.replace(/^\/+/, "");
    const file = path.resolve(root, rel);
    const safeRoot = root.endsWith(path.sep) ? root : root + path.sep;
    if (!file.startsWith(safeRoot) || !fs.existsSync(file) || !fs.statSync(file).isFile()) {
      res.writeHead(404);
      res.end("Not found");
      return;
    }
    sendFile(req, res, file);
  } catch (err) {
    res.writeHead(500);
    res.end(String(err && err.message || err));
  }
}).listen(port, "127.0.0.1");
'@

function Start-NodeServer {
  $node = Get-Command node -ErrorAction SilentlyContinue
  if (-not $node) { return $null }
  $script:NodeTempFile = Join-Path ([System.IO.Path]::GetTempPath()) ("webppt-server-{0}.js" -f [System.Guid]::NewGuid().ToString("N"))
  Set-Content -LiteralPath $script:NodeTempFile -Value $NodeServerCode -Encoding UTF8
  return Start-BackgroundServer "Node" {
    param($Root, $Port, $Exe, $ServerFile)
    & $Exe $ServerFile $Root $Port
  } @($Root, $Port, $node.Source, $script:NodeTempFile)
}

$PowerShellServerBlock = {
  param($Root, $Port)
  $ErrorActionPreference = "Stop"
  $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Parse("127.0.0.1"), $Port)
  $mimeTypes = @{
    ".html" = "text/html; charset=utf-8"
    ".js" = "application/javascript; charset=utf-8"
    ".css" = "text/css; charset=utf-8"
    ".json" = "application/json; charset=utf-8"
    ".png" = "image/png"
    ".jpg" = "image/jpeg"
    ".jpeg" = "image/jpeg"
    ".webp" = "image/webp"
    ".svg" = "image/svg+xml"
    ".mp4" = "video/mp4"
    ".webm" = "video/webm"
    ".glb" = "model/gltf-binary"
    ".wasm" = "application/wasm"
  }

  function Write-HttpResponse {
    param(
      [System.IO.Stream]$Stream,
      [string]$Status,
      [hashtable]$Headers,
      [byte[]]$Body
    )
    $headerText = "HTTP/1.1 $Status`r`n"
    foreach ($key in $Headers.Keys) {
      $headerText += "$key`: $($Headers[$key])`r`n"
    }
    $headerText += "Connection: close`r`n`r`n"
    $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($headerText)
    $Stream.Write($headerBytes, 0, $headerBytes.Length)
    if ($Body -and $Body.Length -gt 0) {
      $Stream.Write($Body, 0, $Body.Length)
    }
  }

  function Send-File {
    param(
      [System.IO.Stream]$Stream,
      [string]$Method,
      [string]$FilePath,
      [hashtable]$Headers
    )
    $fileInfo = Get-Item -LiteralPath $FilePath
    $total = [int64]$fileInfo.Length
    $start = [int64]0
    $end = $total - 1
    $status = "200 OK"
    $responseHeaders = @{
      "Accept-Ranges" = "bytes"
      "Content-Type" = if ($mimeTypes.ContainsKey($fileInfo.Extension.ToLowerInvariant())) { $mimeTypes[$fileInfo.Extension.ToLowerInvariant()] } else { "application/octet-stream" }
    }

    if ($Headers.ContainsKey("range") -and $Headers["range"] -match "^bytes=(\d*)-(\d*)$") {
      if ($Matches[1]) { $start = [int64]$Matches[1] }
      if ($Matches[2]) { $end = [int64]$Matches[2] }
      if ($start -le $end -and $end -lt $total) {
        $status = "206 Partial Content"
        $responseHeaders["Content-Range"] = "bytes $start-$end/$total"
      } else {
        $body = [System.Text.Encoding]::UTF8.GetBytes("Range not satisfiable")
        Write-HttpResponse $Stream "416 Range Not Satisfiable" @{ "Content-Length" = $body.Length; "Content-Type" = "text/plain; charset=utf-8" } $body
        return
      }
    }

    $length = $end - $start + 1
    $responseHeaders["Content-Length"] = $length
    Write-HttpResponse $Stream $status $responseHeaders $null
    if ($Method -eq "HEAD") { return }

    $fileStream = [System.IO.File]::OpenRead($FilePath)
    try {
      $fileStream.Seek($start, [System.IO.SeekOrigin]::Begin) | Out-Null
      $buffer = New-Object byte[] 65536
      $remaining = $length
      while ($remaining -gt 0) {
        $readSize = [Math]::Min($buffer.Length, $remaining)
        $read = $fileStream.Read($buffer, 0, $readSize)
        if ($read -le 0) { break }
        $Stream.Write($buffer, 0, $read)
        $remaining -= $read
      }
    } finally {
      $fileStream.Dispose()
    }
  }

  $listener.Start()
  try {
    while ($true) {
      if (-not $listener.Pending()) {
        Start-Sleep -Milliseconds 50
        continue
      }
      $client = $listener.AcceptTcpClient()
      try {
        $stream = $client.GetStream()
        $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::ASCII, $false, 8192, $true)
        $requestLine = $reader.ReadLine()
        if ([string]::IsNullOrWhiteSpace($requestLine)) { continue }
        $parts = $requestLine.Split(" ")
        $method = $parts[0].ToUpperInvariant()
        $rawPath = $parts[1]
        $headers = @{}
        while ($true) {
          $line = $reader.ReadLine()
          if ($null -eq $line -or $line -eq "") { break }
          $idx = $line.IndexOf(":")
          if ($idx -gt 0) {
            $headers[$line.Substring(0, $idx).Trim().ToLowerInvariant()] = $line.Substring($idx + 1).Trim()
          }
        }

        $pathOnly = ($rawPath -split "\?")[0]
        $decodedPath = [System.Uri]::UnescapeDataString($pathOnly)
        if ($decodedPath -eq "/") { $decodedPath = "/index.html" }
        $relative = $decodedPath.TrimStart("/")
        $fullPath = [System.IO.Path]::GetFullPath((Join-Path $Root $relative))
        $rootFull = [System.IO.Path]::GetFullPath($Root)
        if (-not $fullPath.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
          $body = [System.Text.Encoding]::UTF8.GetBytes("Not found")
          Write-HttpResponse $stream "404 Not Found" @{ "Content-Length" = $body.Length; "Content-Type" = "text/plain; charset=utf-8" } $body
          continue
        }

        Send-File $stream $method $fullPath $headers
      } catch {
        try {
          $body = [System.Text.Encoding]::UTF8.GetBytes($_.Exception.Message)
          Write-HttpResponse $stream "500 Internal Server Error" @{ "Content-Length" = $body.Length; "Content-Type" = "text/plain; charset=utf-8" } $body
        } catch {}
      } finally {
        $client.Close()
      }
    }
  } finally {
    $listener.Stop()
  }
}

function Start-PowerShellServer {
  return Start-BackgroundServer "PowerShell" $PowerShellServerBlock @($Root, $Port)
}

$modeOrder = if ($Mode -eq "Auto") { @("Python", "Node", "PowerShell") } else { @($Mode) }
foreach ($candidate in $modeOrder) {
  $job = $null
  if ($candidate -eq "Python") { $job = Start-PythonServer }
  if ($candidate -eq "Node") { $job = Start-NodeServer }
  if ($candidate -eq "PowerShell") { $job = Start-PowerShellServer }
  if ($job) { Finish-Server $job $candidate }
}

throw "No available local web server mode succeeded."
