using System.Text.Json;

namespace Rift.Daemon.Core;

public static class NotificationIconNormalizer
{
    public const int MaxRawBytes = 131072;
    public const int MaxBase64Characters = ((MaxRawBytes + 2) / 3) * 4;

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

        if (bytes.Length > MaxRawBytes || bytes.Length != byteSize)
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
}
