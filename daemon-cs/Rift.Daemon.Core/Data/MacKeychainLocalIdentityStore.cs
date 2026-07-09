using System.Runtime.InteropServices;
using System.Runtime.Versioning;
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

        if (privateKey is null || tlsCertificate is null)
        {
            throw new InvalidOperationException("macOS Keychain local identity was incomplete.");
        }

        if (privateKey.Length != 32)
        {
            throw new InvalidOperationException("macOS Keychain Ed25519 private key was malformed.");
        }

        var derivedPublicKey = new Ed25519PrivateKeyParameters(privateKey, 0).GeneratePublicKey().GetEncoded();
        var certificate = IdentityManager.LoadPersistedTlsCertificate(
            tlsCertificate,
            new Ed25519PublicKeyParameters(derivedPublicKey, 0));

        var embeddedPublicKey = IdentityManager.ExtractEmbeddedEd25519PublicKey(certificate);
        if (!embeddedPublicKey.AsSpan().SequenceEqual(derivedPublicKey))
        {
            throw new InvalidOperationException("macOS Keychain TLS certificate did not match the Ed25519 private key.");
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
    private const int ErrSecSuccess = 0;
    private const int ErrSecDuplicateItem = -25299;
    private const int ErrSecItemNotFound = -25300;

    public byte[]? GetSecret(string service, string account)
    {
        using var query = new CfMutableDictionary();
        query.AddString("class", "genp");
        query.AddString("svce", service);
        query.AddString("acct", account);
        query.AddBoolean("r_Data", true);
        query.AddString("m_Limit", "m_LimitOne");

        var status = SecItemCopyMatching(query.Handle, out var result);
        if (status == ErrSecItemNotFound)
        {
            return null;
        }

        ThrowIfError(status, $"read Keychain item '{service}/{account}'");
        try
        {
            return CfData.CopyBytes(result);
        }
        finally
        {
            if (result != IntPtr.Zero)
            {
                CfObject.Release(result);
            }
        }
    }

    public void SetSecret(string service, string account, byte[] secret)
    {
        ArgumentNullException.ThrowIfNull(secret);

        using var secretData = new CfData(secret);
        using var query = new CfMutableDictionary();
        query.AddString("class", "genp");
        query.AddString("svce", service);
        query.AddString("acct", account);

        using var attributes = new CfMutableDictionary();
        attributes.AddData("v_Data", secretData);
        attributes.AddString("labl", $"Rift Daemon {account}");

        var updateStatus = SecItemUpdate(query.Handle, attributes.Handle);
        if (updateStatus == ErrSecItemNotFound)
        {
            using var add = new CfMutableDictionary();
            add.AddString("class", "genp");
            add.AddString("svce", service);
            add.AddString("acct", account);
            add.AddString("labl", $"Rift Daemon {account}");
            add.AddData("v_Data", secretData);

            var addStatus = SecItemAdd(add.Handle, IntPtr.Zero);
            if (addStatus == ErrSecDuplicateItem)
            {
                ThrowIfError(SecItemUpdate(query.Handle, attributes.Handle), $"update Keychain item '{service}/{account}'");
                return;
            }

            ThrowIfError(addStatus, $"add Keychain item '{service}/{account}'");
            return;
        }

        ThrowIfError(updateStatus, $"update Keychain item '{service}/{account}'");
    }

    public void DeleteSecret(string service, string account)
    {
        using var query = new CfMutableDictionary();
        query.AddString("class", "genp");
        query.AddString("svce", service);
        query.AddString("acct", account);

        var status = SecItemDelete(query.Handle);
        if (status == ErrSecSuccess || status == ErrSecItemNotFound)
        {
            return;
        }

        ThrowIfError(status, $"delete Keychain item '{service}/{account}'");
    }

    private static void ThrowIfError(int status, string action)
    {
        if (status == ErrSecSuccess)
        {
            return;
        }

        var messageHandle = SecCopyErrorMessageString(status, IntPtr.Zero);
        try
        {
            var message = messageHandle == IntPtr.Zero
                ? $"OSStatus {status}"
                : CfString.CopyString(messageHandle);
            throw new InvalidOperationException($"Failed to {action}: {message}.");
        }
        finally
        {
            if (messageHandle != IntPtr.Zero)
            {
                CfObject.Release(messageHandle);
            }
        }
    }

    [DllImport("/System/Library/Frameworks/Security.framework/Security")]
    private static extern int SecItemAdd(IntPtr attributes, IntPtr result);

    [DllImport("/System/Library/Frameworks/Security.framework/Security")]
    private static extern int SecItemCopyMatching(IntPtr query, out IntPtr result);

    [DllImport("/System/Library/Frameworks/Security.framework/Security")]
    private static extern int SecItemUpdate(IntPtr query, IntPtr attributesToUpdate);

    [DllImport("/System/Library/Frameworks/Security.framework/Security")]
    private static extern int SecItemDelete(IntPtr query);

    [DllImport("/System/Library/Frameworks/Security.framework/Security")]
    private static extern IntPtr SecCopyErrorMessageString(int status, IntPtr reserved);

    private static class CfObject
    {
        [DllImport("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")]
        public static extern void CFRelease(IntPtr cf);

        public static void Release(IntPtr handle)
        {
            CFRelease(handle);
        }
    }

    private sealed class CfString : IDisposable
    {
        private const uint Utf8Encoding = 0x08000100;

        public CfString(string value)
        {
            Handle = CFStringCreateWithCString(IntPtr.Zero, value, Utf8Encoding);
            if (Handle == IntPtr.Zero)
            {
                throw new InvalidOperationException("Failed to allocate CoreFoundation string.");
            }
        }

        public IntPtr Handle { get; }

        public void Dispose()
        {
            CfObject.Release(Handle);
        }

        public static string CopyString(IntPtr handle)
        {
            var length = CFStringGetLength(handle);
            var maxSize = CFStringGetMaximumSizeForEncoding(length, Utf8Encoding) + 1;
            var buffer = Marshal.AllocHGlobal((nint)maxSize);
            try
            {
                if (!CFStringGetCString(handle, buffer, maxSize, Utf8Encoding))
                {
                    throw new InvalidOperationException("Failed to copy CoreFoundation string.");
                }

                return Marshal.PtrToStringUTF8(buffer) ?? string.Empty;
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
        }

        [DllImport("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")]
        private static extern IntPtr CFStringCreateWithCString(IntPtr allocator, string str, uint encoding);

        [DllImport("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")]
        private static extern long CFStringGetLength(IntPtr handle);

        [DllImport("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")]
        private static extern long CFStringGetMaximumSizeForEncoding(long length, uint encoding);

        [DllImport("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")]
        [return: MarshalAs(UnmanagedType.I1)]
        private static extern bool CFStringGetCString(IntPtr handle, IntPtr buffer, long bufferSize, uint encoding);
    }

    private sealed class CfData : IDisposable
    {
        public CfData(byte[] bytes)
        {
            Handle = CFDataCreate(IntPtr.Zero, bytes, bytes.Length);
            if (Handle == IntPtr.Zero)
            {
                throw new InvalidOperationException("Failed to allocate CoreFoundation data.");
            }
        }

        public IntPtr Handle { get; }

        public void Dispose()
        {
            CfObject.Release(Handle);
        }

        public static byte[] CopyBytes(IntPtr handle)
        {
            var length = CFDataGetLength(handle);
            var pointer = CFDataGetBytePtr(handle);
            if (length == 0)
            {
                return [];
            }

            var bytes = new byte[length];
            Marshal.Copy(pointer, bytes, 0, length);
            return bytes;
        }

        [DllImport("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")]
        private static extern IntPtr CFDataCreate(IntPtr allocator, byte[] bytes, int length);

        [DllImport("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")]
        private static extern int CFDataGetLength(IntPtr handle);

        [DllImport("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")]
        private static extern IntPtr CFDataGetBytePtr(IntPtr handle);
    }

    private sealed class CfBoolean : IDisposable
    {
        public static readonly CfBoolean True = new(CFBooleanGetValuePtr(true), ownsHandle: false);
        public static readonly CfBoolean False = new(CFBooleanGetValuePtr(false), ownsHandle: false);

        private readonly bool _ownsHandle;

        private CfBoolean(IntPtr handle, bool ownsHandle)
        {
            Handle = handle;
            _ownsHandle = ownsHandle;
        }

        public IntPtr Handle { get; }

        public void Dispose()
        {
            if (_ownsHandle && Handle != IntPtr.Zero)
            {
                CfObject.Release(Handle);
            }
        }

        private static IntPtr CFBooleanGetValuePtr(bool value)
        {
            return value ? kCFBooleanTrue : kCFBooleanFalse;
        }

        private static readonly IntPtr kCFBooleanTrue = GetBooleanHandle("kCFBooleanTrue");
        private static readonly IntPtr kCFBooleanFalse = GetBooleanHandle("kCFBooleanFalse");

        private static IntPtr GetBooleanHandle(string symbol)
        {
            var symbolPointer = NativeLibrary.GetExport(CoreFoundationHandle, symbol);
            return Marshal.ReadIntPtr(symbolPointer);
        }

        private static readonly IntPtr CoreFoundationHandle = NativeLibrary.Load("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation");
    }

    private sealed class CfMutableDictionary : IDisposable
    {
        private readonly List<IDisposable> _ownedValues = [];

        public CfMutableDictionary()
        {
            Handle = CFDictionaryCreateMutable(IntPtr.Zero, 0, IntPtr.Zero, IntPtr.Zero);
            if (Handle == IntPtr.Zero)
            {
                throw new InvalidOperationException("Failed to allocate CoreFoundation dictionary.");
            }
        }

        public IntPtr Handle { get; }

        public void AddString(string key, string value)
        {
            var keyString = new CfString(key);
            var valueString = new CfString(value);
            _ownedValues.Add(keyString);
            _ownedValues.Add(valueString);
            CFDictionaryAddValue(Handle, keyString.Handle, valueString.Handle);
        }

        public void AddBoolean(string key, bool value)
        {
            var keyString = new CfString(key);
            _ownedValues.Add(keyString);
            CFDictionaryAddValue(Handle, keyString.Handle, value ? CfBoolean.True.Handle : CfBoolean.False.Handle);
        }

        public void AddData(string key, CfData data)
        {
            var keyString = new CfString(key);
            _ownedValues.Add(keyString);
            CFDictionaryAddValue(Handle, keyString.Handle, data.Handle);
        }

        public void Dispose()
        {
            foreach (var ownedValue in _ownedValues)
            {
                ownedValue.Dispose();
            }

            CfObject.Release(Handle);
        }

        [DllImport("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")]
        private static extern IntPtr CFDictionaryCreateMutable(
            IntPtr allocator,
            long capacity,
            IntPtr keyCallBacks,
            IntPtr valueCallBacks);

        [DllImport("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")]
        private static extern void CFDictionaryAddValue(IntPtr dictionary, IntPtr key, IntPtr value);
    }
}
