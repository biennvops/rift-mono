using System;
using System.Text;
using Xunit;
using Rift.Daemon.Core.Protocol;

namespace Rift.Daemon.Tests.Core;

public class RiftFrameTests
{
    [Fact]
    public void Encode_PrependsCorrectLengthAndPayload()
    {
        var payload = Encoding.UTF8.GetBytes("hello");
        var frame = RiftFrame.Encode(payload);

        Assert.Equal(9, frame.Length);
        
        // Length 5 in big endian: 00 00 00 05
        Assert.Equal(0, frame[0]);
        Assert.Equal(0, frame[1]);
        Assert.Equal(0, frame[2]);
        Assert.Equal(5, frame[3]);
        
        var decodedPayload = frame.AsSpan(4).ToArray();
        Assert.Equal(payload, decodedPayload);
    }
    
    [Fact]
    public void Decode_ExtractsProperPayload()
    {
        var frame = new byte[] { 0, 0, 0, 5, (byte)'h', (byte)'e', (byte)'l', (byte)'l', (byte)'o' };
        var payload = RiftFrame.Decode(frame);
        
        Assert.Equal(5, payload.Length);
        Assert.Equal("hello", Encoding.UTF8.GetString(payload.Span));
    }

    [Fact]
    public void Decode_RejectsOversizedPayloads()
    {
        // Indicate length 64 KiB + 1
        var frame = new byte[] { 0x00, 0x01, 0x00, 0x01, 0, 0, 0, 0 }; 
        
        var ex = Assert.Throws<InvalidOperationException>(() => 
            RiftFrame.Decode(frame, maxSize: RiftFrame.MaxPreAuthSize)
        );
        Assert.Contains("PayloadTooLarge", ex.Message);
    }

    [Fact]
    public void Decode_RejectsOversizedPayloads_LargeBuffer()
    {
        // Indicate length 64 KiB + 1, and ensure the buffer actually contains that many bytes
        var frame = new byte[RiftFrame.MaxPreAuthSize + 1 + RiftFrame.LengthPrefixBytes];
        frame[0] = 0x00;
        frame[1] = 0x01;
        frame[2] = 0x00;
        frame[3] = 0x01; // 65537

        var ex = Assert.Throws<InvalidOperationException>(() => 
            RiftFrame.Decode(frame, maxSize: RiftFrame.MaxPreAuthSize)
        );
        Assert.Contains("PayloadTooLarge", ex.Message);
    }

    [Fact]
    public void Decode_RejectsIncompleteBuffer()
    {
        var frame = new byte[] { 0, 0, 0, 5, (byte)'h' }; // Says length 5, but contains 1 byte
        Assert.Throws<InvalidOperationException>(() => RiftFrame.Decode(frame));
    }

    [Fact]
    public void EmptyPayload_EncodeDecode_RoundTrip()
    {
        var payload = Array.Empty<byte>();
        var frame = RiftFrame.Encode(payload);

        // Frame should just be 4 bytes of zeroes
        Assert.Equal(4, frame.Length);
        Assert.Equal(0, frame[0]);
        Assert.Equal(0, frame[1]);
        Assert.Equal(0, frame[2]);
        Assert.Equal(0, frame[3]);

        var decoded = RiftFrame.Decode(frame);
        Assert.Equal(0, decoded.Length);
    }
}
