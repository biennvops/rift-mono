using System.IO.Pipes;
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
                
                var pipeServer = new NamedPipeServerStream(
                    PipeName,
                    PipeDirection.InOut,
                    NamedPipeServerStream.MaxAllowedServerInstances,
                    PipeTransmissionMode.Byte,
                    PipeOptions.Asynchronous);

                await pipeServer.WaitForConnectionAsync(stoppingToken);
                
                logger.LogInformation("Client connected to IPC pipe.");

                _ = HandleClientAsync(pipeServer, stoppingToken);
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
