using System.Windows;
namespace LenovoPowerPlanTools;
public partial class App : Application
{
    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        if (e.Args.Length == 2 && e.Args[0] == "--worker")
        {
            try { await Engine.WorkerAsync(e.Args[1]); } catch { /* Caller detects a disconnected pipe. */ }
            Shutdown(); return;
        }
        if (e.Args.Length == 2 && e.Args[0] == "--diagnose")
        {
            try { var state = await Engine.ReadAsync(Engine.Request("Status")); await System.IO.File.WriteAllTextAsync(e.Args[1], state.ToJsonString()); }
            finally { Shutdown(); }
            return;
        }
        if (!Environment.Is64BitOperatingSystem || System.Runtime.InteropServices.RuntimeInformation.OSArchitecture != System.Runtime.InteropServices.Architecture.X64)
        { MessageBox.Show("首版仅支持 Windows x64。"); Shutdown(); return; }
        if (Environment.OSVersion.Version.Build < 19045)
        { MessageBox.Show("首版要求 Windows 10 22H2 或更新的 Windows x64。"); Shutdown(); return; }
        MainWindow = new MainWindow();
        MainWindow.Show();
    }
}
