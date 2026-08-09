using System.Security.Cryptography;
using Rift.Daemon.Core;

namespace Rift.Daemon.Tests.Core;

public sealed class NotificationIconNormalizerTests
{
    private static readonly byte[] PngBytes = Convert.FromBase64String(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==");

    private static readonly byte[] OversizedDimensionPngBytes = Convert.FromBase64String(
        "iVBORw0KGgoAAAANSUhEUgAAAgEAAAABCAYAAABHeX1IAAAAF0lEQVR4nGNgGAWjYBSMglEwCkbBiAQACAUAAVbgEW4AAAAASUVORK5CYII=");
    [Fact]
    public void ValidIconIsCanonicalized()
    {
        var normalized = NotificationIconNormalizer.Normalize(CreateIcon(PngBytes));

        Assert.NotNull(normalized);
        Assert.Equal(
            new[] { "mediaType", "dataBase64", "byteSize", "sha256" },
            normalized!.Keys);
        Assert.Equal("image/png", normalized["mediaType"]);
        Assert.Equal(Convert.ToBase64String(PngBytes), normalized["dataBase64"]);
        Assert.Equal(PngBytes.Length, normalized["byteSize"]);
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
    public void NonPngPayloadInvalidStructureAndOversizedDimensionsAreDropped()
    {
        var invalidStructure = PngBytes.ToArray();
        invalidStructure[45] ^= 1;
        var extraField = CreateIcon(PngBytes);
        extraField["unknown"] = "ignored";

        Assert.Null(NotificationIconNormalizer.Normalize(CreateIcon([1, 2, 3])));
        Assert.Null(NotificationIconNormalizer.Normalize(CreateIcon(invalidStructure)));
        Assert.Null(NotificationIconNormalizer.Normalize(extraField));
        Assert.Null(NotificationIconNormalizer.Normalize(CreateIcon(OversizedDimensionPngBytes)));
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
