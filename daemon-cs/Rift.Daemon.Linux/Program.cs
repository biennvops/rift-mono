using Rift.Daemon.Core;
using Rift.Daemon.Core.Interfaces;
using Rift.Daemon.Linux;

var builder = Host.CreateApplicationBuilder(args);

builder.Services.AddSystemd();
builder.Services.AddRiftCoreServices(DaemonPaths.GetDefaultDatabasePath());
builder.Services.AddSingleton<IIpcListener, LinuxIpcListener>();
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

host.Run();
