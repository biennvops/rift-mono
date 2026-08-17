using System.Runtime.Versioning;
using System.Text;
using System.Text.Json;
using Rift.Daemon.macOS;

namespace Rift.Daemon.Tests.Core;

[SupportedOSPlatform("macos")]
public sealed class MacOSNotificationExtractorClientTests
{
    [Fact]
    public async Task GetStatusAsync_SendsFixedOperationAndParsesResponse()
    {
        var client = CreateClient(request =>
        {
            Assert.Equal("getStatus", request.RootElement.GetProperty("operation").GetString());
            Assert.Equal(JsonValueKind.Null, request.RootElement.GetProperty("cursor").ValueKind);
            return SuccessResponse(
                request,
                "{\"databaseFound\":true,\"databaseReadable\":true,\"schemaSupported\":true,\"state\":\"ready\"}");
        });

        var status = await client.GetStatusAsync(CancellationToken.None);

        Assert.True(status.DatabaseFound);
        Assert.True(status.DatabaseReadable);
        Assert.True(status.SchemaSupported);
        Assert.Equal("ready", status.State);
    }

    [Fact]
    public async Task ScanNotificationChangesAsync_SendsNonNegativeCursor()
    {
        var client = CreateClient(request =>
        {
            Assert.Equal("scanNotificationChanges", request.RootElement.GetProperty("operation").GetString());
            Assert.Equal(0, request.RootElement.GetProperty("cursor").GetInt64());
            return SuccessResponse(
                request,
                "{\"cursor\":0,\"notifications\":[],\"skippedRecords\":0}");
        });

        var result = await client.ScanNotificationChangesAsync(-10, CancellationToken.None);

        Assert.Equal(0, result.Cursor);
        Assert.Empty(result.Notifications);
    }

    [Fact]
    public async Task GetNotificationActionCapabilitiesAsync_SendsBoundedIdentityFields()
    {
        var client = CreateClient(request =>
        {
            Assert.Equal(
                "getNotificationActionCapabilities",
                request.RootElement.GetProperty("operation").GetString());
            Assert.Equal("notification-1", request.RootElement.GetProperty("notificationId").GetString());
            Assert.Equal("com.example.source", request.RootElement.GetProperty("packageName").GetString());
            return SuccessResponse(
                request,
                "{\"backend\":\"accessibility\",\"canDismiss\":true,\"canOpen\":false}");
        });

        var capabilities = await client.GetNotificationActionCapabilitiesAsync(
            "notification-1",
            "com.example.source",
            CancellationToken.None);

        Assert.Equal("accessibility", capabilities.Backend);
        Assert.True(capabilities.CanDismiss);
        Assert.False(capabilities.CanOpen);
    }

    [Fact]
    public async Task DismissNotificationAsync_ParsesVerifiedResult()
    {
        var client = CreateClient(request =>
        {
            Assert.Equal("dismissNotification", request.RootElement.GetProperty("operation").GetString());
            Assert.Equal("notification-2", request.RootElement.GetProperty("notificationId").GetString());
            Assert.Equal("com.example.source", request.RootElement.GetProperty("packageName").GetString());
            return SuccessResponse(
                request,
                "{\"backend\":\"accessibility\",\"success\":true,\"reason\":\"verified\"}");
        });

        var result = await client.DismissNotificationAsync(
            "notification-2",
            "com.example.source",
            CancellationToken.None);

        Assert.True(result.Success);
        Assert.Equal("verified", result.Reason);
    }

    [Fact]
    public async Task ScanNotificationChangesAsync_RejectsMalformedResponse()
    {
        var client = new MacOSNotificationExtractorClient(
            (_, _, _) => Task.FromResult("not-json"u8.ToArray()));

        var exception = await Assert.ThrowsAsync<MacOSExtractorException>(
            () => client.ScanNotificationChangesAsync(12, CancellationToken.None));

        Assert.Equal("invalidResponse", exception.Code);
    }

    [Fact]
    public async Task ScanNotificationChangesAsync_RejectsOversizedResponse()
    {
        var client = new MacOSNotificationExtractorClient(
            (_, _, _) => Task.FromResult(new byte[1024 * 1024 + 1]));

        var exception = await Assert.ThrowsAsync<MacOSExtractorException>(
            () => client.ScanNotificationChangesAsync(12, CancellationToken.None));

        Assert.Equal("responseTooLarge", exception.Code);
    }

    [Fact]
    public async Task GetStatusAsync_ReportsExtractorError()
    {
        var client = CreateClient(request =>
        {
            var id = request.RootElement.GetProperty("id").GetString();
            return $"{{\"id\":\"{id}\",\"ok\":false,\"error\":{{\"code\":\"fullDiskAccessRequired\",\"message\":\"FDA required\"}}}}";
        });

        var exception = await Assert.ThrowsAsync<MacOSExtractorException>(
            () => client.GetStatusAsync(CancellationToken.None));

        Assert.Equal("fullDiskAccessRequired", exception.Code);
        Assert.Equal("FDA required", exception.Message);
    }

    [Fact]
    public async Task GetStatusAsync_RejectsMismatchedResponseId()
    {
        var client = new MacOSNotificationExtractorClient(
            (_, _, _) => Task.FromResult(
                "{\"id\":\"wrong-id\",\"ok\":true,\"result\":{\"state\":\"ready\"}}"u8.ToArray()));

        var exception = await Assert.ThrowsAsync<MacOSExtractorException>(
            () => client.GetStatusAsync(CancellationToken.None));

        Assert.Equal("invalidResponse", exception.Code);
    }

    [Fact]
    public async Task GetStatusAsync_MapsNativeTimeout()
    {
        var client = new MacOSNotificationExtractorClient(
            async (_, timeout, _) =>
            {
                await Task.Delay(timeout);
                throw new OperationCanceledException();
            },
            TimeSpan.FromMilliseconds(10));

        var exception = await Assert.ThrowsAsync<MacOSExtractorException>(
            () => client.GetStatusAsync(CancellationToken.None));

        Assert.Equal("extractorTimeout", exception.Code);
    }

    private static MacOSNotificationExtractorClient CreateClient(Func<JsonDocument, string> responseFactory) =>
        new((requestBytes, _, _) =>
        {
            using var request = JsonDocument.Parse(requestBytes);
            return Task.FromResult(Encoding.UTF8.GetBytes(responseFactory(request)));
        });

    private static string SuccessResponse(JsonDocument request, string resultJson)
    {
        var id = request.RootElement.GetProperty("id").GetString();
        return $"{{\"id\":\"{id}\",\"ok\":true,\"result\":{resultJson}}}";
    }
}
