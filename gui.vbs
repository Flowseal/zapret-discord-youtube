' Zapret GUI Launcher
' Double-click this file to start the GUI without console flash

Set fso = CreateObject("Scripting.FileSystemObject")
Set WshShell = CreateObject("WScript.Shell")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
psScript = scriptDir & "\gui\src\main.ps1"

' Run PowerShell completely hidden (0 = SW_HIDE)
WshShell.Run "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & psScript & """", 0, False
