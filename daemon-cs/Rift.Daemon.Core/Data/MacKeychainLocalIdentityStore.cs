using System.Runtime.Versioning;
using System.Diagnostics;
using Org.BouncyCastle.Crypto.Parameters;
using Rift.Daemon.Core.Cryptography;
using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.Core.Data;

public sealed class MacKeychainLocalIdentityStore : ILocalIdentityStore
{
    internal const string ServiceName = "com.rift.daemon.identity";
    internal const string PrivateKeyAccount = "ed25519-private-key";
    internal const string TlsCertificateAccount = "tls-pkcs12";

    private readonly DatabaseContext _databaseContext;
    private readonly SqliteLocalIdentityStore _legacyStore;
    private readonly IMacKeychain _keychain;

    [SupportedOSPlatform("macos")]
    public MacKeychainLocalIdentityStore(DatabaseContext databaseContext)
        : this(databaseContext, new MacKeychain())
    {
        if (!OperatingSystem.IsMacOS())
        {
            throw new PlatformNotSupportedException("MacKeychainLocalIdentityStore is only supported on macOS.");
        }
    }

    internal MacKeychainLocalIdentityStore(DatabaseContext databaseContext, IMacKeychain keychain)
    {
        ArgumentNullException.ThrowIfNull(databaseContext);
        ArgumentNullException.ThrowIfNull(keychain);

        _databaseContext = databaseContext;
        _legacyStore = new SqliteLocalIdentityStore(databaseContext);
        _keychain = keychain;
    }

    public LocalIdentityRecord? GetIdentity()
    {
        var metadata = GetMetadata();
        var privateKey = _keychain.GetSecret(ServiceName, PrivateKeyAccount);
        var tlsCertificate = _keychain.GetSecret(ServiceName, TlsCertificateAccount);

        if (privateKey is null && tlsCertificate is null)
        {
            if (metadata is null)
            {
                return null;
            }

            if (metadata.HasLegacySecrets)
            {
                var legacyIdentity = _legacyStore.GetIdentity()
                    ?? throw new InvalidOperationException("Legacy macOS identity metadata existed without readable secret material.");
                SaveIdentity(legacyIdentity);
                return legacyIdentity;
            }

            throw new InvalidOperationException("macOS identity metadata existed in SQLite, but Keychain secrets were missing.");
        }

        if (privateKey is null)
        {
            throw new InvalidOperationException("macOS Keychain local identity was incomplete.");
        }

        if (privateKey.Length != 32)
        {
            throw new InvalidOperationException("macOS Keychain Ed25519 private key was malformed.");
        }

        var derivedPublicKey = new Ed25519PrivateKeyParameters(privateKey, 0).GeneratePublicKey().GetEncoded();
        if (tlsCertificate is not null)
        {
            var certificate = IdentityManager.LoadPersistedTlsCertificate(
                tlsCertificate,
                new Ed25519PublicKeyParameters(derivedPublicKey, 0));

            var embeddedPublicKey = IdentityManager.ExtractEmbeddedEd25519PublicKey(certificate);
            if (!embeddedPublicKey.AsSpan().SequenceEqual(derivedPublicKey))
            {
                throw new InvalidOperationException("macOS Keychain TLS certificate did not match the Ed25519 private key.");
            }
        }

        if (metadata is null)
        {
            var rebuilt = new LocalIdentityRecord
            {
                Ed25519PrivateKey = privateKey,
                Ed25519PublicKey = derivedPublicKey,
                TlsCertificatePfx = tlsCertificate,
                CreatedAt = DateTimeOffset.UtcNow
            };
            SaveMetadata(rebuilt);
            return rebuilt;
        }

        if (!metadata.Ed25519PublicKey.AsSpan().SequenceEqual(derivedPublicKey))
        {
            throw new InvalidOperationException("macOS identity metadata did not match the Keychain Ed25519 private key.");
        }

        if (metadata.HasLegacySecrets)
        {
            SaveMetadata(new LocalIdentityRecord
            {
                Ed25519PrivateKey = privateKey,
                Ed25519PublicKey = derivedPublicKey,
                TlsCertificatePfx = tlsCertificate,
                CreatedAt = metadata.CreatedAt
            });
        }

        return new LocalIdentityRecord
        {
            Ed25519PrivateKey = privateKey,
            Ed25519PublicKey = derivedPublicKey,
            TlsCertificatePfx = tlsCertificate,
            CreatedAt = metadata.CreatedAt
        };
    }

    public void SaveIdentity(LocalIdentityRecord identity)
    {
        ArgumentNullException.ThrowIfNull(identity);

        if (identity.Ed25519PrivateKey.Length != 32)
        {
            throw new InvalidOperationException("Local identity Ed25519 private key was malformed.");
        }

        if (identity.Ed25519PublicKey.Length != 32)
        {
            throw new InvalidOperationException("Local identity Ed25519 public key was malformed.");
        }

        var derivedPublicKey = new Ed25519PrivateKeyParameters(identity.Ed25519PrivateKey, 0).GeneratePublicKey().GetEncoded();
        if (!derivedPublicKey.AsSpan().SequenceEqual(identity.Ed25519PublicKey))
        {
            throw new InvalidOperationException("Local identity Ed25519 keypair was inconsistent.");
        }

        if (identity.TlsCertificatePfx is not null)
        {
            var certificate = IdentityManager.LoadPersistedTlsCertificate(
                identity.TlsCertificatePfx,
                new Ed25519PublicKeyParameters(identity.Ed25519PublicKey, 0));
            var embeddedPublicKey = IdentityManager.ExtractEmbeddedEd25519PublicKey(certificate);
            if (!embeddedPublicKey.AsSpan().SequenceEqual(identity.Ed25519PublicKey))
            {
                throw new InvalidOperationException("Local identity TLS certificate did not match the Ed25519 public key.");
            }
        }

        _keychain.SetSecret(ServiceName, PrivateKeyAccount, identity.Ed25519PrivateKey);
        if (identity.TlsCertificatePfx is not null)
        {
            _keychain.SetSecret(ServiceName, TlsCertificateAccount, identity.TlsCertificatePfx);
        }
        else
        {
            _keychain.DeleteSecret(ServiceName, TlsCertificateAccount);
        }

        SaveMetadata(identity);
    }

    private MetadataRecord? GetMetadata()
    {
        using var connection = _databaseContext.CreateOpenConnection();
        using var command = connection.CreateCommand();
        command.CommandText =
            """
            SELECT Ed25519PrivateKey, Ed25519PublicKey, TlsCertificatePfx, CreatedAt
            FROM LocalIdentity
            WHERE Id = 1;
            """;

        using var reader = command.ExecuteReader();
        if (!reader.Read())
        {
            return null;
        }

        if (reader["Ed25519PublicKey"] is not byte[] publicKey || publicKey.Length != 32)
        {
            throw new InvalidOperationException("Persisted macOS identity metadata did not include a valid Ed25519 public key.");
        }

        return new MetadataRecord(
            publicKey,
            DateTimeOffset.Parse((string)reader["CreatedAt"]),
            HasLegacySecrets: reader["Ed25519PrivateKey"] is byte[] || reader["TlsCertificatePfx"] is byte[]);
    }

    private void SaveMetadata(LocalIdentityRecord identity)
    {
        using var connection = _databaseContext.CreateOpenConnection();
        using var command = connection.CreateCommand();
        command.CommandText =
            """
            INSERT INTO LocalIdentity (Id, Ed25519PrivateKey, Ed25519PublicKey, TlsCertificatePfx, CreatedAt)
            VALUES (1, NULL, $publicKey, NULL, $createdAt)
            ON CONFLICT(Id) DO UPDATE SET
                Ed25519PrivateKey = NULL,
                Ed25519PublicKey = excluded.Ed25519PublicKey,
                TlsCertificatePfx = NULL,
                CreatedAt = excluded.CreatedAt;
            """;
        command.Parameters.AddWithValue("$publicKey", identity.Ed25519PublicKey);
        command.Parameters.AddWithValue("$createdAt", identity.CreatedAt.ToString("O"));
        command.ExecuteNonQuery();
    }

    private sealed record MetadataRecord(byte[] Ed25519PublicKey, DateTimeOffset CreatedAt, bool HasLegacySecrets);
}

internal interface IMacKeychain
{
    byte[]? GetSecret(string service, string account);

    void SetSecret(string service, string account, byte[] secret);

    void DeleteSecret(string service, string account);
}

[SupportedOSPlatform("macos")]
internal sealed class MacKeychain : IMacKeychain
{
    public byte[]? GetSecret(string service, string account)
    {
        var result = RunSecurityCommand(
            "find-generic-password",
            [
                "-s", service,
                "-a", account,
                "-w"
            ],
            allowNotFound: true);

        if (result.ExitCode != 0)
        {
            return null;
        }

        try
        {
            var trimmed = result.StandardOutput.Trim();
            return string.IsNullOrEmpty(trimmed) ? [] : Convert.FromBase64String(trimmed);
        }
        catch (FormatException ex)
        {
            throw new InvalidOperationException(
                $"Failed to decode Keychain item '{service}/{account}' as base64.",
                ex);
        }
    }

    public void SetSecret(string service, string account, byte[] secret)
    {
        ArgumentNullException.ThrowIfNull(secret);
        var encoded = Convert.ToBase64String(secret);
        RunSecurityCommand(
            "add-generic-password",
            [
                "-s", service,
                "-a", account,
                "-l", $"Rift Daemon {account}",
                "-w", encoded,
                "-U"
            ]);
    }

    public void DeleteSecret(string service, string account)
    {
        RunSecurityCommand(
            "delete-generic-password",
            [
                "-s", service,
                "-a", account
            ],
            allowNotFound: true);
    }

    private static SecurityCommandResult RunSecurityCommand(
        string subcommand,
        IReadOnlyList<string> arguments,
        bool allowNotFound = false)
    {
        var startInfo = new ProcessStartInfo("/usr/bin/security")
        {
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        startInfo.ArgumentList.Add(subcommand);
        foreach (var argument in arguments)
        {
            startInfo.ArgumentList.Add(argument);
        }

        using var process = Process.Start(startInfo)
            ?? throw new InvalidOperationException("Failed to launch /usr/bin/security.");
        var standardOutput = process.StandardOutput.ReadToEnd();
        var standardError = process.StandardError.ReadToEnd();
        process.WaitForExit();

        if (process.ExitCode == 0)
        {
            return new SecurityCommandResult(process.ExitCode, standardOutput, standardError);
        }

        if (allowNotFound &&
            (standardError.Contains("could not be found", StringComparison.OrdinalIgnoreCase) ||
             standardError.Contains("The specified item could not be found", StringComparison.OrdinalIgnoreCase)))
        {
            return new SecurityCommandResult(process.ExitCode, standardOutput, standardError);
        }

        throw new InvalidOperationException(
            $"security {subcommand} failed with exit code {process.ExitCode}: {standardError.Trim()}");
    }

    private readonly record struct SecurityCommandResult(int ExitCode, string StandardOutput, string StandardError);
}
