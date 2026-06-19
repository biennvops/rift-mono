using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.Core;

public sealed class NoOpSecurityEventLog : ISecurityEventLog
{
    public Task LogEventAsync(SecurityEventRecord securityEvent) => Task.CompletedTask;

    public Task<IReadOnlyList<SecurityEventRecord>> QueryEventsAsync(SecurityEventQuery query) =>
        Task.FromResult<IReadOnlyList<SecurityEventRecord>>([]);
}
