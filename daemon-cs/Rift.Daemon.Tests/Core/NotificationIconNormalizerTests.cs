using System.Security.Cryptography;
using Rift.Daemon.Core;

namespace Rift.Daemon.Tests.Core;

public sealed class NotificationIconNormalizerTests
{
    [Fact]
    public void ValidIconIsCanonicalized()
    {
        var normalized = NotificationIconNormalizer.Normalize(CreateIcon([1, 2, 3]));

        Assert.NotNull(normalized);
        Assert.Equal(
            new[] { "mediaType", "dataBase64", "byteSize", "sha256" },
            normalized!.Keys);
        Assert.Equal("image/png", normalized["mediaType"]);
        Assert.Equal("AQID", normalized["dataBase64"]);
        Assert.Equal(3, normalized["byteSize"]);
    }

    [Theory]
    [InlineData("image/svg+xml")]
    [InlineData("image/jpeg")]
    public void UnsupportedMediaTypeIsDropped(string mediaType)
    {
        var icon = CreateIcon([1, 2, 3]);
        icon["mediaType"] = mediaType;

        Assert.Null(NotificationIconNormalizer.Normalize(icon));
    }

    [Fact]
    public void InvalidBase64IsDropped()
    {
        var icon = CreateIcon([1, 2, 3]);
        icon["dataBase64"] = "not base64";

        Assert.Null(NotificationIconNormalizer.Normalize(icon));
    }

    [Fact]
    public void IncorrectSizeAndHashAreDropped()
    {
        var wrongSize = CreateIcon([1, 2, 3]);
        wrongSize["byteSize"] = 2;
        var wrongHash = CreateIcon([1, 2, 3]);
        wrongHash["sha256"] = new string('0', 64);

        Assert.Null(NotificationIconNormalizer.Normalize(wrongSize));
        Assert.Null(NotificationIconNormalizer.Normalize(wrongHash));
    }

    [Fact]
    public void OversizedBase64IsDroppedBeforeDecode()
    {
        var icon = new Dictionary<string, object?>
        {
            ["mediaType"] = "image/png",
            ["dataBase64"] = new string('A', NotificationIconNormalizer.MaxBase64Characters + 1),
            ["byteSize"] = NotificationIconNormalizer.MaxRawBytes,
            ["sha256"] = new string('0', 64)
        };

        Assert.Null(NotificationIconNormalizer.Normalize(icon));
    }

    private static Dictionary<string, object?> CreateIcon(IReadOnlyList<byte> bytes)
    {
        var raw = bytes.ToArray();
        return new Dictionary<string, object?>
        {
            ["mediaType"] = "image/png",
            ["dataBase64"] = Convert.ToBase64String(raw),
            ["byteSize"] = raw.Length,
            ["sha256"] = Convert.ToHexString(SHA256.HashData(raw)).ToLowerInvariant()
        };
    }
}
