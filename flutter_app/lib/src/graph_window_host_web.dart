import 'session_controller.dart';

class GraphWindowHost {
  static void exitViewer() =>
      throw UnsupportedError('No separate graph viewer in the browser');
  static const supported = false;
  static Future<void> open(SessionController session, {String? prefix}) async =>
      throw UnsupportedError('Use the graph inside this page');
}
