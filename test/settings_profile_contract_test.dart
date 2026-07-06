import 'package:flutter_test/flutter_test.dart';
import 'package:hatchlog_m/core/settings/settings_profile_contract.dart';

void main() {
  group('Settings profile contract — farm settings', () {
    test('defaults match web FarmSettings model', () {
      expect(SettingsProfileContract.defaultCurrency, 'GHS');
      expect(SettingsProfileContract.defaultEggsPerCrate, 30);
      expect(SettingsProfileContract.defaultEggReminder, '18:00');
      expect(SettingsProfileContract.defaultFeedReminder, '18:00');
      expect(SettingsProfileContract.defaultReorderLevelKg, 500);
    });

    test('currency normalization matches web options', () {
      expect(SettingsProfileContract.normalizeCurrency('GH₵'), 'GHS');
      expect(SettingsProfileContract.normalizeCurrency('USD'), 'USD');
      expect(SettingsProfileContract.normalizeCurrency(null), 'GHS');
    });

    test('currency options align with web SettingsContent', () {
      expect(SettingsProfileContract.currencyOptions.keys, containsAll(['GHS', 'USD', 'NGN', 'KES']));
    });
  });

  group('Settings profile contract — profile edit', () {
    test('validateProfileNames enforces web minimum lengths', () {
      expect(
        SettingsProfileContract.validateProfileNames(firstName: 'A', surname: 'Doe'),
        isNotNull,
      );
      expect(
        SettingsProfileContract.validateProfileNames(firstName: 'John', surname: 'D'),
        isNotNull,
      );
      expect(
        SettingsProfileContract.validateProfileNames(firstName: 'John', surname: 'Doe'),
        isNull,
      );
    });

    test('buildDisplayName mirrors web name composition', () {
      expect(
        SettingsProfileContract.buildDisplayName(
          firstName: 'John',
          middleName: 'Q',
          surname: 'Doe',
        ),
        'John Q Doe',
      );
    });
  });

  group('Settings profile contract — trash', () {
    test('trash tabs match web TrashDashboardClient categories', () {
      expect(
        SettingsProfileContract.trashTabs.map((tab) => tab.key),
        [
          'batches',
          'eggProduction',
          'feedingLogs',
          'mortality',
          'expenses',
          'sales',
          'orders',
          'inventory',
        ],
      );
    });

    test('mortality is audit-only like web', () {
      expect(SettingsProfileContract.canRestoreTrashTab('mortality'), isFalse);
      expect(SettingsProfileContract.canRestoreTrashTab('sales'), isTrue);
    });
  });
}
