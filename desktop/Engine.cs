using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Reflection;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.Json.Nodes;
using Microsoft.Win32;

namespace LenovoPowerPlanTools;

public static class Engine
{
    public static bool IsAdministrator => new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator);
    public static readonly string[] Actions = ["Status", "Details", "Import", "Activate", "Export", "Delete", "Restore", "VendorDisable", "PatchApply", "LegacyRestore"];
    public static string Text(JsonNode? n, string key) => n?[key]?.ToString() ?? "";
    public static bool Bool(JsonNode? n, string key) => n?[key]?.ToString().Equals("true", StringComparison.OrdinalIgnoreCase) == true;
    public static JsonObject Request(string action, string guid = "", string resource = "") => new()
    {
        ["Action"] = action, ["PlanGuid"] = guid, ["ResourceId"] = resource, ["SourceHash"] = "",
        ["SourcePath"] = "", ["BackupDirectory"] = "", ["ExportPath"] = ""
    };
    public static JsonObject Failure(string message) => new() { ["Success"] = false, ["Message"] = message };
    public static async Task<JsonNode> ReadAsync(JsonObject request)
    {
        if (Text(request, "Action") is not ("Status" or "Details")) throw new InvalidOperationException("Read-only request required");
        return await RunBridge(request, false, null);
    }
    public static async Task<JsonNode> ExecuteAsync(JsonObject request, Action<string> progress, Func<ProcessStartInfo, Process?>? launch = null)
    {
        if (IsAdministrator) return Failure("请普通启动界面；修改操作会单独请求管理员权限，以便托盘按普通权限重启。");
        var pipeName = "LzPlans-" + Guid.NewGuid().ToString("N");
        await using var pipe = new NamedPipeServerStream(pipeName, PipeDirection.InOut, 1,
            PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        Process? worker;
        try
        {
            var start = new ProcessStartInfo(Environment.ProcessPath!)
            {
                UseShellExecute = true, Verb = "runas", Arguments = "--worker " + pipeName, WindowStyle = ProcessWindowStyle.Hidden
            };
            worker = (launch ?? Process.Start)(start);
        }
        catch (Win32Exception e) when (e.NativeErrorCode == 1223) { return Failure("已取消管理员授权；没有执行修改。"); }
        using var lifetime = new CancellationTokenSource(TimeSpan.FromMinutes(4));
        try
        {
            await pipe.WaitForConnectionAsync(lifetime.Token);
            using var reader = new StreamReader(pipe, Encoding.UTF8, false, 4096, true);
            using var writer = new StreamWriter(pipe, new UTF8Encoding(false), 4096, true) { AutoFlush = true };
            await writer.WriteLineAsync(request.ToJsonString());
            while (true)
            {
                var line = await reader.ReadLineAsync(lifetime.Token);
                if (line is null) throw new IOException("管理员进程提前退出，请在备份页面检查操作记录。");
                var message = JsonNode.Parse(line)!;
                if (Text(message, "Kind") == "Result") return message["Value"]!.DeepClone();
                if (Text(message, "Kind") == "Tray")
                {
                    JsonObject reply;
                    try { StartTray(message["Value"]!); reply = new() { ["Success"] = true }; }
                    catch (Exception ex) { reply = Failure(ex.Message); }
                    await writer.WriteLineAsync(reply.ToJsonString());
                }
                else progress(Text(message, "Message"));
            }
        }
        catch (OperationCanceledException) { return Failure("等待工作进程超时。不会强行终止正在修改的进程；请检查备份记录后再操作。"); }
        finally { worker?.Dispose(); }
    }
    static void StartTray(JsonNode instruction)
    {
        if (IsAdministrator) throw new InvalidOperationException("托盘必须由普通权限界面启动。");
        using var baseKey = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry32);
        using var key = baseKey.OpenSubKey(@"SOFTWARE\Lenovo\LegionZone");
        if (key?.GetValue("Version")?.ToString() != "2.0.28.8182") throw new InvalidDataException("托盘版本已变化");
        var expected = Path.GetFullPath(Path.Combine(key.GetValue("InstallDir")!.ToString()!, "2.0.28.8182", "LZTray.exe"));
        if (!expected.Equals(Text(instruction, "Tray"), StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("托盘路径不匹配");
        Process.Start(new ProcessStartInfo(expected) { UseShellExecute = false, Arguments = Text(instruction, "Arguments"), WorkingDirectory = Path.GetDirectoryName(expected)!, WindowStyle = ProcessWindowStyle.Hidden });
    }
    public static async Task WorkerAsync(string pipeName)
    {
        if (!IsAdministrator || !System.Text.RegularExpressions.Regex.IsMatch(pipeName, "^LzPlans-[a-f0-9]{32}$")) return;
        await using var pipe = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        await pipe.ConnectAsync(20000);
        using var reader = new StreamReader(pipe, Encoding.UTF8, false, 4096, true);
        using var writer = new StreamWriter(pipe, new UTF8Encoding(false), 4096, true) { AutoFlush = true };
        JsonNode result;
        // FileShare.None provides a cross-process lock even across UAC and different UI instances.
        FileStream? operationLock = null;
        try
        {
            var request = JsonNode.Parse(await reader.ReadLineAsync() ?? "")!.AsObject();
            Validate(request);
            SecureRoot();
            operationLock = new FileStream(Path.Combine(Path.GetDirectoryName(Catalog.BackupRoot)!, "operation.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
            if (Text(request, "Action") is not ("Restore" or "LegacyRestore"))
                request["BackupDirectory"] = Path.Combine(Catalog.BackupRoot, DateTime.Now.ToString("yyyyMMdd-HHmmss") + "-" + Guid.NewGuid().ToString("N"));
            if (Text(request, "Action") == "Import")
            {
                if (Text(request, "ResourceId") != "")
                {
                    var asset = Catalog.Find(Text(request, "ResourceId"));
                    request["SourcePath"] = Catalog.CachePath(asset);
                    request["SourceHash"] = asset.Sha256;
                    if (!Catalog.Matches(Text(request, "SourcePath"), asset.Sha256)) throw new InvalidDataException("缓存缺失或哈希校验失败；请重新下载。");
                }
                else request["SourceHash"] = ""; // Computed from the locked, staged local file below.
            }
            await writer.WriteLineAsync(new JsonObject { ["Kind"] = "Progress", ["Message"] = "正在核验、备份并执行；请勿关闭窗口…" }.ToJsonString());
            result = await RunBridge(request, true, async instruction =>
            {
                await writer.WriteLineAsync(new JsonObject { ["Kind"] = "Tray", ["Value"] = instruction.DeepClone() }.ToJsonString());
                using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(35));
                return JsonNode.Parse(await reader.ReadLineAsync(timeout.Token) ?? "")!;
            });
        }
        catch (Exception ex) { result = Failure(ex is IOException ? "操作被占用或文件访问失败：" + ex.Message : ex.Message); }
        finally { operationLock?.Dispose(); }
        await writer.WriteLineAsync(new JsonObject { ["Kind"] = "Result", ["Value"] = result.DeepClone() }.ToJsonString());
    }
    public static void Validate(JsonObject request)
    {
        var action = Text(request, "Action");
        if (!Actions.Contains(action) || action is "Status" or "Details") throw new InvalidDataException("不支持的修改操作");
        if (action is "Activate" or "Export" or "Delete")
            if (!Guid.TryParseExact(Text(request, "PlanGuid"), "D", out _)) throw new InvalidDataException("无效的 GUID");
        if (Text(request, "ResourceId") != "") _ = Catalog.Find(Text(request, "ResourceId"));
        if (action == "Import" && Text(request, "ResourceId") == "")
        {
            var source = Path.GetFullPath(Text(request, "SourcePath"));
            if (!source.EndsWith(".pow", StringComparison.OrdinalIgnoreCase) || !File.Exists(source)) throw new InvalidDataException("请选择有效的 .pow 文件");
            request["SourcePath"] = source;
        }
        if (action == "Export")
        {
            var path = Path.GetFullPath(Text(request, "ExportPath"));
            if (!path.EndsWith(".pow", StringComparison.OrdinalIgnoreCase) || File.Exists(path)) throw new InvalidDataException("请选择尚不存在的 .pow 导出文件");
            request["ExportPath"] = path;
        }
        if (action is "Restore" or "LegacyRestore")
        {
            var path = Path.GetFullPath(Text(request, "BackupDirectory"));
            if (!File.Exists(Path.Combine(path, "manifest.json"))) throw new InvalidDataException("备份清单不存在");
            request["BackupDirectory"] = path;
        }
    }
    static void SecureRoot()
    {
        var root = Path.GetDirectoryName(Catalog.BackupRoot)!;
        Directory.CreateDirectory(root);
        if ((File.GetAttributes(root) & FileAttributes.ReparsePoint) != 0) throw new InvalidDataException("工作目录不能是链接");
        var admins = new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null);
        var acl = new DirectorySecurity();
        acl.SetAccessRuleProtection(true, false); acl.SetOwner(admins);
        foreach (var sid in new[] { admins, new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null) })
            acl.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
        acl.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.BuiltinUsersSid, null), FileSystemRights.ReadAndExecute, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
        new DirectoryInfo(root).SetAccessControl(acl);
        Directory.CreateDirectory(Catalog.BackupRoot);
        if ((File.GetAttributes(Catalog.BackupRoot) & FileAttributes.ReparsePoint) != 0) throw new InvalidDataException("备份目录不能是链接");
    }
    static async Task<JsonNode> RunBridge(JsonObject request, bool elevated, Func<JsonNode, Task<JsonNode>>? trayHandler)
    {
        var parent = elevated ? Path.GetDirectoryName(Catalog.BackupRoot)! : Catalog.UserRoot;
        Directory.CreateDirectory(parent);
        var dir = Path.Combine(parent, "session-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        if (Text(request, "Action") == "Import")
        {
            var staged = Path.Combine(dir, "source.pow");
            using (var input = File.OpenRead(Text(request, "SourcePath")))
            using (var output = File.Create(staged))
            {
                if (input.Length > 1048576) throw new InvalidDataException("计划文件超过允许大小");
                input.CopyTo(output);
            }
            using var check = File.OpenRead(staged);
            var hash = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(check));
            if (Text(request, "SourceHash") != "" && !hash.Equals(Text(request, "SourceHash"), StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("资源在准备期间发生变化");
            request["SourceHash"] = hash; request["SourcePath"] = staged;
            var known = Catalog.Assets.FirstOrDefault(a => a.Sha256.Equals(hash, StringComparison.OrdinalIgnoreCase));
            if (known is not null) request["ResourceId"] = known.Id;
        }
        var assembly = Assembly.GetExecutingAssembly();
        foreach (var resource in assembly.GetManifestResourceNames().Where(n => n.StartsWith("Engine.", StringComparison.Ordinal)))
        {
            using var input = assembly.GetManifestResourceStream(resource)!;
            using var output = File.Create(Path.Combine(dir, resource["Engine.".Length..]));
            input.CopyTo(output);
        }
        var requestPath = Path.Combine(dir, "request.json"); var responsePath = Path.Combine(dir, "response.json");
        await File.WriteAllTextAsync(requestPath, request.ToJsonString(), new UTF8Encoding(false));
        var info = new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), @"System32\WindowsPowerShell\v1.0\powershell.exe"))
        { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var arg in new[] { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", Path.Combine(dir, "GuiBridge.ps1"), "-RequestPath", requestPath, "-ResponsePath", responsePath }) info.ArgumentList.Add(arg);
        using var process = Process.Start(info)!;
        var outputTask = process.StandardOutput.ReadToEndAsync(); var errorTask = process.StandardError.ReadToEndAsync();
        var handled = new HashSet<string>();
        while (!process.HasExited)
        {
            if (trayHandler is not null)
                foreach (var file in Directory.EnumerateFiles(dir, "tray-*.json").Where(f => !handled.Contains(f)))
                {
                    handled.Add(file);
                    JsonNode reply;
                    try { reply = await trayHandler(JsonNode.Parse(await File.ReadAllTextAsync(file))!); }
                    catch (Exception ex) { reply = Failure(ex.Message); }
                    await File.WriteAllTextAsync(Path.ChangeExtension(file, ".reply"), reply.ToJsonString());
                }
            await Task.Delay(150);
        }
        await process.WaitForExitAsync();
        var stderr = await errorTask; _ = await outputTask;
        if (!File.Exists(responsePath)) throw new InvalidOperationException("执行引擎未返回结果：" + stderr + "\n诊断目录：" + dir);
        var result = JsonNode.Parse(await File.ReadAllTextAsync(responsePath))!;
        // Keep failed sessions for diagnosis. Successful temporary sessions contain no backups.
        if (Bool(result, "Success") && Path.GetFullPath(dir).StartsWith(Path.GetFullPath(parent) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            Directory.Delete(dir, true);
        return result;
    }
}
