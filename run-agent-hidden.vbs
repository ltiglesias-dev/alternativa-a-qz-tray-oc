Option Explicit

Dim shell, nodePath, serverPath, configPath, command
Set shell = CreateObject("WScript.Shell")

If WScript.Arguments.Count < 3 Then
    WScript.Quit 2
End If

nodePath = WScript.Arguments(0)
serverPath = WScript.Arguments(1)
configPath = WScript.Arguments(2)
command = """" & nodePath & """ """ & serverPath & """ --config """ & configPath & """"
shell.Run command, 0, False
