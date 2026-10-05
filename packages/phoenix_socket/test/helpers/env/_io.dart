import 'dart:io';

final _logAllLevels = Platform.environment['LOG_ALL_LEVELS'];

bool shouldPrintAllLogs() {
  return _logAllLevels == 'y';
}
