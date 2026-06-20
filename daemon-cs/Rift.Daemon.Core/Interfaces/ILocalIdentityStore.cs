using System;

namespace Rift.Daemon.Core.Interfaces;

public sealed class LocalIdentityRecord
{
    public byte[] Ed25519PrivateKey { get; init; } = [];
    public byte[] Ed25519PublicKey { get; init; } = [];
    public byte[]? TlsCertificatePfx { get; init; }
    public DateTimeOffset CreatedAt { get; init; } = DateTimeOffset.UtcNow;
}

public interface ILocalIdentityStore
{
    LocalIdentityRecord? GetIdentity();

    void SaveIdentity(LocalIdentityRecord identity);
}
