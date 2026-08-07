using System.Text.Json;
using System.Text.Json.Serialization;
using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.Core.Data;

public sealed class SqliteNotificationSyncPolicyStore(DatabaseContext databaseContext) : INotificationSyncPolicyStore
{
    public NotificationSyncPolicy Load()
    {
        using var connection = databaseContext.CreateOpenConnection();
        using var command = connection.CreateCommand();
        command.CommandText =
            "SELECT Enabled, BlacklistedPackagesJson, PolicyJson FROM NotificationSyncPolicy WHERE Id = 1;";

        using var reader = command.ExecuteReader();
        if (!reader.Read())
        {
            return CreateDefaultPolicy();
        }

        try
        {
            if (!reader.IsDBNull(2))
            {
                return DeserializeCanonicalPolicy(reader.GetString(2));
            }

            return DeserializeLegacyPolicy(reader);
        }
        catch (Exception ex) when (ex is JsonException or FormatException or InvalidCastException or OverflowException or NotificationSyncFailureException)
        {
            return CreateFailClosedPolicy();
        }
    }

    public void Save(NotificationSyncPolicy policy)
    {
        var mode = NotificationSyncPolicyModes.Validate(policy.Mode);
        var packageNames = NotificationSyncPolicyModes.NormalizePackageNames(policy.PackageNames);
        var storedPolicyJson = JsonSerializer.Serialize(new StoredNotificationSyncPolicyV2
        {
            Version = 2,
            Enabled = policy.Enabled,
            Mode = mode,
            PackageNames = packageNames.Select(packageName => (string?)packageName).ToList()
        });
        var legacyPackageNames = mode == NotificationSyncPolicyModes.Exclude
            ? packageNames
            : [];
        var legacyEnabled = mode == NotificationSyncPolicyModes.Include
            ? false
            : policy.Enabled;

        using var connection = databaseContext.CreateOpenConnection();
        using var command = connection.CreateCommand();
        command.CommandText =
            """
            INSERT INTO NotificationSyncPolicy (Id, Enabled, BlacklistedPackagesJson, PolicyJson)
            VALUES (1, $enabled, $blacklist, $policy)
            ON CONFLICT(Id) DO UPDATE SET
                Enabled = excluded.Enabled,
                BlacklistedPackagesJson = excluded.BlacklistedPackagesJson,
                PolicyJson = excluded.PolicyJson;
            """;
        command.Parameters.AddWithValue("$enabled", legacyEnabled ? 1 : 0);
        command.Parameters.AddWithValue("$blacklist", JsonSerializer.Serialize(legacyPackageNames));
        command.Parameters.AddWithValue("$policy", storedPolicyJson);
        command.ExecuteNonQuery();
    }

    private static NotificationSyncPolicy DeserializeCanonicalPolicy(string policyJson)
    {
        var storedPolicy = JsonSerializer.Deserialize<StoredNotificationSyncPolicyV2>(policyJson)
            ?? throw new JsonException("Stored notification sync policy must be an object.");
        if (storedPolicy.Version != 2 ||
            storedPolicy.Enabled is null ||
            storedPolicy.Mode is null ||
            storedPolicy.PackageNames is null)
        {
            throw new JsonException("Stored notification sync policy is not a valid version 2 policy.");
        }

        return new NotificationSyncPolicy
        {
            Enabled = storedPolicy.Enabled.Value,
            Mode = NotificationSyncPolicyModes.Validate(storedPolicy.Mode),
            PackageNames = NotificationSyncPolicyModes.NormalizePackageNames(storedPolicy.PackageNames)
        };
    }

    private static NotificationSyncPolicy DeserializeLegacyPolicy(Microsoft.Data.Sqlite.SqliteDataReader reader)
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

        var packageNames = JsonSerializer.Deserialize<List<string?>>(reader.GetString(1))
            ?? throw new JsonException("Legacy notification sync blacklist must be an array.");
        var normalizedPackageNames = NotificationSyncPolicyModes.NormalizePackageNames(packageNames);
        return new NotificationSyncPolicy
        {
            Enabled = enabledValue == 1,
            Mode = normalizedPackageNames.Count == 0
                ? NotificationSyncPolicyModes.All
                : NotificationSyncPolicyModes.Exclude,
            PackageNames = normalizedPackageNames
        };
    }

    private static NotificationSyncPolicy CreateDefaultPolicy() => new()
    {
        Enabled = true,
        Mode = NotificationSyncPolicyModes.All,
        PackageNames = []
    };

    private static NotificationSyncPolicy CreateFailClosedPolicy() => new()
    {
        Enabled = false,
        Mode = NotificationSyncPolicyModes.All,
        PackageNames = []
    };

    private sealed class StoredNotificationSyncPolicyV2
    {
        [JsonPropertyName("version")]
        public int? Version { get; init; }

        [JsonPropertyName("enabled")]
        public bool? Enabled { get; init; }

        [JsonPropertyName("mode")]
        public string? Mode { get; init; }

        [JsonPropertyName("packageNames")]
        public List<string?>? PackageNames { get; init; }
    }
}
