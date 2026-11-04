from dataclasses import dataclass
from enum import Enum
import queue
import struct
import sys
import time

from PySide6.QtCore import Qt, QThread, Signal
from PySide6.QtWidgets import (
    QApplication,
    QCheckBox,
    QComboBox,
    QFrame,
    QGridLayout,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QMainWindow,
    QPushButton,
    QScrollArea,
    QVBoxLayout,
    QWidget,
)
import serial
import serial.tools.list_ports


# ==========================================
# 1. Register definitions and configuration
# ==========================================
class RegType(Enum):
    INT32 = "int32"
    FLOAT = "float"
    ASCII = "ascii"
    BITS = "bits"


@dataclass
class RegConfig:
    index: int
    name: str
    reg_type: RegType
    bit_Count: int = 8

NUM_REGISTERS = 16
REGISTER_CONFIGS = []
for i in range(NUM_REGISTERS):
    if i == 0:
        REGISTER_CONFIGS.append(
            RegConfig(i, f"REG_{i:02d}_BIT", RegType.BITS, bit_Count=8)
        )
    else:
        REGISTER_CONFIGS.append(RegConfig(i, f"REG_{i:02d}_INT", RegType.INT32))
        
# ==========================================
# 2. Serial communication worker thread
# ==========================================
class SerialWorker(QThread):
    data_received = Signal(bytes)
    status_changed = Signal(str)
    connection_Result = Signal(bool)  # Connection succeeded (True) / failed or disconnected (False)

    def __init__(self, port: str, baudrate: int = 115200):
        super().__init__()
        self.port = port
        self.baudrate = baudrate
        self.dummy_mode = port == "DUMMY"
        self.running = True
        self.write_queue = queue.Queue()

        # Initialize internal memory for dummy mode.
        self._dummy_memory = bytearray(256)
        for i in range(NUM_REGISTERS):
            if REGISTER_CONFIGS[i].reg_type == RegType.FLOAT:
                struct.pack_into(">f", self._dummy_memory, i * 4, i * 1.5)
            elif REGISTER_CONFIGS[i].reg_type == RegType.ASCII:
                struct.pack_into(">4s", self._dummy_memory, i * 4, b"ABCD")
            else:
                struct.pack_into(">i", self._dummy_memory, i * 4, i * 10)

    def enqueue_write(self, reg_index: int, raw_bytes: bytes):
        if len(raw_bytes) == 4:
            self.write_queue.put((reg_index, raw_bytes))

    def run(self):
        ser = None
        if not self.dummy_mode:
            try:
                ser = serial.Serial(self.port, self.baudrate, timeout=0.05)
                self.status_changed.emit(
                    f"Connected: {self.port} ({self.baudrate} bps)"
                )
                self.connection_Result.emit(True)
            except Exception as e:
                self.status_changed.emit(f"Connection Error ({self.port}): {e}")
                self.connection_Result.emit(False)
                return  # Exit the thread immediately if the connection fails.
        else:
            self.status_changed.emit("Connected: DUMMY (simulation mode)")
            self.connection_Result.emit(True)

        while self.running:
            cycle_start = time.perf_counter()

            try:
                # --- A. Process write requests ---
                while not self.write_queue.empty():
                    reg_idx, data_4bytes = self.write_queue.get()
                    if self.dummy_mode:
                        self._dummy_memory[reg_idx * 4 : (reg_idx + 1) * 4] = (
                            data_4bytes
                        )
                    else:
                        cmd = bytes([0x77, reg_idx]) + data_4bytes # 0x77: 'w'
                        ser.write(cmd)

                # --- B. Read all NUM_REGISTERS registers (NUM_REGISTERS * 4 bytes) at once ---
                if self.dummy_mode:
                    val = struct.unpack_from(">i", self._dummy_memory, 0)[0]
                    struct.pack_into(
                        ">i", self._dummy_memory, 0, (val + 1) % 10000
                    )
                    raw_data = bytes(self._dummy_memory)
                else:
                    ser.write(bytes([0x52, 0x00, NUM_REGISTERS])) # 0x52: 'R'
                    raw_data = ser.read(NUM_REGISTERS * 4)

                if len(raw_data) == NUM_REGISTERS * 4:
                    self.data_received.emit(raw_data)

            except serial.SerialException as e:
                # Detect unexpected disconnections, such as a USB cable being unplugged.
                self.status_changed.emit(f"Disconnected by error: {e}")
                break

            # --- C. Wait for the 0.1-second (100 ms) cycle ---
            elapsed = time.perf_counter() - cycle_start
            sleep_time = max(0.005, 0.1 - elapsed)
            time.sleep(sleep_time)

        if ser and ser.is_open:
            ser.close()

        self.connection_Result.emit(False)

    def stop(self):
        self.running = False
        self.wait()


# ==========================================
# 3. Individual register UI widget
# ==========================================
class RegisterWidget(QFrame):
    write_requested = Signal(int, bytes)

    def __init__(self, config: RegConfig):
        super().__init__()
        self.config = config
        self.current_raw = None  # Initialize to None to ensure the first update is applied.

        self.setFrameShape(QFrame.StyledPanel)
        layout = QHBoxLayout(self)
        layout.setContentsMargins(6, 4, 6, 4)

        lbl_name = QLabel(
            f"[{config.index:02d}] {config.name} ({config.reg_type.value})"
        )
        lbl_name.setFixedWidth(160)
        lbl_name.setStyleSheet("font-weight: bold;")
        layout.addWidget(lbl_name)

        self.lbl_hex = QLabel("0x--------")
        self.lbl_hex.setFixedWidth(85)
        self.lbl_hex.setStyleSheet("color: #666; font-family: monospace;")
        layout.addWidget(self.lbl_hex)

        if config.reg_type == RegType.BITS:
            self.checkboxes = []
            bit_layout = QHBoxLayout()
            bit_layout.setSpacing(6)
            for b in range(config.bit_Count):
                cb = QCheckBox(f"B{b}")
                cb.clicked.connect(self._on_bit_clicked)
                self.checkboxes.append(cb)
                bit_layout.addWidget(cb)
            bit_layout.addStretch()
            layout.addLayout(bit_layout)
        else:
            self.line_edit = QLineEdit()
            self.line_edit.setPlaceholderText("Enter to write")
            self.line_edit.returnPressed.connect(self._on_text_submitted)
            layout.addWidget(self.line_edit)

    def update_display(self, raw_4bytes: bytes):
        if raw_4bytes == self.current_raw:
            return
        self.current_raw = raw_4bytes

        uint_val = struct.unpack(">I", raw_4bytes)[0]
        self.lbl_hex.setText(f"0x{uint_val:08X}")

        if self.config.reg_type == RegType.BITS:
            for b, cb in enumerate(self.checkboxes):
                cb.blockSignals(True)
                cb.setChecked(bool(uint_val & (1 << b)))
                cb.blockSignals(False)
            return

        if self.line_edit.hasFocus():
            return

        if self.config.reg_type == RegType.INT32:
            val = struct.unpack(">i", raw_4bytes)[0]
            self.line_edit.setText(str(val))
        elif self.config.reg_type == RegType.FLOAT:
            val = struct.unpack(">f", raw_4bytes)[0]
            self.line_edit.setText(f"{val:.4f}")
        elif self.config.reg_type == RegType.ASCII:
            text = raw_4bytes.decode("ascii", errors="replace").rstrip("\x00")
            self.line_edit.setText(text)

    def _on_text_submitted(self):
        text = self.line_edit.text().strip()
        try:
            if self.config.reg_type == RegType.INT32:
                raw = struct.pack(">i", int(text))
            elif self.config.reg_type == RegType.FLOAT:
                raw = struct.pack(">f", float(text))
            elif self.config.reg_type == RegType.ASCII:
                raw = text.encode("ascii", errors="ignore")[:4].ljust(
                    4, b"\x00"
                )

            self.write_requested.emit(self.config.index, raw)
            self.line_edit.clearFocus()
            if self.config.index in (1, 2):
                self.line_edit.setStyleSheet(
                    "background-color: #2e7d32; color: #ffffff;"
                )
            else:
                self.line_edit.setStyleSheet("background-color: #e6ffed;")
        except ValueError:
            self.line_edit.setStyleSheet("background-color: #ffeef0;")

    def _on_bit_clicked(self):
        if self.current_raw is None:
            return
        uint_val = struct.unpack(">I", self.current_raw)[0]
        for b, cb in enumerate(self.checkboxes):
            if cb.isChecked():
                uint_val |= 1 << b
            else:
                uint_val &= ~(1 << b)

        raw = struct.pack(">I", uint_val)
        self.write_requested.emit(self.config.index, raw)


# ==========================================
# 4. Main window
# ==========================================
class MainWindow(QMainWindow):

    def __init__(self):
        super().__init__()
        self.setWindowTitle("Control GUI")
        self.resize(1100, 780)
        self.worker = None
        self.is_connected = False

        central = QWidget()
        self.setCentralWidget(central)
        main_layout = QVBoxLayout(central)

        # --- Top: COM port connection control bar ---
        conn_bar = QHBoxLayout()

        conn_bar.addWidget(QLabel("COM PORT:"))
        self.combo_ports = QComboBox()
        self.combo_ports.setMinimumWidth(260)
        conn_bar.addWidget(self.combo_ports)

        self.btn_refresh = QPushButton("RESCAN")
        self.btn_refresh.clicked.connect(self.refresh_ports)
        conn_bar.addWidget(self.btn_refresh)

        self.btn_connect = QPushButton("CONNECT")
        self.btn_connect.setFixedWidth(100)
        self.btn_connect.setStyleSheet("font-weight: bold;")
        self.btn_connect.clicked.connect(self.toggle_connection)
        conn_bar.addWidget(self.btn_connect)

        conn_bar.addSpacing(20)
        self.lbl_status = QLabel("Unconnected")
        self.lbl_status.setStyleSheet("font-size: 13px; color: #444;")
        conn_bar.addWidget(self.lbl_status, 1)  # Use the remaining space.

        main_layout.addLayout(conn_bar)

        # --- Center: Register list ---
        scroll = QScrollArea()
        #scroll.setWidgetResizable(True)
        self.reg_container = QWidget()
        grid = QGridLayout(self.reg_container)
        grid.setSpacing(6)

        self.reg_widgets = []
        for i, cfg in enumerate(REGISTER_CONFIGS):
            w = RegisterWidget(cfg)
            w.write_requested.connect(self.on_write_requested)
            self.reg_widgets.append(w)
            grid.addWidget(w, i, 0)

        scroll.setWidget(self.reg_container)
        main_layout.addWidget(scroll)

        # Disable register controls initially and populate the port list.
        self.reg_container.setEnabled(False)
        self.refresh_ports()

    def refresh_ports(self):
        """Find serial ports connected to the PC and update the drop-down list."""
        self.combo_ports.clear()
        ports = serial.tools.list_ports.comports()
        for p in ports:
            # Show "COM3 - USB Serial Port" while storing "COM3" as the item data.
            self.combo_ports.addItem(f"{p.device} - {p.description}", p.device)

        # Add a dummy port for testing.
        self.combo_ports.addItem("DUMMY (simulation)", "DUMMY")

    def toggle_connection(self):
        """Toggle the connection when the connect/disconnect button is clicked."""
        if not self.is_connected:
            port_name = self.combo_ports.currentData()
            if not port_name:
                return

            # Lock the UI while connecting.
            self.btn_connect.setEnabled(False)
            self.worker = SerialWorker(port=port_name, baudrate=115200)
            self.worker.data_received.connect(self.on_data_received)
            self.worker.status_changed.connect(self.lbl_status.setText)
            self.worker.connection_Result.connect(self.on_connection_result)
            self.worker.start()
        else:
            # Disconnect.
            if self.worker:
                self.worker.stop()
                self.worker = None
            self.lbl_status.setText("Disconnected")

    def on_connection_result(self, connected: bool):
        """Update the UI state in response to a connection or disconnection notification."""
        self.is_connected = connected
        self.btn_connect.setEnabled(True)

        if connected:
            self.btn_connect.setText("DISCONNECT")
            self.btn_connect.setStyleSheet(
                "font-weight: bold; background-color: #ffcccc;"
            )
            self.combo_ports.setEnabled(False)
            self.btn_refresh.setEnabled(False)
            self.reg_container.setEnabled(True)
        else:
            self.btn_connect.setText("CONNECT")
            self.btn_connect.setStyleSheet("font-weight: bold;")
            self.combo_ports.setEnabled(True)
            self.btn_refresh.setEnabled(True)
            self.reg_container.setEnabled(False)

    def on_write_requested(self, reg_index: int, raw_bytes: bytes):
        """Forward a write request from an individual widget to the current worker thread."""
        if self.worker and self.is_connected:
            self.worker.enqueue_write(reg_index, raw_bytes)

    def on_data_received(self, raw_all_bytes: bytes):
        for i in range(NUM_REGISTERS):
            chunk = raw_all_bytes[i * 4 : (i + 1) * 4]
            self.reg_widgets[i].update_display(chunk)

    def closeEvent(self, event):
        if self.worker:
            self.worker.stop()
        super().closeEvent(event)


if __name__ == "__main__":
    app = QApplication(sys.argv)
    win = MainWindow()
    win.show()
    sys.exit(app.exec())