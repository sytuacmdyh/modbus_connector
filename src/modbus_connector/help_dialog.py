"""Немодальная помощь по окнам: иконочная кнопка показывает HTML-справку."""

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QDialog,
    QDialogButtonBox,
    QTextBrowser,
    QToolButton,
    QVBoxLayout,
    QWidget,
)

from modbus_connector import icons
from modbus_connector.i18n import current_language, tr

REGISTERS_HELP = """
<h3>Registers table</h3>
<p>Each row is a register range: <b>Name</b>, <b>Type</b> (coils, discrete
inputs, holding or input registers), <b>Address</b> (dec or 0x-hex),
<b>Count</b>, optional per-row <b>Unit ID</b> and <b>Poll, ms</b> interval,
display <b>Format</b>, the last read <b>Value</b> with a trend sparkline,
and <b>New value</b> for writes: numbers are entered in the row's display
format for s16/u32/s32/f32/u64/s64/f64 (e.g. 0.1 for f32), ascii takes
plain text, dec/hex and bit areas take raw values; scale/offset is not
applied.</p>
<ul>
<li>The <b>checkbox in the first column</b> includes the row in polling and
<b>Read all</b>; unchecked rows are skipped (Ctrl+R, quick actions and
writes still work on them).</li>
<li><b>Read all</b> reads every checked row once; the split button starts polling
with or without history recording (the dropdown chooses; the choice flips
recording mid-poll without restarting timers).</li>
<li><b>Group reads</b> (toggle) merges adjacent addresses of the polling tick
and Read all into one request (rows with their own Poll, ms interval are not
merged). If a grouped read fails, its rows are retried individually.</li>
<li><b>Log to file</b> records read values to CSV or JSON Lines; <b>⚙</b>
opens file/format/field/row settings.</li>
<li><b>Display…</b> — per-row Scale/Offset/Unit and byte order;
<b>Filter…</b> hides non-matching rows; <b>Sort by address</b> reorders;
<b>CSV</b> imports/exports the table; <b>Mask write (0x16)…</b> and
<b>Read/Write (0x17)…</b> run the advanced functions.</li>
<li><b>Value names</b> (the Display… dialog, bottom editor for the selected
row): name integer values as an enum, one <code>value=name</code> per line
(e.g. <code>0=Stopped</code>). A matching single-register dec/s16 or bit
value shows as "name (N)", and the row's New value cell turns into a combo
that writes the picked value immediately (the combo resets after each
write, so the same value can be picked again). The <b>Bitmask</b> checkbox
switches the mode: value names label bits 0..15 of a single-register
dec/s16/hex row, the Value cell lists the set bits ("Running, Alarm
(0000 0000 1010 0101)") and New value becomes a button opening a bit
checkbox dialog.</li>
<li><b>Alarms…</b> — per-row alarm rules over the scaled value (hex/ascii
rows are skipped). The first matching rule wins and paints the Value cell
red/yellow, outranking the change flash; activation and clearing are logged
once per edge (if Log is set), with a beep on activation if Sound is set.</li>
<li><b>Expressions</b> (the fx toolbar button) opens a block of computed
rows under the table: <b>[name]</b> references another row's scaled value,
arithmetic (+ - * / // % **), parentheses, pi/e and functions
(abs, sqrt, sin, cos, log, min, max, clamp, …) are allowed. Each expression
has a trend sparkline and appears in the graph window as "fx name"; history
is recorded in poll-and-record mode only. An invalid expression shows ⚠
with the error in the tooltip. Alarm rules apply to expressions as well —
they appear in the Alarms… dialog as "fx name".</li>
<li><b>Snapshot</b> remembers the current raw values of all rows;
<b>Diff…</b> (enabled after a snapshot) opens a window comparing them with
the latest reads — changed rows are highlighted, "(removed)" marks rows
deleted after the snapshot, "Take new snapshot" accepts the current values
as the new baseline.</li>
<li>Right-click a row for quick actions (copy, write 0/1, increment,
decrement, toggle, move) — they act on the selected rows. Drag a column
header to reorder columns; right-click the header to hide/show columns
(the layout is saved between sessions).</li>
</ul>
<table border="1" cellspacing="0" cellpadding="3">
<tr><th>Hotkey</th><th>Action</th></tr>
<tr><td>Enter</td><td>write the row's New value</td></tr>
<tr><td>Ctrl+R</td><td>read the current row</td></tr>
<tr><td>Ctrl+Shift+R</td><td>read all rows</td></tr>
<tr><td>Ctrl+C</td><td>copy the value</td></tr>
<tr><td>Ctrl+0 / Ctrl+1</td><td>write 0 / 1</td></tr>
<tr><td>Ctrl+= / Ctrl+-</td><td>increment / decrement the last read value
(numpad Ctrl++ works too)</td></tr>
<tr><td>Ctrl+T</td><td>toggle (coil flips; register 0↔1)</td></tr>
<tr><td>Ctrl+Up / Ctrl+Down</td><td>move the selected rows</td></tr>
</table>
<p>⌘ replaces Ctrl on macOS.</p>
"""

GRAPH_HELP = """
<h3>Graph window</h3>
<ul>
<li>The <b>Series</b> checklist picks which table rows are plotted (new rows
join checked; "Refresh rows" rebuilds the list). Only rows enabled for polling
(the leftmost checkbox in the table) are listed — unchecking a row there hides
its series here, and the checklist state survives the hide/show cycle.</li>
<li><b>X scale</b>: <b>Follow</b> slides a window of the given width behind
the latest data, <b>Full</b> fits everything, <b>Manual</b> freezes the
view. Wheel zooms at the cursor, left-drag pans, <b>Zoom rect</b> zooms to a
rectangle — any of these switches the mode to Manual;
<b>Reset view</b> returns to Follow.</li>
<li><b>Markers</b> shows two draggable lines (green A, red B) with per-series
min/max/avg between them and Δt.</li>
<li>Hovering the plot shows a crosshair: a dashed vertical and a top-right
readout with every series' value at that time (nearest sample).</li>
<li><b>Clear</b> wipes the recorded history and restarts the time axis.</li>
<li><b>Start polling and record</b> drives the register table's polling from
here; while it records, the button stops it.</li>
</ul>
"""

EXPRESSIONS_HELP = """
<h3>Expressions</h3>
<p>The expressions block (the <b>Expressions</b> toolbar button) holds computed
rows over register values. Every expression is re-evaluated after each read,
using the <b>scaled</b> primary values of the referenced rows (scale/offset
applied; hex/ascii rows are not numeric and cannot be referenced).</p>
<h4>Syntax</h4>
<ul>
<li><b>[name]</b> — reference to a register row by its Name (spaces and
unicode are allowed): <code>([temp] + [flow rate]) / 2</code></li>
<li>Numbers (incl. <code>1e3</code>), parentheses, operators
<code>+ - * / // % **</code>, unary <code>+/-</code></li>
<li>Constants: <b>pi</b>, <b>e</b></li>
<li>The Expression cell auto-completes: typing <b>[</b> offers register row
names, a word start offers functions and constants (Enter inserts, Esc
closes the popup).</li>
</ul>
<table border="1" cellspacing="0" cellpadding="3">
<tr><th>Function</th><th>Meaning</th></tr>
<tr><td>abs(x)</td><td>absolute value</td></tr>
<tr><td>sqrt(x)</td><td>square root</td></tr>
<tr><td>exp(x)</td><td>e raised to x</td></tr>
<tr><td>log(x) / log2(x) / log10(x)</td><td>natural / base-2 / base-10
logarithm</td></tr>
<tr><td>sin(x) / cos(x) / tan(x)</td><td>trigonometry (radians)</td></tr>
<tr><td>asin(x) / acos(x) / atan(x)</td><td>inverse trigonometry
(radians)</td></tr>
<tr><td>floor(x) / ceil(x) / round(x)</td><td>round down / up / to
nearest</td></tr>
<tr><td>min(a, b, …) / max(a, b, …)</td><td>smallest / largest of the
arguments</td></tr>
<tr><td>pow(x, y)</td><td>x to the power y (same as x**y)</td></tr>
<tr><td>clamp(x, lo, hi)</td><td>limit x to the range [lo, hi]</td></tr>
</table>
<h4>Behavior</h4>
<ul>
<li><b>—</b> — no value: a referenced row is missing or not read yet, or the
evaluation failed (division by zero, out-of-domain, overflow).</li>
<li><b>⚠</b> — syntax error; the cell tooltip shows the error text. Fix the
expression to recover.</li>
<li>Each expression has a trend sparkline and appears in the graph window as
"fx name"; history is recorded in poll-and-record mode only and is wiped by
the graph's <b>Clear</b>.</li>
<li>Alarm rules apply to expressions too: they are listed in the
<b>Alarms…</b> dialog as "fx name" and paint the expression's Value cell
(the computed value is compared, "—" and "⚠" never match).</li>
</ul>
"""

SCANNER_HELP = """
<h3>Scanner</h3>
<ul>
<li><b>Unit scan</b>: sweeps the unit range with the probe list (type,
address, count per probe) and lists units that answered at least one probe.
Add/remove probes above; <b>Stop</b> aborts the sweep.</li>
<li><b>Double-click</b> a found unit to select it in the connection panel;
<b>Device ID…</b> reads the selected unit's identification (0x2B/0x0E).</li>
<li><b>Registers scan</b>: probes the address range of one unit and kind.
Register areas are read in pairs, so found values show as dec/hex/s16/u32/s32/
f32/ascii columns (a single register at the map edge shows "—" for 32-bit);
coils/discrete inputs show a Bool column. Found addresses arrive checked;
uncheck rows you don't need (Space toggles,
All/None for long lists) and <b>Add selected to table</b> creates register
rows for them — duplicates (same type and address) are skipped.</li>
</ul>
"""


SNIFFER_HELP = """
<h3>Sniffer</h3>
<p>The <b>Mode</b> combo switches the tab to <b>Sniffer</b> — a passive
listener for a Modbus RTU bus: it watches the traffic between an existing
master and its slaves and rebuilds the register map from what it sees, without
sending a single frame. Connect a <b>separate serial adapter</b> (a "tap") to
the same RS-485 line: pyserial opens the port exclusively, so the sniffer
needs its own interface — it cannot share the master's port.</p>
<ul>
<li><b>Port settings</b> (port, baud, bits, parity, stop bits) must match the
bus exactly, otherwise frames turn into garbage.</li>
<li><b>Start sniffing</b> begins listening; the status line turns green. One
<b>unit tab</b> appears per unit id seen on the bus.</li>
<li>Each unit tab has a table of observed addresses
(<b>Address</b>/<b>Name</b>/<b>Type</b>/<b>Format</b>/<b>Value</b>/<b>Trend</b>)
and a <b>per-unit frame log</b>; the session log at the bottom shows all
frames. Rows appear automatically, sorted by address; the Name and the display
Format are editable, a changed value flashes green, the Trend sparkline
follows every update.</li>
<li><b>Graph…</b> opens a live graph window for the tab's rows (the sniffer
does not poll, so there is no polling button there);
<b>Export CSV…</b> writes the table in the master-table CSV format — the file
imports back into a master tab's register table as is.</li>
<li>Limits: <b>serial RTU only</b> — Modbus TCP cannot be sniffed; the frame
direction (tx = master → slave, rx = slave → master) is not physically
distinguishable on the wire and is guessed heuristically from the frame
structure, so exotic function codes or noisy lines may misclassify.</li>
</ul>
"""


GATEWAY_HELP = """
<h3>Gateway</h3>
<p>The <b>Mode</b> combo switches the tab to <b>Gateway</b> — a transparent
Modbus proxy: it runs a slave server on the <b>Listen</b> side and forwards
every incoming request to the device on the <b>Target</b> side. Use it to
bridge networks (e.g. expose a serial RTU device as Modbus TCP), to log the
traffic between an existing master and its device, or to share one serial
port between several TCP clients. The combo is locked while the gateway is
running.</p>
<h4>Sides</h4>
<ul>
<li><b>Listen</b> — where masters connect: <b>TCP</b> (host/port, 1502 by
default so no admin rights are needed), <b>RTU over TCP</b> (TCP socket with
RTU framing) or <b>RTU</b> (a serial port). A busy TCP port fails the start
with an error in the status line.</li>
<li><b>Target</b> — where requests are forwarded: any connection type
(<b>TCP</b>, <b>RTU</b>, <b>RTU over TCP</b>, <b>RTU over UDP</b>) with its
own <b>Timeout</b>. The target must be reachable at start, otherwise the
gateway refuses to run.</li>
<li>Any direction works: TCP → RTU, RTU → TCP, TCP → TCP, RTU over TCP →
RTU over UDP, and so on — listen and target are configured independently.</li>
</ul>
<h4>Units filter</h4>
<p><b>Units</b> lists the unit ids the gateway serves: empty means all
(1..247); ids and ranges separated by commas, e.g. <code>1, 5, 10-20</code>.
Requests to other units get <b>no answer</b> — the master just times out.</p>
<h4>Errors</h4>
<ul>
<li>Every transaction goes to the session log
(<code>-&gt; unit 5 read ...</code> / <code>&lt;- ok (N ms)</code>).</li>
<li>If the target answers with a Modbus exception, times out or the request
fails, the master receives <b>Slave Failure (0x04)</b>; the actual reason is
in the log (<code>&lt;- error: ...</code>).</li>
<li>The status line shows the bound listen address and the number of
connected TCP clients.</li>
</ul>
"""


SIMULATOR_HELP = """
<h3>Simulator (slave mode)</h3>
<p>The <b>Mode</b> combo above switches the tab between <b>Master</b> (poll a
device) and <b>Slave</b> (this panel) — a Modbus device emulator for
debugging masters, clients and gateways without real hardware. The combo is
locked while the master side is connected or the server is running.</p>
<h4>Server</h4>
<ul>
<li><b>TCP</b> (host, port — 1502 by default, so no admin rights are needed),
<b>RTU</b> (serial port, baudrate, parity) or <b>RTU over TCP</b> (TCP socket
with RTU framing — for masters configured as "Modbus RTU over TCP");
<b>Unit</b> picks the unit id
to answer, <b>any</b> answers every unit id.</li>
<li><b>Start server</b> pushes the whole map into the datastore and starts
listening; the status line shows the bound address and the number of
connected clients. Every master request goes to the log, and master writes
update the matching map rows.</li>
</ul>
<h4>Map</h4>
<ul>
<li>Each row is a value range: <b>Name</b>, <b>Type</b> (coils, discrete
inputs, holding or input registers), <b>Address</b> (0..9999, dec or 0x-hex),
<b>Count</b>, display <b>Format</b> and <b>Value</b>. Editing a manual value
writes it to the datastore immediately — even before the server starts.
Text formats: <b>ascii</b> packs two chars per register, <b>ascii1</b> one
char per register (Wiren Board string convention, e.g. for model/firmware
strings).</li>
<li><b>Template…</b> adds rows from a bundled device template (duplicates by
type+address are skipped); <b>Add row</b> appends an empty row, ✕ deletes
one.</li>
<li><b>Value names…</b> names the current row's integer values (one
<code>value=name</code> per line). A matching single-register dec/s16 or bit
value shows as "name (N)"; a manual row's Value cell becomes a combo that
writes the pick to the datastore at once, an expression row only displays
the name. The <b>Bitmask</b> checkbox switches the mode: value names label
bits 0..15 of a single-register dec/s16/hex row, Value lists the set bits
and a manual row's cell becomes a button opening a bit checkbox dialog.</li>
</ul>
<h4>Rules</h4>
<p>The <b>Rule</b> column picks <b>Manual</b> (edit the Value yourself) or
<b>Expression</b> — the value is recomputed every <b>Tick, ms</b> from the
<b>Rule text</b>. The syntax is the same as in the master table's expressions
block: <code>[name]</code> references another row's value, arithmetic
(+ - * / // % **), parentheses, pi/e and functions (abs, sqrt, sin, min, max,
clamp, …) are allowed, plus simulator-specific extras:</p>
<table border="1" cellspacing="0" cellpadding="3">
<tr><th>Extra</th><th>Meaning</th></tr>
<tr><td>rand()</td><td>random float in [0, 1)</td></tr>
<tr><td>randint(a, b)</td><td>random integer in [a, b]</td></tr>
<tr><td>t</td><td>seconds since the server started</td></tr>
<tr><td>prev</td><td>the row's previous result (first tick: its current
value)</td></tr>
</table>
<p>Examples: <code>20+5*sin(2*pi*t/60)</code> — a slow sine;
<code>prev+1</code> — a counter; <code>min(prev+0.5, 100)</code> — a capped
ramp.</p>
<ul>
<li><b>⚠</b> — syntax error; the tooltip shows the error text. <b>—</b> — no
value this tick: a referenced row is missing, the evaluation failed or the
result does not fit the row's format; such ticks are skipped and the
datastore keeps the old value.</li>
<li>Results are encoded back into registers with the fixed <b>ABCD</b> byte
order (hex/ascii rows encode as dec).</li>
</ul>
"""


def make_help_button(parent: QWidget, title: str, html: str) -> QToolButton:
    """Маленькая квадратная иконочная кнопка, открывающая справку по окну."""
    button = icons.make_button(tr("Help"), "help")
    button.setParent(parent)
    button.setFixedSize(26, 26)
    button.clicked.connect(lambda: show_help(parent, title, html))
    return button


def show_help(parent: QWidget, title: str, html: str) -> QDialog:
    """Показать немодальный диалог помощи; удаляется при закрытии."""
    dialog = QDialog(parent)
    dialog.setAttribute(Qt.WidgetAttribute.WA_DeleteOnClose)
    dialog.setWindowTitle(tr(title))
    dialog.resize(520, 480)
    browser = QTextBrowser()
    browser.setHtml(_sheet(html))  # resolved at click time, never cached
    buttons = QDialogButtonBox(QDialogButtonBox.StandardButton.Close)
    buttons.rejected.connect(dialog.reject)
    layout = QVBoxLayout(dialog)
    layout.addWidget(browser)
    layout.addWidget(buttons)
    dialog.show()
    return dialog


def _sheet(english_html: str) -> str:
    """Resolve a help sheet in the current language, falling back to English."""
    sheets = {"ru": HELP_RU, "zh_CN": HELP_ZH_CN}.get(current_language(), {})
    return sheets.get(english_html, english_html)


REGISTERS_HELP_RU = """
<h3>Таблица регистров</h3>
<p>Каждая строка — диапазон регистров: <b>имя</b>, <b>тип</b> (coils, discrete
inputs, holding или input registers), <b>адрес</b> (dec или 0x-hex),
<b>кол-во</b>, необязательные <b>Unit ID</b> и интервал <b>Poll, мс</b> на
строку, <b>формат</b> отображения, последнее прочитанное <b>значение</b> со
спарклайном и поле <b>Новое значение</b> для записи: для форматов
s16/u32/s32/f32/u64/s64/f64 числа вводятся в формате отображения (например
0.1 для f32), ascii принимает обычный текст, dec/hex и битовые области —
сырые значения; scale/offset не применяется.</p>
<ul>
<li><b>Галочка в первой колонке</b> включает строку в опрос и
<b>Прочитать все</b>; снятые строки пропускаются (Ctrl+R, быстрые действия
и запись на них по-прежнему работают).</li>
<li><b>Прочитать все</b> читает каждую отмеченную строку один раз; split-кнопка
начинает опрос с записью истории или без (выбор в выпадающем меню; на ходу
переключает запись без перезапуска таймеров).</li>
<li><b>Объединять чтения</b> (переключатель) сливает соседние адреса тика
опроса и «Прочитать все» в один запрос (строки со своим интервалом Poll, мс
не объединяются). При ошибке объединённого чтения его строки перечитываются
по отдельности.</li>
<li><b>Запись в файл</b> пишет значения в CSV или JSON Lines; <b>⚙</b> открывает
настройки файла, формата, полей и строк.</li>
<li><b>Отображение…</b> — Scale/Offset/Unit и порядок байт на строку;
<b>Фильтр…</b> скрывает лишние строки; <b>Сортировать по адресу</b>
упорядочивает таблицу; <b>CSV</b> — импорт/экспорт; <b>Mask write (0x16)…</b> и
<b>Read/Write (0x17)…</b> — расширенные функции.</li>
<li><b>Имена значений</b> (диалог «Отображение…», редактор внизу для
выбранной строки): имена целых значений как enum, по строке
<code>значение=имя</code> (например <code>0=Остановлен</code>). Совпавшее
значение одиночного регистра dec/s16 или бита показывается как «имя (N)»,
а поле «Новое значение» строки превращается в комбо, записывающее выбранное
значение сразу (после записи комбо сбрасывается — то же значение можно
выбрать повторно). Галочка <b>Битовая маска</b> переключает режим: имена
значений подписывают биты 0..15 строки одиночного регистра dec/s16/hex,
ячейка значения перечисляет установленные биты («Работает, Авария
(0000 0000 1010 0101)»), а «Новое значение» становится кнопкой, открывающей
диалог с галочками битов.</li>
<li><b>Алармы…</b> — правила алармов на строку по масштабированному значению
(строки hex/ascii пропускаются). Срабатывает первое совпавшее правило и
красит ячейку значения в красный/жёлтый (приоритет над зелёной вспышкой
изменения); активация и снятие пишутся в лог один раз на фронт (если
включён «Лог»), при активации — звук, если включён «Звук».</li>
<li><b>Выражения</b> (кнопка fx в тулбаре) открывает блок вычисляемых строк
под таблицей: <b>[имя]</b> — ссылка на масштабированное значение строки,
допускаются арифметика (+ - * / // % **), скобки, pi/e и функции
(abs, sqrt, sin, cos, log, min, max, clamp, …). У каждого выражения свой
спарклайн, а в окне графика оно видно как «fx имя»; история пишется только
в режиме опроса с записью. Невалидное выражение показывает ⚠, текст ошибки —
в подсказке ячейки. Алармы работают и на выражения — в диалоге «Алармы…»
они показаны как «fx имя».</li>
<li><b>Снапшот</b> запоминает текущие raw-значения всех строк;
<b>Сравнение…</b> (активно после снапшота) открывает окно сравнения с
последними чтениями — изменённые строки подсвечены, «(удалена)» помечает
строки, удалённые после снапшота, «Снять новый снапшот» принимает текущие
значения как новую базу.</li>
<li>Правый клик по строке — быстрые действия (копия, запись 0/1, шаг,
переключение, сдвиг); действуют на выбранные строки. Колонки можно
перетаскивать за заголовки, а правый клик по заголовку скрывает/показывает
колонки (раскладка сохраняется между сессиями).</li>
</ul>
<table border="1" cellspacing="0" cellpadding="3">
<tr><th>Клавиши</th><th>Действие</th></tr>
<tr><td>Enter</td><td>записать «Новое значение» строки</td></tr>
<tr><td>Ctrl+R</td><td>прочитать текущую строку</td></tr>
<tr><td>Ctrl+Shift+R</td><td>прочитать все строки</td></tr>
<tr><td>Ctrl+C</td><td>копировать значение</td></tr>
<tr><td>Ctrl+0 / Ctrl+1</td><td>записать 0 / 1</td></tr>
<tr><td>Ctrl+= / Ctrl+-</td><td>увеличить / уменьшить последнее прочитанное
(работает и Ctrl++ на нампаде)</td></tr>
<tr><td>Ctrl+T</td><td>переключить (coil инвертируется; регистр 0↔1)</td></tr>
<tr><td>Ctrl+Up / Ctrl+Down</td><td>сдвинуть выбранные строки</td></tr>
</table>
<p>На macOS вместо Ctrl используется ⌘.</p>
"""

GRAPH_HELP_RU = """
<h3>Окно графика</h3>
<ul>
<li>Чек-лист <b>Series</b> выбирает строки таблицы для построения (новые
строки добавляются отмеченными; «Refresh rows» перечитывает список). В список
попадают только строки, включённые в поллинг (крайняя левая галочка в таблице)
— снятие галочки скрывает ряд отсюда, состояние чек-листа при этом
сохраняется.</li>
<li><b>X scale</b>: <b>Follow</b> ведёт скользящее окно за последними данными,
<b>Full</b> вписывает всё, <b>Manual</b> замораживает вид. Колесо — зум у
курсора, драг — панорама, <b>Zoom rect</b> — зум рамкой; любой из них
переключает режим в Manual; <b>Reset view</b> возвращает Follow.</li>
<li><b>Markers</b> показывает две перетаскиваемые линии (зелёную A, красную B)
с min/max/avg каждого ряда между ними и Δt.</li>
<li>При наведении курсора — кроссхеар: пунктирная вертикаль и значения всех
рядов в этот момент в правом верхнем углу (ближайший отсчёт).</li>
<li><b>Clear</b> очищает записанную историю и перезапускает ось времени.</li>
<li><b>Начать опрос с записью</b> управляет опросом таблицы прямо из окна;
при активной записи кнопка останавливает его.</li>
</ul>
"""

EXPRESSIONS_HELP_RU = """
<h3>Выражения</h3>
<p>Блок выражений (кнопка <b>Выражения</b> в тулбаре) — вычисляемые строки
над значениями регистров. Каждое выражение пересчитывается после каждого
чтения по <b>масштабированным</b> primary-значениям строк-зависимостей
(применены scale/offset; строки hex/ascii не числовые и ссылаться на них
нельзя).</p>
<h4>Синтаксис</h4>
<ul>
<li><b>[имя]</b> — ссылка на строку регистров по имени (можно пробелы и
юникод): <code>([temp] + [flow rate]) / 2</code></li>
<li>Числа (в т.ч. <code>1e3</code>), скобки, операторы
<code>+ - * / // % **</code>, унарные <code>+/-</code></li>
<li>Константы: <b>pi</b>, <b>e</b></li>
<li>Ячейка Expression автодополняет ввод: <b>[</b> предлагает имена строк
регистров, начало слова — функции и константы (Enter вставляет, Esc
закрывает попап).</li>
</ul>
<table border="1" cellspacing="0" cellpadding="3">
<tr><th>Функция</th><th>Значение</th></tr>
<tr><td>abs(x)</td><td>модуль</td></tr>
<tr><td>sqrt(x)</td><td>квадратный корень</td></tr>
<tr><td>exp(x)</td><td>e в степени x</td></tr>
<tr><td>log(x) / log2(x) / log10(x)</td><td>натуральный / по основанию 2 /
по основанию 10 логарифм</td></tr>
<tr><td>sin(x) / cos(x) / tan(x)</td><td>тригонометрия (радианы)</td></tr>
<tr><td>asin(x) / acos(x) / atan(x)</td><td>обратная тригонометрия
(радианы)</td></tr>
<tr><td>floor(x) / ceil(x) / round(x)</td><td>округление вниз / вверх /
до ближайшего</td></tr>
<tr><td>min(a, b, …) / max(a, b, …)</td><td>минимум / максимум из
аргументов</td></tr>
<tr><td>pow(x, y)</td><td>x в степени y (то же, что x**y)</td></tr>
<tr><td>clamp(x, lo, hi)</td><td>ограничить x диапазоном [lo, hi]</td></tr>
</table>
<h4>Поведение</h4>
<ul>
<li><b>—</b> — значения нет: строка-зависимость отсутствует или ещё не
читалась, либо ошибка вычисления (деление на ноль, область определения,
переполнение).</li>
<li><b>⚠</b> — ошибка синтаксиса; текст ошибки — в подсказке ячейки.
Исправьте выражение, чтобы восстановить значение.</li>
<li>У каждого выражения свой спарклайн, а в окне графика оно видно как
«fx имя»; история пишется только в режиме опроса с записью и сбрасывается
кнопкой <b>Clear</b> графика.</li>
<li>Алармы работают и на выражения: они показаны в диалоге <b>Алармы…</b>
как «fx имя» и красят ячейку Value выражения (сравнивается вычисленное
значение; «—» и «⚠» не срабатывают).</li>
</ul>
"""

SCANNER_HELP_RU = """
<h3>Сканер</h3>
<ul>
<li><b>Скан unit-адресов</b>: обход диапазона с списком проб (тип, адрес,
кол-во) и список устройств, ответивших хотя бы на одну пробу. Пробы
добавляются и удаляются выше; <b>Stop</b> прерывает обход.</li>
<li><b>Двойной клик</b> по найденному unit подставляет его в панель
подключения; <b>Device ID…</b> читает идентификацию выбранного unit
(0x2B/0x0E).</li>
<li><b>Скан регистров</b>: проверяет диапазон адресов одного unit и типа.
Регистровые области читаются парами, поэтому найденные значения показаны
колонками dec/hex/s16/u32/s32/f32/ascii (одиночный регистр на границе карты
даёт «—» для 32-битных); coils/discrete inputs — колонка Bool.
Найденные адреса отмечены; лишние можно снять (Space переключает, All/None —
для длинных списков), а <b>Add selected to table</b> создаёт строки таблицы
по отмеченным — дубли (тот же тип и адрес) пропускаются.</li>
</ul>
"""

SNIFFER_HELP_RU = """
<h3>Сниффер</h3>
<p>Комбо <b>Режим</b> переключает вкладку в <b>Сниффер</b> — пассивного
слушателя Modbus RTU шины: он наблюдает за трафиком между существующим
мастером и его слейвами и восстанавливает карту регистров по увиденному, не
отправляя ни одного кадра. Подключите к той же линии RS-485 <b>отдельный
serial-адаптер</b> («тап»): pyserial открывает порт эксклюзивно, поэтому
снифферу нужен свой интерфейс — порт мастера он разделить не может.</p>
<ul>
<li><b>Настройки порта</b> (порт, скорость, биты, чётность, стоп-биты) должны
точно совпадать с настройками шины, иначе кадры превратятся в мусор.</li>
<li><b>Начать сниффинг</b> запускает прослушивание; строка статуса зеленеет.
Для каждого unit id, увиденного на шине, появляется своя <b>вкладка
unit</b>.</li>
<li>Во вкладке unit — таблица наблюдаемых адресов
(<b>адрес</b>/<b>имя</b>/<b>тип</b>/<b>формат</b>/<b>значение</b>/<b>тренд</b>)
и <b>лог кадров этого unit</b>; общий лог сессии внизу показывает все кадры.
Строки появляются автоматически, отсортированные по адресу; имя и формат
отображения редактируются, изменившееся значение вспыхивает зелёным, спарклайн
тренда следует за каждым обновлением.</li>
<li><b>График…</b> открывает окно живого графика строк вкладки (сниффер не
поллит, поэтому кнопки поллинга там нет); <b>Экспорт CSV…</b> пишет таблицу в
формате CSV master-таблицы — файл как есть импортируется в таблицу регистров
master-вкладки.</li>
<li>Ограничения: <b>только serial RTU</b> — Modbus TCP не сниффится;
направление кадра (tx = мастер → слейв, rx = слейв → мастер) на проводе
физически не различить и угадывается эвристически по структуре кадра, поэтому
экзотические коды функций или зашумлённая линия могут классифицироваться
неверно.</li>
</ul>
"""


GATEWAY_HELP_RU = """
<h3>Шлюз</h3>
<p>Комбо <b>Режим</b> переключает вкладку в <b>Шлюз</b> — прозрачный
Modbus-прокси: на стороне <b>Приём</b> поднимается slave-сервер, и каждый
входящий запрос транслируется устройству на стороне <b>Цель</b>. Шлюз нужен,
чтобы связывать сети (например, выставить serial-устройство RTU как Modbus
TCP), логировать трафик между существующим мастером и его устройством или
разделить один serial-порт между несколькими TCP-клиентами. Комбо
заблокировано, пока шлюз запущен.</p>
<h4>Стороны</h4>
<ul>
<li><b>Приём</b> — куда подключаются мастера: <b>TCP</b> (хост/порт, по
умолчанию 1502 — права администратора не нужны), <b>RTU over TCP</b>
(TCP-сокет с RTU-фреймингом) или <b>RTU</b> (serial-порт). Занятый TCP-порт
приводит к ошибке старта в строке статуса.</li>
<li><b>Цель</b> — куда транслируются запросы: любой тип подключения
(<b>TCP</b>, <b>RTU</b>, <b>RTU over TCP</b>, <b>RTU over UDP</b>) со своим
<b>таймаутом</b>. Цель должна быть доступна при старте, иначе шлюз не
запустится.</li>
<li>Работает любое направление: TCP → RTU, RTU → TCP, TCP → TCP,
RTU over TCP → RTU over UDP и т.д. — приём и цель настраиваются независимо.</li>
</ul>
<h4>Фильтр юнитов</h4>
<p>Поле <b>Юниты</b> задаёт unit id, которые обслуживает шлюз: пустое поле —
все (1..247); id и диапазоны через запятую, например
<code>1, 5, 10-20</code>. На запросы к остальным unit шлюз <b>не отвечает</b> —
мастер просто отваливается по таймауту.</p>
<h4>Ошибки</h4>
<ul>
<li>Каждая транзакция попадает в лог сессии
(<code>-&gt; unit 5 read ...</code> / <code>&lt;- ok (N мс)</code>).</li>
<li>Если цель отвечает Modbus-исключением, молчит или запрос падает, мастер
получает <b>Slave Failure (0x04)</b>; реальная причина — в логе
(<code>&lt;- error: ...</code>).</li>
<li>Строка статуса показывает адрес прослушки и число подключённых
TCP-клиентов.</li>
</ul>
"""


SIMULATOR_HELP_RU = """
<h3>Симулятор (slave-режим)</h3>
<p>Комбо <b>Режим</b> выше переключает вкладку между <b>Мастером</b> (опрос
устройства) и <b>Слейвом</b> (эта панель) — эмулятором Modbus-устройства для
отладки мастеров, клиентов и шлюзов без реального железа. Комбо заблокировано,
пока master-сторона подключена или сервер запущен.</p>
<h4>Сервер</h4>
<ul>
<li><b>TCP</b> (хост, порт — по умолчанию 1502, права администратора не
нужны), <b>RTU</b> (порт, скорость, чётность) или <b>RTU over TCP</b>
(TCP-сокет с RTU-фреймингом — для мастеров в режиме «Modbus RTU over TCP»);
<b>Unit</b> задаёт
unit id для ответов, <b>любой</b> — отвечать на любой unit id.</li>
<li><b>Запустить сервер</b> пишет всю карту в datastore и начинает слушать
порт; строка статуса показывает адрес и число подключённых клиентов. Каждый
запрос мастера попадает в лог, а записи мастера обновляют покрывающие строки
карты.</li>
</ul>
<h4>Карта</h4>
<ul>
<li>Каждая строка — диапазон значений: <b>имя</b>, <b>тип</b> (coils,
discrete inputs, holding или input registers), <b>адрес</b> (0..9999, dec или
0x-hex), <b>кол-во</b>, <b>формат</b> отображения и <b>значение</b>. Правка
ручного значения пишется в datastore сразу — даже до старта сервера.
Текстовые форматы: <b>ascii</b> — 2 символа на регистр, <b>ascii1</b> — один
символ на регистр (конвенция строк Wiren Board, например model/firmware).</li>
<li><b>Шаблон…</b> добавляет строки из встроенного шаблона устройства (дубли
по типу+адресу пропускаются); <b>Добавить строку</b> — пустую строку,
✕ удаляет строку.</li>
<li><b>Имена значений…</b> задаёт имена целых значений текущей строки (по
строке <code>значение=имя</code>). Совпавшее значение одиночного регистра
dec/s16 или бита показывается как «имя (N)»; ячейка Value ручной строки
становится комбо, записывающим выбор в datastore сразу, а строка-выражение
только показывает имя. Галочка <b>Битовая маска</b> переключает режим:
имена значений подписывают биты 0..15 строки одиночного регистра
dec/s16/hex, Value перечисляет установленные биты, а ячейка ручной строки
становится кнопкой, открывающей диалог с галочками битов.</li>
</ul>
<h4>Правила</h4>
<p>Колонка <b>Правило</b> выбирает <b>Вручную</b> (значение правите вы) или
<b>Выражение</b> — значение пересчитывается каждые <b>Тик, мс</b> из
<b>текста правила</b>. Синтаксис как у блока выражений master-таблицы:
<code>[имя]</code> — ссылка на значение другой строки, арифметика
(+ - * / // % **), скобки, pi/e и функции (abs, sqrt, sin, min, max,
clamp, …), плюс дополнения симулятора:</p>
<table border="1" cellspacing="0" cellpadding="3">
<tr><th>Дополнение</th><th>Значение</th></tr>
<tr><td>rand()</td><td>случайное число из [0, 1)</td></tr>
<tr><td>randint(a, b)</td><td>случайное целое из [a, b]</td></tr>
<tr><td>t</td><td>секунды с момента старта сервера</td></tr>
<tr><td>prev</td><td>предыдущий результат строки (на первом тике — её текущее
значение)</td></tr>
</table>
<p>Примеры: <code>20+5*sin(2*pi*t/60)</code> — медленный синус;
<code>prev+1</code> — счётчик; <code>min(prev+0.5, 100)</code> — пила с
ограничением.</p>
<ul>
<li><b>⚠</b> — ошибка синтаксиса (текст — в подсказке ячейки). <b>—</b> — на
этом тике значения нет: строка-зависимость отсутствует, ошибка вычисления или
результат не помещается в формат строки; такие тики пропускаются, datastore
хранит старое значение.</li>
<li>Результаты кодируются обратно в регистры с фиксированным порядком байт
<b>ABCD</b> (строки hex/ascii кодируются как dec).</li>
</ul>
"""

HELP_RU = {
    REGISTERS_HELP: REGISTERS_HELP_RU,
    GRAPH_HELP: GRAPH_HELP_RU,
    SCANNER_HELP: SCANNER_HELP_RU,
    EXPRESSIONS_HELP: EXPRESSIONS_HELP_RU,
    SIMULATOR_HELP: SIMULATOR_HELP_RU,
    SNIFFER_HELP: SNIFFER_HELP_RU,
    GATEWAY_HELP: GATEWAY_HELP_RU,
}


REGISTERS_HELP_ZH_CN = """
<h3>寄存器表</h3>
<p>每行代表一段寄存器：<b>名称</b>、<b>类型</b>（线圈、离散输入、保持寄存器或输入寄存器）、
<b>地址</b>（十进制或 0x 十六进制）、<b>数量</b>，以及可选的每行<b>从站地址</b>和
<b>轮询间隔（毫秒）</b>、显示<b>格式</b>、带趋势线的最后读取<b>当前值</b>和用于写入的
<b>新值</b>。s16/u32/s32/f32/u64/s64/f64 按显示格式输入数字（如 f32 输入 0.1），
ascii 输入普通文本，dec/hex 和位区域输入原始值；写入时不应用缩放和偏移。</p>
<ul>
<li><b>首列复选框</b>决定该行是否参与轮询和<b>读取全部</b>；取消勾选后跳过该行，
但 Ctrl+R、快捷操作和写入仍然可用。</li>
<li><b>读取全部</b>读取每个勾选行一次；轮询按钮的下拉菜单选择是否记录历史。
轮询过程中可切换记录模式，无需重启定时器。</li>
<li><b>合并读取</b>将同一轮询周期或“读取全部”中的相邻地址合并为一个请求；
有独立轮询间隔的行不合并。合并读取失败后逐行重试。</li>
<li><b>记录到文件</b>将读取值保存为 CSV 或 JSON Lines；<b>⚙</b>打开文件、格式、字段和行设置。</li>
<li><b>显示设置…</b>设置各行的缩放、偏移、单位和字节序；<b>筛选…</b>隐藏不匹配行；
<b>按地址排序</b>重新排列；<b>CSV</b>导入/导出表格；<b>掩码写入（0x16）…</b>和
<b>读写寄存器（0x17）…</b>执行高级功能。</li>
<li><b>值名称</b>位于显示设置对话框底部，为选中行的整数值命名，每行填写
<code>值=名称</code>（如 <code>0=停止</code>）。单寄存器 dec/s16 或位值匹配时，
显示为“名称 (N)”，“新值”变为下拉框，选择后立即写入。每次写入后重置选择，
因此可以再次选择相同值。勾选<b>位掩码</b>后，名称对应单寄存器 dec/s16/hex 行的位 0..15；
“当前值”列出已置位的名称，如“运行, 报警 (0000 0000 1010 0101)”，
“新值”变为打开位选择对话框的按钮。</li>
<li><b>报警…</b>根据缩放后的值设置每行报警规则（跳过 hex/ascii 行）。
第一个匹配的规则生效，将值单元格标为红色/黄色，优先于数值变化闪烁。
启用日志后，报警触发和解除时各记录一次；启用声音后，触发时发出提示音。</li>
<li><b>表达式</b>（工具栏 fx 按钮）在表格下方显示计算行：<b>[名称]</b>引用其他行缩放后的值，
支持算术（+ - * / // % **）、括号、pi/e 和函数（abs、sqrt、sin、cos、log、min、max、clamp 等）。
每个表达式有独立趋势线，在曲线图中显示为“fx 名称”；仅在轮询并记录模式下保存历史。
无效表达式显示 ⚠，悬停查看错误。表达式也支持报警，在报警对话框中显示为“fx 名称”。</li>
<li><b>快照</b>保存所有行的当前原始值；<b>比较…</b>在创建快照后可用，
将快照与最新值比较并高亮变化行。“（已删除）”表示快照后删除的行。
<b>创建新快照</b>将当前值设为新的比较基准。</li>
<li>右键单击行可执行快捷操作（复制、写入 0/1、加一、减一、翻转、移动），操作作用于选中行。
拖动列标题可调整顺序，右键单击标题可隐藏/显示列；布局在下次启动时保留。</li>
</ul>
<table border="1" cellspacing="0" cellpadding="3">
<tr><th>快捷键</th><th>操作</th></tr>
<tr><td>Enter</td><td>写入当前行的“新值”</td></tr>
<tr><td>Ctrl+R</td><td>读取当前行</td></tr>
<tr><td>Ctrl+Shift+R</td><td>读取所有勾选行</td></tr>
<tr><td>Ctrl+C</td><td>复制值</td></tr>
<tr><td>Ctrl+0 / Ctrl+1</td><td>写入 0 / 1</td></tr>
<tr><td>Ctrl+= / Ctrl+-</td><td>将最后读取值加一/减一（也支持数字键盘 Ctrl++）</td></tr>
<tr><td>Ctrl+T</td><td>翻转（线圈取反；寄存器 0↔1）</td></tr>
<tr><td>Ctrl+Up / Ctrl+Down</td><td>移动选中行</td></tr>
</table>
<p>macOS 使用 ⌘ 代替 Ctrl。</p>
"""

GRAPH_HELP_ZH_CN = """
<h3>曲线图</h3>
<ul>
<li><b>曲线</b>列表选择要绘制的表格行；新增行默认勾选，<b>刷新行列表</b>重新生成列表。
仅列出寄存器表中启用轮询的行（最左侧复选框）；禁用后隐藏对应曲线，重新启用时保留选择状态。</li>
<li><b>X 轴范围</b>：<b>跟随</b>以指定窗口宽度跟随最新数据；<b>全部</b>显示全部数据；
<b>手动</b>固定视图。滚轮以光标为中心缩放，按住鼠标左键拖动平移，<b>框选缩放</b>按矩形区域缩放；
这些操作都会切换到手动模式。<b>重置视图</b>恢复跟随模式。</li>
<li><b>标记线</b>显示两条可拖动的线（绿色 A、红色 B），统计区显示两线之间各曲线的最小值、
最大值、平均值以及时间差 Δt。</li>
<li>鼠标悬停时显示十字光标：垂直虚线和右上角读数，展示各曲线在该时刻的最近采样值。</li>
<li><b>清除</b>删除已记录的历史并重置时间轴。</li>
<li><b>开始轮询并记录</b>控制寄存器表轮询；记录期间点击按钮可停止。</li>
</ul>
"""

EXPRESSIONS_HELP_ZH_CN = """
<h3>表达式</h3>
<p>工具栏的<b>表达式</b>按钮显示计算行区域。每次读取后重新计算表达式，
使用所引用行<b>缩放后</b>的第一个值（已应用缩放/偏移；hex/ascii 行不是数值，不能引用）。</p>
<h4>语法</h4>
<ul>
<li><b>[名称]</b>按名称引用寄存器行，允许空格和中文等 Unicode 字符：
<code>([温度] + [流量]) / 2</code></li>
<li>数字（包括 <code>1e3</code>）、括号、运算符 <code>+ - * / // % **</code>、
一元 <code>+/-</code></li>
<li>常量：<b>pi</b>、<b>e</b></li>
<li>表达式单元格支持自动补全：输入 <b>[</b> 提示寄存器行名称，输入单词开头提示函数和常量；
Enter 插入，Esc 关闭提示。</li>
</ul>
<table border="1" cellspacing="0" cellpadding="3">
<tr><th>函数</th><th>含义</th></tr>
<tr><td>abs(x)</td><td>绝对值</td></tr>
<tr><td>sqrt(x)</td><td>平方根</td></tr>
<tr><td>exp(x)</td><td>e 的 x 次方</td></tr>
<tr><td>log(x) / log2(x) / log10(x)</td><td>自然对数 / 以 2 为底 / 以 10 为底的对数</td></tr>
<tr><td>sin(x) / cos(x) / tan(x)</td><td>三角函数（弧度）</td></tr>
<tr><td>asin(x) / acos(x) / atan(x)</td><td>反三角函数（弧度）</td></tr>
<tr><td>floor(x) / ceil(x) / round(x)</td><td>向下 / 向上 / 就近取整</td></tr>
<tr><td>min(a, b, …) / max(a, b, …)</td><td>参数中的最小值 / 最大值</td></tr>
<tr><td>pow(x, y)</td><td>x 的 y 次方（等同于 x**y）</td></tr>
<tr><td>clamp(x, lo, hi)</td><td>将 x 限制在 [lo, hi] 范围内</td></tr>
</table>
<h4>行为</h4>
<ul>
<li><b>—</b>表示无值：引用行缺失、尚未读取，或计算失败（除零、超出函数定义域、溢出）。</li>
<li><b>⚠</b>表示语法错误，悬停查看错误信息，修正表达式后恢复。</li>
<li>每个表达式都有趋势线，在曲线图中显示为“fx 名称”；
仅在轮询并记录模式下保存历史，曲线图的<b>清除</b>按钮可清空历史。</li>
<li>表达式也支持报警：在<b>报警…</b>对话框中显示为“fx 名称”，
根据计算值为单元格着色；“—”和“⚠”不触发报警。</li>
</ul>
"""

SCANNER_HELP_ZH_CN = """
<h3>扫描器</h3>
<ul>
<li><b>从站扫描</b>使用探测项列表（每项含类型、地址、数量）扫描指定从站范围，
列出至少响应一个探测项的从站。可添加/删除探测项；<b>停止</b>中止扫描。</li>
<li><b>双击</b>找到的从站，可在连接面板中选中它；<b>设备标识…</b>读取该从站的标识（0x2B/0x0E）。</li>
<li><b>寄存器扫描</b>探测指定从站、类型和地址范围。寄存器区域按两个一组读取，
结果以 dec/hex/s16/u32/s32/f32/ascii 各列显示；映射边缘只有一个寄存器时，32 位列显示“—”。
线圈/离散输入显示布尔值。找到的地址默认勾选；取消不需要的行（空格键切换，也可全选/全不选），
点击<b>将选中项添加到表格</b>生成寄存器行；相同类型和地址的重复项会跳过。</li>
</ul>
"""

SNIFFER_HELP_ZH_CN = """
<h3>嗅探器</h3>
<p>将<b>模式</b>切换为<b>嗅探器</b>，即可被动监听 Modbus RTU 总线，
观察现有主站与从站之间的通信，从流量中重建寄存器映射，不发送任何帧。
请将<b>独立的串口适配器</b>接入同一条 RS-485 线路：pyserial 独占打开端口，
嗅探器必须使用自己的接口，无法与主站共用串口。</p>
<ul>
<li><b>串口设置</b>（端口、波特率、数据位、校验位、停止位）必须与总线完全一致，否则无法正确解析帧。</li>
<li><b>开始嗅探</b>后状态变绿；每发现一个从站地址，就创建一个<b>从站标签页</b>。</li>
<li>每个从站标签页包含地址表（<b>地址/名称/类型/格式/当前值/趋势</b>）和该从站的帧日志，
底部会话日志显示所有帧。行自动添加并按地址排序；名称和显示格式可编辑，值变化时绿色闪烁，
趋势线随每次更新变化。</li>
<li><b>曲线图…</b>显示该从站各行的实时曲线；嗅探器不主动轮询，因此没有轮询按钮。
<b>导出 CSV…</b>使用主站表格的 CSV 格式，可直接导入主站标签页的寄存器表。</li>
<li>限制：<b>仅支持串口 RTU</b>，不能嗅探 Modbus TCP。
线路上无法物理区分方向（tx 主站→从站，rx 从站→主站），程序根据帧结构推断；
特殊功能码或线路噪声可能导致方向判断错误。</li>
</ul>
"""

GATEWAY_HELP_ZH_CN = """
<h3>网关</h3>
<p>将<b>模式</b>切换为<b>网关</b>，即可作为透明 Modbus 代理：
在<b>监听端</b>运行从站服务器，将每个请求转发给<b>目标端</b>设备。
可用于跨网络桥接（如将串口 RTU 设备转换为 Modbus TCP）、记录现有主站与设备的通信，
或让多个 TCP 客户端共享一个串口。网关运行期间无法切换模式。</p>
<h4>两端设置</h4>
<ul>
<li><b>监听端</b>供主站连接：支持 <b>TCP</b>（主机/端口，默认 1502，无需管理员权限）、
<b>RTU 透传 TCP</b>（使用 RTU 帧的 TCP 连接）或 <b>RTU</b>（串口）。
TCP 端口被占用时无法启动，状态栏显示错误。</li>
<li><b>目标端</b>接收转发请求，支持任意连接类型：<b>TCP</b>、<b>RTU</b>、
<b>RTU 透传 TCP</b>、<b>RTU 透传 UDP</b>，可单独设置<b>超时</b>。
启动时目标必须可连接，否则网关拒绝启动。</li>
<li>两端独立配置，支持 TCP → RTU、RTU → TCP、TCP → TCP、RTU 透传 TCP → RTU 透传 UDP 等组合。</li>
</ul>
<h4>从站地址筛选</h4>
<p><b>从站地址</b>指定网关服务的地址，留空表示全部 1..247；
用逗号分隔地址和范围，如 <code>1, 5, 10-20</code>。
其他地址的请求<b>不会得到应答</b>，主站将超时。</p>
<h4>错误与日志</h4>
<ul>
<li>每次事务记录到会话日志（<code>-&gt; unit 5 read ...</code> /
<code>&lt;- ok (N ms)</code>）。</li>
<li>目标返回 Modbus 异常、超时或请求失败时，主站收到<b>从站故障 Slave Failure（0x04）</b>；
具体原因见日志（<code>&lt;- error: ...</code>）。</li>
<li>状态栏显示绑定的监听地址和已连接的 TCP 客户端数。</li>
</ul>
"""

SIMULATOR_HELP_ZH_CN = """
<h3>模拟器（从站模式）</h3>
<p>上方<b>模式</b>可将标签页从<b>主站</b>（轮询设备）切换为<b>从站</b>（此面板），
无需真实硬件即可模拟 Modbus 设备，用于调试主站、客户端和网关。
主站连接期间或服务器运行期间无法切换模式。</p>
<h4>服务器</h4>
<ul>
<li>支持 <b>TCP</b>（主机、端口，默认 1502，无需管理员权限）、<b>RTU</b>（串口、波特率、校验位）
或 <b>RTU 透传 TCP</b>（使用 RTU 帧的 TCP 连接）。<b>从站地址</b>选择响应的地址，
<b>任意</b>表示响应所有从站地址。</li>
<li><b>启动服务器</b>将整个映射表写入数据区并开始监听；状态栏显示绑定地址和客户端数。
每个主站请求都记录到日志，主站写入时更新对应的表格行。</li>
</ul>
<h4>寄存器映射表</h4>
<ul>
<li>每行代表一段值：<b>名称</b>、<b>类型</b>（线圈、离散输入、保持寄存器或输入寄存器）、
<b>地址</b>（0..9999，十进制或 0x 十六进制）、<b>数量</b>、显示<b>格式</b>和<b>当前值</b>。
编辑手动值后立即写入数据区，即使服务器尚未启动。文本格式 <b>ascii</b> 每个寄存器存放两个字符，
<b>ascii1</b> 每个寄存器存放一个字符（Wiren Board 的字符串约定，例如型号/固件字符串）。</li>
<li><b>模板…</b>从内置设备模板添加行，跳过类型+地址重复的项；<b>添加行</b>追加空行，✕ 删除行。</li>
<li><b>值名称…</b>为当前行整数值命名，每行填写 <code>值=名称</code>。
单寄存器 dec/s16 或位值匹配时显示为“名称 (N)”；手动行的值单元格变为下拉框，选择后立即写入数据区，
表达式行仅显示名称。勾选<b>位掩码</b>后，名称对应单寄存器 dec/s16/hex 行的位 0..15；
值单元格列出置位项，手动行可通过按钮打开位选择对话框。</li>
</ul>
<h4>规则</h4>
<p><b>规则</b>列可选择<b>手动</b>（自行编辑值）或<b>表达式</b>，后者按<b>更新周期（毫秒）</b>
根据<b>规则表达式</b>重新计算。语法与主站表达式相同：<code>[名称]</code>引用其他行的值，
支持算术（+ - * / // % **）、括号、pi/e 和函数（abs、sqrt、sin、min、max、clamp 等），
还支持以下模拟器专用项：</p>
<table border="1" cellspacing="0" cellpadding="3">
<tr><th>扩展项</th><th>含义</th></tr>
<tr><td>rand()</td><td>[0, 1) 内的随机浮点数</td></tr>
<tr><td>randint(a, b)</td><td>[a, b] 内的随机整数</td></tr>
<tr><td>t</td><td>服务器启动后经过的秒数</td></tr>
<tr><td>prev</td><td>该行上次的计算结果，第一次更新时使用当前值</td></tr>
</table>
<p>示例：<code>20+5*sin(2*pi*t/60)</code> 生成慢速正弦；<code>prev+1</code> 为计数器；
<code>min(prev+0.5, 100)</code> 逐步增长到上限。</p>
<ul>
<li><b>⚠</b>表示语法错误，悬停查看详情；<b>—</b>表示本次无值：引用行缺失、计算失败或结果超出行格式范围。
此时跳过本次更新，数据区保留旧值。</li>
<li>结果以固定 <b>ABCD</b> 字节序编码回寄存器（hex/ascii 行按 dec 编码）。</li>
</ul>
"""

HELP_ZH_CN = {
    REGISTERS_HELP: REGISTERS_HELP_ZH_CN,
    GRAPH_HELP: GRAPH_HELP_ZH_CN,
    SCANNER_HELP: SCANNER_HELP_ZH_CN,
    EXPRESSIONS_HELP: EXPRESSIONS_HELP_ZH_CN,
    SIMULATOR_HELP: SIMULATOR_HELP_ZH_CN,
    SNIFFER_HELP: SNIFFER_HELP_ZH_CN,
    GATEWAY_HELP: GATEWAY_HELP_ZH_CN,
}
