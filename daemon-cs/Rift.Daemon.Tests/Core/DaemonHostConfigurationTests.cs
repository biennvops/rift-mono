using Microsoft.Extensions.DependencyInjection;
using Microsoft.Data.Sqlite;
using Rift.Daemon.Core;
using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.Tests.Core;

public sealed class DaemonHostConfigurationTests : IDisposable
{
    private readonly string _databasePath =
        Path.Combine(Path.GetTempPath(), $"rift-di-{Guid.NewGuid():N}.db");

    [Fact]
    public async Task AddRiftCoreServices_ResolvesConfiguredRiftApiHandler()
    {
        var services = new ServiceCollection();
        services.AddLogging();
        services.AddRiftCoreServices(_databasePath);

        using var provider = services.BuildServiceProvider();
        var identityManager = provider.GetRequiredService<IIdentityManager>();
        identityManager.EnsureIdentityInitialized();

        var api = provider.GetRequiredService<IRiftApi>();
        var deviceInfo = await api.GetDeviceInfoAsync();
        var notifications = await api.ListNotificationsAsync();

        Assert.NotEmpty(deviceInfo.DeviceId);
        Assert.NotNull(notifications.Policy);
    }

    public void Dispose()
    {
        SqliteConnection.ClearAllPools();
        if (File.Exists(_databasePath))
        {
            File.Delete(_databasePath);
        }
    }
}
