using System;

namespace Rift.Daemon.Core.Networking;

public sealed class UnexpectedPeerIdentityException : InvalidOperationException
{
    public UnexpectedPeerIdentityException(
        string address,
        int port,
        string expectedDeviceId,
        string actualDeviceId)
        : base(
            $"Endpoint {address}:{port} authenticated unexpected peer " +
            $"{actualDeviceId} instead of {expectedDeviceId}.")
    {
        Address = address;
        Port = port;
        ExpectedDeviceId = expectedDeviceId;
        ActualDeviceId = actualDeviceId;
    }

    public string Address { get; }
    public int Port { get; }
    public string ExpectedDeviceId { get; }
    public string ActualDeviceId { get; }
}
