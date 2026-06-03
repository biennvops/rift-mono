import 'package:flutter/material.dart';
import '../constants.dart';

class PairingScreen extends StatelessWidget {
  const PairingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text(AppStrings.pairingTitle)),
      body: const Center(
        child: Text(AppStrings.pairingTitle),
      ),
    );
  }
}
