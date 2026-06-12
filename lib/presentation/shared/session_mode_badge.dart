import 'package:flutter/material.dart';

class SessionModeBadge extends StatelessWidget {
  const SessionModeBadge({
    super.key,
    required this.isOnline,
    required this.authenticatedOffline,
    this.pendingCount,
    this.foregroundOnDark = false,
  });

  final bool isOnline;
  final bool authenticatedOffline;
  final int? pendingCount;
  final bool foregroundOnDark;

  bool get _secureLocal => authenticatedOffline || !isOnline;

  @override
  Widget build(BuildContext context) {
    final color = _secureLocal
        ? const Color(0xffd99025)
        : const Color(0xff16845c);
    final background = foregroundOnDark
        ? Colors.white
        : color.withValues(alpha: 0.1);
    final borderColor = foregroundOnDark
        ? Colors.white.withValues(alpha: 0.2)
        : color.withValues(alpha: 0.22);
    final textColor = foregroundOnDark ? const Color(0xff17231d) : color;
    final pending = pendingCount ?? 0;
    final label = _secureLocal
        ? 'Secure Local Hardware Mode'
        : 'Cloud Synchronized Mode';
    final suffix = pending > 0 ? ' - $pending pending' : '';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            _secureLocal ? Icons.security_outlined : Icons.cloud_done_outlined,
            color: color,
            size: 18,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              '$label$suffix',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: textColor, fontWeight: FontWeight.w900),
            ),
          ),
        ],
      ),
    );
  }
}
