namespace Rift.Daemon.Windows;

public class RiftApiHandler : IRiftApi
{
    public Task<string> GetVersionAsync() => Task.FromResult("0.1-draft");

    public Task<string> GetStatusAsync() => Task.FromResult("daemon-running");
}
