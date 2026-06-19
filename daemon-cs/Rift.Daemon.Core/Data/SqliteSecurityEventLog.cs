using System.Text.Json;
using Microsoft.Data.Sqlite;
using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.Core.Data;

public sealed class SqliteSecurityEventLog(DatabaseContext databaseContext) : ISecurityEventLog
{
    public Task LogEventAsync(SecurityEventRecord securityEvent)
    {
        ArgumentNullException.ThrowIfNull(securityEvent);

        using var connection = databaseContext.CreateOpenConnection();
        using var command = connection.CreateCommand();
        command.CommandText =
            """
            INSERT INTO SecurityEvents (
                EventId,
                EventType,
                Severity,
                LocalDeviceId,
                PeerDeviceId,
                OperationId,
                Timestamp,
                Outcome,
                FailureReason,
                DetailsJson)
            VALUES (
                $eventId,
                $eventType,
                $severity,
                $localDeviceId,
                $peerDeviceId,
                $operationId,
                $timestamp,
                $outcome,
                $failureReason,
                $detailsJson);
            """;
        BindRecord(command, securityEvent);
        command.ExecuteNonQuery();
        return Task.CompletedTask;
    }

    public Task<IReadOnlyList<SecurityEventRecord>> QueryEventsAsync(SecurityEventQuery query)
    {
        ArgumentNullException.ThrowIfNull(query);

        using var connection = databaseContext.CreateOpenConnection();
        using var command = connection.CreateCommand();

        var predicates = new List<string>();

        if (query.EventTypes is { Count: > 0 })
        {
            predicates.Add(BuildInClause(command, "$eventType", "EventType", query.EventTypes));
        }

        if (query.Severities is { Count: > 0 })
        {
            predicates.Add(BuildInClause(command, "$severity", "Severity", query.Severities));
        }

        if (!string.IsNullOrWhiteSpace(query.PeerDeviceId))
        {
            predicates.Add("PeerDeviceId = $peerDeviceId");
            command.Parameters.AddWithValue("$peerDeviceId", query.PeerDeviceId);
        }

        if (query.Since is not null)
        {
            predicates.Add("Timestamp >= $since");
            command.Parameters.AddWithValue("$since", query.Since.Value.ToString("O"));
        }

        command.CommandText =
            $"""
            SELECT EventId, EventType, Severity, LocalDeviceId, PeerDeviceId, OperationId, Timestamp, Outcome, FailureReason, DetailsJson
            FROM SecurityEvents
            {(predicates.Count > 0 ? "WHERE " + string.Join(" AND ", predicates) : string.Empty)}
            ORDER BY Timestamp DESC
            LIMIT $limit OFFSET $offset;
            """;
        command.Parameters.AddWithValue("$limit", Math.Max(1, query.Limit));
        command.Parameters.AddWithValue("$offset", Math.Max(0, query.Offset));

        var results = new List<SecurityEventRecord>();
        using var reader = command.ExecuteReader();
        while (reader.Read())
        {
            results.Add(new SecurityEventRecord
            {
                EventId = (string)reader["EventId"],
                EventType = (string)reader["EventType"],
                Severity = Enum.Parse<SecurityEventSeverity>((string)reader["Severity"]),
                LocalDeviceId = (string)reader["LocalDeviceId"],
                PeerDeviceId = reader["PeerDeviceId"] as string,
                OperationId = reader["OperationId"] as string,
                Timestamp = DateTimeOffset.Parse((string)reader["Timestamp"]),
                Outcome = Enum.Parse<SecurityEventOutcome>((string)reader["Outcome"]),
                FailureReason = reader["FailureReason"] as string,
                Details = ParseDetails(reader["DetailsJson"] as string)
            });
        }

        return Task.FromResult<IReadOnlyList<SecurityEventRecord>>(results);
    }

    private static void BindRecord(SqliteCommand command, SecurityEventRecord record)
    {
        command.Parameters.AddWithValue("$eventId", record.EventId);
        command.Parameters.AddWithValue("$eventType", record.EventType);
        command.Parameters.AddWithValue("$severity", record.Severity.ToString());
        command.Parameters.AddWithValue("$localDeviceId", record.LocalDeviceId);
        command.Parameters.AddWithValue("$peerDeviceId", (object?)record.PeerDeviceId ?? DBNull.Value);
        command.Parameters.AddWithValue("$operationId", (object?)record.OperationId ?? DBNull.Value);
        command.Parameters.AddWithValue("$timestamp", record.Timestamp.ToString("O"));
        command.Parameters.AddWithValue("$outcome", record.Outcome.ToString());
        command.Parameters.AddWithValue("$failureReason", (object?)record.FailureReason ?? DBNull.Value);
        command.Parameters.AddWithValue("$detailsJson", record.Details is null ? DBNull.Value : JsonSerializer.Serialize(record.Details));
    }

    private static string BuildInClause(SqliteCommand command, string parameterPrefix, string columnName, IReadOnlyList<string> values)
    {
        var parameterNames = new List<string>(values.Count);
        for (var i = 0; i < values.Count; i++)
        {
            var parameterName = $"{parameterPrefix}{i}";
            parameterNames.Add(parameterName);
            command.Parameters.AddWithValue(parameterName, values[i]);
        }

        return $"{columnName} IN ({string.Join(", ", parameterNames)})";
    }

    private static IDictionary<string, object>? ParseDetails(string? detailsJson)
    {
        if (string.IsNullOrWhiteSpace(detailsJson))
        {
            return null;
        }

        var document = JsonDocument.Parse(detailsJson);
        var result = new Dictionary<string, object>(StringComparer.Ordinal);
        foreach (var property in document.RootElement.EnumerateObject())
        {
            result[property.Name] = property.Value.ValueKind switch
            {
                JsonValueKind.String => property.Value.GetString() ?? string.Empty,
                JsonValueKind.Number when property.Value.TryGetInt64(out var intValue) => intValue,
                JsonValueKind.Number => property.Value.GetDouble(),
                JsonValueKind.True => true,
                JsonValueKind.False => false,
                _ => property.Value.ToString()
            };
        }

        return result;
    }
}
