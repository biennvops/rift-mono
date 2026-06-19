using Microsoft.Data.Sqlite;
using Rift.Daemon.Core.Data;
using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.Tests.Core;

public sealed class SqliteSecurityEventLogTests : IDisposable
{
    private readonly string _databasePath;
    private readonly DatabaseContext _databaseContext;
    private readonly SqliteSecurityEventLog _eventLog;

    public SqliteSecurityEventLogTests()
    {
        _databasePath = Path.Combine(Path.GetTempPath(), $"rift-events-{Guid.NewGuid():N}.db");
        _databaseContext = new DatabaseContext(_databasePath);
        _databaseContext.Initialize();
        _eventLog = new SqliteSecurityEventLog(_databaseContext);
    }

    [Fact]
    public async Task QueryEventsAsync_FiltersByPeerAndEventType()
    {
        await _eventLog.LogEventAsync(new SecurityEventRecord
        {
            EventType = SecurityEventTypes.PairingAttempted,
            Severity = SecurityEventSeverity.Info,
            LocalDeviceId = "rift-local",
            PeerDeviceId = "rift-peer-a",
            Outcome = SecurityEventOutcome.Success
        });

        await _eventLog.LogEventAsync(new SecurityEventRecord
        {
            EventType = SecurityEventTypes.TrustRevoked,
            Severity = SecurityEventSeverity.Warning,
            LocalDeviceId = "rift-local",
            PeerDeviceId = "rift-peer-b",
            Outcome = SecurityEventOutcome.Success
        });

        var results = await _eventLog.QueryEventsAsync(new SecurityEventQuery
        {
            EventTypes = [SecurityEventTypes.PairingAttempted],
            PeerDeviceId = "rift-peer-a"
        });

        Assert.Single(results);
        Assert.Equal(SecurityEventTypes.PairingAttempted, results[0].EventType);
        Assert.Equal("rift-peer-a", results[0].PeerDeviceId);
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
