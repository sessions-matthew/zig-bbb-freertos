param (
    [string]$Url = "https://ziglang.org/download/0.17.1/zig-x86_64-windows-0.17.1.zip",
    [string]$OutFile = ""
)

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$req = [System.Net.HttpWebRequest]::Create($Url)
$req.UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) ZigBootstrap"
$resp = $req.GetResponse()
$totalBytes = $resp.ContentLength
$totalMB = [math]::Round($totalBytes / 1MB, 1)

$stream = $resp.GetResponseStream()
$fileStream = [System.IO.File]::Create($OutFile)
$buffer = New-Object byte[] 131072
$totalRead = 0
$lastPercent = -1

Write-Host "[Zig Bootstrap] Connected to server. Total size: $totalMB MB"

while (($bytesRead = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
    $fileStream.Write($buffer, 0, $bytesRead)
    $totalRead += $bytesRead
    $percent = [int](($totalRead / $totalBytes) * 100)
    
    if ($percent -ne $lastPercent -and ($percent % 10 -eq 0 -or $percent -eq 100)) {
        $readMB = [math]::Round($totalRead / 1MB, 1)
        Write-Host "[Zig Bootstrap] Downloading: $percent% ($readMB MB / $totalMB MB)"
        $lastPercent = $percent
    }
}

$fileStream.Close()
$stream.Close()
$resp.Close()
Write-Host "[Zig Bootstrap] Download complete."
