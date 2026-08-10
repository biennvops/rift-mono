using Rift.Daemon.Core;
using Rift.Daemon.Core.Data;
using Rift.Daemon.Core.Interfaces;
using Rift.Daemon.Linux;

var builder = Host.CreateApplicationBuilder(args);

builder.Services.AddSystemd();
builder.Services.AddRiftCoreServices(DaemonPaths.GetDefaultDatabasePath());
builder.Services.AddSingleton<ILinuxSecretStore, LinuxSecretStore>();
builder.Services.AddSingleton<IUnixIdentityProtectionKeyProvider, LinuxSecretServiceIdentityProtectionKeyProvider>();
builder.Services.AddSingleton<ILocalIdentityStore>(sp => new SqliteLocalIdentityStore(
    sp.GetRequiredService<DatabaseContext>(),
    sp.GetRequiredService<IUnixIdentityProtectionKeyProvider>()));
builder.Services.AddSingleton<IIpcListener, LinuxIpcListener>();
builder.Services.AddSingleton<ILinuxMprisArtworkLoader, LinuxMprisArtworkLoader>();
builder.Services.AddSingleton<ILinuxMprisClient, LinuxMprisClient>();
builder.Services.AddSingleton<ILinuxMprisRemotePlayer, LinuxMprisRemotePlayer>();
builder.Services.AddSingleton<ILinuxNotificationMonitor, LinuxFreedesktopNotificationMonitor>();
builder.Services.AddSingleton<LinuxMediaPlaybackService>();
builder.Services.AddHostedService<LinuxNotificationSyncObserver>();
builder.Services.AddSingleton<ILocalMediaPlaybackActionHandler>(sp =>
    sp.GetRequiredService<LinuxMediaPlaybackService>());
builder.Services.AddHostedService<Worker>();

var host = builder.Build();
var logger = host.Services.GetRequiredService<ILoggerFactory>()
    .CreateLogger("Rift.Daemon.Linux");

try
{
    LinuxIpcListener.EnsureNoDuplicateInstance();
}
catch (InvalidOperationException ex)
{
    logger.LogCritical("{message}", ex.Message);
    return;
}

var lifetime = host.Services.GetRequiredService<IHostApplicationLifetime>();
var mediaPlaybackService = host.Services.GetRequiredService<LinuxMediaPlaybackService>();
lifetime.ApplicationStarted.Register(() =>
    mediaPlaybackService.Start(lifetime.ApplicationStopping));

host.Run();
