$ErrorActionPreference = 'SilentlyContinue'
Get-WinEvent -FilterHashtable @{LogName='Application'} -MaxEvents 40 |
  Where-Object { $_.Message -match 'tankwar' } |
  Select-Object -First 3 |
  ForEach-Object { $_.TimeCreated; $_.Message; '----' }
