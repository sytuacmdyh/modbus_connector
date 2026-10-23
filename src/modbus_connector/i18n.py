"""Мини-i18n без .ts/.qm: английский исходник — ключ, перевод — в RU/ZH.

Только отображаемые строки: внутренние значения (RegisterKind, форматы,
порядки байт, ключи настроек) никогда не переводятся — они persist'ятся в JSON.
Переводы добавляются инкрементально; отсутствующий ключ → английский.
"""

import re

from PySide6.QtCore import QCoreApplication, QLibraryInfo, QLocale, QObject, QTranslator, Signal

from modbus_connector.backend import BackendError, ModbusExceptionError
from modbus_connector.models import EXCEPTION_CODES

LANGUAGES = ("en", "ru", "zh_CN")
LANGUAGE_NAMES = {"en": "English", "ru": "Русский", "zh_CN": "简体中文"}

RU: dict[str, str] = {
    "Public templates":
        "Общие шаблоны",
    "Custom templates":
        "Пользовательские шаблоны",
    "Save as custom template…":
        "Сохранить как пользовательский шаблон…",
    "Save new version":
        "Сохранить новую версию",
    "Manage custom templates…":
        "Управление пользовательскими шаблонами…",
    "Manage custom templates":
        "Управление пользовательскими шаблонами",
    "Open a version, edit it, then save a new version.":
        "Откройте версию, измените и сохраните новую версию.",
    "Open version":
        "Открыть версию",
    "Rename…":
        "Переименовать…",
    "Delete template…":
        "Удалить шаблон…",
    "Delete version…":
        "Удалить версию…",
    "Template name:":
        "Название шаблона:",
    "Delete this custom template and all its versions?":
        "Удалить этот шаблон и все его версии?",
    "Delete this saved version?":
        "Удалить эту сохранённую версию?",
    "Custom template version saved.":
        "Версия пользовательского шаблона сохранена.",
    "Invalid custom template ID.":
        "Недопустимый идентификатор шаблона.",
    "Invalid custom template file.":
        "Некорректный файл шаблона.",
    "Invalid custom template version.":
        "Некорректная версия шаблона.",
    "Custom template version not found.":
        "Версия шаблона не найдена.",
    "Template name cannot be empty.":
        "Название шаблона не может быть пустым.",
    "Invalid custom template state.":
        "Некорректное содержимое шаблона.",
    "Cannot delete the last version; delete the template instead.":
        "Нельзя удалить последнюю версию; удалите шаблон целиком.",
    # backend errors (rendered in the current UI language)
    "Could not connect to {description}": "Не удалось подключиться к {description}",
    "Read {kind}@{address} failed": "Ошибка чтения {kind}@{address}",
    "Write {kind}@{address} failed": "Ошибка записи {kind}@{address}",
    "No values to write": "Нет значений для записи",
    "Writing {kind} is unsupported (only coils/holding_registers)":
        "Запись в {kind} не поддерживается (только coils/holding_registers)",
    "{name} out of range 0..65535: {value}": "{name} вне диапазона 0..65535: {value}",
    "Mask write @{address} failed": "Ошибка mask write @{address}",
    "Read count out of range 1..125: {count}": "Количество чтения вне диапазона 1..125: {count}",
    "Register value out of range 0..65535: {value}":
        "Значение регистра вне диапазона 0..65535: {value}",
    "Read/write @{address} failed": "Ошибка чтения/записи @{address}",
    "Read device ID unit={unit} failed": "Ошибка чтения идентификатора unit={unit}",
    "Diagnostic loopback failed": "Ошибка диагностического эха",
    "Clear diagnostic counters failed": "Ошибка сброса диагностических счётчиков",
    "Connection lost while scanning unit={unit}":
        "Соединение потеряно при сканировании unit={unit}",
    "Connection lost while scanning addresses unit={unit}":
        "Соединение потеряно при сканировании адресов unit={unit}",
    "Not connected to a Modbus device": "Нет подключения к Modbus-устройству",
    "No response or incomplete frame: expected at least {expected} bytes, received {received}":
        "Устройство не ответило или кадр неполный: ожидалось не менее {expected} байт, "
        "получено {received}",
    "No response from the device (timeout or invalid response)":
        "Устройство не ответило (таймаут или неверный ответ)",
    "Unable to decode the device response": "Не удалось декодировать ответ устройства",
    "Illegal Function": "Недопустимая функция",
    "Illegal Data Address": "Недопустимый адрес данных",
    "Illegal Data Value": "Недопустимое значение данных",
    "Slave Device Failure": "Ошибка устройства",
    "Acknowledge": "Подтверждение",
    "Slave Device Busy": "Устройство занято",
    "Memory Parity Error": "Ошибка чётности памяти",
    "Gateway Path Unavailable": "Путь шлюза недоступен",
    "Gateway Target Device Failed to Respond": "Целевое устройство шлюза не отвечает",
    "Exception": "Исключение",
    # main window
    "File": "Файл",
    "Save Settings to File…": "Сохранить настройки в файл…",
    "Load Settings from File…": "Загрузить настройки из файла…",
    "View": "Вид",
    "Theme": "Тема",
    "Language": "Язык",
    "System": "Системная",
    "Light": "Светлая",
    "Dark": "Тёмная",
    "Save Settings": "Сохранить настройки",
    "Load Settings": "Загрузить настройки",
    "Templates": "Шаблоны",
    "(empty)": "(пусто)",
    "Tx: {total}  Err: {errors} ({percent:.1f}%)  Avg: {avg:.0f} ms":
        "Запросов: {total}  Ошибок: {errors} ({percent:.1f}%)  Среднее: {avg:.0f} мс",
    "  top: {kind}": "  частая: {kind}",
    "no errors yet": "ошибок пока нет",
    # session widget
    "New connection": "Новое подключение",
    "Scanner…": "Сканер…",
    "Graph…": "График…",
    "Log": "Лог",
    "Modbus Scanner": "Сканер Modbus",
    # connection panel
    "Host:": "Хост:",
    "Port:": "Порт:",
    "Baud:": "Скорость:",
    "Bits:": "Биты:",
    "Parity:": "Чётность:",
    "Stop:": "Стоп:",
    "Unit:": "Юнит:",
    "Timeout:": "Таймаут:",
    "Connect": "Подключиться",
    "Disconnect": "Отключиться",
    "Device ID…": "ID устройства…",
    "Diagnostics…": "Диагностика…",
    "Refresh": "Обновить",
    "Serial-line diagnostics (0x08); some TCP devices answer it too":
        "Диагностика последовательной линии (0x08); "
        "некоторые TCP-устройства тоже отвечают",
    "Disconnected": "Отключено",
    "Disconnecting…": "Отключение…",
    "(idle)": "(простой)",
    "Invalid settings": "Неверные настройки",
    "RTU over TCP": "RTU через TCP",
    "RTU over UDP": "RTU через UDP",
    "Device identification (0x2B/0x0E)": "Идентификация устройства (0x2B/0x0E)",
    "Reading…": "Чтение…",
    "(device reported no objects)": "(устройство не вернуло объекты)",
    "Diagnostics (function 0x08)": "Диагностика (функция 0x08)",
    "Loopback": "Эхо-запрос",
    "Clear counters": "Сбросить счётчики",
    "mismatch": "не совпадает",
    # registers panel
    "Name": "Имя",
    "Type": "Тип",
    "Address": "Адрес",
    "Count": "Кол-во",
    "Unit ID": "Unit ID",
    "Poll, ms": "Poll, мс",
    "Format": "Формат",
    "Value": "Значение",
    "New value": "Новое значение",
    "Trend": "Тренд",
    "Enter in 'New value' = write raw values (no scale/offset applied), "
    "Ctrl/Cmd+R = read current row, Ctrl/Cmd+Shift+R = read all rows":
        "Enter в «New value» — запись сырых значений (без scale/offset), "
        "Ctrl/Cmd+R — чтение текущей строки, Ctrl/Cmd+Shift+R — прочитать все",
    "Add register": "Добавить регистр",
    "Read all": "Прочитать все",
    "Read every row once (Ctrl/Cmd+Shift+R)":
        "Прочитать каждую строку один раз (Ctrl/Cmd+Shift+R)",
    "Group reads": "Объединять чтения",
    "Enable trends by default": "Тренды по умолчанию",
    "Enable trend": "Включить тренд",
    "Disable trend": "Выключить тренд",
    "Merge adjacent addresses of the polling tick and Read all into "
    "one request; falls back to per-row reads if a grouped read fails":
        "Объединять соседние адреса тика опроса и «Прочитать все» в один "
        "запрос; при ошибке объединённого чтения — откат на чтение по строкам",
    "✗ grouped read {kind}@{address} ({count}): {error}"
    " — retrying rows individually":
        "✗ объединённое чтение {kind}@{address} ({count}): {error}"
        " — повтор по строкам",
    "Sort by address": "Сортировать по адресу",
    "Mask write (0x16)…": "Запись по маске (0x16)…",
    "Set or clear individual bits of a holding register without touching "
    "others: result = (value AND and-mask) OR (or-mask AND NOT and-mask). "
    "Typical use: bit fields in PLC configuration registers.":
        "Установить или сбросить отдельные биты holding-регистра, не трогая "
        "остальные: result = (value AND and-mask) OR (or-mask AND NOT and-mask). "
        "Типичное применение — битовые поля в регистрах конфигурации ПЛК.",
    "Read/Write (0x17)…": "Чтение/запись (0x17)…",
    "Atomic transaction: write holding registers and read others in a "
    "single Modbus exchange (function 0x17). Used when a device requires "
    "read-modify-write without a race window.":
        "Атомарная транзакция: запись holding-регистров и чтение других "
        "в одном обмене Modbus (функция 0x17). Нужна, когда устройство требует "
        "read-modify-write без гонок.",
    "Filter…": "Фильтр…",
    "Show checked rows only": "Показывать только отмеченные строки",
    "Display…": "Отображение…",
    "Per-row Scale/Offset/Unit and byte order settings":
        "Scale/Offset/Unit и порядок байт для каждой строки",
    "Import/export the register table as CSV":
        "Импорт/экспорт таблицы регистров в CSV",
    "Import table…": "Импорт таблицы…",
    "Export…": "Экспорт…",
    "Log to file": "Запись в файл",
    "Logging settings…": "Настройки записи…",
    "Log read values to a file (CSV or JSON Lines)":
        "Записывать прочитанные значения в файл (CSV или JSON Lines)",
    "Logging to {path} — click to stop":
        "Запись в {path} — нажмите для остановки",
    "Order:": "Порядок:",
    "Default byte order for 32/64-bit formats "
    "(rows without an explicit order inherit it)":
        "Порядок байт по умолчанию для 32/64-битных форматов "
        "(строки без явного порядка наследуют его)",
    "Interval:": "Интервал:",
    "Poll all rows with the Interval period; the dropdown chooses whether "
    "value history is recorded for sparklines and the graph window "
    "(bounded buffer, ~10k samples per row)":
        "Опрос всех строк с заданным интервалом; в выпадающем меню выбирается, "
        "записывать ли историю значений для спарклайнов и окна графика "
        "(буфер ограничен ~10 тыс. отсчётов на строку)",
    "Start polling": "Начать опрос",
    "Start polling and record": "Начать опрос с записью",
    "Stop polling": "Остановить опрос",
    "Modbus unit 1..247, empty = unit from the connection panel":
        "Modbus unit 1..247, пусто = unit из панели подключения",
    "Per-row poll interval in ms, empty = global interval; "
    "a row with its own interval is polled by a dedicated timer":
        "Интервал опроса строки в мс, пусто = общий интервал; "
        "строку со своим интервалом опрашивает отдельный таймер",
    "Display format (registers only; coils/discrete show 0/1)":
        "Формат отображения (только регистры; coils/discrete показывают 0/1)",
    "Delete row": "Удалить строку",
    "Poll this row": "Опрашивать строку",
    "Poll this row; drag in this column to invert multiple rows":
        "Опрашивать строку; проведите по столбцу, чтобы инвертировать несколько строк",
    "Select all / deselect all rows": "Выбрать все / снять выбор со всех строк",
    # expressions block
    "Expressions": "Выражения",
    "Computed rows over register values ([name] references), "
    "with their own sparklines and graph series":
        "Вычисляемые строки над значениями регистров (ссылки [имя]), "
        "со своими спарклайнами и рядами графика",
    "Add expression": "Добавить выражение",
    "Add a computed row; [name] references a register row's "
    "scaled value, e.g. ([temp] + [flow]) / 2":
        "Добавить вычисляемую строку; [имя] — ссылка на масштабированное "
        "значение строки регистров, например ([temp] + [flow]) / 2",
    "Expression": "Выражение",
    "Delete expression": "Удалить выражение",
    "Expressions compute over scaled row values: [name] is a row "
    "reference, functions abs/sqrt/sin/… and pi/e are available":
        "Выражения вычисляются над масштабированными значениями строк: "
        "[имя] — ссылка на строку, доступны функции abs/sqrt/sin/… и pi/e",
    "Move up": "Переместить вверх",
    "Move down": "Переместить вниз",
    "Copy value": "Копировать значение",
    "Write 0": "Записать 0",
    "Write 1": "Записать 1",
    "Increment": "Увеличить",
    "Decrement": "Уменьшить",
    "Toggle": "Переключить",
    "Clear history": "Очистить историю",
    # registers panel: dialogs and log lines
    "Per-row display settings": "Настройки отображения строк",
    "Value names": "Имена значений",
    "Value names…": "Имена значений…",
    "Value names (selected row):": "Имена значений (выбранная строка):",
    "One 'value=name' per line, e.g. 0=Stopped; a matching integer value "
    "shows as 'name (N)' and the row's New value cell becomes a combo.":
        "По строке «значение=имя», например 0=Остановлен; совпавшее целое "
        "показывается как «имя (N)», а поле New value строки становится комбо.",
    "One 'value=name' per line, e.g. 0=Stopped; a matching integer value "
    "shows as 'name (N)' and the Value cell of a manual row becomes a combo.":
        "По строке «значение=имя», например 0=Остановлен; совпавшее целое "
        "показывается как «имя (N)», а ячейка Value ручной строки становится "
        "комбо.",
    "Name integer values of the current row (enum), e.g. 0=Off, 1=On":
        "Имена целых значений текущей строки (enum), например 0=Выкл, 1=Вкл",
    "Bitmask (16 named bits)": "Битовая маска (16 именованных битов)",
    "Edit bits": "Правка битов",
    "Edit bits…": "Биты…",
    "Treat the u16 value as 16 named bits: value names label bits 0..15, "
    "the Value cell lists the set bits and New value becomes a button "
    "opening a bit checkbox dialog.":
        "Трактовать значение u16 как 16 именованных битов: имена значений "
        "подписывают биты 0..15, ячейка Value перечисляет установленные биты, "
        "а New value становится кнопкой, открывающей диалог с галочками битов.",
    "Treat the u16 value as 16 named bits: value names label bits 0..15, "
    "the Value cell lists the set bits and a manual row's cell becomes "
    "a button opening a bit checkbox dialog.":
        "Трактовать значение u16 как 16 именованных битов: имена значений "
        "подписывают биты 0..15, ячейка Value перечисляет установленные биты, "
        "а у ручной строки она становится кнопкой, открывающей диалог "
        "с галочками битов.",
    "Scale": "Scale",
    "Offset": "Offset",
    "Unit": "Ед.",
    "default": "по умолчанию",
    "Rows added or deleted while this dialog is open appear after reopening it.":
        "Строки, добавленные или удалённые при открытом диалоге, "
        "появятся после его повторного открытия.",
    "Mask write (function 0x16)": "Mask write (функция 0x16)",
    "empty = global unit": "пусто = общий unit",
    "Set/clear bits of one holding register:\n"
    "result = (value AND and-mask) OR (or-mask AND NOT and-mask).\n"
    "Masks accept decimal or hex (e.g. 0xFF0F).":
        "Установка/сброс битов одного holding-регистра:\n"
        "result = (value AND and-mask) OR (or-mask AND NOT and-mask).\n"
        "Маски принимаются в dec или hex (например, 0xFF0F).",
    "AND mask:": "AND-маска:",
    "OR mask:": "OR-маска:",
    "Read/Write multiple registers (function 0x17)":
        "Read/Write нескольких регистров (функция 0x17)",
    "comma/space separated, hex ok": "через запятую/пробел, можно hex",
    "One atomic exchange: write Values at Write address, then read\n"
    "Read count registers from Read address; read values go to the log.\n"
    "Addresses accept decimal or hex (e.g. 0x10).":
        "Один атомарный обмен: записать Values по Write address, затем прочитать\n"
        "Read count регистров с Read address; прочитанное попадает в лог.\n"
        "Адреса принимаются в dec или hex (например, 0x10).",
    "Write address:": "Адрес записи:",
    "Values:": "Значения:",
    "Read address:": "Адрес чтения:",
    "Read count:": "Кол-во чтения:",
    "Import registers from CSV": "Импорт регистров из CSV",
    "Export registers to CSV": "Экспорт регистров в CSV",
    "✗ failed to read {path}: {exc}": "✗ не удалось прочитать {path}: {exc}",
    "✗ failed to import {path}: {exc}": "✗ не удалось импортировать {path}: {exc}",
    "✗ failed to write {path}: {exc}": "✗ не удалось записать {path}: {exc}",
    "✗ failed to load template {name}: {exc}": "✗ не удалось загрузить шаблон {name}: {exc}",
    "← imported {count} rows from {path}":
        "← импортировано строк: {count} из {path}",
    "→ exported {count} rows to {path}": "→ экспортировано строк: {count} в {path}",
    "✗ export: no columns selected": "✗ экспорт: не выбраны колонки",
    "✗ mask write: invalid address/mask (dec or 0x… hex)":
        "✗ mask write: неверный адрес/маска (dec или 0x… hex)",
    "✗ mask write: address/mask out of range 0..0xFFFF":
        "✗ mask write: адрес/маска вне диапазона 0..0xFFFF",
    "✗ read/write: invalid address (dec or 0x… hex)":
        "✗ read/write: неверный адрес (dec или 0x… hex)",
    "✗ read/write: address out of range 0..0xFFFF":
        "✗ read/write: адрес вне диапазона 0..0xFFFF",
    "✗ parse error: {exc}": "✗ ошибка разбора: {exc}",
    "← read/write read values: {values}": "← read/write прочитано: {values}",
    "✗ row {row}: invalid address/count": "✗ строка {row}: неверный адрес/кол-во",
    "✗ row {row}: {kind} is a read-only area":
        "✗ строка {row}: область {kind} только для чтения",
    "✗ row {row}: read the row before +/-":
        "✗ строка {row}: сначала прочитайте строку (для +/-)",
    "✗ row {row}: read the row before toggling":
        "✗ строка {row}: сначала прочитайте строку (для переключения)",
    "← scanner: added {added} rows to the table":
        "← сканер: добавлено строк в таблицу: {added}",
    ", skipped {skipped} duplicates": ", пропущено дублей: {skipped}",
    "✗ logging: cannot open {path}: {exc}":
        "✗ запись: не удалось открыть {path}: {exc}",
    "→ logging values to {path} ({format})":
        "→ запись значений в {path} ({format})",
    "← logging stopped: {rows} rows written to {path}":
        "← запись остановлена: записано строк: {rows} в {path}",
    # alarms dialog and log lines
    "Alarms…": "Алармы…",
    "Per-row alarm rules: highlight, log and beep when the scaled "
    "value matches a condition":
        "Правила алармов по строкам: подсветка, лог и звук, когда "
        "масштабированное значение совпадает с условием",
    "Alarm rules": "Правила алармов",
    "Condition": "Условие",
    "Value 2": "Значение 2",
    "Color": "Цвет",
    "Sound": "Звук",
    "in range": "в диапазоне",
    "outside range": "вне диапазона",
    "red": "красный",
    "yellow": "жёлтый",
    "Add": "Добавить",
    "Remove": "Удалить",
    "Up": "Вверх",
    "Down": "Вниз",
    "The first matching rule wins; Value 2 is used by the range conditions":
        "Срабатывает первое совпавшее правило; Значение 2 используется "
        "условиями диапазона",
    "Rule value must be a number": "Значение правила должно быть числом",
    "ALARM {label}: {value} {condition}": "АЛАРМ {label}: {value} {condition}",
    "ALARM cleared {label}": "АЛАРМ снят: {label}",
    # snapshot diff
    "Snapshot": "Снапшот",
    "Remember current values of all rows for later comparison":
        "Запомнить текущие значения всех строк для последующего сравнения",
    "Diff…": "Сравнение…",
    "Compare the snapshot with the current values":
        "Сравнить снапшот с текущими значениями",
    "Snapshot taken: {count} rows": "Снапшот снят: строк: {count}",
    "Snapshot diff": "Сравнение со снапшотом",
    "Snapshot taken at {time}": "Снапшот снят в {time}",
    "Only differences": "Только различия",
    "Take new snapshot": "Снять новый снапшот",
    "Current": "Текущее",
    "(removed)": "(удалена)",
    # CSV dialogs
    "Export CSV": "Экспорт CSV",
    "Choose columns to export and their order":
        "Выберите колонки для экспорта и их порядок",
    "Select all": "Выбрать все",
    "Select none": "Снять выбор",
    "Import CSV": "Импорт CSV",
    "Match file columns to register fields":
        "Сопоставьте колонки файла полям регистров",
    "File column": "Колонка файла",
    "Maps to": "Соответствует",
    "— skip —": "— пропустить —",
    "Map the essential fields: {fields}":
        "Сопоставьте обязательные поля: {fields}",
    # logging settings dialog
    "Logging settings": "Настройки записи",
    "Log file path": "Путь к файлу записи",
    "Browse…": "Обзор…",
    "Timestamp": "Метка времени",
    "Row name": "Имя строки",
    "Register type": "Тип регистра",
    "Append to the file if it exists": "Дописывать в существующий файл",
    "Rows to log": "Записываемые строки",
    "File:": "Файл:",
    "Format:": "Формат:",
    "Fields:": "Поля:",
    "Log values to file": "Запись значений в файл",
    "Choose a log file": "Выберите файл записи",
    # log panel
    "Clear": "Очистить",
    "Raw": "Raw",
    "Save…": "Сохранить…",
    "Save Log": "Сохранить лог",
    "✗ failed to save log to {path}: {exc}":
        "✗ не удалось сохранить лог в {path}: {exc}",
    "→ log saved to {path}": "→ лог сохранён в {path}",
    # worker log lines
    "Connected ({desc})": "Подключено ({desc})",
    "→ connect {desc}": "→ подключение {desc}",
    "✗ connect failed: {exc}": "✗ подключение не удалось: {exc}",
    "← connected": "← подключено",
    "✗ disconnect failed: {exc}": "✗ отключение не удалось: {exc}",
    "→ disconnect": "→ отключение",
    "→ read {kind} unit={unit} addr={address} count={count}":
        "→ чтение {kind} unit={unit} адр={address} кол-во={count}",
    "✗ read failed: {exc}": "✗ чтение не удалось: {exc}",
    "→ write {kind} unit={unit} addr={address} values={values}":
        "→ запись {kind} unit={unit} адр={address} значения={values}",
    "✗ write failed: {exc}": "✗ запись не удалась: {exc}",
    "← ok": "← ok",
    "→ mask write unit={unit} addr={address} and=0x{and_mask:04x} "
    "or=0x{or_mask:04x}":
        "→ mask write unit={unit} адр={address} and=0x{and_mask:04x} "
        "or=0x{or_mask:04x}",
    "✗ mask write failed: {exc}": "✗ mask write не удался: {exc}",
    "→ read/write unit={unit} read@{read_address} x{read_count} "
    "write@{write_address} values={values}":
        "→ read/write unit={unit} чтение@{read_address} x{read_count} "
        "запись@{write_address} значения={values}",
    "✗ read/write failed: {exc}": "✗ read/write не удался: {exc}",
    "→ read device id unit={unit}": "→ чтение ID устройства unit={unit}",
    "✗ read device id failed: {exc}": "✗ чтение ID устройства не удалось: {exc}",
    "← device id: {count} objects": "← ID устройства: объектов: {count}",
    "→ diag loopback unit={unit}": "→ diag эхо unit={unit}",
    "✗ diag loopback failed: {exc}": "✗ diag эхо не удалось: {exc}",
    "← loopback ok": "← эхо ok",
    "← loopback mismatch": "← эхо не совпадает",
    "→ diag counters unit={unit}": "→ diag счётчики unit={unit}",
    "✗ diag counters failed: {exc}": "✗ diag счётчики не удались: {exc}",
    "← diag counters: {counters}": "← diag счётчики: {counters}",
    "→ diag clear counters unit={unit}": "→ diag сброс счётчиков unit={unit}",
    "✗ diag clear counters failed: {exc}":
        "✗ diag сброс счётчиков не удался: {exc}",
    "← counters cleared": "← счётчики сброшены",
    "→ scan units {start}..{end} ({count} probes)":
        "→ скан unit-адресов {start}..{end} (проб: {count})",
    "← scan hit unit={unit} probes={indices}":
        "← найден unit={unit} пробы={indices}",
    "✗ scan failed: {exc}": "✗ скан не удался: {exc}",
    "← scan stopped": "← скан остановлен",
    "← scan finished": "← скан завершён",
    "→ scan addresses {kind} unit={unit} {start}..{end}":
        "→ скан адресов {kind} unit={unit} {start}..{end}",
    "← addr scan hit {kind}@{address} = {values}":
        "← найден адрес {kind}@{address} = {values}",
    "✗ address scan failed: {exc}": "✗ скан адресов не удался: {exc}",
    "← address scan stopped": "← скан адресов остановлен",
    "← address scan finished": "← скан адресов завершён",
    # main window file dialogs and log lines
    "✗ failed to save settings to {path}: {exc}":
        "✗ не удалось сохранить настройки в {path}: {exc}",
    "→ settings saved to {path}": "→ настройки сохранены в {path}",
    "✗ failed to load settings from {path}: {exc}":
        "✗ не удалось загрузить настройки из {path}: {exc}",
    "✗ failed to load settings from {path}: not an object":
        "✗ не удалось загрузить настройки из {path}: не объект",
    "← settings loaded from {path}": "← настройки загружены из {path}",
    # session widget log line
    "→ unit {unit} selected in connection panel":
        "→ unit {unit} выбран в панели подключения",
    # slave mode / sim panel
    "Mode:": "Режим:",
    "Master": "Мастер",
    "Slave": "Слейв",
    "Simulator": "Симулятор",
    "Start server": "Запустить сервер",
    "Stop server": "Остановить сервер",
    "Stopped": "Остановлен",
    "any": "любой",
    "Add row": "Добавить строку",
    "Add a row to the register map": "Добавить строку в карту регистров",
    "Template…": "Шаблон…",
    "Add rows from a device template": "Добавить строки из шаблона устройства",
    "clients: {count}": "клиентов: {count}",
    "← template: added {added} rows to the map":
        "← шаблон: добавлено строк в карту: {added}",
    "Rule": "Правило",
    "Rule text": "Текст правила",
    "Tick, ms": "Тик, мс",
    # sim worker log lines
    "→ start simulator {desc}": "→ запуск симулятора {desc}",
    "✗ simulator start failed: {exc}": "✗ запуск симулятора не удался: {exc}",
    "← simulator running ({desc})": "← симулятор работает ({desc})",
    "Simulator running ({desc})": "Симулятор работает ({desc})",
    "✗ simulator stop failed: {exc}": "✗ остановка симулятора не удалась: {exc}",
    "→ simulator stopped": "→ симулятор остановлен",
    "✗ simulator set values failed: {exc}":
        "✗ запись значений симулятора не удалась: {exc}",
    "✗ simulator get values failed: {exc}":
        "✗ чтение значений симулятора не удалось: {exc}",
    "← client connected {address}": "← клиент подключился {address}",
    "→ client disconnected {address}": "→ клиент отключился {address}",
    # sniffer mode / sniffer panel
    "Sniffer": "Сниффер",
    "Start sniffing": "Начать сниффинг",
    "Stop sniffing": "Остановить сниффинг",
    "unit {unit}": "юнит {unit}",
    "Listening ({desc})": "Слушаем ({desc})",
    "Export CSV…": "Экспорт CSV…",
    "Live graph of this unit's rows": "Живой график строк этого unit",
    "Export rows to CSV in the master table format":
        "Экспорт строк в CSV в формате master-таблицы",
    # sniffer worker log lines
    "→ start sniffer {desc}": "→ запуск сниффера {desc}",
    "✗ sniffer start failed: {exc}": "✗ запуск сниффера не удался: {exc}",
    "← sniffer listening ({desc})": "← сниффер слушает ({desc})",
    "→ sniffer stopped": "→ сниффер остановлен",
    "✗ sniffer stop failed: {exc}": "✗ остановка сниффера не удалась: {exc}",
    "✗ sniffer: {message}": "✗ сниффер: {message}",
    # gateway mode / gateway panel
    "Gateway": "Шлюз",
    "Listen:": "Приём:",
    "Target:": "Цель:",
    "Units:": "Юниты:",
    "Units to serve: empty = all 1..247; comma-separated ids and ranges, "
    "e.g. 1, 5, 10-20; other units get no answer (master times out)":
        "Обслуживаемые unit: пусто = все 1..247; id и диапазоны через запятую, "
        "например 1, 5, 10-20; остальным шлюз не отвечает (таймаут у мастера)",
    "Start gateway": "Запустить шлюз",
    "Stop gateway": "Остановить шлюз",
    "Gateway running ({desc})": "Шлюз работает ({desc})",
    "← gateway client connected": "← клиент шлюза подключился",
    "→ gateway client disconnected": "→ клиент шлюза отключился",
    # gateway worker log lines
    "→ start gateway {desc}": "→ запуск шлюза {desc}",
    "✗ gateway start failed: {exc}": "✗ запуск шлюза не удался: {exc}",
    "← gateway running ({desc})": "← шлюз работает ({desc})",
    "✗ gateway stop failed: {exc}": "✗ остановка шлюза не удалась: {exc}",
    "→ gateway stopped": "→ шлюз остановлен",
    "✗ gateway: {message}": "✗ шлюз: {message}",
    # scanner panel
    "Add probe": "Добавить пробу",
    "Start scan": "Начать сканирование",
    "Stop": "Стоп",
    "Delete": "Удалить",
    "Start": "Старт",
    "All": "Все",
    "None": "Ни одного",
    "Add selected to table": "Добавить отмеченные в таблицу",
    "Add one row per checked address to the registers table":
        "Добавить по строке на каждый отмеченный адрес в таблицу регистров",
    "Double-click a unit to select it for the connection":
        "Двойной клик по unit выбирает его для подключения",
    "Read the selected unit's identification (function 0x2B/0x0E)":
        "Прочитать идентификацию выбранного unit (функция 0x2B/0x0E)",
    "Unit range:": "Диапазон unit:",
    "Type:": "Тип:",
    "Addresses:": "Адреса:",
    "Address:": "Адрес:",
    "Results:": "Результаты:",
    "Registers scan:": "Скан регистров:",
    "Unit {unit} — device identification (0x2B/0x0E)":
        "Unit {unit} — идентификация устройства (0x2B/0x0E)",
    "Unit {unit}: {labels}": "Unit {unit}: {labels}",
    "Bool": "Логич.",
    # graph window
    "Graph": "График",
    "Refresh rows": "Обновить строки",
    "Follow": "Следом",
    "Full": "Всё",
    "Manual": "Вручную",
    "Zoom rect": "Зум рамкой",
    "Markers": "Маркеры",
    "Reset view": "Сбросить вид",
    "Clear recorded history and restart the time axis":
        "Очистить записанную историю и перезапустить ось времени",
    "Poll the register table and record value history for this graph":
        "Опрос таблицы регистров с записью истории для этого графика",
    "X scale:": "Шкала X:",
    "Series:": "Ряды:",
    "Series": "Ряды",
    "Min": "Мин",
    "Max": "Макс",
    "Avg": "Сред",
    "time, s (relative)": "время, с (относительное)",
    "Δt = {dt:.4g} s": "Δt = {dt:.4g} с",
    # help dialog
    "Help": "Справка",
    "New connection tab": "Новая вкладка-подключение",
    "Registers — Help": "Таблица регистров — справка",
    "Graph — Help": "График — справка",
    "Scanner — Help": "Сканер — справка",
    "Expressions — Help": "Выражения — справка",
    "Simulator — Help": "Симулятор — справка",
    "Sniffer — Help": "Сниффер — справка",
    "Gateway — Help": "Шлюз — справка",
}


ZH_CN: dict[str, str] = {
    "Public templates":
        "公共模板",
    "Custom templates":
        "用户自定义模板",
    "Save as custom template…":
        "另存为自定义模板…",
    "Save new version":
        "保存新版本",
    "Manage custom templates…":
        "管理自定义模板…",
    "Manage custom templates":
        "管理自定义模板",
    "Open a version, edit it, then save a new version.":
        "打开历史版本，编辑后可保存为新版本。",
    "Open version":
        "打开版本",
    "Rename…":
        "重命名…",
    "Delete template…":
        "删除模板…",
    "Delete version…":
        "删除版本…",
    "Template name:":
        "模板名称：",
    "Delete this custom template and all its versions?":
        "删除此自定义模板及其所有历史版本？",
    "Delete this saved version?":
        "删除此历史版本？",
    "Custom template version saved.":
        "自定义模板版本已保存。",
    "Invalid custom template ID.":
        "无效的自定义模板标识。",
    "Invalid custom template file.":
        "自定义模板文件无效。",
    "Invalid custom template version.":
        "自定义模板版本无效。",
    "Custom template version not found.":
        "未找到此自定义模板版本。",
    "Template name cannot be empty.":
        "模板名称不能为空。",
    "Invalid custom template state.":
        "自定义模板内容无效。",
    "Cannot delete the last version; delete the template instead.":
        "不能单独删除最后一个版本，请删除整个模板。",
    # backend errors (rendered in the current UI language)
    "Could not connect to {description}": "无法连接到 {description}",
    "Read {kind}@{address} failed": "读取 {kind}@{address} 失败",
    "Write {kind}@{address} failed": "写入 {kind}@{address} 失败",
    "No values to write": "没有要写入的值",
    "Writing {kind} is unsupported (only coils/holding_registers)":
        "不支持写入 {kind}（仅支持 coils/holding_registers）",
    "{name} out of range 0..65535: {value}": "{name} 超出范围 0..65535：{value}",
    "Mask write @{address} failed": "掩码写入 @{address} 失败",
    "Read count out of range 1..125: {count}": "读取数量超出范围 1..125：{count}",
    "Register value out of range 0..65535: {value}": "寄存器值超出范围 0..65535：{value}",
    "Read/write @{address} failed": "读写 @{address} 失败",
    "Read device ID unit={unit} failed": "读取从站 {unit} 的设备标识失败",
    "Diagnostic loopback failed": "诊断回环失败",
    "Clear diagnostic counters failed": "清除诊断计数器失败",
    "Connection lost while scanning unit={unit}": "扫描从站 {unit} 时连接丢失",
    "Connection lost while scanning addresses unit={unit}": "扫描从站 {unit} 的地址时连接丢失",
    "Not connected to a Modbus device": "尚未连接 Modbus 设备",
    "No response or incomplete frame: expected at least {expected} bytes, received {received}":
        "设备未响应或响应帧不完整：至少需要 {expected} 字节，实际收到 {received} 字节",
    "No response from the device (timeout or invalid response)": "设备未响应（超时或响应无效）",
    "Unable to decode the device response": "无法解析设备响应",
    "Illegal Function": "不支持的功能码",
    "Illegal Data Address": "非法数据地址",
    "Illegal Data Value": "非法数据值",
    "Slave Device Failure": "从站设备故障",
    "Acknowledge": "已确认",
    "Slave Device Busy": "从站设备忙",
    "Memory Parity Error": "存储器奇偶校验错误",
    "Gateway Path Unavailable": "网关路径不可用",
    "Gateway Target Device Failed to Respond": "网关目标设备未响应",
    "Exception": "异常",
    # main window
    "File": "文件",
    "Save Settings to File…": "保存设置到文件…",
    "Load Settings from File…": "从文件加载设置…",
    "View": "视图",
    "Theme": "主题",
    "Language": "语言",
    "System": "跟随系统",
    "Light": "浅色",
    "Dark": "深色",
    "Save Settings": "保存设置",
    "Load Settings": "加载设置",
    "Templates": "模板",
    "(empty)": "（空）",
    "Tx: {total}  Err: {errors} ({percent:.1f}%)  Avg: {avg:.0f} ms":
        "请求：{total}  错误：{errors} ({percent:.1f}%)  平均：{avg:.0f} 毫秒",
    "  top: {kind}": "  最常见：{kind}",
    "no errors yet": "暂无错误",
    # session widget
    "New connection": "新建连接",
    "Scanner…": "扫描器…",
    "Graph…": "曲线图…",
    "Log": "日志",
    "Modbus Scanner": "Modbus 扫描器",
    # connection panel
    "Host:": "主机：",
    "Port:": "端口：",
    "Baud:": "波特率：",
    "Bits:": "数据位：",
    "Parity:": "校验位：",
    "Stop:": "停止位：",
    "Unit:": "从站地址：",
    "Timeout:": "超时：",
    "Connect": "连接",
    "Disconnect": "断开连接",
    "Device ID…": "设备标识…",
    "Diagnostics…": "诊断…",
    "Refresh": "刷新",
    "Serial-line diagnostics (0x08); some TCP devices answer it too":
        "串行线路诊断（0x08）；部分 TCP 设备也支持",
    "Disconnected": "未连接",
    "Disconnecting…": "正在断开…",
    "(idle)": "（空闲）",
    "Invalid settings": "设置无效",
    "RTU over TCP": "RTU 透传 TCP",
    "RTU over UDP": "RTU 透传 UDP",
    "Device identification (0x2B/0x0E)": "设备标识（0x2B/0x0E）",
    "Reading…": "正在读取…",
    "(device reported no objects)": "（设备未返回任何对象）",
    "Diagnostics (function 0x08)": "诊断（功能码 0x08）",
    "Loopback": "回环测试",
    "Clear counters": "清除计数器",
    "mismatch": "不匹配",
    # registers panel
    "Name": "名称",
    "Type": "类型",
    "Address": "地址",
    "Count": "数量",
    "Unit ID": "从站地址",
    "Poll, ms": "轮询间隔（毫秒）",
    "Format": "格式",
    "Value": "当前值",
    "New value": "新值",
    "Trend": "趋势",
    "Enter in 'New value' = write raw values (no scale/offset applied), "
    "Ctrl/Cmd+R = read current row, Ctrl/Cmd+Shift+R = read all rows":
        "在“新值”中按 Enter 写入原始值（不应用缩放/偏移），"
        "Ctrl/Cmd+R 读取当前行，Ctrl/Cmd+Shift+R 读取所有行",
    "Add register": "添加寄存器",
    "Read all": "读取全部",
    "Read every row once (Ctrl/Cmd+Shift+R)": "读取每行一次（Ctrl/Cmd+Shift+R）",
    "Group reads": "合并读取",
    "Enable trends by default": "默认启用趋势",
    "Enable trend": "启用趋势",
    "Disable trend": "关闭趋势",
    "Merge adjacent addresses of the polling tick and Read all into "
    "one request; falls back to per-row reads if a grouped read fails":
        "轮询和“读取全部”时，将相邻地址合并为一个请求；合并读取失败后逐行重试",
    "✗ grouped read {kind}@{address} ({count}): {error}"
    " — retrying rows individually":
        "✗ 合并读取 {kind}@{address}（{count}）：{error} — 正在逐行重试",
    "Sort by address": "按地址排序",
    "Mask write (0x16)…": "掩码写入（0x16）…",
    "Set or clear individual bits of a holding register without touching "
    "others: result = (value AND and-mask) OR (or-mask AND NOT and-mask). "
    "Typical use: bit fields in PLC configuration registers.":
        "设置或清除保持寄存器中的指定位，其他位不变："
        "result = (value AND and-mask) OR (or-mask AND NOT and-mask)。"
        "常用于 PLC 配置寄存器的位字段。",
    "Read/Write (0x17)…": "读写寄存器（0x17）…",
    "Atomic transaction: write holding registers and read others in a "
    "single Modbus exchange (function 0x17). Used when a device requires "
    "read-modify-write without a race window.":
        "原子事务：在一次 Modbus 交互中写入保持寄存器并读取其他寄存器（功能码 0x17）。"
        "用于需要避免读改写竞争的设备。",
    "Filter…": "筛选…",
    "Show checked rows only": "仅显示勾选行",
    "Display…": "显示设置…",
    "Per-row Scale/Offset/Unit and byte order settings": "每行的缩放、偏移、单位和字节序设置",
    "Import/export the register table as CSV": "以 CSV 格式导入/导出寄存器表",
    "Import table…": "导入表格…",
    "Export…": "导出…",
    "Log to file": "记录到文件",
    "Logging settings…": "记录设置…",
    "Log read values to a file (CSV or JSON Lines)": "将读取值记录到文件（CSV 或 JSON Lines）",
    "Logging to {path} — click to stop": "正在记录到 {path} — 点击停止",
    "Order:": "字节序：",
    "Default byte order for 32/64-bit formats "
    "(rows without an explicit order inherit it)":
        "32/64 位格式的默认字节序（未单独指定的行继承此设置）",
    "Interval:": "间隔：",
    "Poll all rows with the Interval period; the dropdown chooses whether "
    "value history is recorded for sparklines and the graph window "
    "(bounded buffer, ~10k samples per row)":
        "按指定间隔轮询所有行；下拉菜单选择是否为趋势和曲线图记录历史值"
        "（缓冲区有限，每行约 1 万个采样点）",
    "Start polling": "开始轮询",
    "Start polling and record": "开始轮询并记录",
    "Stop polling": "停止轮询",
    "Modbus unit 1..247, empty = unit from the connection panel":
        "Modbus 从站地址 1..247，留空则使用连接面板的从站地址",
    "Per-row poll interval in ms, empty = global interval; "
    "a row with its own interval is polled by a dedicated timer":
        "每行轮询间隔（毫秒），留空则使用全局间隔；单独设置间隔的行使用独立定时器",
    "Display format (registers only; coils/discrete show 0/1)":
        "显示格式（仅用于寄存器；线圈/离散输入显示为 0/1）",
    "Delete row": "删除行",
    "Poll this row": "轮询此行",
    "Poll this row; drag in this column to invert multiple rows":
        "轮询此行；沿此列拖动可翻转多行勾选状态",
    "Select all / deselect all rows": "全选／全部取消",
    # expressions block
    "Expressions": "表达式",
    "Computed rows over register values ([name] references), "
    "with their own sparklines and graph series":
        "基于寄存器值的计算行（通过 [名称] 引用），具有独立的趋势和曲线",
    "Add expression": "添加表达式",
    "Add a computed row; [name] references a register row's "
    "scaled value, e.g. ([temp] + [flow]) / 2":
        "添加计算行；[名称] 引用寄存器行缩放后的值，例如 ([temp] + [flow]) / 2",
    "Expression": "表达式",
    "Delete expression": "删除表达式",
    "Expressions compute over scaled row values: [name] is a row "
    "reference, functions abs/sqrt/sin/… and pi/e are available":
        "表达式使用缩放后的行值计算：[名称] 引用行，可使用 abs/sqrt/sin/… 函数和 pi/e 常量",
    "Move up": "上移",
    "Move down": "下移",
    "Copy value": "复制值",
    "Write 0": "写入 0",
    "Write 1": "写入 1",
    "Increment": "加一",
    "Decrement": "减一",
    "Toggle": "翻转",
    "Clear history": "清除历史",
    # registers panel: dialogs and log lines
    "Per-row display settings": "各行显示设置",
    "Value names": "值名称",
    "Value names…": "值名称…",
    "Value names (selected row):": "值名称（选中行）：",
    "One 'value=name' per line, e.g. 0=Stopped; a matching integer value "
    "shows as 'name (N)' and the row's New value cell becomes a combo.":
        "每行填写“值=名称”，例如 0=停止；匹配的整数显示为“名称 (N)”，"
        "该行的“新值”单元格变为下拉框。",
    "One 'value=name' per line, e.g. 0=Stopped; a matching integer value "
    "shows as 'name (N)' and the Value cell of a manual row becomes a combo.":
        "每行填写“值=名称”，例如 0=停止；匹配的整数显示为“名称 (N)”，"
        "手动行的“当前值”单元格变为下拉框。",
    "Name integer values of the current row (enum), e.g. 0=Off, 1=On":
        "为当前行的整数值命名（枚举），例如 0=关闭，1=开启",
    "Bitmask (16 named bits)": "位掩码（16 个命名位）",
    "Edit bits": "编辑位",
    "Edit bits…": "编辑位…",
    "Treat the u16 value as 16 named bits: value names label bits 0..15, "
    "the Value cell lists the set bits and New value becomes a button "
    "opening a bit checkbox dialog.":
        "将 u16 值视为 16 个命名位：值名称对应位 0..15，“当前值”列出置位项，"
        "“新值”变为按钮，可打开位选择对话框。",
    "Treat the u16 value as 16 named bits: value names label bits 0..15, "
    "the Value cell lists the set bits and a manual row's cell becomes "
    "a button opening a bit checkbox dialog.":
        "将 u16 值视为 16 个命名位：值名称对应位 0..15，“当前值”列出置位项，"
        "手动行的单元格变为按钮，可打开位选择对话框。",
    "Scale": "缩放系数",
    "Offset": "偏移量",
    "Unit": "单位",
    "default": "默认",
    "Rows added or deleted while this dialog is open appear after reopening it.":
        "此对话框打开期间新增或删除的行，将在重新打开后更新。",
    "Mask write (function 0x16)": "掩码写入（功能码 0x16）",
    "empty = global unit": "留空则使用全局从站地址",
    "Set/clear bits of one holding register:\n"
    "result = (value AND and-mask) OR (or-mask AND NOT and-mask).\n"
    "Masks accept decimal or hex (e.g. 0xFF0F).":
        "设置/清除单个保持寄存器的位：\n"
        "result = (value AND and-mask) OR (or-mask AND NOT and-mask)。\n"
        "掩码支持十进制或十六进制（例如 0xFF0F）。",
    "AND mask:": "AND 掩码：",
    "OR mask:": "OR 掩码：",
    "Read/Write multiple registers (function 0x17)": "读写多个寄存器（功能码 0x17）",
    "comma/space separated, hex ok": "逗号/空格分隔，支持十六进制",
    "One atomic exchange: write Values at Write address, then read\n"
    "Read count registers from Read address; read values go to the log.\n"
    "Addresses accept decimal or hex (e.g. 0x10).":
        "一次原子交互：从写入地址写入指定值，再从读取地址\n"
        "读取指定数量的寄存器；读取结果输出到日志。\n"
        "地址支持十进制或十六进制（例如 0x10）。",
    "Write address:": "写入地址：",
    "Values:": "写入值：",
    "Read address:": "读取地址：",
    "Read count:": "读取数量：",
    "Import registers from CSV": "从 CSV 导入寄存器",
    "Export registers to CSV": "将寄存器导出为 CSV",
    "✗ failed to read {path}: {exc}": "✗ 读取 {path} 失败：{exc}",
    "✗ failed to import {path}: {exc}": "✗ 导入 {path} 失败：{exc}",
    "✗ failed to write {path}: {exc}": "✗ 写入 {path} 失败：{exc}",
    "✗ failed to load template {name}: {exc}": "✗ 加载模板 {name} 失败：{exc}",
    "← imported {count} rows from {path}": "← 已从 {path} 导入 {count} 行",
    "→ exported {count} rows to {path}": "→ 已将 {count} 行导出到 {path}",
    "✗ export: no columns selected": "✗ 导出失败：未选择任何列",
    "✗ mask write: invalid address/mask (dec or 0x… hex)":
        "✗ 掩码写入：地址/掩码无效（使用十进制或 0x… 十六进制）",
    "✗ mask write: address/mask out of range 0..0xFFFF":
        "✗ 掩码写入：地址/掩码超出 0..0xFFFF 范围",
    "✗ read/write: invalid address (dec or 0x… hex)":
        "✗ 读写寄存器：地址无效（使用十进制或 0x… 十六进制）",
    "✗ read/write: address out of range 0..0xFFFF": "✗ 读写寄存器：地址超出 0..0xFFFF 范围",
    "✗ parse error: {exc}": "✗ 解析错误：{exc}",
    "← read/write read values: {values}": "← 读写寄存器的读取结果：{values}",
    "✗ row {row}: invalid address/count": "✗ 第 {row} 行：地址/数量无效",
    "✗ row {row}: {kind} is a read-only area": "✗ 第 {row} 行：{kind} 为只读区域",
    "✗ row {row}: read the row before +/-": "✗ 第 {row} 行：加减操作前请先读取该行",
    "✗ row {row}: read the row before toggling": "✗ 第 {row} 行：翻转前请先读取该行",
    "← scanner: added {added} rows to the table": "← 扫描器：已向表格添加 {added} 行",
    ", skipped {skipped} duplicates": "，已跳过 {skipped} 个重复项",
    "✗ logging: cannot open {path}: {exc}": "✗ 记录失败：无法打开 {path}：{exc}",
    "→ logging values to {path} ({format})": "→ 正在将数值记录到 {path}（{format}）",
    "← logging stopped: {rows} rows written to {path}":
        "← 记录已停止：已向 {path} 写入 {rows} 行",
    # alarms dialog and log lines
    "Alarms…": "报警…",
    "Per-row alarm rules: highlight, log and beep when the scaled "
    "value matches a condition": "每行报警规则：缩放后的值满足条件时高亮、记录日志并发出提示音",
    "Alarm rules": "报警规则",
    "Condition": "条件",
    "Value 2": "值 2",
    "Color": "颜色",
    "Sound": "声音",
    "in range": "在范围内",
    "outside range": "在范围外",
    "red": "红色",
    "yellow": "黄色",
    "Add": "添加",
    "Remove": "移除",
    "Up": "上移",
    "Down": "下移",
    "The first matching rule wins; Value 2 is used by the range conditions":
        "使用第一个匹配的规则；“值 2”用于范围条件",
    "Rule value must be a number": "规则值必须为数字",
    "ALARM {label}: {value} {condition}": "报警 {label}：{value} {condition}",
    "ALARM cleared {label}": "报警已解除：{label}",
    # snapshot diff
    "Snapshot": "快照",
    "Remember current values of all rows for later comparison": "保存所有行的当前值，以便后续比较",
    "Diff…": "比较…",
    "Compare the snapshot with the current values": "将快照与当前值比较",
    "Snapshot taken: {count} rows": "已创建快照：{count} 行",
    "Snapshot diff": "快照比较",
    "Snapshot taken at {time}": "快照时间：{time}",
    "Only differences": "仅显示差异",
    "Take new snapshot": "创建新快照",
    "Current": "当前",
    "(removed)": "（已删除）",
    # CSV dialogs
    "Export CSV": "导出 CSV",
    "Choose columns to export and their order": "选择导出的列及其顺序",
    "Select all": "全选",
    "Select none": "全不选",
    "Import CSV": "导入 CSV",
    "Match file columns to register fields": "将文件列映射到寄存器字段",
    "File column": "文件列",
    "Maps to": "映射到",
    "— skip —": "— 跳过 —",
    "Map the essential fields: {fields}": "请映射必填字段：{fields}",
    # logging settings dialog
    "Logging settings": "记录设置",
    "Log file path": "记录文件路径",
    "Browse…": "浏览…",
    "Timestamp": "时间戳",
    "Row name": "行名称",
    "Register type": "寄存器类型",
    "Append to the file if it exists": "文件已存在时追加内容",
    "Rows to log": "要记录的行",
    "File:": "文件：",
    "Format:": "格式：",
    "Fields:": "字段：",
    "Log values to file": "将数值记录到文件",
    "Choose a log file": "选择记录文件",
    # log panel
    "Clear": "清除",
    "Raw": "原始帧",
    "Save…": "保存…",
    "Save Log": "保存日志",
    "✗ failed to save log to {path}: {exc}": "✗ 保存日志到 {path} 失败：{exc}",
    "→ log saved to {path}": "→ 日志已保存到 {path}",
    # worker log lines
    "Connected ({desc})": "已连接（{desc}）",
    "→ connect {desc}": "→ 连接 {desc}",
    "✗ connect failed: {exc}": "✗ 连接失败：{exc}",
    "← connected": "← 已连接",
    "✗ disconnect failed: {exc}": "✗ 断开连接失败：{exc}",
    "→ disconnect": "→ 断开连接",
    "→ read {kind} unit={unit} addr={address} count={count}":
        "→ 读取 {kind} 从站={unit} 地址={address} 数量={count}",
    "✗ read failed: {exc}": "✗ 读取失败：{exc}",
    "→ write {kind} unit={unit} addr={address} values={values}":
        "→ 写入 {kind} 从站={unit} 地址={address} 值={values}",
    "✗ write failed: {exc}": "✗ 写入失败：{exc}",
    "← ok": "← 成功",
    "→ mask write unit={unit} addr={address} and=0x{and_mask:04x} "
    "or=0x{or_mask:04x}":
        "→ 掩码写入 从站={unit} 地址={address} and=0x{and_mask:04x} or=0x{or_mask:04x}",
    "✗ mask write failed: {exc}": "✗ 掩码写入失败：{exc}",
    "→ read/write unit={unit} read@{read_address} x{read_count} "
    "write@{write_address} values={values}":
        "→ 读写 从站={unit} 读取@{read_address} x{read_count} "
        "写入@{write_address} 值={values}",
    "✗ read/write failed: {exc}": "✗ 读写失败：{exc}",
    "→ read device id unit={unit}": "→ 读取设备标识 从站={unit}",
    "✗ read device id failed: {exc}": "✗ 读取设备标识失败：{exc}",
    "← device id: {count} objects": "← 设备标识：{count} 个对象",
    "→ diag loopback unit={unit}": "→ 回环诊断 从站={unit}",
    "✗ diag loopback failed: {exc}": "✗ 回环诊断失败：{exc}",
    "← loopback ok": "← 回环测试成功",
    "← loopback mismatch": "← 回环数据不匹配",
    "→ diag counters unit={unit}": "→ 读取诊断计数器 从站={unit}",
    "✗ diag counters failed: {exc}": "✗ 读取诊断计数器失败：{exc}",
    "← diag counters: {counters}": "← 诊断计数器：{counters}",
    "→ diag clear counters unit={unit}": "→ 清除诊断计数器 从站={unit}",
    "✗ diag clear counters failed: {exc}": "✗ 清除诊断计数器失败：{exc}",
    "← counters cleared": "← 计数器已清除",
    "→ scan units {start}..{end} ({count} probes)":
        "→ 扫描从站 {start}..{end}（{count} 个探测项）",
    "← scan hit unit={unit} probes={indices}": "← 发现从站={unit} 探测项={indices}",
    "✗ scan failed: {exc}": "✗ 扫描失败：{exc}",
    "← scan stopped": "← 扫描已停止",
    "← scan finished": "← 扫描已完成",
    "→ scan addresses {kind} unit={unit} {start}..{end}":
        "→ 扫描地址 {kind} 从站={unit} {start}..{end}",
    "← addr scan hit {kind}@{address} = {values}": "← 发现地址 {kind}@{address} = {values}",
    "✗ address scan failed: {exc}": "✗ 地址扫描失败：{exc}",
    "← address scan stopped": "← 地址扫描已停止",
    "← address scan finished": "← 地址扫描已完成",
    # main window file dialogs and log lines
    "✗ failed to save settings to {path}: {exc}": "✗ 保存设置到 {path} 失败：{exc}",
    "→ settings saved to {path}": "→ 设置已保存到 {path}",
    "✗ failed to load settings from {path}: {exc}": "✗ 从 {path} 加载设置失败：{exc}",
    "✗ failed to load settings from {path}: not an object":
        "✗ 从 {path} 加载设置失败：内容不是 JSON 对象",
    "← settings loaded from {path}": "← 已从 {path} 加载设置",
    "→ unit {unit} selected in connection panel": "→ 已在连接面板选择从站 {unit}",
    # slave mode / sim panel
    "Mode:": "模式：",
    "Master": "主站",
    "Slave": "从站",
    "Simulator": "模拟器",
    "Start server": "启动服务器",
    "Stop server": "停止服务器",
    "Stopped": "已停止",
    "any": "任意",
    "Add row": "添加行",
    "Add a row to the register map": "向寄存器映射表添加一行",
    "Template…": "模板…",
    "Add rows from a device template": "从设备模板添加行",
    "clients: {count}": "客户端：{count}",
    "← template: added {added} rows to the map": "← 模板：已向映射表添加 {added} 行",
    "Rule": "规则",
    "Rule text": "规则表达式",
    "Tick, ms": "更新周期（毫秒）",
    # sim worker log lines
    "→ start simulator {desc}": "→ 启动模拟器 {desc}",
    "✗ simulator start failed: {exc}": "✗ 启动模拟器失败：{exc}",
    "← simulator running ({desc})": "← 模拟器运行中（{desc}）",
    "Simulator running ({desc})": "模拟器运行中（{desc}）",
    "✗ simulator stop failed: {exc}": "✗ 停止模拟器失败：{exc}",
    "→ simulator stopped": "→ 模拟器已停止",
    "✗ simulator set values failed: {exc}": "✗ 设置模拟器值失败：{exc}",
    "✗ simulator get values failed: {exc}": "✗ 读取模拟器值失败：{exc}",
    "← client connected {address}": "← 客户端已连接 {address}",
    "→ client disconnected {address}": "→ 客户端已断开 {address}",
    # sniffer mode / sniffer panel
    "Sniffer": "嗅探器",
    "Start sniffing": "开始嗅探",
    "Stop sniffing": "停止嗅探",
    "unit {unit}": "从站 {unit}",
    "Listening ({desc})": "监听中（{desc}）",
    "Export CSV…": "导出 CSV…",
    "Live graph of this unit's rows": "此从站各行的实时曲线图",
    "Export rows to CSV in the master table format": "按主站表格格式将各行导出为 CSV",
    # sniffer worker log lines
    "→ start sniffer {desc}": "→ 启动嗅探器 {desc}",
    "✗ sniffer start failed: {exc}": "✗ 启动嗅探器失败：{exc}",
    "← sniffer listening ({desc})": "← 嗅探器监听中（{desc}）",
    "→ sniffer stopped": "→ 嗅探器已停止",
    "✗ sniffer stop failed: {exc}": "✗ 停止嗅探器失败：{exc}",
    "✗ sniffer: {message}": "✗ 嗅探器：{message}",
    # gateway mode / gateway panel
    "Gateway": "网关",
    "Listen:": "监听端：",
    "Target:": "目标端：",
    "Units:": "从站地址：",
    "Units to serve: empty = all 1..247; comma-separated ids and ranges, "
    "e.g. 1, 5, 10-20; other units get no answer (master times out)":
        "服务的从站地址：留空表示全部 1..247；用逗号分隔地址和范围，"
        "例如 1, 5, 10-20；其他从站地址无应答（主站超时）",
    "Start gateway": "启动网关",
    "Stop gateway": "停止网关",
    "Gateway running ({desc})": "网关运行中（{desc}）",
    "← gateway client connected": "← 网关客户端已连接",
    "→ gateway client disconnected": "→ 网关客户端已断开",
    # gateway worker log lines
    "→ start gateway {desc}": "→ 启动网关 {desc}",
    "✗ gateway start failed: {exc}": "✗ 启动网关失败：{exc}",
    "← gateway running ({desc})": "← 网关运行中（{desc}）",
    "✗ gateway stop failed: {exc}": "✗ 停止网关失败：{exc}",
    "→ gateway stopped": "→ 网关已停止",
    "✗ gateway: {message}": "✗ 网关：{message}",
    # scanner panel
    "Add probe": "添加探测项",
    "Start scan": "开始扫描",
    "Stop": "停止",
    "Delete": "删除",
    "Start": "开始",
    "All": "全选",
    "None": "全不选",
    "Add selected to table": "将选中项添加到表格",
    "Add one row per checked address to the registers table":
        "将每个选中地址作为一行添加到寄存器表",
    "Double-click a unit to select it for the connection": "双击从站，将其选为连接目标",
    "Read the selected unit's identification (function 0x2B/0x0E)":
        "读取选中从站的设备标识（功能码 0x2B/0x0E）",
    "Unit range:": "从站范围：",
    "Type:": "类型：",
    "Addresses:": "地址范围：",
    "Address:": "地址：",
    "Results:": "结果：",
    "Registers scan:": "寄存器扫描：",
    "Unit {unit} — device identification (0x2B/0x0E)": "从站 {unit} — 设备标识（0x2B/0x0E）",
    "Unit {unit}: {labels}": "从站 {unit}：{labels}",
    "Bool": "布尔值",
    # graph window
    "Graph": "曲线图",
    "Refresh rows": "刷新行列表",
    "Follow": "跟随",
    "Full": "全部",
    "Manual": "手动",
    "Zoom rect": "框选缩放",
    "Markers": "标记线",
    "Reset view": "重置视图",
    "Clear recorded history and restart the time axis": "清除历史记录并重置时间轴",
    "Poll the register table and record value history for this graph":
        "轮询寄存器表，并为此曲线图记录历史值",
    "X scale:": "X 轴范围：",
    "Series:": "曲线：",
    "Series": "曲线",
    "Min": "最小值",
    "Max": "最大值",
    "Avg": "平均值",
    "time, s (relative)": "相对时间（秒）",
    "Δt = {dt:.4g} s": "Δt = {dt:.4g} 秒",
    # help dialog
    "Help": "帮助",
    "New connection tab": "新建连接标签页",
    "Registers — Help": "寄存器表 — 帮助",
    "Graph — Help": "曲线图 — 帮助",
    "Scanner — Help": "扫描器 — 帮助",
    "Expressions — Help": "表达式 — 帮助",
    "Simulator — Help": "模拟器 — 帮助",
    "Sniffer — Help": "嗅探器 — 帮助",
    "Gateway — Help": "网关 — 帮助",
}


RU.update({
    "Cloud sync…": "Облачная синхронизация…",
    "Connection settings": "Настройки подключения",
    "Template sync": "Синхронизация шаблонов",
    "Template history": "История шаблонов",
    "Use selected templates": "Использовать выбранные шаблоны",
    "Set as current cloud version…": "Сделать текущей облачной версией…",
    "Sync public templates only; personal templates are not included. "
    "Consumers download; publishers can also publish and activate template versions. "
    "Account permissions are enforced by the WebDAV server.":
        "Синхронизируются только общие шаблоны, без личных. Пользователи скачивают; "
        "издатели также публикуют и активируют версии шаблонов. "
        "Права доступа определяются сервером WebDAV.",
    "Consumer": "Пользователь",
    "Publisher": "Издатель",
    "Publish local templates": "Опубликовать локальные шаблоны",
    "Load history": "Загрузить историю",
    "Invalid cloud mode.": "Неверный облачный режим.",
    "Consumer mode cannot publish templates.": "В режиме пользователя публикация запрещена.",
    "Invalid cloud version.": "Неверная облачная версия.",
    "Invalid cloud template catalog.": "Неверный каталог облачных шаблонов.",
    "Select a cloud version first.": "Сначала выберите облачную версию.",
    "Publish all {count} local templates as a new cloud version?":
        "Опубликовать все локальные шаблоны ({count}) как новую облачную версию?",
    "Set the selected version as current for all users?":
        "Сделать выбранную версию текущей для всех пользователей?",
    "Loaded {count} cloud versions.": "Загружено облачных версий: {count}.",
    "Published {count} templates. Version: {version}":
        "Опубликовано шаблонов: {count}. Версия: {version}",
    "Cloud version restored: {version}": "Облачная версия восстановлена: {version}",
    "Cloud sync": "Облачная синхронизация",
    "Provider:": "Сервис:",
    "WebDAV folder URL:": "URL папки WebDAV:",
    "Username:": "Имя пользователя:",
    "Password:": "Пароль:",
    "Templates folder:": "Папка шаблонов:",
    "Timeout, s:": "Таймаут, с:",
    "Remember password on this computer (plain text)":
        "Запомнить пароль на этом компьютере (открытый текст)",
    "Test connection": "Проверить подключение",
    "Update templates": "Обновить шаблоны",
    "Save connection": "Сохранить подключение",
    "Cloud sync failed: {detail}": "Ошибка облачной синхронизации: {detail}",
    "Cloud connection saved.": "Облачное подключение сохранено.",
    "Cloud operation in progress…": "Выполняется облачная операция…",
    "Cloud operation cancelled.": "Облачная операция отменена.",
    "Updated {count} cloud templates.": "Обновлено облачных шаблонов: {count}.",
    "WebDAV connection successful.": "Подключение WebDAV успешно.",
    "Cancelling cloud operation…": "Отмена облачной операции…",
    "Enter a relative cloud path without '..'.": "Укажите относительный путь без '..'.",
    "Enter a valid HTTP or HTTPS WebDAV URL.": "Укажите корректный HTTP или HTTPS URL WebDAV.",
    "Invalid WebDAV username.": "Некорректное имя пользователя WebDAV.",
    "Timeout must be between 1 and 120 seconds.": "Таймаут должен быть от 1 до 120 секунд.",
    "WebDAV {method} failed: HTTP {status}.": "Ошибка WebDAV {method}: HTTP {status}.",
    "Cloud response exceeds the 16 MiB limit.": "Облачный ответ превышает лимит 16 МиБ.",
    "WebDAV connection failed: {detail}": "Ошибка подключения WebDAV: {detail}",
    "Invalid WebDAV directory response.": "Неверный ответ каталога WebDAV.",
    "Cloud template catalog is too large.": "Облачный каталог шаблонов слишком большой.",
    "Invalid cloud template: {name}": "Неверный облачный шаблон: {name}",
})

ZH_CN.update({
    "Cloud sync…": "云端同步…",
    "Connection settings": "连接设置",
    "Template sync": "模板同步",
    "Template history": "模板历史",
    "Use selected templates": "使用此版模板",
    "Set as current cloud version…": "设为云端当前版本…",
    "Sync public templates only; personal templates are not included. "
    "Consumers download; publishers can also publish and activate template versions. "
    "Account permissions are enforced by the WebDAV server.":
        "仅同步公共模板，不包含个人模板。使用者可下载；发布者还可发布模板和切换云端版本。"
        "账号的实际读写权限由 WebDAV 服务控制。",
    "Consumer": "使用者",
    "Publisher": "发布者",
    "Publish local templates": "发布本地模板",
    "Load history": "加载历史",
    "Invalid cloud mode.": "云端模式无效。",
    "Consumer mode cannot publish templates.": "使用者模式不允许发布模板。",
    "Invalid cloud version.": "云端版本无效。",
    "Invalid cloud template catalog.": "云端模板目录无效。",
    "Select a cloud version first.": "请先选择云端版本。",
    "Publish all {count} local templates as a new cloud version?":
        "将全部 {count} 个本地模板发布为新的云端版本？",
    "Set the selected version as current for all users?": "将所选版本设为所有用户的当前版本？",
    "Loaded {count} cloud versions.": "已加载 {count} 个云端版本。",
    "Published {count} templates. Version: {version}": "已发布 {count} 个模板。版本：{version}",
    "Cloud version restored: {version}": "已回退云端版本，新版本：{version}",
    "Cloud sync": "云端同步",
    "Provider:": "服务类型：",
    "WebDAV folder URL:": "WebDAV 文件夹地址：",
    "Username:": "用户名：",
    "Password:": "密码：",
    "Templates folder:": "模板文件夹：",
    "Timeout, s:": "超时（秒）：",
    "Remember password on this computer (plain text)": "在本机记住密码（明文保存）",
    "Test connection": "测试连接",
    "Update templates": "更新模板",
    "Save connection": "保存连接设置",
    "Cloud sync failed: {detail}": "云端同步失败：{detail}",
    "Cloud connection saved.": "云端连接设置已保存。",
    "Cloud operation in progress…": "正在执行云端操作…",
    "Cloud operation cancelled.": "云端操作已取消。",
    "Updated {count} cloud templates.": "已更新 {count} 个云端模板。",
    "WebDAV connection successful.": "WebDAV 连接成功。",
    "Cancelling cloud operation…": "正在取消云端操作…",
    "Enter a relative cloud path without '..'.": "请输入不包含“..”的云端相对路径。",
    "Enter a valid HTTP or HTTPS WebDAV URL.": "请输入有效的 HTTP 或 HTTPS WebDAV 地址。",
    "Invalid WebDAV username.": "WebDAV 用户名无效。",
    "Timeout must be between 1 and 120 seconds.": "超时必须在 1 到 120 秒之间。",
    "WebDAV {method} failed: HTTP {status}.": "WebDAV {method} 失败：HTTP {status}。",
    "Cloud response exceeds the 16 MiB limit.": "云端响应超过 16 MiB 限制。",
    "WebDAV connection failed: {detail}": "WebDAV 连接失败：{detail}",
    "Invalid WebDAV directory response.": "WebDAV 目录响应无效。",
    "Cloud template catalog is too large.": "云端模板目录过大。",
    "Invalid cloud template: {name}": "云端模板无效：{name}",
})


RU.update({
    "Check for updates…": "Проверить обновления…",
    "Check for updates": "Проверка обновлений",
    "Current version: {version}": "Текущая версия: {version}",
    "Check again": "Проверить снова",
    "Open releases page": "Открыть страницу релизов",
    "Checking for updates…": "Проверка обновлений…",
    "Finishing update check…": "Завершение проверки обновлений…",
    "Update check failed: {detail}": "Не удалось проверить обновления: {detail}",
    "No public stable release is available. Check the releases page.":
        "Публичный стабильный релиз недоступен. Проверьте страницу релизов.",
    "No release notes.": "Описание релиза отсутствует.",
    "New version available: {version}": "Доступна новая версия: {version}",
    "Download update…": "Скачать обновление…",
    "You are up to date. Latest release: {version}":
        "Обновление не требуется. Последний релиз: {version}",
    "Could not open browser. Visit: {url}": "Не удалось открыть браузер. Перейдите: {url}",
    "Unsupported release version: {version}": "Неподдерживаемая версия релиза: {version}",
    "GitHub denied the request or rate limit exceeded. Try later.":
        "GitHub отклонил запрос или превышен лимит запросов. Повторите позже.",
    "GitHub request failed: HTTP {status}.": "Ошибка запроса GitHub: HTTP {status}.",
    "Could not reach GitHub: {detail}": "Не удалось подключиться к GitHub: {detail}",
    "Invalid GitHub release response.": "Некорректный ответ GitHub о релизе.",
})

ZH_CN.update({
    "Check for updates…": "检查更新…",
    "Check for updates": "检查更新",
    "Current version: {version}": "当前版本：{version}",
    "Check again": "重新检查",
    "Open releases page": "打开发布页",
    "Checking for updates…": "正在检查更新…",
    "Finishing update check…": "正在结束更新检查…",
    "Update check failed: {detail}": "检查更新失败：{detail}",
    "No public stable release is available. Check the releases page.":
        "暂无可用的公开正式版本，请查看发布页。",
    "No release notes.": "暂无更新说明。",
    "New version available: {version}": "发现新版本：{version}",
    "Download update…": "下载更新…",
    "You are up to date. Latest release: {version}": "当前已是最新版本。最新发布：{version}",
    "Could not open browser. Visit: {url}": "无法打开浏览器，请访问：{url}",
    "Unsupported release version: {version}": "不支持的发布版本号：{version}",
    "GitHub denied the request or rate limit exceeded. Try later.":
        "GitHub 拒绝了请求或请求次数已达上限，请稍后重试。",
    "GitHub request failed: HTTP {status}.": "GitHub 请求失败：HTTP {status}。",
    "Could not reach GitHub: {detail}": "无法连接 GitHub：{detail}",
    "Invalid GitHub release response.": "GitHub 版本信息响应无效。",
})


RU.update({
    'Download, install and restart': 'Скачать, установить и перезапустить',
    'Install update': 'Установка обновления',
    (
        'Automatic installation requires a Windows installed copy and a verified '
        'installer asset. Use the releases page for manual installation.'
    ): (
        'Автоустановка требует установленную Windows-версию и проверяемый установщик. '
        'Установите обновление вручную со страницы релиза.'
    ),
    (
        'Download and install this update? Sessions will be saved, connections closed, '
        'and the application restarted. Close other Modbus Connector windows first.'
    ): (
        'Скачать и установить обновление? Сеансы будут сохранены, соединения закрыты, '
        'приложение перезапущено. Сначала закройте другие окна Modbus Connector.'
    ),
    (
        'Downloading and verifying update… Close to cancel.'
    ): (
        'Загрузка и проверка обновления… Закройте окно для отмены.'
    ),
    'Cancelling download…': 'Отмена загрузки…',
    'Update failed: {detail}': 'Ошибка обновления: {detail}',
    'Unsafe installer download URL.': 'Небезопасный адрес загрузки установщика.',
    'Installer download failed: HTTP {status}.': 'Ошибка загрузки установщика: HTTP {status}.',
    (
        'Installer verification failed. Please download again.'
    ): (
        'Проверка установщика не пройдена. Повторите загрузку.'
    ),
    (
        'The update helper stopped. Please try again.'
    ): (
        'Процесс обновления остановился. Повторите попытку.'
    ),
    (
        'Could not start the update helper. Please try again.'
    ): (
        'Не удалось запустить процесс обновления. Повторите попытку.'
    ),
})

ZH_CN.update({
    'Download, install and restart': '下载并安装重启',
    'Install update': '安装更新',
    (
        'Automatic installation requires a Windows installed copy and a verified '
        'installer asset. Use the releases page for manual installation.'
    ): (
        '自动安装需要 Windows 安装版和可校验的安装包。请从发布页手动下载安装。'
    ),
    (
        'Download and install this update? Sessions will be saved, connections closed, '
        'and the application restarted. Close other Modbus Connector windows first.'
    ): (
        '是否下载并安装此更新？将保存会话、断开连接并重启程序。请先关闭其他 Modbus Connector 窗口。'
    ),
    'Downloading and verifying update… Close to cancel.': '正在下载并校验更新…关闭此窗口可取消。',
    'Cancelling download…': '正在取消下载…',
    'Update failed: {detail}': '更新失败：{detail}',
    'Unsafe installer download URL.': '安装包下载地址不安全。',
    'Installer download failed: HTTP {status}.': '安装包下载失败：HTTP {status}。',
    'Installer verification failed. Please download again.': '安装包校验失败，请重新下载。',
    'The update helper stopped. Please try again.': '更新辅助进程已停止，请重试。',
    'Could not start the update helper. Please try again.': '无法启动更新辅助进程，请重试。',
})

class _LanguageNotifier(QObject):
    changed = Signal(str)


_notifier = _LanguageNotifier()
languageChanged = _notifier.changed  # подключается к retranslate() виджетов

_current: str | None = None
_qt_translator = QTranslator()


def _detect() -> str:
    language = QLocale.system().name().lower().split("_")[0]
    return {"ru": "ru", "zh": "zh_CN"}.get(language, "en")


def current_language() -> str:
    global _current
    if _current is None:
        _current = _detect()
    return _current


def set_language(name: str | None) -> None:
    """Переключить язык; None — определить по системе, неизвестное → "en"."""
    global _current
    if name is None:
        new = _detect()
    else:
        new = name if name in LANGUAGES else "en"
    changed = new != current_language()
    _current = new
    app = QCoreApplication.instance()
    if app is not None:
        app.removeTranslator(_qt_translator)
        if new == "zh_CN" and _qt_translator.load(
            "qtbase_zh_CN", QLibraryInfo.path(QLibraryInfo.LibraryPath.TranslationsPath)
        ):
            app.installTranslator(_qt_translator)
    if changed:
        _notifier.changed.emit(new)


def tr(text: str, **fmt: object) -> str:
    """Перевести строку на текущий язык; без перевода остаётся английской."""
    translations = {"ru": RU, "zh_CN": ZH_CN}.get(current_language(), {})
    text = translations.get(text, text)
    return text.format(**fmt) if fmt else text


def format_error(error: object) -> str:
    """Translate structured backend errors and common pymodbus response failures."""
    if isinstance(error, BackendError):
        text = tr(error.message_key, **error.message_params)
        if isinstance(error, ModbusExceptionError):
            code = error.exception_code
            detail = f"{tr(EXCEPTION_CODES.get(code, 'Exception'))} (0x{code:02X})"
        elif error.detail is not None:
            detail = format_error(error.detail)
        else:
            return text
        return f"{text}: {detail}"
    text = re.sub(r"Modbus Error: \[[^]]*\]\s*", "", str(error))
    short_response = re.search(r"expected at least (\d+) bytes \((\d+) received\)", text)
    if short_response:
        return tr(
            "No response or incomplete frame: expected at least {expected} bytes, "
            "received {received}",
            expected=short_response[1], received=short_response[2],
        )
    if "no response" in text.lower():
        return tr("No response from the device (timeout or invalid response)")
    if "unable to decode response" in text.lower():
        return tr("Unable to decode the device response")
    return tr(text)
