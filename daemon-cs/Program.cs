using Rift.Daemon.Windows;

var builder = Host.CreateApplicationBuilder(args);
builder.Services.AddWindowsService(options =>
{
    options.ServiceName = "RiftDaemon";
});

builder.Services.AddSingleton<IpcListener>();
builder.Services.AddHostedService<Worker>();

var host = builder.Build();
host.Run();
