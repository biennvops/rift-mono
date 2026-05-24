namespace Rift.Daemon.Windows;

public interface IRiftApi
{
    Task<string> GetVersionAsync();
    Task<string> GetStatusAsync();
}
