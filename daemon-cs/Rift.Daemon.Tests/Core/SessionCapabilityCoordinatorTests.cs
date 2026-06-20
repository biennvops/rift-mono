using System.Text;
using System.Text.Json;
using Rift.Daemon.Core.Networking;
using Rift.Daemon.Core.Protocol;

namespace Rift.Daemon.Tests.Core;

public sealed class SessionCapabilityCoordinatorTests
{
    [Fact]
    public void ComputeSelectedCapabilities_UsesIntersectionWithMinimumVersion()
    {
        var local = new[]
        {
            new CapabilityDescriptor("clipboard.offer_fetch", 2),
            new CapabilityDescriptor("presence.basic", 1),
            new CapabilityDescriptor("security.event_log", 1)
        };
        var remote = new[]
        {
            new CapabilityDescriptor("clipboard.offer_fetch", 1),
            new CapabilityDescriptor("presence.basic", 3),
            new CapabilityDescriptor("operation.lifecycle", 1)
        };

        var selected = SessionCapabilityCoordinator.ComputeSelectedCapabilities(local, remote);

        Assert.Collection(
            selected,
            capability =>
            {
                Assert.Equal("clipboard.offer_fetch", capability.Name);
                Assert.Equal(1, capability.Version);
            },
            capability =>
            {
                Assert.Equal("presence.basic", capability.Name);
                Assert.Equal(1, capability.Version);
            });
    }

    [Fact]
    public void ValidateSelectedCapabilities_AcceptsExactComputedIntersection()
    {
        var local = new[]
        {
            new CapabilityDescriptor("clipboard.offer_fetch", 1),
            new CapabilityDescriptor("presence.basic", 1)
        };
        var remote = new[]
        {
            new CapabilityDescriptor("clipboard.offer_fetch", 2),
            new CapabilityDescriptor("presence.basic", 1)
        };
        var selected = new[]
        {
            new CapabilityDescriptor("clipboard.offer_fetch", 1),
            new CapabilityDescriptor("presence.basic", 1)
        };

        Assert.True(SessionCapabilityCoordinator.ValidateSelectedCapabilities(local, remote, selected));
    }

    [Fact]
    public void ValidateSelectedCapabilities_RejectsUnexpectedCapability()
    {
        var local = new[]
        {
            new CapabilityDescriptor("clipboard.offer_fetch", 1)
        };
        var remote = new[]
        {
            new CapabilityDescriptor("clipboard.offer_fetch", 1)
        };
        var selected = new[]
        {
            new CapabilityDescriptor("clipboard.offer_fetch", 1),
            new CapabilityDescriptor("presence.basic", 1)
        };

        Assert.False(SessionCapabilityCoordinator.ValidateSelectedCapabilities(local, remote, selected));
    }

    [Fact]
    public async Task NegotiateAsync_CompletesEndToEndHandshake()
    {
        var initiatorCoordinator = new SessionCapabilityCoordinator();
        var responderCoordinator = new SessionCapabilityCoordinator();
        var initiatorStream = new LoopbackDuplexStream();
        var responderStream = initiatorStream.CreatePeer();

        var initiatorTask = initiatorCoordinator.NegotiateAsync(
            initiatorStream,
            "rift-local",
            "rift-remote",
            isInitiator: true,
            ReadFramePayloadAsync,
            CancellationToken.None);
        var responderTask = responderCoordinator.NegotiateAsync(
            responderStream,
            "rift-remote",
            "rift-local",
            isInitiator: false,
            ReadFramePayloadAsync,
            CancellationToken.None);

        var initiatorSelected = await initiatorTask;
        var responderSelected = await responderTask;

        Assert.Equal(initiatorSelected, responderSelected);
        Assert.Contains(initiatorSelected, capability => capability.Name == "clipboard.offer_fetch" && capability.Version == 1);
        Assert.Contains(initiatorSelected, capability => capability.Name == "presence.basic" && capability.Version == 1);
    }

    [Fact]
    public async Task NegotiateAsync_RejectsAdvertiseMessageWithSpoofedSourceDeviceId()
    {
        var coordinator = new SessionCapabilityCoordinator();
        await using var stream = new MemoryStream();
        var spoofedAdvertise = CreateFramedMessage(
            "capability.advertise",
            "rift-spoofed",
            new
            {
                capabilities = new[]
                {
                    new { name = "clipboard.offer_fetch", version = 1 }
                }
            });

        var ex = await Assert.ThrowsAsync<InvalidOperationException>(() =>
            coordinator.NegotiateAsync(
                stream,
                "rift-local",
                "rift-remote",
                isInitiator: true,
                (_, _, _) => Task.FromResult<byte[]?>(spoofedAdvertise),
                CancellationToken.None));

        Assert.Contains("sourceDeviceId", ex.Message, StringComparison.Ordinal);
    }

    private static async Task<byte[]?> ReadFramePayloadAsync(Stream stream, int maxFrameSize, CancellationToken cancellationToken)
    {
        var headerBuffer = new byte[RiftFrame.LengthPrefixBytes];
        var headerRead = await ReadExactAsync(stream, headerBuffer, cancellationToken);
        if (headerRead == 0)
        {
            return null;
        }

        var payloadLength = System.Buffers.Binary.BinaryPrimitives.ReadUInt32BigEndian(headerBuffer);
        if (payloadLength > maxFrameSize)
        {
            throw new InvalidOperationException("PayloadTooLarge");
        }

        var payloadBuffer = new byte[payloadLength];
        var payloadRead = await ReadExactAsync(stream, payloadBuffer, cancellationToken);
        return payloadRead == 0 ? null : payloadBuffer;
    }

    private static async Task<int> ReadExactAsync(Stream stream, byte[] buffer, CancellationToken cancellationToken)
    {
        var totalRead = 0;
        while (totalRead < buffer.Length)
        {
            var read = await stream.ReadAsync(buffer.AsMemory(totalRead, buffer.Length - totalRead), cancellationToken);
            if (read == 0)
            {
                return 0;
            }

            totalRead += read;
        }

        return totalRead;
    }

    private static byte[] CreateFramedMessage(string type, string sourceDeviceId, object payload)
    {
        var envelope = new
        {
            rift = "0.1-draft",
            type,
            messageId = Guid.NewGuid().ToString("D"),
            sourceDeviceId,
            payload
        };

        return RiftFrame.Encode(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(envelope))).AsSpan(RiftFrame.LengthPrefixBytes).ToArray();
    }

    private sealed class LoopbackDuplexStream : Stream
    {
        private readonly object _syncRoot = new();
        private readonly Queue<byte> _incoming = [];
        private readonly SemaphoreSlim _signal = new(0);
        private LoopbackDuplexStream? _peer;
        private bool _disposed;

        public LoopbackDuplexStream CreatePeer()
        {
            var peer = new LoopbackDuplexStream();
            _peer = peer;
            peer._peer = this;
            return peer;
        }

        public override bool CanRead => !_disposed;
        public override bool CanSeek => false;
        public override bool CanWrite => !_disposed;
        public override long Length => throw new NotSupportedException();

        public override long Position
        {
            get => throw new NotSupportedException();
            set => throw new NotSupportedException();
        }

        public override void Flush() { }

        public override Task FlushAsync(CancellationToken cancellationToken) => Task.CompletedTask;

        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();

        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
        {
            while (true)
            {
                lock (_syncRoot)
                {
                    if (_incoming.Count > 0)
                    {
                        var read = 0;
                        while (read < buffer.Length && _incoming.Count > 0)
                        {
                            buffer.Span[read++] = _incoming.Dequeue();
                        }

                        return read;
                    }

                    if (_disposed)
                    {
                        return 0;
                    }
                }

                await _signal.WaitAsync(cancellationToken);
            }
        }

        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();

        public override Task WriteAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken) =>
            WriteAsync(buffer.AsMemory(offset, count), cancellationToken).AsTask();

        public override ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken cancellationToken = default)
        {
            var peer = _peer ?? throw new InvalidOperationException("Peer stream not connected.");

            lock (peer._syncRoot)
            {
                foreach (var b in buffer.Span)
                {
                    peer._incoming.Enqueue(b);
                }
            }

            peer._signal.Release();
            return ValueTask.CompletedTask;
        }

        protected override void Dispose(bool disposing)
        {
            if (!disposing || _disposed)
            {
                return;
            }

            _disposed = true;
            _signal.Release();
            base.Dispose(disposing);
        }

        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();

        public override void SetLength(long value) => throw new NotSupportedException();
    }
}
