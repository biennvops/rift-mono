using Rift.Daemon.Core;
using Rift.Daemon.Core.Data;
using Rift.Daemon.Core.Interfaces;
using Rift.Daemon.macOS;

var builder = Host.CreateApplicationBuilder(args);

builder.Services.AddRiftCoreServices(DaemonPaths.GetDefaultDatabasePath());
builder.Services.AddSingleton<ILocalIdentityStore>(sp =>
    new MacKeychainLocalIdentityStore(sp.GetRequiredService<DatabaseContext>()));
builder.Services.AddSingleton<IIpcListener, MacIpcListener>();
builder.Services.AddSingleton<MacOSMediaPlaybackService>();
builder.Services.AddSingleton<ILocalMediaPlaybackActionHandler>(sp => sp.GetRequiredService<MacOSMediaPlaybackService>());
builder.Services.AddHostedService<Worker>();

var host = builder.Build();
var logger = host.Services.GetRequiredService<ILoggerFactory>()
    .CreateLogger("Rift.Daemon.macOS");

try
{
    MacIpcListener.EnsureNoDuplicateInstance();
}
catch (InvalidOperationException ex)
{
    logger.LogCritical("{message}", ex.Message);
    return;
}

var lifetime = host.Services.GetRequiredService<IHostApplicationLifetime>();
var mediaPlaybackService = host.Services.GetRequiredService<MacOSMediaPlaybackService>();
lifetime.ApplicationStarted.Register(() => mediaPlaybackService.Start(lifetime.ApplicationStopping));

host.Run();
