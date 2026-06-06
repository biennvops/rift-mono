import 'package:flutter/material.dart';
import '../constants.dart';

class TrustedDevicesScreen extends StatelessWidget {
  const TrustedDevicesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text(AppStrings.trustedDevicesTitle)),
      body: const Center(
        child: Text(AppStrings.trustedDevicesTitle),
      ),
    );
  }
}
