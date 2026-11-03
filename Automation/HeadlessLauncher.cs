using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;

internal static class HeadlessLauncher
{
    private static readonly object LogLock = new object();
    private static string Quote(string value)
    {
        var result = new StringBuilder("\"");
        int slashes = 0;
        foreach (char c in value)
        {
            if (c == '\\') { slashes++; continue; }
            if (c == '"') { result.Append('\\', slashes * 2 + 1); result.Append(c); }
            else { result.Append('\\', slashes); result.Append(c); }
            slashes = 0;
        }
        result.Append('\\', slashes * 2);
        return result.Append('"').ToString();
    }

    [STAThread]
    private static int Main(string[] args)
    {
        string directory = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        string log = Path.Combine(directory, "launcher.log");
        try
        {
            bool host = args.Length > 0 && args[0] == "--host";
            string scriptName = host ? "ChildDesktopHost.ps1" : "Invoke-HeadlessOneDragon.ps1";
            string script = Path.Combine(directory, scriptName);
            var command = new StringBuilder("-NoLogo -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File ");
            command.Append(Quote(script));
            for (int index = host ? 1 : 0; index < args.Length; index++)
            {
                string argument = args[index];
                if (argument == "--run") continue;
                if (argument == "--check") argument = "-Check";
                if (argument == "--scheduled") argument = "-Scheduled";
                command.Append(' ').Append(Quote(argument));
            }
            var start = new ProcessStartInfo
            {
                FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell\\v1.0\\powershell.exe"),
                Arguments = command.ToString(),
                WorkingDirectory = directory,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };
            using (var process = new Process { StartInfo = start })
            {
                DataReceivedEventHandler record = (sender, value) =>
                {
                    if (value.Data == null) return;
                    try
                    {
                        lock (LogLock) File.AppendAllText(log, DateTime.Now.ToString("o") + " " + value.Data + Environment.NewLine);
                    }
                    catch (IOException) { /* Logging must not terminate the supervised process. */ }
                };
                process.OutputDataReceived += record;
                process.ErrorDataReceived += record;
                process.Start();
                process.BeginOutputReadLine();
                process.BeginErrorReadLine();
                process.WaitForExit();
                return process.ExitCode;
            }
        }
        catch (Exception error)
        {
            File.AppendAllText(log, DateTime.Now.ToString("o") + " Launcher failure: " + error.Message + Environment.NewLine);
            return 1;
        }
    }
}
