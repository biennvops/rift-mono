using System;
using Xunit;
using Rift.Daemon.Core.Cryptography;

namespace Rift.Daemon.Tests.Core;

public class Base32EncodingTests
{
    [Fact]
    public void Encode_MatchesProtocolSpecVector()
    {
        // SHA-256 from protocol spec §16.1
        var sha256Hex = "13cd677ac428d57b5cb434aa2486c9f30efe18b067fc7f6b248644a9580d21e7";
        var inputBytes = Convert.FromHexString(sha256Hex);

        var expectedBase32 = "cpgwo6wefdkxwxfugsvcjbwj6mhp4gfqm76h62zeqzckswanehtq";
        
        var actualBase32 = Base32Encoding.Encode(inputBytes);

        Assert.Equal(expectedBase32, actualBase32);
    }
    
    [Fact]
    public void Encode_EmptyBytes_ReturnsEmptyString()
    {
        var inputBytes = Array.Empty<byte>();
        var result = Base32Encoding.Encode(inputBytes);
        Assert.Equal(string.Empty, result);
    }
}
