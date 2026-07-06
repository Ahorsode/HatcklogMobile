class FeedSourceSelection {
  const FeedSourceSelection({
    this.feedTypeId,
    this.formulationId,
    required this.label,
  });

  final String? feedTypeId;
  final String? formulationId;
  final String label;
}

FeedSourceSelection parseFeedSource(String source, {String? label}) {
  final trimmed = source.trim();
  if (trimmed.startsWith('inv_')) {
    return FeedSourceSelection(
      feedTypeId: trimmed.split('_').last,
      formulationId: null,
      label: label ?? trimmed,
    );
  }
  if (trimmed.startsWith('form_')) {
    return FeedSourceSelection(
      feedTypeId: null,
      formulationId: trimmed.split('_').last,
      label: label ?? trimmed,
    );
  }
  return FeedSourceSelection(label: label ?? trimmed);
}
