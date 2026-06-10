using System;
using System.Text;

namespace Rift.Daemon.Core.Cryptography;

/// <summary>
/// Implements RFC 4648 Base32 encoding without padding characters.
/// </summary>
public static class Base32Encoding
{
    private const string Alphabet = "abcdefghijklmnopqrstuvwxyz234567";

    public static string Encode(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length == 0) return string.Empty;

        var sb = new StringBuilder((bytes.Length * 8 + 4) / 5);
        int bitIndex = 0;
        
        while (bitIndex < bytes.Length * 8)
        {
            int index = bitIndex / 8;
            int offset = bitIndex % 8;
            int bitCount = Math.Min(8 - offset, 5);
            
            int bits = (bytes[index] >> (8 - offset - bitCount)) & ((1 << bitCount) - 1);
            
            int remainingBits = 5 - bitCount;
            if (remainingBits > 0 && index + 1 < bytes.Length)
            {
                int nextBits = (bytes[index + 1] >> (8 - remainingBits)) & ((1 << remainingBits) - 1);
                bits = (bits << remainingBits) | nextBits;
            }
            else if (remainingBits > 0)
            {
                bits <<= remainingBits;
            }
            
            sb.Append(Alphabet[bits]);
            bitIndex += 5;
        }

        return sb.ToString();
    }
}
