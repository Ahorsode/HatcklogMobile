import 'package:flutter_test/flutter_test.dart';
import 'package:hatchlog_m/utils/feed_source_utils.dart';

void main() {
  test('parseFeedSource maps inventory prefix to feed_type_id', () {
    final selection = parseFeedSource(
      'inv_abc123',
      label: '[Inventory] Layer Mash',
    );

    expect(selection.feedTypeId, 'abc123');
    expect(selection.formulationId, isNull);
    expect(selection.label, '[Inventory] Layer Mash');
  });

  test('parseFeedSource maps formulation prefix to formulation_id', () {
    final selection = parseFeedSource(
      'form_mix-9',
      label: '[Formulation] Starter Mix',
    );

    expect(selection.feedTypeId, isNull);
    expect(selection.formulationId, 'mix-9');
    expect(selection.label, '[Formulation] Starter Mix');
  });
}
