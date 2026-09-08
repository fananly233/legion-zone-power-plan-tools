using System.IO;
using System.Net.Http;
using System.Reflection;
using System.Security.Cryptography;
using System.Text.Json;

namespace LenovoPowerPlanTools;

public sealed record PlanAsset(string Id, string Name, string Repository, string Commit, string Path,
    string Sha256, string Description, string SourceUrl, string LicenseUrl, string DownloadUrl,
    string License, string Validation);

public static class Catalog
{
    public static readonly string UserRoot = System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "LenovoPowerPlanTools");
    public static readonly string BackupRoot = System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "LenovoPowerPlanTools", "backups");
    public static readonly IReadOnlyList<PlanAsset> Assets = Load();
    static IReadOnlyList<PlanAsset> Load()
    {
        using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("Catalog.json")!;
        var assets = JsonSerializer.Deserialize<List<PlanAsset>>(stream)!;
        if (assets.Select(x => x.Id).Distinct().Count() != assets.Count) throw new InvalidDataException("Duplicate resource id");
        foreach (var a in assets)
        {
            var expected = $"https://raw.githubusercontent.com/{a.Repository}/{a.Commit}/";
            if (!a.DownloadUrl.StartsWith(expected, StringComparison.Ordinal) || a.Commit.Length != 40 ||
                a.Sha256.Length != 64 || a.Id.Any(c => !char.IsAsciiLetterOrDigit(c) && c != '-'))
                throw new InvalidDataException("Invalid pinned catalog");
        }
        return assets;
    }
    public static PlanAsset Find(string id) => Assets.Single(x => x.Id == id);
    public static string CachePath(PlanAsset a) => System.IO.Path.Combine(UserRoot, "cache", a.Id, a.Sha256 + ".pow");
    public static bool Matches(string path, string hash)
    {
        if (!File.Exists(path)) return false;
        using var input = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(input)).Equals(hash, StringComparison.OrdinalIgnoreCase);
    }
    public static async Task<string> DownloadAsync(PlanAsset a, Action<string> progress, HttpClient? suppliedClient = null)
    {
        var target = CachePath(a);
        if (Matches(target, a.Sha256)) { progress("离线缓存校验通过"); return target; }
        Directory.CreateDirectory(System.IO.Path.GetDirectoryName(target)!);
        var tmp = target + "." + Guid.NewGuid().ToString("N") + ".partial";
        using var owned = suppliedClient is null ? new HttpClient(new HttpClientHandler { AllowAutoRedirect = false }) { Timeout = TimeSpan.FromSeconds(60) } : null;
        var client = suppliedClient ?? owned!;
        try
        {
            progress("正在从固定上游版本下载…");
            using var response = await client.GetAsync(a.DownloadUrl, HttpCompletionOption.ResponseHeadersRead);
            response.EnsureSuccessStatusCode();
            if (response.Content.Headers.ContentLength > 1048576) throw new InvalidDataException("资源超过允许大小");
            using (var source = await response.Content.ReadAsStreamAsync())
            await using (var destination = new FileStream(tmp, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                var buffer = new byte[8192]; int count; long total = 0;
                while ((count = await source.ReadAsync(buffer)) != 0)
                {
                    if ((total += count) > 1048576) throw new InvalidDataException("资源超过允许大小");
                    await destination.WriteAsync(buffer.AsMemory(0, count));
                }
            }
            if (!Matches(tmp, a.Sha256)) throw new InvalidDataException("SHA256 不匹配，下载已拒绝；不会导入。");
            File.Move(tmp, target, true);
            progress("下载完成，SHA256 已核验");
            return target;
        }
        finally { if (File.Exists(tmp)) File.Delete(tmp); }
    }
}
