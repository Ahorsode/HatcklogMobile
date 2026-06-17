import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:url_launcher/url_launcher.dart';

Future<bool> openLicenseUpgrade() async {
  final baseUrl = dotenv.env['WEB_APP_URL']?.trim() ?? '';
  if (baseUrl.isEmpty) {
    return false;
  }

  final uri = Uri.parse(
    '${baseUrl.replaceAll(RegExp(r'/$'), '')}/dashboard/license-upgrade',
  );
  return launchUrl(uri, mode: LaunchMode.externalApplication);
}
