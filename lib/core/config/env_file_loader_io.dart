import 'dart:io';

Future<Map<String, String>> loadLocalEnvFileImpl() async {
  final candidates = [
    File('.env'),
    File('C:/Users/ahors/hosting_pfms/hatchlog_m/.env'),
  ];

  for (final file in candidates) {
    if (await file.exists()) {
      return _parseEnv(await file.readAsString());
    }
  }

  return const {};
}

Map<String, String> _parseEnv(String contents) {
  final values = <String, String>{};
  for (final rawLine in contents.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) {
      continue;
    }

    final separatorIndex = line.indexOf('=');
    if (separatorIndex <= 0) {
      continue;
    }

    final key = line.substring(0, separatorIndex).trim();
    var value = line.substring(separatorIndex + 1).trim();
    if ((value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'"))) {
      value = value.substring(1, value.length - 1);
    }

    values[key] = value;
  }

  return values;
}
