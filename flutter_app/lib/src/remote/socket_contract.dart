abstract class RemoteSocket {
  Stream<String> get messages;
  void send(String text);
  Future<void> close();
}
