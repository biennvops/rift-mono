using System.Runtime.CompilerServices;
using System.Threading.Channels;
using Rift.Daemon.Core.Interfaces;
using Tmds.DBus.Protocol;

namespace Rift.Daemon.Linux;

internal interface ILinuxNotificationMonitor
{
    IAsyncEnumerable<LinuxNotificationBusEvent> ObserveAsync(CancellationToken cancellationToken);
}

internal abstract record LinuxNotificationBusEvent;

internal sealed record LinuxNotificationPostedCall(
    string Sender,
    uint Serial,
    string AppName,
    uint ReplacesId,
    string Summary,
    string Body,
    string? DesktopEntry,
    DateTimeOffset ReceivedAt) : LinuxNotificationBusEvent;

internal sealed record LinuxNotificationPostedReply(
    string Sender,
    string? Destination,
    uint ReplySerial,
    uint NotificationId) : LinuxNotificationBusEvent;

internal sealed record LinuxNotificationClosed(
    string Sender,
    uint NotificationId,
    uint Reason) : LinuxNotificationBusEvent;

internal sealed class LinuxFreedesktopNotificationMonitor(
    ILogger<LinuxFreedesktopNotificationMonitor> logger) : ILinuxNotificationMonitor
{
    private const string NotificationsService = "org.freedesktop.Notifications";
    private const string NotificationsInterface = "org.freedesktop.Notifications";
    private const string NotificationsPath = "/org/freedesktop/Notifications";

    public async IAsyncEnumerable<LinuxNotificationBusEvent> ObserveAsync(
        [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        var address = Environment.GetEnvironmentVariable("DBUS_SESSION_BUS_ADDRESS");
        if (string.IsNullOrWhiteSpace(address))
        {
            throw new InvalidOperationException("The Linux session D-Bus address is unavailable.");
        }

        var events = Channel.CreateUnbounded<LinuxNotificationBusEvent>(
            new UnboundedChannelOptions { SingleReader = true, SingleWriter = false });
        using var connection = new DBusConnection(address);

        await connection.ConnectAsync().ConfigureAwait(false);
        await connection.BecomeMonitorAsync(
            (exception, disposableMessage) =>
            {
                if (exception is not null)
                {
                    events.Writer.TryComplete(
                        cancellationToken.IsCancellationRequested ? null : exception);
                    return;
                }

                using (disposableMessage)
                {
                    try
                    {
                        if (LinuxFreedesktopNotificationMessageParser.TryParse(
                                disposableMessage.Message,
                                out var parsed))
                        {
                            events.Writer.TryWrite(parsed);
                        }
                    }
                    catch (Exception ex)
                    {
                        logger.LogDebug(ex, "Ignored malformed Linux notification D-Bus traffic.");
                    }
                }
            },
            CreateMatchRules()).ConfigureAwait(false);

        try
        {
            await foreach (var item in events.Reader.ReadAllAsync(cancellationToken).ConfigureAwait(false))
            {
                yield return item;
            }
        }
        finally
        {
            events.Writer.TryComplete();
            logger.LogDebug("Linux notification D-Bus monitor stopped.");
        }
    }

    private static IReadOnlyList<MatchRule> CreateMatchRules() =>
    [
        new MatchRule
        {
            Type = MessageType.MethodCall,
            Destination = NotificationsService,
            Interface = NotificationsInterface,
            Member = "Notify",
            Path = NotificationsPath
        },
        new MatchRule
        {
            Type = MessageType.MethodReturn,
            Sender = NotificationsService
        },
        new MatchRule
        {
            Type = MessageType.Signal,
            Sender = NotificationsService,
            Interface = NotificationsInterface,
            Member = "NotificationClosed",
            Path = NotificationsPath
        }
    ];
}

internal static class LinuxFreedesktopNotificationMessageParser
{
    private const string NotificationsInterface = "org.freedesktop.Notifications";
    private const string NotificationsPath = "/org/freedesktop/Notifications";
    private const string NotifySignature = "susssasa{sv}i";
    private const string NotificationClosedSignature = "uu";
    private const string NotificationIdSignature = "u";

    public static bool TryParse(Message message, out LinuxNotificationBusEvent parsed)
    {
        parsed = null!;
        try
        {
            if (message.MessageType == MessageType.MethodCall &&
                string.Equals(message.InterfaceAsString, NotificationsInterface, StringComparison.Ordinal) &&
                string.Equals(message.PathAsString, NotificationsPath, StringComparison.Ordinal) &&
                string.Equals(message.MemberAsString, "Notify", StringComparison.Ordinal) &&
                string.Equals(message.SignatureAsString, NotifySignature, StringComparison.Ordinal))
            {
                var reader = message.GetBodyReader();
                var appName = reader.ReadString();
                var replacesId = reader.ReadUInt32();
                _ = reader.ReadString(); // app_icon; icons are intentionally omitted in v1.
                var summary = reader.ReadString();
                var body = reader.ReadString();
                _ = reader.ReadArrayOfString(); // actions; arbitrary actions are out of scope.
                var hints = reader.ReadDictionaryOfStringToVariantValue();
                _ = reader.ReadInt32(); // expire_timeout; closure arrives as a signal.

                hints.TryGetValue("desktop-entry", out var desktopEntryValue);
                var desktopEntry = desktopEntryValue.Type == VariantValueType.String
                    ? desktopEntryValue.GetString()
                    : null;
                parsed = new LinuxNotificationPostedCall(
                    message.SenderAsString ?? string.Empty,
                    message.Serial,
                    appName,
                    replacesId,
                    summary,
                    body,
                    desktopEntry,
                    DateTimeOffset.UtcNow);
                return true;
            }

            if (message.MessageType == MessageType.MethodReturn &&
                string.Equals(message.SignatureAsString, NotificationIdSignature, StringComparison.Ordinal) &&
                message.ReplySerial.HasValue)
            {
                parsed = new LinuxNotificationPostedReply(
                    message.SenderAsString ?? string.Empty,
                    message.DestinationAsString,
                    message.ReplySerial.Value,
                    message.GetBodyReader().ReadUInt32());
                return true;
            }

            if (message.MessageType == MessageType.Signal &&
                string.Equals(message.InterfaceAsString, NotificationsInterface, StringComparison.Ordinal) &&
                string.Equals(message.PathAsString, NotificationsPath, StringComparison.Ordinal) &&
                string.Equals(message.MemberAsString, "NotificationClosed", StringComparison.Ordinal) &&
                string.Equals(message.SignatureAsString, NotificationClosedSignature, StringComparison.Ordinal))
            {
                var reader = message.GetBodyReader();
                parsed = new LinuxNotificationClosed(
                    message.SenderAsString ?? string.Empty,
                    reader.ReadUInt32(),
                    reader.ReadUInt32());
                return true;
            }
        }
        catch (DBusReadException)
        {
            // The monitor fails closed for malformed notification traffic and
            // continues observing subsequent messages.
        }

        return false;
    }
}

internal sealed class LinuxNotificationSyncObserver(
    ILinuxNotificationMonitor monitor,
    INotificationSyncService notificationSyncService,
    IIdentityManager identityManager,
    LinuxNotificationRegistry registry,
    ILinuxNotificationControl control,
    ILogger<LinuxNotificationSyncObserver> logger) : BackgroundService
{
    private static readonly TimeSpan RetryInterval = TimeSpan.FromSeconds(30);
    private static readonly TimeSpan PendingCallLifetime = TimeSpan.FromMinutes(2);
    private const string RiftDesktopEntry = "dev.rift.Rift";

    private readonly Dictionary<PendingCallKey, LinuxNotificationPostedCall> _pendingCalls = [];
    private readonly Dictionary<NotificationKey, LinuxNotificationPostedCall> _activeNotifications = [];
    private readonly Lock _gate = new();

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                await foreach (var item in monitor.ObserveAsync(stoppingToken).ConfigureAwait(false))
                {
                    await ProcessEventAsync(item, stoppingToken).ConfigureAwait(false);
                }
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                break;
            }
            catch (Exception ex)
            {
                logger.LogWarning(ex, "Linux notification observation is unavailable.");
            }

            try
            {
                await Task.Delay(RetryInterval, stoppingToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                break;
            }
        }
    }

    internal async Task ProcessEventAsync(
        LinuxNotificationBusEvent item,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        switch (item)
        {
            case LinuxNotificationPostedCall call:
                ProcessPostedCall(call);
                break;
            case LinuxNotificationPostedReply reply:
                await ProcessPostedReplyAsync(reply, cancellationToken).ConfigureAwait(false);
                break;
            case LinuxNotificationClosed closed:
                await ProcessClosedAsync(closed, cancellationToken).ConfigureAwait(false);
                break;
        }
    }

    private void ProcessPostedCall(LinuxNotificationPostedCall call)
    {
        if (ShouldIgnore(call))
        {
            return;
        }

        lock (_gate)
        {
            var cutoff = call.ReceivedAt - PendingCallLifetime;
            foreach (var key in _pendingCalls
                         .Where(entry => entry.Value.ReceivedAt < cutoff)
                         .Select(entry => entry.Key)
                         .ToArray())
            {
                _pendingCalls.Remove(key);
            }

            _pendingCalls[new PendingCallKey(call.Sender, call.Serial)] = call;
        }
    }

    private async Task ProcessPostedReplyAsync(
        LinuxNotificationPostedReply reply,
        CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(reply.Destination))
        {
            return;
        }

        LinuxNotificationPostedCall? call;
        lock (_gate)
        {
            _pendingCalls.Remove(
                new PendingCallKey(reply.Destination, reply.ReplySerial),
                out call);
        }

        if (call is null)
        {
            return;
        }

        var serverOwner = string.IsNullOrWhiteSpace(reply.Sender)
            ? "org.freedesktop.Notifications"
            : reply.Sender;
        var keyForNotification = new NotificationKey(serverOwner, reply.NotificationId);
        bool isUpdate;
        lock (_gate)
        {
            var replacementKey = new NotificationKey(serverOwner, call.ReplacesId);
            isUpdate = call.ReplacesId != 0 && _activeNotifications.ContainsKey(replacementKey);
            if (isUpdate && replacementKey != keyForNotification)
            {
                _activeNotifications.Remove(replacementKey);
                registry.Remove(CreateNotificationId(serverOwner, call.ReplacesId));
            }
            _activeNotifications[keyForNotification] = call;
        }

        var notificationId = CreateNotificationId(serverOwner, reply.NotificationId);
        var target = new LinuxNotificationTarget(
            notificationId,
            serverOwner,
            reply.NotificationId);
        var hasStableControlTarget =
            control.IsAvailable &&
            reply.Sender.StartsWith(":", StringComparison.Ordinal);
        if (hasStableControlTarget)
        {
            registry.Register(target);
        }
        else
        {
            registry.Remove(notificationId);
        }

        var notification = new NotificationSyncRecord
        {
            NotificationId = notificationId,
            SourceDeviceId = identityManager.GetDeviceId(),
            SourcePlatform = "linux",
            PackageName = GetPackageName(call),
            AppName = string.IsNullOrWhiteSpace(call.AppName) ? "Linux application" : call.AppName,
            Title = LimitPreview(call.Summary, 256),
            BodyPreview = LimitPreview(call.Body, 1024),
            PostedAt = call.ReceivedAt.ToUniversalTime().ToString("O"),
            IsDismissible = hasStableControlTarget,
            IsOpenable = false
        };

        var eventType = isUpdate ? "updated" : "posted";
        try
        {
            var result = await notificationSyncService.HandleLocalNotificationEventAsync(
                eventType,
                notification,
                removedAt: null,
                cancellationToken).ConfigureAwait(false);
            logger.LogInformation(
                "Linux notification {EventType} processed (suppressed={Suppressed}, broadcastPeers={BroadcastPeerCount}).",
                eventType,
                result.Suppressed,
                result.BroadcastTo.Count);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            registry.Remove(notification.NotificationId);
            lock (_gate)
            {
                _activeNotifications.Remove(keyForNotification);
            }
            logger.LogWarning(ex, "Failed to publish Linux notification {NotificationId}.", notification.NotificationId);
        }
    }

    private async Task ProcessClosedAsync(
        LinuxNotificationClosed closed,
        CancellationToken cancellationToken)
    {
        var serverOwner = string.IsNullOrWhiteSpace(closed.Sender)
            ? "org.freedesktop.Notifications"
            : closed.Sender;
        var key = new NotificationKey(serverOwner, closed.NotificationId);
        lock (_gate)
        {
            if (!_activeNotifications.Remove(key))
            {
                return;
            }
        }

        var notificationId = CreateNotificationId(serverOwner, closed.NotificationId);
        registry.Remove(notificationId);
        try
        {
            var result = await notificationSyncService.HandleLocalNotificationEventAsync(
                "removed",
                new NotificationSyncRecord
                {
                    NotificationId = notificationId,
                    SourceDeviceId = identityManager.GetDeviceId(),
                    SourcePlatform = "linux"
                },
                DateTimeOffset.UtcNow.ToString("O"),
                cancellationToken).ConfigureAwait(false);
            logger.LogInformation(
                "Linux notification removed (reason={Reason}, broadcastPeers={BroadcastPeerCount}).",
                closed.Reason,
                result.BroadcastTo.Count);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            logger.LogWarning(ex, "Failed to publish removed Linux notification {NotificationId}.", notificationId);
        }
    }

    private static bool ShouldIgnore(LinuxNotificationPostedCall call) =>
        string.Equals(call.DesktopEntry, RiftDesktopEntry, StringComparison.OrdinalIgnoreCase) ||
        string.Equals(call.AppName, RiftDesktopEntry, StringComparison.OrdinalIgnoreCase);

    private static string GetPackageName(LinuxNotificationPostedCall call) =>
        string.IsNullOrWhiteSpace(call.DesktopEntry)
            ? (string.IsNullOrWhiteSpace(call.AppName) ? "linux.unknown" : call.AppName.Trim())
            : call.DesktopEntry.Trim();

    private static string? LimitPreview(string value, int maxLength)
    {
        if (string.IsNullOrEmpty(value))
        {
            return null;
        }

        return value.Length <= maxLength ? value : value[..maxLength];
    }

    private static string CreateNotificationId(string serverOwner, uint notificationId) =>
        $"linux:{serverOwner}:{notificationId}";

    private readonly record struct PendingCallKey(string Sender, uint Serial);

    private readonly record struct NotificationKey(string ServerOwner, uint NotificationId);
}
