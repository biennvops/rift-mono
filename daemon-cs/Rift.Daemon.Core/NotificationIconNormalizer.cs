using System.Buffers.Binary;
using System.Text.Json;

namespace Rift.Daemon.Core;

public static class NotificationIconNormalizer
{
    public const int MaxRawBytes = 131072;
    public const int MaxBase64Characters = ((MaxRawBytes + 2) / 3) * 4;
    public const int MaxDimension = 512;

    private static ReadOnlySpan<byte> PngSignature =>
        [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

    public static IReadOnlyDictionary<string, object?>? Normalize(
        IReadOnlyDictionary<string, object?>? icon)
    {
        if (icon is null ||
            !TryGetString(icon, "mediaType", out var mediaType) ||
            !string.Equals(mediaType, "image/png", StringComparison.Ordinal) ||
            !TryGetString(icon, "dataBase64", out var dataBase64) ||
            dataBase64.Length > MaxBase64Characters ||
            !TryGetInt32(icon, "byteSize", out var byteSize) ||
            byteSize < 0 ||
            byteSize > MaxRawBytes ||
            !TryGetString(icon, "sha256", out var sha256) ||
            !IsLowercaseSha256(sha256))
        {
            return null;
        }

        byte[] bytes;
        try
        {
            bytes = Convert.FromBase64String(dataBase64);
        }
        catch (FormatException)
        {
            return null;
        }

        if (bytes.Length > MaxRawBytes ||
            bytes.Length != byteSize ||
            !IsValidPng(bytes))
        {
            return null;
        }

        var actualSha256 = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(bytes))
            .ToLowerInvariant();
        if (!string.Equals(actualSha256, sha256, StringComparison.Ordinal))
        {
            return null;
        }

        return new Dictionary<string, object?>(StringComparer.Ordinal)
        {
            ["mediaType"] = "image/png",
            ["dataBase64"] = Convert.ToBase64String(bytes),
            ["byteSize"] = bytes.Length,
            ["sha256"] = actualSha256
        };
    }

    private static bool TryGetString(
        IReadOnlyDictionary<string, object?> values,
        string key,
        out string value)
    {
        if (values.TryGetValue(key, out var rawValue))
        {
            if (rawValue is string stringValue)
            {
                value = stringValue;
                return true;
            }

            if (rawValue is JsonElement { ValueKind: JsonValueKind.String } element)
            {
                value = element.GetString() ?? string.Empty;
                return true;
            }
        }

        value = string.Empty;
        return false;
    }

    private static bool TryGetInt32(
        IReadOnlyDictionary<string, object?> values,
        string key,
        out int value)
    {
        if (values.TryGetValue(key, out var rawValue))
        {
            switch (rawValue)
            {
                case int intValue:
                    value = intValue;
                    return true;
                case long longValue when longValue is >= int.MinValue and <= int.MaxValue:
                    value = (int)longValue;
                    return true;
                case JsonElement { ValueKind: JsonValueKind.Number } element when element.TryGetInt32(out var elementValue):
                    value = elementValue;
                    return true;
            }
        }

        value = 0;
        return false;
    }

    private static bool IsLowercaseSha256(string value)
    {
        if (value.Length != 64)
        {
            return false;
        }

        return value.All(character =>
            character is >= '0' and <= '9' or >= 'a' and <= 'f');
    }

    private static bool IsValidPng(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length < PngSignature.Length ||
            !bytes[..PngSignature.Length].SequenceEqual(PngSignature))
        {
            return false;
        }

        var offset = PngSignature.Length;
        var chunkIndex = 0;
        var sawHeader = false;
        var sawPalette = false;
        var sawImageData = false;
        var finishedImageData = false;
        var imageDataBytes = 0L;
        byte colorType = 0;

        while (offset <= bytes.Length - 12)
        {
            var length = BinaryPrimitives.ReadUInt32BigEndian(bytes[offset..]);
            if (length > int.MaxValue || length > bytes.Length - offset - 12)
            {
                return false;
            }

            var dataLength = (int)length;
            var type = bytes.Slice(offset + 4, 4);
            var data = bytes.Slice(offset + 8, dataLength);
            var expectedCrc = BinaryPrimitives.ReadUInt32BigEndian(
                bytes.Slice(offset + 8 + dataLength, 4));
            if (!IsChunkType(type) || ComputeCrc32(type, data) != expectedCrc)
            {
                return false;
            }

            var isHeader = type.SequenceEqual("IHDR"u8);
            var isPalette = type.SequenceEqual("PLTE"u8);
            var isImageData = type.SequenceEqual("IDAT"u8);
            var isEnd = type.SequenceEqual("IEND"u8);
            if (chunkIndex == 0 && !isHeader || chunkIndex > 0 && isHeader)
            {
                return false;
            }

            if (isHeader)
            {
                if (dataLength != 13 || !IsValidHeader(data, out colorType))
                {
                    return false;
                }
                sawHeader = true;
            }
            else if (isPalette)
            {
                if (!sawHeader || sawPalette || sawImageData ||
                    colorType is 0 or 4 ||
                    dataLength == 0 || dataLength % 3 != 0 || dataLength > 768)
                {
                    return false;
                }
                sawPalette = true;
            }
            else if (isImageData)
            {
                if (!sawHeader || finishedImageData || colorType == 3 && !sawPalette)
                {
                    return false;
                }
                sawImageData = true;
                imageDataBytes += dataLength;
            }
            else
            {
                if (sawImageData)
                {
                    finishedImageData = true;
                }

                if (isEnd)
                {
                    return dataLength == 0 &&
                        sawImageData &&
                        imageDataBytes > 0 &&
                        offset + 12 == bytes.Length;
                }

                // Unknown critical chunks cannot be safely interpreted.
                if ((type[0] & 0x20) == 0)
                {
                    return false;
                }
            }

            offset += dataLength + 12;
            chunkIndex++;
        }

        return false;
    }

    private static bool IsValidHeader(ReadOnlySpan<byte> header, out byte colorType)
    {
        var width = BinaryPrimitives.ReadUInt32BigEndian(header);
        var height = BinaryPrimitives.ReadUInt32BigEndian(header[4..]);
        var bitDepth = header[8];
        colorType = header[9];
        var validBitDepth = colorType switch
        {
            0 => bitDepth is 1 or 2 or 4 or 8 or 16,
            2 => bitDepth is 8 or 16,
            3 => bitDepth is 1 or 2 or 4 or 8,
            4 => bitDepth is 8 or 16,
            6 => bitDepth is 8 or 16,
            _ => false
        };
        return width is > 0 and <= MaxDimension &&
            height is > 0 and <= MaxDimension &&
            validBitDepth &&
            header[10] == 0 &&
            header[11] == 0 &&
            header[12] is 0 or 1;
    }

    private static bool IsChunkType(ReadOnlySpan<byte> type)
    {
        foreach (var value in type)
        {
            if (value is not (>= (byte)'A' and <= (byte)'Z') and
                not (>= (byte)'a' and <= (byte)'z'))
            {
                return false;
            }
        }
        return (type[2] & 0x20) == 0;
    }

    private static uint ComputeCrc32(ReadOnlySpan<byte> type, ReadOnlySpan<byte> data)
    {
        var crc = uint.MaxValue;
        foreach (var value in type)
        {
            crc = UpdateCrc32(crc, value);
        }
        foreach (var value in data)
        {
            crc = UpdateCrc32(crc, value);
        }
        return ~crc;
    }

    private static uint UpdateCrc32(uint crc, byte value)
    {
        crc ^= value;
        for (var bit = 0; bit < 8; bit++)
        {
            crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xedb88320u : crc >> 1;
        }
        return crc;
    }
}
