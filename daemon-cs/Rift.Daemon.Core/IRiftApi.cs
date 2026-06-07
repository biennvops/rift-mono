namespace Rift.Daemon.Core;

public interface IRiftApi
{
    Task<string> GetVersionAsync();
    Task<string> GetStatusAsync();
}
