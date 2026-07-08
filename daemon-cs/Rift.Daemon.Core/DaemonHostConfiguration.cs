using Microsoft.Extensions.DependencyInjection;
using Rift.Daemon.Core.Cryptography;
using Rift.Daemon.Core.Data;
using Rift.Daemon.Core.Interfaces;
using Rift.Daemon.Core.Networking;

namespace Rift.Daemon.Core;

public static class DaemonHostConfiguration
{
    public static IServiceCollection AddRiftCoreServices(
        this IServiceCollection services,
        string databasePath)
    {
        ArgumentNullException.ThrowIfNull(services);
        ArgumentException.ThrowIfNullOrWhiteSpace(databasePath);

        var databaseContext = new DatabaseContext(databasePath);
        databaseContext.Initialize();

        services.AddSingleton(databaseContext);
        services.AddSingleton<ILocalIdentityStore, SqliteLocalIdentityStore>();
        services.AddSingleton<ITrustStore, SqliteTrustStore>();
        services.AddSingleton<ISecurityEventLog, SqliteSecurityEventLog>();
        services.AddSingleton<IIdentityManager, IdentityManager>();
        services.AddSingleton<IDiscoveryCoordinator, DiscoveryCoordinator>();
        services.AddSingleton<IDaemonInfoService, DaemonInfoService>();
        services.AddSingleton<IIpcNotificationService, IpcNotificationHub>();
        services.AddSingleton<IPresenceService, PresenceService>();
        services.AddSingleton<IOperationService, OperationService>();
        services.AddSingleton<IClipboardService, ClipboardService>();
        services.AddSingleton<IPairingProtocolCoordinator, PairingProtocolCoordinator>();
        services.AddSingleton<IProtocolMessageRouter, ProtocolMessageRouter>();
        services.AddSingleton<IPairingService, PairingService>();
        services.AddSingleton<IDiscoveryService, DiscoveryService>();
        services.AddSingleton<ITransport, TlsTransport>();
        services.AddTransient<IRiftApi, RiftApiHandler>();

        return services;
    }
}
