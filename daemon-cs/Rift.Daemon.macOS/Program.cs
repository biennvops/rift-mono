using Rift.Daemon.Core;
using Rift.Daemon.Core.Interfaces;
using Rift.Daemon.macOS;

var builder = Host.CreateApplicationBuilder(args);

builder.Services.AddSingleton<IIpcListener, MacIpcListener>();
builder.Services.AddHostedService<Worker>();

var host = builder.Build();
host.Run();
