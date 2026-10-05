import 'package:logging/logging.dart';

import 'env/base.dart' if (dart.library.io) 'env/_io.dart';

void maybeActivateAllLogLevels() {
  if (!shouldPrintAllLogs()) {
    return;
  }

  Logger.root.level = Level.ALL;
  Logger.root.onRecord.forEach((record) {
    print(
        '[${record.loggerName}] ${record.level.name} ${record.time}: ${record.message}');
    if (record.error != null) {
      print('${record.error}');
      if (record.stackTrace != null) {
        record.stackTrace.toString().split('\n').forEach(print);
      }
    }
  });
}
