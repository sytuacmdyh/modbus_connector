from collections.abc import Callable, Iterator

import pytest
from pymodbus.client import serial as serial_client
from pymodbus.exceptions import ModbusIOException
from pymodbus.factory import ClientDecoder
from pymodbus.framer.rtu_framer import ModbusRtuFramer
from pymodbus.register_read_message import ReadHoldingRegistersResponse

from modbus_connector.backend import ModbusBackend, ModbusExceptionError
from modbus_connector.models import RtuParams


class _Clock:
    now = 0.0

    def time(self) -> float:
        return self.now

    def sleep(self, seconds: float) -> None:
        self.now += seconds


class _UsbSerial:
    """Windows read semantics with USB deliveries separated by 10 ms."""

    def __init__(self, clock: _Clock, chunks: list[bytes], timeout: float) -> None:
        self.clock = clock
        self.chunks = chunks
        self.timeout = timeout
        self.inter_byte_timeout: float | None = None
        self.is_open = True
        self.pending: list[tuple[float, bytes]] = []
        self.buffer = bytearray()

    @property
    def in_waiting(self) -> int:
        while self.pending and self.pending[0][0] <= self.clock.now:
            _, data = self.pending.pop(0)
            self.buffer.extend(data)
        return len(self.buffer)

    def write(self, request: bytes) -> int:
        self.pending = [(self.clock.now + i * 0.01, part) for i, part in enumerate(self.chunks)]
        return len(request)

    def read(self, size: int) -> bytes:
        deadline = self.clock.now + self.timeout
        result = bytearray()
        while len(result) < size:
            available = min(self.in_waiting, size - len(result))
            result.extend(self.buffer[:available])
            del self.buffer[:available]
            if len(result) == size:
                break
            until = deadline
            if result and self.inter_byte_timeout is not None:
                # pyserial serialwin32 clamps a configured interval to >= 1 ms.
                interval = max(int(self.inter_byte_timeout * 1000), 1) / 1000
                until = min(until, self.clock.now + interval)
            if self.pending and self.pending[0][0] <= until:
                self.clock.now = self.pending[0][0]
            else:
                self.clock.now = until
                break
        return bytes(result)

    def close(self) -> None:
        self.is_open = False


@pytest.fixture()
def connect_serial(
    monkeypatch: pytest.MonkeyPatch,
) -> Iterator[Callable[[list[bytes]], ModbusBackend]]:
    clock = _Clock()
    monkeypatch.setattr(serial_client, "time", clock)
    backend = ModbusBackend()

    def connect(chunks: list[bytes]) -> ModbusBackend:
        def open_serial(port: str, **kwargs: object) -> _UsbSerial:
            return _UsbSerial(clock, chunks, float(kwargs["timeout"]))

        monkeypatch.setattr(serial_client.serial, "serial_for_url", open_serial)
        backend.connect(RtuParams(port="COM30", baudrate=115200, timeout=3.0))
        return backend

    yield connect
    backend.disconnect()


def _response(count: int) -> bytes:
    response = ReadHoldingRegistersResponse(list(range(count)), slave=1)
    return ModbusRtuFramer(ClientDecoder()).buildPacket(response)


@pytest.mark.parametrize("count,chunk_size", [(64, 131), (120, 128), (125, 32)])
def test_usb_packet_gaps_do_not_truncate_response(
    connect_serial: Callable[[list[bytes]], ModbusBackend], count: int, chunk_size: int
) -> None:
    frame = _response(count)
    chunks = [frame[i : i + chunk_size] for i in range(0, len(frame), chunk_size)]
    backend = connect_serial(chunks)
    traffic: list[tuple[str, bytes]] = []
    backend.traffic_hook = lambda direction, data: traffic.append((direction, data))
    for _ in range(2):
        traffic.clear()
        assert backend.read(1, "holding_registers", 30, count) == list(range(count))
        assert b"".join(data for direction, data in traffic if direction == "rx") == frame


def test_incomplete_serial_response_still_fails(
    connect_serial: Callable[[list[bytes]], ModbusBackend],
) -> None:
    backend = connect_serial([_response(64)[:-2]])
    with pytest.raises(ModbusIOException, match="Unable to decode response"):
        backend.read(1, "holding_registers", 30, 64)


def test_invalid_serial_crc_still_fails(
    connect_serial: Callable[[list[bytes]], ModbusBackend],
) -> None:
    frame = _response(64)
    backend = connect_serial([frame[:-1] + bytes([frame[-1] ^ 1])])
    with pytest.raises(ModbusIOException, match="Unable to decode response"):
        backend.read(1, "holding_registers", 30, 64)


def test_serial_exception_response_is_preserved(
    connect_serial: Callable[[list[bytes]], ModbusBackend],
) -> None:
    backend = connect_serial([bytes.fromhex("01 83 02 c0 f1")])
    with pytest.raises(ModbusExceptionError, match="Illegal Data Address") as error:
        backend.read(1, "holding_registers", 30, 64)
    assert error.value.exception_code == 2
