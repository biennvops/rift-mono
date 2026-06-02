using System.IO.Pipes;
using System.Security.AccessControl;
using System.Security.Principal;
using StreamJsonRpc;

namespace Rift.Daemon.Windows;

public class IpcListener(ILogger<IpcListener> logger)
{
    private const string PipeName = "rift-daemon-v0.1";

    public async Task ListenAsync(CancellationToken stoppingToken)
    {
        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                logger.LogInformation("Waiting for IPC connection on \\\\.\\pipe\\{pipe}", PipeName);
                
                var pipeSecurity = new PipeSecurity();

                // Deny remote network access explicitly
                pipeSecurity.AddAccessRule(new PipeAccessRule(
                    new SecurityIdentifier(WellKnownSidType.NetworkSid, null),
                    PipeAccessRights.FullControl,
                    AccessControlType.Deny));

                // Allow the current user (e.g. SYSTEM or Service Account) full control
                using (var currentIdentity = WindowsIdentity.GetCurrent())
                {
                    if (currentIdentity.User != null)
                    {
                        pipeSecurity.AddAccessRule(new PipeAccessRule(
                            currentIdentity.User,
                            PipeAccessRights.FullControl,
                            AccessControlType.Allow));
                    }
                }

                // Allow local interactive users (the UI process in session 1+) to connect and read/write
                pipeSecurity.AddAccessRule(new PipeAccessRule(
                    new SecurityIdentifier(WellKnownSidType.InteractiveSid, null),
                    PipeAccessRights.ReadWrite,
                    AccessControlType.Allow));

                var pipeServer = NamedPipeServerStreamAcl.Create(
                    PipeName,
                    PipeDirection.InOut,
                    NamedPipeServerStream.MaxAllowedServerInstances,
                    PipeTransmissionMode.Byte,
                    PipeOptions.Asynchronous,
                    inBufferSize: 0,
                    outBufferSize: 0,
                    pipeSecurity: pipeSecurity);

                await pipeServer.WaitForConnectionAsync(stoppingToken);
                
                logger.LogInformation("Client connected to IPC pipe.");

                try
                {
                    _ = Task.Run(() => HandleClientAsync(pipeServer, stoppingToken), stoppingToken);
                }
                catch (Exception ex)
                {
                    logger.LogError(ex, "Failed to spawn IPC handler.");
                    await pipeServer.DisposeAsync();
                }
            }
            catch (OperationCanceledException)
            {
                break;
            }
            catch (Exception ex)
            {
                logger.LogError(ex, "Error in IPC listener loop.");
                await Task.Delay(1000, stoppingToken);
            }
        }
    }

    private async Task HandleClientAsync(NamedPipeServerStream pipe, CancellationToken stoppingToken)
    {
        try
        {
            using var jsonRpc = JsonRpc.Attach(pipe, new RiftApiHandler());
            await jsonRpc.Completion;
            logger.LogInformation("IPC client disconnected.");
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Error handling IPC client.");
        }
        finally
        {
            await pipe.DisposeAsync();
        }
    }
}
