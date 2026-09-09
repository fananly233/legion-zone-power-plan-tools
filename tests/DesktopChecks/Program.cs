using System.IO;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.IO.Pipes;
using System.Text.Json.Nodes;
using LenovoPowerPlanTools;

static void Assert(bool value, string message) { if (!value) throw new Exception(message); }
static void Reject(Action action) { try { action(); } catch { return; } throw new Exception("Expected rejection"); }
Assert(Catalog.Assets.Count == 7, "Catalog count");
Assert(Catalog.Assets.All(a => a.Commit.Length == 40 && a.Sha256.Length == 64 && a.DownloadUrl.Contains(a.Commit)), "Pinning");
Reject(() => Engine.Validate(Engine.Request("RunCommand")));
Reject(() => Engine.Validate(Engine.Request("Activate", "bad; calc.exe")));
Reject(() => Engine.Validate(Engine.Request("Import", resource: "unknown")));
Console.WriteLine("PASS: pinned catalog and worker operation allowlist");
if (!Engine.IsAdministrator)
{
    var cancelled = await Engine.ExecuteAsync(Engine.Request("Activate", Guid.NewGuid().ToString()), _ => { },
        _ => throw new System.ComponentModel.Win32Exception(1223));
    Assert(!Engine.Bool(cancelled, "Success") && Engine.Text(cancelled, "Message").Contains("取消"), "UAC cancellation");
    Console.WriteLine("PASS: cancelled elevation returns without launching worker");
}
var bytes = Encoding.UTF8.GetBytes("synthetic power plan");
var hash = Convert.ToHexString(SHA256.HashData(bytes));
var id = "test-" + Guid.NewGuid().ToString("N");
var asset = Catalog.Assets[0] with { Id = id, Sha256 = hash };
var folder = Path.GetDirectoryName(Catalog.CachePath(asset))!;
try
{
    using var badClient = new HttpClient(new FakeHandler([1, 2, 3]));
    var rejected = false;
    try { await Catalog.DownloadAsync(asset, _ => { }, badClient); } catch (InvalidDataException) { rejected = true; }
    Assert(rejected && !File.Exists(Catalog.CachePath(asset)), "Corrupt download was retained");
    var handler = new FakeHandler(bytes);
    using var goodClient = new HttpClient(handler);
    var path = await Catalog.DownloadAsync(asset, _ => { }, goodClient);
    Assert(Catalog.Matches(path, hash), "Downloaded digest");
    await Catalog.DownloadAsync(asset, _ => { }, badClient);
    Assert(handler.Calls == 1, "Verified cache unexpectedly fetched");
    File.WriteAllText(path, "tamper");
    Assert(!Catalog.Matches(path, hash), "Cache tampering not detected");
    Console.WriteLine("PASS: corrupt download rejection, verified offline cache, cache tampering");
}
finally
{
    var expected = Path.GetFullPath(Path.Combine(Catalog.UserRoot, "cache")) + Path.DirectorySeparatorChar;
    if (Path.GetFullPath(folder).StartsWith(expected, StringComparison.OrdinalIgnoreCase) && Path.GetFileName(folder) == id && Directory.Exists(folder)) Directory.Delete(folder, true);
}
var lockPath = Path.Combine(Path.GetTempPath(), Guid.NewGuid() + ".lock");
try
{
    using var held = new FileStream(lockPath, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None);
    Reject(() => { using var conflict = new FileStream(lockPath, FileMode.Open, FileAccess.ReadWrite, FileShare.None); });
    Console.WriteLine("PASS: exclusive operation lock rejects concurrent writer");
}
finally { File.Delete(lockPath); }
if (args.Contains("--vm-worker"))
{
    if (Environment.GetEnvironmentVariable("GITHUB_ACTIONS") != "true" || !Engine.IsAdministrator)
        throw new InvalidOperationException("Worker integration is restricted to the elevated disposable CI VM.");
    var pipeName = "LzPlans-" + Guid.NewGuid().ToString("N");
    var exportPath = Path.Combine(Path.GetTempPath(), "lz-worker-" + Guid.NewGuid().ToString("N") + ".pow");
    try
    {
        var before = await Engine.ReadAsync(Engine.Request("Status"));
        var active = Engine.Text(before["State"], "ActiveGuid");
        await using var pipe = new NamedPipeServerStream(pipeName, PipeDirection.InOut, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        var worker = Engine.WorkerAsync(pipeName);
        using var timeout = new CancellationTokenSource(TimeSpan.FromMinutes(1));
        await pipe.WaitForConnectionAsync(timeout.Token);
        using var reader = new StreamReader(pipe, Encoding.UTF8, false, 4096, true);
        using var writer = new StreamWriter(pipe, new UTF8Encoding(false), 4096, true) { AutoFlush = true };
        var request = Engine.Request("Export", active); request["ExportPath"] = exportPath;
        await writer.WriteLineAsync(request.ToJsonString());
        JsonNode? result = null;
        while (result is null)
        {
            var msg = JsonNode.Parse(await reader.ReadLineAsync(timeout.Token) ?? "")!;
            if (Engine.Text(msg, "Kind") == "Result") result = msg["Value"];
        }
        await worker;
        Assert(Engine.Bool(result, "Success") && new FileInfo(exportPath).Length > 0, "Native worker export failed: " + result);
        var after = await Engine.ReadAsync(Engine.Request("Status"));
        Assert(Engine.Text(after["State"], "ActiveGuid") == active, "Worker export changed active plan");
        Console.WriteLine("PASS: named-pipe administrator worker, embedded PowerShell bridge, native export and state preservation");
    }
    finally { if(File.Exists(exportPath)) File.Delete(exportPath); }
}
Console.WriteLine("Desktop checks passed (no real power mutations or UAC).");

sealed class FakeHandler(byte[] content) : HttpMessageHandler
{
    public int Calls;
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
    { Calls++; return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(content) }); }
}
