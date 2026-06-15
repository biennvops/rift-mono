using Rift.Daemon.Core;
using Rift.Daemon.Core.Interfaces;
using Rift.Daemon.Core.Networking;
using Rift.Daemon.Windows;

var builder = Host.CreateApplicationBuilder(args);
builder.Services.AddWindowsService(options =>
{
    options.ServiceName = "RiftDaemon";
});

builder.Services.AddSingleton<IIpcListener, WindowsIpcListener>();
builder.Services.AddSingleton<IIdentityManager, Rift.Daemon.Core.Cryptography.IdentityManager>();
builder.Services.AddSingleton<ITrustStore, Rift.Daemon.Core.Persistence.InMemoryTrustStore>();
builder.Services.AddSingleton<IDiscoveryService, Rift.Daemon.Core.Networking.DiscoveryService>();
builder.Services.AddSingleton<SessionBootstrap>(); // Needs to be concrete for TlsTransport
builder.Services.AddSingleton<ITransport, Rift.Daemon.Core.Networking.TlsTransport>();
builder.Services.AddHostedService<Worker>();

var host = builder.Build();
host.Run();
