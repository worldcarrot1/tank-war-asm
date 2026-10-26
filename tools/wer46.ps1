$ev = Get-WinEvent -FilterHashtable @{LogName='Application'; ProviderName='Application Error'} -MaxEvents 30 -ErrorAction SilentlyContinue
foreach ($e in $ev) {
  if ($e.Message -match 'tankwar') {
    Write-Output ("{0} | {1}" -f $e.TimeCreated.ToString('MM-dd HH:mm:ss'), ($e.Message -replace "`r?`n", ' '))
  }
}
