using System.IO;
using Rift.Daemon.Core;
using Rift.Daemon.Core.Cryptography;
using Rift.Daemon.Core.Data;
using Rift.Daemon.Core.Interfaces;
using Rift.Daemon.Core.Networking;
using Rift.Daemon.Windows;

var builder = Host.CreateApplicationBuilder(args);
builder.Services.AddWindowsService(options =>
{
    options.ServiceName = "RiftDaemon";
});

var serviceDataDir = Path.Combine(
    Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
    "Rift");
var databasePath = Path.Combine(serviceDataDir, "riftd.sqlite3");

var databaseContext = new DatabaseContext(databasePath);
databaseContext.Initialize();

builder.Services.AddSingleton(databaseContext);
builder.Services.AddSingleton<ILocalIdentityStore, SqliteLocalIdentityStore>();
builder.Services.AddSingleton<ITrustStore, SqliteTrustStore>();
builder.Services.AddSingleton<ISecurityEventLog, SqliteSecurityEventLog>();
builder.Services.AddSingleton<IIdentityManager, IdentityManager>();
builder.Services.AddSingleton<IDiscoveryCoordinator, DiscoveryCoordinator>();
builder.Services.AddSingleton<IDaemonInfoService, DaemonInfoService>();
builder.Services.AddSingleton<IPresenceService, PresenceService>();
builder.Services.AddSingleton<IClipboardService, ClipboardService>();
builder.Services.AddSingleton<IPairingProtocolCoordinator, PairingProtocolCoordinator>();
builder.Services.AddSingleton<IProtocolMessageRouter, ProtocolMessageRouter>();
builder.Services.AddSingleton<IPairingService, PairingService>();
builder.Services.AddSingleton<IDiscoveryService, DiscoveryService>();
builder.Services.AddSingleton<ITransport, TlsTransport>();
builder.Services.AddTransient<IRiftApi, RiftApiHandler>();
builder.Services.AddSingleton<IIpcListener, WindowsIpcListener>();
builder.Services.AddHostedService<Worker>();

var host = builder.Build();
host.Run();
