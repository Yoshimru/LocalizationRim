using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Web.Script.Serialization;

internal static class AgentRouterBridge
{
    private static string Quote(string value)
    {
        if (value == null) return "\"\"";
        return "\"" + value.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";
    }

    private static string FindCli()
    {
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var candidates = new[]
        {
            Path.Combine(local, "Programs", "ai.opencode.desktop", "resources", "opencode-cli.exe"),
            Path.Combine(local, "Programs", "ai.opencode.desktop.update-2F4E3E86A2D15FFE", "resources", "opencode-cli.exe")
        };
        foreach (var path in candidates) if (File.Exists(path)) return path;
        return "opencode";
    }

    public static int Main(string[] args)
    {
        var serializer = new JavaScriptSerializer();
        try
        {
            var model = "gpt-5.6-sol";
            for (var i = 0; i < args.Length - 1; i++)
                if (args[i] == "--model") model = args[i + 1];

            var prompt = Console.In.ReadToEnd();
            var psi = new ProcessStartInfo
            {
                FileName = FindCli(),
                Arguments = "run --model " + Quote("agentrouter/" + model) + " --format json " + Quote(prompt),
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                StandardOutputEncoding = Encoding.UTF8,
                StandardErrorEncoding = Encoding.UTF8
            };
            using (var process = Process.Start(psi))
            {
                var output = process.StandardOutput.ReadToEnd();
                var error = process.StandardError.ReadToEnd();
                process.WaitForExit();
                if (process.ExitCode != 0) throw new Exception(string.IsNullOrWhiteSpace(error) ? output : error);
                var text = new StringBuilder();
                foreach (var line in output.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries))
                {
                    try
                    {
                        var evt = serializer.DeserializeObject(line) as Dictionary<string, object>;
                        if (evt == null || !evt.ContainsKey("type") || (string)evt["type"] != "text") continue;
                        var part = evt["part"] as Dictionary<string, object>;
                        if (part != null && part.ContainsKey("text")) text.Append((string)part["text"]);
                    }
                    catch { }
                }
                if (text.Length == 0) throw new Exception("OpenCode CLI returned no text output");
                Console.OutputEncoding = Encoding.UTF8;
                Console.Write(serializer.Serialize(new Dictionary<string, object>
                {
                    {"type", "result"}, {"is_error", false}, {"result", text.ToString()}
                }));
                return 0;
            }
        }
        catch (Exception ex)
        {
            Console.OutputEncoding = Encoding.UTF8;
            Console.Write(serializer.Serialize(new Dictionary<string, object>
            {
                {"type", "result"}, {"is_error", true}, {"result", ex.Message}
            }));
            return 1;
        }
    }
}
