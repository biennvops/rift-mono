import 'package:flutter/material.dart';
import '../constants.dart';

class EventLogScreen extends StatelessWidget {
  const EventLogScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text(AppStrings.eventLogTitle)),
      body: const Center(
        child: Text(AppStrings.eventLogTitle),
      ),
    );
  }
}
