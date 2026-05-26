using Rift.Daemon.Windows;

var builder = Host.CreateApplicationBuilder(args);
builder.Services.AddWindowsService(options =>
{
    options.ServiceName = "RiftDaemon";
});

// IPC
builder.Services.AddSingleton<IpcListener>();

// Interfaces implementation setup (Mock implementations for Week 2 M1)
builder.Services.AddSingleton<Rift.Daemon.Windows.Interfaces.IIdentityManager, Rift.Daemon.Windows.Services.Mocks.MockIdentityManager>();
builder.Services.AddSingleton<Rift.Daemon.Windows.Interfaces.ITrustStore, Rift.Daemon.Windows.Services.Mocks.MockTrustStore>();
builder.Services.AddSingleton<Rift.Daemon.Windows.Interfaces.IDiscoveryService, Rift.Daemon.Windows.Services.Mocks.MockDiscoveryService>();
builder.Services.AddSingleton<Rift.Daemon.Windows.Interfaces.IClipboardService, Rift.Daemon.Windows.Services.Mocks.MockClipboardService>();

builder.Services.AddHostedService<Worker>();

var host = builder.Build();
host.Run();
