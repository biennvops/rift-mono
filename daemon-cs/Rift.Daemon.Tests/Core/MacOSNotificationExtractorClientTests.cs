using System.Runtime.Versioning;
using System.Text.Json;
using Rift.Daemon.macOS;

namespace Rift.Daemon.Tests.Core;

[SupportedOSPlatform("macos")]
public sealed class MacOSNotificationExtractorClientTests : IDisposable
{
    private readonly string _appPath = Directory.CreateTempSubdirectory("rift-extractor-app-").FullName;

    [Fact]
    public async Task GetStatusAsync_UsesPrivateFilesAndParsesResponse()
    {
        var client = new MacOSNotificationExtractorClient(
            _appPath,
            async (_, requestPath, responsePath, errorPath, cancellationToken) =>
            {
                AssertPrivateFile(requestPath);
                AssertPrivateFile(responsePath);
                AssertPrivateFile(errorPath);
                using var request = JsonDocument.Parse(await File.ReadAllTextAsync(requestPath, cancellationToken));
                Assert.Equal("getStatus", request.RootElement.GetProperty("operation").GetString());
                await File.WriteAllTextAsync(
                    responsePath,
                    "{\"ok\":true,\"result\":{\"databaseFound\":true,\"databaseReadable\":true,\"schemaSupported\":true,\"state\":\"ready\"}}\n",
                    cancellationToken);
            });

        var status = await client.GetStatusAsync(CancellationToken.None);

        Assert.True(status.DatabaseFound);
        Assert.True(status.DatabaseReadable);
        Assert.True(status.SchemaSupported);
        Assert.Equal("ready", status.State);
    }

    [Fact]
    public async Task ScanNotificationChangesAsync_RejectsMalformedResponse()
    {
        var client = CreateClient((_, responsePath, cancellationToken) =>
            File.WriteAllTextAsync(responsePath, "not-json\n", cancellationToken));

        var exception = await Assert.ThrowsAsync<MacOSExtractorException>(
            () => client.ScanNotificationChangesAsync(12, CancellationToken.None));

        Assert.Equal("invalidResponse", exception.Code);
    }

    [Fact]
    public async Task ScanNotificationChangesAsync_RejectsOversizedResponse()
    {
        var client = CreateClient((_, responsePath, cancellationToken) =>
            File.WriteAllTextAsync(responsePath, new string('x', 1024 * 1024 + 1) + "\n", cancellationToken));

        var exception = await Assert.ThrowsAsync<MacOSExtractorException>(
            () => client.ScanNotificationChangesAsync(12, CancellationToken.None));

        Assert.Equal("responseTooLarge", exception.Code);
    }

    [Fact]
    public async Task GetStatusAsync_ReportsExtractorError()
    {
        var client = CreateClient((_, responsePath, cancellationToken) =>
            File.WriteAllTextAsync(
                responsePath,
                "{\"ok\":false,\"error\":{\"code\":\"fullDiskAccessRequired\",\"message\":\"FDA required\"}}\n",
                cancellationToken));

        var exception = await Assert.ThrowsAsync<MacOSExtractorException>(
            () => client.GetStatusAsync(CancellationToken.None));

        Assert.Equal("fullDiskAccessRequired", exception.Code);
        Assert.Equal("FDA required", exception.Message);
    }

    [Fact]
    public async Task GetStatusAsync_TimesOutWhenNoResponseArrives()
    {
        var client = new MacOSNotificationExtractorClient(
            _appPath,
            (_, _, _, _, _) => Task.CompletedTask,
            TimeSpan.FromMilliseconds(50));

        var exception = await Assert.ThrowsAsync<MacOSExtractorException>(
            () => client.GetStatusAsync(CancellationToken.None));

        Assert.Equal("extractorTimeout", exception.Code);
    }

    private MacOSNotificationExtractorClient CreateClient(
        Func<string, string, CancellationToken, Task> writeResponse) =>
        new(
            _appPath,
            (_, requestPath, responsePath, _, cancellationToken) =>
                writeResponse(requestPath, responsePath, cancellationToken));

    private static void AssertPrivateFile(string path)
    {
        var mode = File.GetUnixFileMode(path);
        Assert.Equal(UnixFileMode.UserRead | UnixFileMode.UserWrite, mode);
    }

    public void Dispose()
    {
        if (Directory.Exists(_appPath))
        {
            Directory.Delete(_appPath, recursive: true);
        }
    }
}
