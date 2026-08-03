using System.Runtime.InteropServices;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.macOS;

internal sealed class MacOSNetworkMonitor : IHostedService, IDisposable
{
    private readonly IDiscoveryService _discoveryService;
    private readonly ILogger<MacOSNetworkMonitor> _logger;

    public MacOSNetworkMonitor(
        IDiscoveryService discoveryService,
        ILogger<MacOSNetworkMonitor> logger)
    {
        _discoveryService = discoveryService;
        _logger = logger;
    }

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate void NetworkUpdateCallback(IntPtr context);

    private readonly NetworkUpdateCallback _callback = OnNetworkUpdate;
    private GCHandle _selfHandle;
    private bool _started;

    public Task StartAsync(CancellationToken cancellationToken)
    {
        if (!OperatingSystem.IsMacOS())
        {
            return Task.CompletedTask;
        }

        try
        {
            _selfHandle = GCHandle.Alloc(this);
            var result = NativeMethods.Start(_callback, GCHandle.ToIntPtr(_selfHandle));
            if (result != 0)
            {
                _selfHandle.Free();
                _logger.LogWarning("macOS network path monitor could not be started (status {Status}).", result);
                return Task.CompletedTask;
            }

            _started = true;
            _logger.LogInformation("Started macOS Network.framework path monitor.");
        }
        catch (DllNotFoundException)
        {
            if (_selfHandle.IsAllocated)
            {
                _selfHandle.Free();
            }

            _logger.LogWarning(
                "macOS network path monitor native helper is unavailable; discovery will use its existing refresh behavior.");
        }
        catch (EntryPointNotFoundException)
        {
            if (_selfHandle.IsAllocated)
            {
                _selfHandle.Free();
            }

            _logger.LogWarning("macOS network path monitor native helper has no compatible entry points.");
        }

        return Task.CompletedTask;
    }

    public Task StopAsync(CancellationToken cancellationToken)
    {
        StopNativeMonitor();
        return Task.CompletedTask;
    }

    public void Dispose()
    {
        StopNativeMonitor();
    }

    private void StopNativeMonitor()
    {
        if (_started)
        {
            NativeMethods.Stop();
            _started = false;
        }

        if (_selfHandle.IsAllocated)
        {
            _selfHandle.Free();
        }
    }

    private static void OnNetworkUpdate(IntPtr context)
    {
        if (context == IntPtr.Zero)
        {
            return;
        }

        try
        {
            var monitor = (MacOSNetworkMonitor?)GCHandle.FromIntPtr(context).Target;
            monitor?._discoveryService.NotifyNetworkChanged();
        }
        catch (InvalidOperationException)
        {
            // The callback raced with native monitor shutdown.
        }
    }

    private static class NativeMethods
    {
        [DllImport("librift-network-monitor.dylib", EntryPoint = "rift_network_monitor_start")]
        internal static extern int Start(NetworkUpdateCallback callback, IntPtr context);

        [DllImport("librift-network-monitor.dylib", EntryPoint = "rift_network_monitor_stop")]
        internal static extern void Stop();
    }
}
