import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'registers.dart';
import 'serial_channel_native.dart';
import 'wire_channel.dart';
import 'wire_protocol.dart';

Future<WireChannel> openWireChannel(Json parameters) async {
  final p = parameters;
  if (p['transport'] == 'rtu') return _SerialWireChannel(SerialChannel(p));
  if (p['transport'] == 'rtu_udp') {
    final host =
        InternetAddress.tryParse(p['host']) ??
        (await InternetAddress.lookup(p['host'])).first;
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    return _UdpWireChannel(socket, host, p['port'] as int);
  }
  final socket = await Socket.connect(
    InternetAddress.tryParse(p['host']) ?? p['host'],
    p['port'],
    timeout: Duration(milliseconds: ((p['timeout'] as num) * 1000).round()),
  );
  socket.setOption(SocketOption.tcpNoDelay, true);
  return _TcpWireChannel(socket);
}

class _SerialWireChannel implements WireChannel {
  _SerialWireChannel(this.channel);
  final SerialChannel channel;
  @override
  Stream<Uint8List> get stream => channel.stream;
  @override
  Future<void> write(List<int> bytes, {ReadCancellation? cancellation}) =>
      channel.write(bytes, cancellation: cancellation);
  @override
  Future<void> close() async => channel.close();
}

class _TcpWireChannel implements WireChannel {
  _TcpWireChannel(this.socket);
  final Socket socket;
  @override
  Stream<Uint8List> get stream => socket;
  @override
  Future<void> write(List<int> bytes, {ReadCancellation? cancellation}) async {
    cancellation?.check();
    socket.add(bytes);
  }

  @override
  Future<void> close() async => socket.destroy();
}

class _UdpWireChannel implements WireChannel {
  _UdpWireChannel(this.socket, this.host, this.port);
  final RawDatagramSocket socket;
  final InternetAddress host;
  final int port;
  @override
  Stream<Uint8List> get stream => socket.expand<Uint8List>((event) {
    final packets = <Uint8List>[];
    if (event == RawSocketEvent.read) {
      Datagram? packet;
      while ((packet = socket.receive()) != null) {
        if (packet!.address.address == host.address && packet.port == port) {
          packets.add(packet.data);
        }
      }
    }
    return packets;
  });
  @override
  Future<void> write(List<int> bytes, {ReadCancellation? cancellation}) async {
    cancellation?.check();
    if (socket.send(bytes, host, port) != bytes.length) {
      throw const WireDisconnected('UDP send failed');
    }
  }

  @override
  Future<void> close() async => socket.close();
}
