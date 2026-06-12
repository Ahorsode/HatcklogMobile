import 'package:flutter/material.dart';

import '../../core/models/app_user.dart';

class AccessDeniedScreen extends StatelessWidget {
  const AccessDeniedScreen({
    super.key,
    required this.currentUser,
    required this.onSignOut,
  });

  final AppUser currentUser;
  final Future<void> Function() onSignOut;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Access Denied'),
        actions: [
          IconButton(
            tooltip: 'Sign out',
            onPressed: onSignOut,
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.block_outlined,
                size: 56,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: 16),
              Text(
                'This account does not have mobile access.',
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              Text(currentUser.phoneNumber, textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    );
  }
}
