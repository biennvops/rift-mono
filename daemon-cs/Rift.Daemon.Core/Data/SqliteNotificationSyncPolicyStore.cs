using System.Text.Json;
using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.Core.Data;

public sealed class SqliteNotificationSyncPolicyStore(DatabaseContext databaseContext) : INotificationSyncPolicyStore
{
    public NotificationSyncPolicy Load()
    {
        using var connection = databaseContext.CreateOpenConnection();
        using var command = connection.CreateCommand();
        command.CommandText =
            "SELECT Enabled, BlacklistedPackagesJson FROM NotificationSyncPolicy WHERE Id = 1;";

        using var reader = command.ExecuteReader();
        if (!reader.Read())
        {
            return CreateDefaultPolicy();
        }

        try
        {
            if (reader.IsDBNull(0) || reader.IsDBNull(1))
            {
                return CreateFailClosedPolicy();
            }

            var enabledValue = reader.GetInt64(0);
            if (enabledValue is not 0 and not 1)
            {
                return CreateFailClosedPolicy();
            }

            var blacklist = JsonSerializer.Deserialize<string[]>(reader.GetString(1));
            if (blacklist is null || blacklist.Any(string.IsNullOrWhiteSpace))
            {
                return CreateFailClosedPolicy();
            }

            return new NotificationSyncPolicy
            {
                Enabled = enabledValue == 1,
                BlacklistedPackages = NormalizeBlacklist(blacklist)
            };
        }
        catch (Exception ex) when (ex is JsonException or FormatException or InvalidCastException)
        {
            return CreateFailClosedPolicy();
        }
    }

    public void Save(NotificationSyncPolicy policy)
    {
        var blacklistJson = JsonSerializer.Serialize(NormalizeBlacklist(policy.BlacklistedPackages));
        using var connection = databaseContext.CreateOpenConnection();
        using var command = connection.CreateCommand();
        command.CommandText =
            """
            INSERT INTO NotificationSyncPolicy (Id, Enabled, BlacklistedPackagesJson)
            VALUES (1, $enabled, $blacklist)
            ON CONFLICT(Id) DO UPDATE SET
                Enabled = excluded.Enabled,
                BlacklistedPackagesJson = excluded.BlacklistedPackagesJson;
            """;
        command.Parameters.AddWithValue("$enabled", policy.Enabled ? 1 : 0);
        command.Parameters.AddWithValue("$blacklist", blacklistJson);
        command.ExecuteNonQuery();
    }

    private static NotificationSyncPolicy CreateDefaultPolicy() => new()
    {
        Enabled = true,
        BlacklistedPackages = []
    };

    private static NotificationSyncPolicy CreateFailClosedPolicy() => new()
    {
        Enabled = false,
        BlacklistedPackages = []
    };

    private static IReadOnlyList<string> NormalizeBlacklist(IEnumerable<string> values) =>
        values
            .Where(value => !string.IsNullOrWhiteSpace(value))
            .Select(value => value.Trim())
            .Distinct(StringComparer.Ordinal)
            .ToArray();
}
