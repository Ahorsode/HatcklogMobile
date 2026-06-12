import 'package:flutter/widgets.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'app/app_services.dart';
import 'app/hatchlog_app.dart';
import 'core/config/google_auth_config.dart';

Future<void> main() async {
  // 1. Ensure Flutter engine is firmly attached to the native host container
  WidgetsFlutterBinding.ensureInitialized();

  // 2. Attempt to hydrate packaged mobile configuration without blocking fallback boot.
  try {
    await dotenv.load(fileName: '.env.mobile');
  } on Object catch (error) {
    debugPrint('WARN: Packed .env.mobile asset could not be loaded: $error');
  }

  // 3. Validate Google auth hydration early so missing keys are visible at boot.
  await GoogleAuthConfig.load();

  // 4. Bootstrap app services, which load local environment config and initialize Supabase.
  final services = await AppServices.bootstrap();

  runApp(HatchLogApp(services: services));
}
