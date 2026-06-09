using System;
using System.Buffers.Binary;
using System.Text;

namespace Rift.Daemon.Core.Protocol;

/// <summary>
/// Provides framing utilities for the Rift Protocol.
/// </summary>
public static class RiftFrame
{
    public const int LengthPrefixBytes = 4;
    public const int MaxPreAuthSize = 64 * 1024; // 64 KiB
    public const int MaxPostAuthSize = 32 * 1024 * 1024; // 32 MiB

    /// <summary>
    /// Encodes a UTF-8 JSON payload by prepending a 4-byte big-endian length prefix.
    /// </summary>
    /// <param name="utf8JsonPayload">The raw JSON payload to encode.</param>
    /// <returns>A new byte array containing the full framed message.</returns>
    public static byte[] Encode(ReadOnlySpan<byte> utf8JsonPayload)
    {
        int totalLength = LengthPrefixBytes + utf8JsonPayload.Length;
        byte[] frame = new byte[totalLength];
        
        BinaryPrimitives.WriteUInt32BigEndian(frame.AsSpan(0, LengthPrefixBytes), (uint)utf8JsonPayload.Length);
        utf8JsonPayload.CopyTo(frame.AsSpan(LengthPrefixBytes));
        
        return frame;
    }

    /// <summary>
    /// Attempts to read the framing prefix and extract the payload, validating against the applicable size limit.
    /// </summary>
    /// <param name="buffer">The full frame including the length prefix.</param>
    /// <param name="maxSize">The maximum allowed size based on auth state (MaxPreAuthSize or MaxPostAuthSize).</param>
    /// <returns>The un-prefixed JSON payload bytes.</returns>
    /// <exception cref="InvalidOperationException">If the payload exceeds the max size or the buffer is too small.</exception>
    public static ReadOnlyMemory<byte> Decode(ReadOnlyMemory<byte> buffer, int maxSize = MaxPostAuthSize)
    {
        if (buffer.Length < LengthPrefixBytes)
        {
            throw new InvalidOperationException("Buffer is too small to contain a length prefix.");
        }

        uint payloadLength = BinaryPrimitives.ReadUInt32BigEndian(buffer.Span.Slice(0, LengthPrefixBytes));
        if (payloadLength > (uint)maxSize)
        {
            throw new InvalidOperationException($"PayloadTooLarge: Length {payloadLength} outside allowed limit [0, {maxSize}].");
        }

        if (buffer.Length < LengthPrefixBytes + payloadLength)
        {
            throw new InvalidOperationException("Buffer is incomplete, missing payload data.");
        }

        return buffer.Slice(LengthPrefixBytes, (int)payloadLength);
    }
}
