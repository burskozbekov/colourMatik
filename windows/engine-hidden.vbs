' colourMatik — start the engine silently (no console window). Used by the
' Startup shortcut. Logs go to %LOCALAPPDATA%\colourMatik\engine.log.
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
root = fso.GetParentFolderName(fso.GetParentFolderName(WScript.ScriptFullName))
logdir = sh.ExpandEnvironmentStrings("%LOCALAPPDATA%") & "\colourMatik"
If Not fso.FolderExists(logdir) Then fso.CreateFolder(logdir)
cmd = "cmd /c cd /d """ & root & """ && "".venv\Scripts\python.exe"" -u -m colourmatik.webapp >> """ & logdir & "\engine.log"" 2>&1"
sh.Run cmd, 0, False
