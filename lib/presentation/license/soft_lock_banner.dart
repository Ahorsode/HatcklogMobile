import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/license/license_upgrade_launcher.dart';

class SoftLockBanner extends StatelessWidget {
  const SoftLockBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xffdc2626),
      child: InkWell(
        onTap: () {
          unawaited(openLicenseUpgrade());
        },
        child: const Padding(
          padding: EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Row(
            children: [
              Icon(Icons.warning_amber_outlined, color: Colors.white),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  "Your farm's subscription has expired. You have 5 days of grace access remaining - ask your farm owner to renew.",
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    height: 1.25,
                  ),
                ),
              ),
              SizedBox(width: 8),
              Icon(Icons.open_in_new, color: Colors.white, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}
