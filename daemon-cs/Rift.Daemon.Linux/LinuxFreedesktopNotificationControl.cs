using Tmds.DBus.Protocol;

namespace Rift.Daemon.Linux;

internal interface ILinuxNotificationControl
{
    bool IsAvailable { get; }

    Task<string> GetNotificationServerOwnerAsync(CancellationToken cancellationToken);

    Task CloseNotificationAsync(
        string notificationServerOwner,
        uint notificationId,
        CancellationToken cancellationToken);
}

internal sealed record LinuxNotificationMethodCall(
    string Destination,
    string Path,
    string Interface,
    string Member,
    string Signature,
    string? StringArgument = null,
    uint? UInt32Argument = null);

internal sealed class LinuxFreedesktopNotificationControl : ILinuxNotificationControl
{
    internal const string NotificationsService = "org.freedesktop.Notifications";
    internal const string NotificationsPath = "/org/freedesktop/Notifications";
    internal const string NotificationsInterface = "org.freedesktop.Notifications";
    internal const string DBusService = "org.freedesktop.DBus";
    internal const string DBusPath = "/org/freedesktop/DBus";
    internal const string DBusInterface = "org.freedesktop.DBus";

    private static readonly TimeSpan CallTimeout = TimeSpan.FromSeconds(5);
    private readonly DBusConnection _connection = DBusConnection.Session;

    public bool IsAvailable => !string.IsNullOrWhiteSpace(DBusAddress.Session);

    public async Task<string> GetNotificationServerOwnerAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        EnsureAvailable();
        await _connection.ConnectAsync().AsTask().WaitAsync(CallTimeout, cancellationToken).ConfigureAwait(false);
        var message = CreateGetNameOwnerMessage(_connection);
        return await _connection.CallMethodAsync(
                message,
                static (reply, _) => reply.GetBodyReader().ReadString(),
                readerState: null)
            .WaitAsync(CallTimeout, cancellationToken)
            .ConfigureAwait(false);
    }

    public async Task CloseNotificationAsync(
        string notificationServerOwner,
        uint notificationId,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        EnsureAvailable();
        await _connection.ConnectAsync().AsTask().WaitAsync(CallTimeout, cancellationToken).ConfigureAwait(false);
        var message = CreateCloseNotificationMessage(
            _connection,
            notificationServerOwner,
            notificationId);
        await _connection.CallMethodAsync(message)
            .WaitAsync(CallTimeout, cancellationToken)
            .ConfigureAwait(false);
    }

    internal static LinuxNotificationMethodCall CreateGetNameOwnerCall() => new(
        DBusService,
        DBusPath,
        DBusInterface,
        "GetNameOwner",
        "s",
        StringArgument: NotificationsService);

    internal static LinuxNotificationMethodCall CreateCloseNotificationCall(
        string notificationServerOwner,
        uint notificationId) => new(
            notificationServerOwner,
            NotificationsPath,
            NotificationsInterface,
            "CloseNotification",
            "u",
            UInt32Argument: notificationId);

    internal static MessageBuffer CreateGetNameOwnerMessage(DBusConnection connection)
    {
        var call = CreateGetNameOwnerCall();
        using var writer = connection.GetMessageWriter();
        writer.WriteMethodCallHeader(
            call.Destination,
            call.Path,
            call.Interface,
            call.Member,
            call.Signature,
            MessageFlags.None);
        writer.WriteString(call.StringArgument!);
        return writer.CreateMessage();
    }

    internal static MessageBuffer CreateCloseNotificationMessage(
        DBusConnection connection,
        string notificationServerOwner,
        uint notificationId)
    {
        var call = CreateCloseNotificationCall(notificationServerOwner, notificationId);
        using var writer = connection.GetMessageWriter();
        writer.WriteMethodCallHeader(
            call.Destination,
            call.Path,
            call.Interface,
            call.Member,
            call.Signature,
            MessageFlags.None);
        writer.WriteUInt32(call.UInt32Argument!.Value);
        return writer.CreateMessage();
    }

    private void EnsureAvailable()
    {
        if (!IsAvailable)
        {
            throw new InvalidOperationException("The Linux session D-Bus address is unavailable.");
        }
    }
}
