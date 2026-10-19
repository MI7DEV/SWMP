Option Explicit

Dim WshShell, fso, scriptDir, serverPy, http, isRunning

Set WshShell = CreateObject("WScript.Shell")
Set fso      = CreateObject("Scripting.FileSystemObject")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
serverPy  = fso.BuildPath(scriptDir, "server.py")

' Check if server already running
Set http = CreateObject("MSXML2.XMLHTTP")
On Error Resume Next
http.Open "GET", "http://127.0.0.1:8766/api/info", False
http.SetTimeouts 300, 300, 1500, 1500
http.send
isRunning = (Err.Number = 0 And http.Status = 200)
On Error GoTo 0

If isRunning Then WScript.Quit 0

' Start server.py without terminal window
On Error Resume Next
WshShell.Run Chr(34) & "pythonw.exe" & Chr(34) & " " & Chr(34) & serverPy & Chr(34), 0, False
If Err.Number <> 0 Then
    Err.Clear
    WshShell.Run Chr(34) & "python.exe" & Chr(34) & " " & Chr(34) & serverPy & Chr(34), 2, False
End If
On Error GoTo 0
