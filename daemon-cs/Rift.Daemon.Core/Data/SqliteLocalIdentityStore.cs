using System.Runtime.InteropServices;
using Microsoft.Data.Sqlite;
using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.Core.Data;

public sealed class SqliteLocalIdentityStore(DatabaseContext databaseContext) : ILocalIdentityStore
{
    private static readonly byte[] ProtectedPrivateKeyPrefix = [0x52, 0x49, 0x46, 0x54, 0x01];
    private static readonly byte[] ProtectedTlsCertificatePrefix = [0x52, 0x49, 0x46, 0x54, 0x02];

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
            Ed25519PrivateKey = UnprotectBlob((byte[])reader["Ed25519PrivateKey"], ProtectedPrivateKeyPrefix),
            Ed25519PublicKey = (byte[])reader["Ed25519PublicKey"],
            TlsCertificatePfx = reader["TlsCertificatePfx"] is DBNull ? null : UnprotectBlob((byte[])reader["TlsCertificatePfx"], ProtectedTlsCertificatePrefix),
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
        command.Parameters.AddWithValue("$privateKey", ProtectBlob(identity.Ed25519PrivateKey, ProtectedPrivateKeyPrefix));
        command.Parameters.AddWithValue("$publicKey", identity.Ed25519PublicKey);
        command.Parameters.AddWithValue("$tlsCertificatePfx", (object?)ProtectOptionalBlob(identity.TlsCertificatePfx, ProtectedTlsCertificatePrefix) ?? DBNull.Value);
        command.Parameters.AddWithValue("$createdAt", identity.CreatedAt.ToString("O"));
        command.ExecuteNonQuery();
    }

    private static byte[] ProtectBlob(byte[] plaintext, byte[] prefix)
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new InvalidOperationException("Protected local identity storage is only implemented on Windows. Refusing to persist sensitive identity material without OS-backed secret storage.");
        }

        var protectedBytes = WindowsDpapi.Protect(plaintext);
        return [.. prefix, .. protectedBytes];
    }

    private static byte[]? ProtectOptionalBlob(byte[]? plaintext, byte[] prefix)
    {
        return plaintext is null ? null : ProtectBlob(plaintext, prefix);
    }

    private static byte[] UnprotectBlob(byte[] storedValue, byte[] prefix)
    {
        if (!IsProtectedBlob(storedValue, prefix))
        {
            if (!OperatingSystem.IsWindows())
            {
                throw new InvalidOperationException("Unprotected local identity material cannot be opened on a non-Windows runtime. Platform secret storage integration is required.");
            }

            return storedValue;
        }

        if (!OperatingSystem.IsWindows())
        {
            throw new InvalidOperationException("Protected local identity material cannot be opened on a non-Windows runtime.");
        }

        var protectedBytes = storedValue.AsSpan(prefix.Length).ToArray();
        return WindowsDpapi.Unprotect(protectedBytes);
    }

    private static bool IsProtectedBlob(byte[] storedValue, byte[] prefix)
    {
        return storedValue.Length > prefix.Length &&
               storedValue.AsSpan(0, prefix.Length).SequenceEqual(prefix);
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
