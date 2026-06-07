using Rift.Daemon.Core;
using Rift.Daemon.Core.Interfaces;
using Rift.Daemon.macOS;

var builder = Host.CreateApplicationBuilder(args);

builder.Services.AddSingleton<IIpcListener, MacIpcListener>();
builder.Services.AddHostedService<Worker>();

var host = builder.Build();

try
{
    host.Run();
}
catch (InvalidOperationException ex) when (ex.Message.Contains("Another rift-daemon instance"))
{
    var logger = host.Services.GetRequiredService<ILoggerFactory>()
        .CreateLogger("Rift.Daemon.macOS");
    logger.LogCritical(ex, "Exiting: {message}", ex.Message);
}
