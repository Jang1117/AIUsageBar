' Launch the GUI executable directly. A .bat launcher allocates cmd.exe first.
Option Explicit
Dim shell, fs, exePath
Set shell = CreateObject("WScript.Shell")
Set fs = CreateObject("Scripting.FileSystemObject")
exePath = fs.BuildPath(fs.GetParentFolderName(WScript.ScriptFullName), "AIUsageBar.exe")
If Not fs.FileExists(exePath) Then exePath = fs.BuildPath(fs.GetParentFolderName(WScript.ScriptFullName), "dist\AIUsageBar.exe")
If Not fs.FileExists(exePath) Then
    MsgBox "Build AIUsageBar.exe first (.\Build.ps1). See README.md.", vbExclamation, "AIUsageBar"
    WScript.Quit 1
End If
shell.CurrentDirectory = fs.GetParentFolderName(exePath)
shell.Run Chr(34) & exePath & Chr(34), 0, False
