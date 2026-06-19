using Microsoft.Data.Sqlite;
using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.Core.Data;

public sealed class SqliteLocalIdentityStore(DatabaseContext databaseContext) : ILocalIdentityStore
{
    public LocalIdentityRecord? GetIdentity()
    {
        using var connection = databaseContext.CreateOpenConnection();
        using var command = connection.CreateCommand();
        command.CommandText =
            """
            SELECT Ed25519PrivateKey, Ed25519PublicKey, CreatedAt
            FROM LocalIdentity
            WHERE Id = 1;
            """;

        using var reader = command.ExecuteReader();
        if (!reader.Read())
        {
            return null;
        }

        return new LocalIdentityRecord
        {
            Ed25519PrivateKey = (byte[])reader["Ed25519PrivateKey"],
            Ed25519PublicKey = (byte[])reader["Ed25519PublicKey"],
            CreatedAt = DateTimeOffset.Parse((string)reader["CreatedAt"])
        };
    }

    public void SaveIdentity(LocalIdentityRecord identity)
    {
        ArgumentNullException.ThrowIfNull(identity);

        using var connection = databaseContext.CreateOpenConnection();
        using var command = connection.CreateCommand();
        command.CommandText =
            """
            INSERT INTO LocalIdentity (Id, Ed25519PrivateKey, Ed25519PublicKey, CreatedAt)
            VALUES (1, $privateKey, $publicKey, $createdAt)
            ON CONFLICT(Id) DO UPDATE SET
                Ed25519PrivateKey = excluded.Ed25519PrivateKey,
                Ed25519PublicKey = excluded.Ed25519PublicKey,
                CreatedAt = excluded.CreatedAt;
            """;
        command.Parameters.AddWithValue("$privateKey", identity.Ed25519PrivateKey);
        command.Parameters.AddWithValue("$publicKey", identity.Ed25519PublicKey);
        command.Parameters.AddWithValue("$createdAt", identity.CreatedAt.ToString("O"));
        command.ExecuteNonQuery();
    }
}
