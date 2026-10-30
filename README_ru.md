# Modbus Connector

Единственный desktop-интерфейс — Flutter для Windows/Linux. Qt GUI удалён.
Desktop использует асинхронный backend на Dart и нативную libserialport;
Python и отдельный backend-процесс не требуются.

```bash
cd flutter_app
flutter pub get
flutter run -d linux  # Windows: -d windows
flutter build linux --release
```

Режимы: Master, Simulator, пассивный RTU Sniffer, Gateway. Поддерживаются
TCP/RTU/RTU over TCP/UDP, карты регистров, выражения, графики, CSV/JSONL,
шаблоны с историей и WebDAV. Старые Qt JSON доступны для явного импорта.
Данные Flutter остаются в `~/.modbus_connector/flutter/`.

См. [руководство Flutter](flutter_app/README.md) и [README](README.md).
Python-пакет сохранён отдельно для CLI/MCP и проверки совместимости backend.
