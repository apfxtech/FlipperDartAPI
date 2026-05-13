import 'package:flutter/foundation.dart';

class LogService {
  static void log(String msg) {
    if (!kDebugMode) return;

    final ts = DateTime.now().toIso8601String().substring(11, 19);
    final line = '[$ts] $msg';
    debugPrint(line);
  }
}
