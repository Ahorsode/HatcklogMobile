import 'package:flutter/material.dart';

class BatchSummary {
  const BatchSummary({
    required this.id,
    required this.batchLabel,
    required this.livestockType,
    required this.currentCount,
    this.houseId = '',
    this.houseLabel = '',
  });

  final String id;
  final String batchLabel;
  final String livestockType;
  final int currentCount;
  final String houseId;
  final String houseLabel;

  String get detailLabel {
    final type = livestockType.trim();
    final house = houseLabel.trim();
    if (type.isEmpty && house.isEmpty) {
      return '$currentCount birds';
    }
    if (house.isEmpty) {
      return '$type | $currentCount birds';
    }
    if (type.isEmpty) {
      return '$house | $currentCount birds';
    }
    return '$type | $house | $currentCount birds';
  }
}

class QuickAddBatchGrid extends StatelessWidget {
  const QuickAddBatchGrid({
    super.key,
    required this.batches,
    required this.accentColor,
    required this.icon,
    required this.onTapAdd,
    required this.emptyMessage,
    this.onLongPress,
  });

  final List<BatchSummary> batches;
  final Color accentColor;
  final IconData icon;
  final void Function(BatchSummary batch) onTapAdd;
  final String emptyMessage;
  final void Function(BatchSummary batch)? onLongPress;

  @override
  Widget build(BuildContext context) {
    if (batches.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Text(
            emptyMessage,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.grey,
              fontStyle: FontStyle.italic,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      );
    }
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 1.25,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
      ),
      itemCount: batches.length,
      itemBuilder: (context, index) {
        final batch = batches[index];
        return Card(
          elevation: 1.5,
          color: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => onTapAdd(batch),
            onLongPress:
                onLongPress == null ? null : () => onLongPress!(batch),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(icon, color: accentColor, size: 20),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          batch.batchLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0,
                          ),
                        ),
                      ),
                      CircleAvatar(
                        radius: 16,
                        backgroundColor: accentColor.withValues(alpha: 0.14),
                        child: Icon(Icons.add, size: 18, color: accentColor),
                      ),
                    ],
                  ),
                  const Spacer(),
                  Text(
                    batch.detailLabel,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xff66736c),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
