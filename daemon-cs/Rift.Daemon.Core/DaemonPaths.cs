namespace Rift.Daemon.Core;

public static class DaemonPaths
{
    public static string GetDefaultDatabasePath()
    {
        if (OperatingSystem.IsWindows())
        {
            var commonAppData = Environment.GetFolderPath(
                Environment.SpecialFolder.CommonApplicationData);
            return Path.Combine(commonAppData, "Rift", "riftd.sqlite3");
        }

        if (OperatingSystem.IsMacOS())
        {
            var appSupport = Environment.GetFolderPath(
                Environment.SpecialFolder.ApplicationData);
            return Path.Combine(appSupport, "Rift", "riftd.sqlite3");
        }

        if (OperatingSystem.IsLinux())
        {
            var xdgDataHome = Environment.GetEnvironmentVariable("XDG_DATA_HOME");
            if (!string.IsNullOrWhiteSpace(xdgDataHome))
            {
                return Path.Combine(xdgDataHome, "rift-daemon", "riftd.sqlite3");
            }

            var localAppData = Environment.GetFolderPath(
                Environment.SpecialFolder.LocalApplicationData);
            if (!string.IsNullOrWhiteSpace(localAppData))
            {
                return Path.Combine(localAppData, "rift-daemon", "riftd.sqlite3");
            }

            var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            return Path.Combine(home, ".local", "share", "rift-daemon", "riftd.sqlite3");
        }

        throw new PlatformNotSupportedException("Unsupported platform for Rift daemon storage.");
    }
}
