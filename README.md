# BMCCollector-ilo4-5 | 30 secondi di tempo di polling | 
BMCCollector ilo4/5

utilizzare powershell

Avviarlo con Start-Process (Senza finestra)
Start-Process powershell.exe -ArgumentList "-ExecutionPolicy Bypass -File C:\BMCCollector\bmc_collector.ps1" -WindowStyle Hidden

PowerShell 7.6.1
PS C:\Windows\System32> PowerShell.exe -ExecutionPolicy Bypass -File C:\BMCCollector\./bmc_collector.ps1

