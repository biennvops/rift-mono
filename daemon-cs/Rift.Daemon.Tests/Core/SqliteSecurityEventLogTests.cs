using Microsoft.Data.Sqlite;
using Rift.Daemon.Core.Data;
using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.Tests.Core;

public sealed class SqliteSecurityEventLogTests : IDisposable
{
    private readonly string _databasePath;
    private readonly DatabaseContext _databaseContext;
    private readonly SqliteSecurityEventLog _eventLog;
    private readonly SqliteSecurityEventLog _boundedEventLog;

    public SqliteSecurityEventLogTests()
    {
        _databasePath = Path.Combine(Path.GetTempPath(), $"rift-events-{Guid.NewGuid():N}.db");
        _databaseContext = new DatabaseContext(_databasePath);
        _databaseContext.Initialize();
        _eventLog = new SqliteSecurityEventLog(_databaseContext);
        _boundedEventLog = new SqliteSecurityEventLog(_databaseContext, maxRetainedEvents: 3);
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

    [Fact]
    public async Task LogEventAsync_PrunesOldestEventsBeyondRetentionLimit()
    {
        for (var i = 0; i < 5; i++)
        {
            await _boundedEventLog.LogEventAsync(new SecurityEventRecord
            {
                EventId = $"event-{i}",
                EventType = SecurityEventTypes.PairingAttempted,
                Severity = SecurityEventSeverity.Info,
                LocalDeviceId = "rift-local",
                PeerDeviceId = $"rift-peer-{i}",
                Timestamp = DateTimeOffset.Parse("2026-06-19T00:00:00Z").AddMinutes(i),
                Outcome = SecurityEventOutcome.Success,
                Details = new Dictionary<string, object> { ["sequence"] = i }
            });
        }

        var results = await _boundedEventLog.QueryEventsAsync(new SecurityEventQuery
        {
            Limit = 10
        });

        Assert.Equal(3, results.Count);
        Assert.DoesNotContain(results, evt => evt.EventId == "event-0");
        Assert.DoesNotContain(results, evt => evt.EventId == "event-1");
        Assert.Contains(results, evt => evt.EventId == "event-4");
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
