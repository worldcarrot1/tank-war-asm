$evs = Get-WinEvent -FilterHashtable @{LogName='Application'; ProviderName='Application Error','Windows Error Reporting'; StartTime=(Get-Date).AddMinutes(-120)} -MaxEvents 60 -ErrorAction SilentlyContinue | Where-Object { $_.Message -match 'tankwar' }
foreach ($e in $evs) {
  Write-Output ("=== " + $e.TimeCreated)
  ($e.Message -split "`n")[0..10] -join "`n"
  Write-Output ""
}
