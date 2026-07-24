// RAM Monitor launcher - starts the PowerShell app hidden, no console window.
// Built by tools/build-launcher.ps1 using the C# compiler bundled with Windows.
using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

static class Launcher
{
    [STAThread]
    static void Main()
    {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(dir, "src", "RamMonitor.ps1");
        if (!File.Exists(script))
        {
            MessageBox.Show("Could not find the application script:\n" + script +
                "\n\nKeep RAM Monitor.exe next to the 'src' folder.", "RAM Monitor",
                MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return;
        }
        ProcessStartInfo psi = new ProcessStartInfo();
        psi.FileName = "powershell.exe";
        psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + script + "\"";
        psi.WindowStyle = ProcessWindowStyle.Hidden;
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        Process.Start(psi);
    }
}
