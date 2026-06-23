using System.Security.Cryptography;
using System.Runtime.InteropServices;
using Microsoft.Data.Sqlite;
using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.Core.Data;

public sealed class SqliteLocalIdentityStore(DatabaseContext databaseContext) : ILocalIdentityStore
{
    private static readonly byte[] WindowsProtectedPrivateKeyPrefix = [0x52, 0x49, 0x46, 0x54, 0x01];
    private static readonly byte[] WindowsProtectedTlsCertificatePrefix = [0x52, 0x49, 0x46, 0x54, 0x02];
    private static readonly byte[] UnixProtectedPrivateKeyPrefix = [0x52, 0x49, 0x46, 0x54, 0x11];
    private static readonly byte[] UnixProtectedTlsCertificatePrefix = [0x52, 0x49, 0x46, 0x54, 0x12];
    private readonly string _keyFilePath = CreateScopedKeyFilePath(databaseContext.DatabasePath);
    private readonly string _legacyKeyFilePath = Path.Combine(
        Path.GetDirectoryName(databaseContext.DatabasePath)!,
        ".rift-secrets.key");

    public LocalIdentityRecord? GetIdentity()
    {
        using var connection = databaseContext.CreateOpenConnection();
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

        return new LocalIdentityRecord
        {
            Ed25519PrivateKey = UnprotectBlob(
                (byte[])reader["Ed25519PrivateKey"],
                WindowsProtectedPrivateKeyPrefix,
                UnixProtectedPrivateKeyPrefix),
            Ed25519PublicKey = (byte[])reader["Ed25519PublicKey"],
            TlsCertificatePfx = reader["TlsCertificatePfx"] is DBNull
                ? null
                : UnprotectBlob(
                    (byte[])reader["TlsCertificatePfx"],
                    WindowsProtectedTlsCertificatePrefix,
                    UnixProtectedTlsCertificatePrefix),
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
            INSERT INTO LocalIdentity (Id, Ed25519PrivateKey, Ed25519PublicKey, TlsCertificatePfx, CreatedAt)
            VALUES (1, $privateKey, $publicKey, $tlsCertificatePfx, $createdAt)
            ON CONFLICT(Id) DO UPDATE SET
                Ed25519PrivateKey = excluded.Ed25519PrivateKey,
                Ed25519PublicKey = excluded.Ed25519PublicKey,
                TlsCertificatePfx = excluded.TlsCertificatePfx,
                CreatedAt = excluded.CreatedAt;
            """;
        command.Parameters.AddWithValue(
            "$privateKey",
            ProtectBlob(
                identity.Ed25519PrivateKey,
                WindowsProtectedPrivateKeyPrefix,
                UnixProtectedPrivateKeyPrefix));
        command.Parameters.AddWithValue("$publicKey", identity.Ed25519PublicKey);
        command.Parameters.AddWithValue(
            "$tlsCertificatePfx",
            (object?)ProtectOptionalBlob(
                identity.TlsCertificatePfx,
                WindowsProtectedTlsCertificatePrefix,
                UnixProtectedTlsCertificatePrefix) ?? DBNull.Value);
        command.Parameters.AddWithValue("$createdAt", identity.CreatedAt.ToString("O"));
        command.ExecuteNonQuery();
    }

    private byte[] ProtectBlob(byte[] plaintext, byte[] windowsPrefix, byte[] unixPrefix)
    {
        if (OperatingSystem.IsWindows())
        {
            var protectedBytes = WindowsDpapi.Protect(plaintext);
            return [.. windowsPrefix, .. protectedBytes];
        }

        return UnixFileKeyProtector.Protect(plaintext, unixPrefix, _keyFilePath);
    }

    private byte[]? ProtectOptionalBlob(byte[]? plaintext, byte[] windowsPrefix, byte[] unixPrefix)
    {
        return plaintext is null ? null : ProtectBlob(plaintext, windowsPrefix, unixPrefix);
    }

    private byte[] UnprotectBlob(byte[] storedValue, byte[] windowsPrefix, byte[] unixPrefix)
    {
        if (IsProtectedBlob(storedValue, windowsPrefix))
        {
            if (!OperatingSystem.IsWindows())
            {
                throw new InvalidOperationException(
                    "Windows-protected local identity material cannot be opened on a non-Windows runtime.");
            }

            var protectedBytes = storedValue.AsSpan(windowsPrefix.Length).ToArray();
            return WindowsDpapi.Unprotect(protectedBytes);
        }

        if (IsProtectedBlob(storedValue, unixPrefix))
        {
            return UnixFileKeyProtector.Unprotect(
                storedValue,
                unixPrefix,
                _keyFilePath,
                legacyKeyFilePath: _legacyKeyFilePath);
        }

        // Legacy compatibility: older rows may contain raw identity material
        // without an at-rest protection prefix.
        return storedValue;
    }

    private static bool IsProtectedBlob(byte[] storedValue, byte[] prefix)
    {
        return storedValue.Length > prefix.Length &&
               storedValue.AsSpan(0, prefix.Length).SequenceEqual(prefix);
    }

    private static string CreateScopedKeyFilePath(string databasePath)
    {
        var directory = Path.GetDirectoryName(databasePath)
            ?? throw new InvalidOperationException("Database path must have a parent directory.");
        var fileName = Path.GetFileName(databasePath);
        return Path.Combine(directory, $"{fileName}.rift-secrets.key");
    }

    private static class UnixFileKeyProtector
    {
        private const int KeyLength = 32;
        private const int NonceLength = 12;
        private const int TagLength = 16;

        public static byte[] Protect(byte[] plaintext, byte[] prefix, string keyFilePath)
        {
            var key = LoadOrCreateKey(keyFilePath);
            var nonce = RandomNumberGenerator.GetBytes(NonceLength);
            var ciphertext = new byte[plaintext.Length];
            var tag = new byte[TagLength];

            using var aes = new AesGcm(key, TagLength);
            aes.Encrypt(nonce, plaintext, ciphertext, tag);

            return [.. prefix, .. nonce, .. tag, .. ciphertext];
        }

        public static byte[] Unprotect(
            byte[] storedValue,
            byte[] prefix,
            string keyFilePath,
            string? legacyKeyFilePath = null)
        {
            var minimumLength = prefix.Length + NonceLength + TagLength;
            if (storedValue.Length < minimumLength)
            {
                throw new InvalidOperationException("Protected local identity material was malformed.");
            }

            var key = LoadExistingKey(keyFilePath)
                ?? (legacyKeyFilePath is not null ? LoadExistingKey(legacyKeyFilePath) : null)
                ?? throw new InvalidOperationException(
                    "Unix identity protection key was missing for persisted identity material.");
            var nonceOffset = prefix.Length;
            var tagOffset = nonceOffset + NonceLength;
            var ciphertextOffset = tagOffset + TagLength;
            var ciphertextLength = storedValue.Length - ciphertextOffset;
            var plaintext = new byte[ciphertextLength];

            using var aes = new AesGcm(key, TagLength);
            aes.Decrypt(
                storedValue.AsSpan(nonceOffset, NonceLength),
                storedValue.AsSpan(ciphertextOffset, ciphertextLength),
                storedValue.AsSpan(tagOffset, TagLength),
                plaintext);

            return plaintext;
        }

        private static byte[] LoadOrCreateKey(string keyFilePath)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(keyFilePath)!);

            var existingKey = LoadExistingKey(keyFilePath);
            if (existingKey is not null) return existingKey;

            var key = RandomNumberGenerator.GetBytes(KeyLength);
            File.WriteAllBytes(keyFilePath, key);
            if (OperatingSystem.IsLinux() || OperatingSystem.IsMacOS())
            {
                File.SetUnixFileMode(
                    keyFilePath,
                    UnixFileMode.UserRead | UnixFileMode.UserWrite);
            }

            return key;
        }

        private static byte[]? LoadExistingKey(string keyFilePath)
        {
            if (!File.Exists(keyFilePath))
            {
                return null;
            }

            var existingKey = File.ReadAllBytes(keyFilePath);
            if (existingKey.Length != KeyLength)
            {
                throw new InvalidOperationException("Unix identity protection key was malformed.");
            }

            return existingKey;
        }
    }

    private static class WindowsDpapi
    {
        public static byte[] Protect(byte[] plaintext)
        {
            return ProtectOrUnprotect(plaintext, protect: true);
        }

        public static byte[] Unprotect(byte[] ciphertext)
        {
            return ProtectOrUnprotect(ciphertext, protect: false);
        }

        private static byte[] ProtectOrUnprotect(byte[] input, bool protect)
        {
            var inputBlob = DataBlob.CreateManaged(input);
            var outputBlob = DataBlob.CreateEmpty();

            try
            {
                var succeeded = protect
                    ? CryptProtectData(ref inputBlob, null, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 0, ref outputBlob)
                    : CryptUnprotectData(ref inputBlob, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 0, ref outputBlob);

                if (!succeeded)
                {
                    throw new InvalidOperationException($"Windows DPAPI {(protect ? "protect" : "unprotect")} failed with Win32 error {Marshal.GetLastWin32Error()}.");
                }

                var output = new byte[outputBlob.cbData];
                Marshal.Copy(outputBlob.pbData, output, 0, outputBlob.cbData);
                return output;
            }
            finally
            {
                inputBlob.Dispose();
                outputBlob.Dispose();
            }
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct DataBlob : IDisposable
        {
            public int cbData;
            public IntPtr pbData;
            private bool _usesLocalFree;

            public static DataBlob CreateManaged(byte[] data)
            {
                var blob = new DataBlob
                {
                    cbData = data.Length,
                    pbData = Marshal.AllocHGlobal(data.Length),
                    _usesLocalFree = false
                };
                Marshal.Copy(data, 0, blob.pbData, data.Length);
                return blob;
            }

            public static DataBlob CreateEmpty()
            {
                return new DataBlob
                {
                    cbData = 0,
                    pbData = IntPtr.Zero,
                    _usesLocalFree = true
                };
            }

            public void Dispose()
            {
                if (pbData != IntPtr.Zero)
                {
                    if (_usesLocalFree)
                    {
                        LocalFree(pbData);
                    }
                    else
                    {
                        Marshal.FreeHGlobal(pbData);
                    }

                    pbData = IntPtr.Zero;
                    cbData = 0;
                }
            }
        }

        [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern bool CryptProtectData(
            ref DataBlob pDataIn,
            string? szDataDescr,
            IntPtr pOptionalEntropy,
            IntPtr pvReserved,
            IntPtr pPromptStruct,
            int dwFlags,
            ref DataBlob pDataOut);

        [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern bool CryptUnprotectData(
            ref DataBlob pDataIn,
            IntPtr ppszDataDescr,
            IntPtr pOptionalEntropy,
            IntPtr pvReserved,
            IntPtr pPromptStruct,
            int dwFlags,
            ref DataBlob pDataOut);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr LocalFree(IntPtr hMem);
    }
}
