Option Explicit
Dim shell, baseDir, command
Set shell = CreateObject("WScript.Shell")
baseDir = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
command = "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & baseDir & "iniciar-agente-oculto.ps1"""
shell.Run command, 0, False
