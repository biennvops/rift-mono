import 'dart:isolate';
import 'dart:io';
import 'lib/src/daemon_isolate.dart';

void main() async {
  print('Starting Daemon in standalone mode...');
  
  var receivePort = ReceivePort();
  
  try {
    await Isolate.spawn(daemonEntryPoint, receivePort.sendPort);
    
    var tempDir = await Directory.systemTemp.createTemp('rift_demo');
    print('Storage path: ${tempDir.path}');
    
    SendPort? daemonSendPort;
    
    receivePort.listen((msg) {
      if (msg is SendPort) {
        daemonSendPort = msg;
        print('Sending configuration to daemon...');
        daemonSendPort!.send(DaemonConfig(storagePath: tempDir.path, port: 8080));
      } else {
        print('[Daemon Output] $msg');
      }
    });
    
  } catch (e) {
    print('Failed to spawn daemon: $e');
  }
}
