import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../constants.dart';
import '../src/ipc/json_rpc_client.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  Future<dynamic>? _deviceInfoFuture;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _fetchDeviceInfo();
    });
  }

  void _fetchDeviceInfo() {
    final client = Provider.of<JsonRpcRiftClient>(context, listen: false);
    setState(() {
      _deviceInfoFuture = client.getDeviceInfo();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(AppStrings.settingsTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _fetchDeviceInfo,
          ),
        ],
      ),
      body: FutureBuilder<dynamic>(
        future: _deviceInfoFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          } else if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Text(
                  'Error fetching device info:\n${snapshot.error}',
                  style: const TextStyle(color: Colors.red),
                  textAlign: TextAlign.center,
                ),
              ),
            );
          } else if (snapshot.hasData) {
            final data = snapshot.data as Map<String, dynamic>;
            final deviceId = data['deviceId'] ?? 'Unknown';
            final fingerprint = data['fingerprint'] ?? 'Unknown';
            final implId = data['implementationId'] ?? 'Unknown';
            final protocolVer = data['protocolVersion'] ?? 'Unknown';

            return ListView(
              padding: const EdgeInsets.all(16.0),
              children: [
                _buildInfoCard('Device ID', deviceId),
                _buildInfoCard('Fingerprint', fingerprint),
                _buildInfoCard('Implementation ID', implId),
                _buildInfoCard('Protocol Version', protocolVer),
              ],
            );
          } else {
            return const Center(child: Text('No data available.'));
          }
        },
      ),
    );
  }

  Widget _buildInfoCard(String title, String value) {
    return Card(
      elevation: 2,
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontSize: 14,
                color: Colors.grey,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            SelectableText(
              value,
              style: const TextStyle(
                fontSize: 16,
                fontFamily: 'monospace',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
