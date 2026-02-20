#!/usr/bin/env python3
"""System tray application for monitoring and controlling the MSSQL Podman container."""

import os
import signal
import subprocess
import sys
from enum import Enum

from PyQt5.QtCore import QTimer
from PyQt5.QtGui import QColor, QIcon, QPainter, QPixmap
from PyQt5.QtWidgets import QAction, QApplication, QMenu, QSystemTrayIcon

# ── Configuration ────────────────────────────────────────────────────────────

CONTAINER_NAME = os.environ.get("MSSQL_CONTAINER_NAME", "mssql-server")
MSSQL_SH_PATH = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "mssql.sh",
)
POLL_INTERVAL_MS = 5000  # 5 seconds


# ── Domain ───────────────────────────────────────────────────────────────────


class ContainerStatus(Enum):
    RUNNING = "running"
    STOPPED = "stopped"
    UNKNOWN = "unknown"

    @property
    def color(self) -> str:
        return {
            ContainerStatus.RUNNING: "green",
            ContainerStatus.STOPPED: "red",
            ContainerStatus.UNKNOWN: "yellow",
        }[self]

    @property
    def label(self) -> str:
        return {
            ContainerStatus.RUNNING: "Running",
            ContainerStatus.STOPPED: "Stopped",
            ContainerStatus.UNKNOWN: "Unknown",
        }[self]


def build_icon(color: str) -> QPixmap:
    """Draw a 22x22 filled circle icon for the given color name."""
    size = 22
    pixmap = QPixmap(size, size)
    pixmap.fill(QColor(0, 0, 0, 0))  # transparent background
    painter = QPainter(pixmap)
    painter.setRenderHint(QPainter.Antialiasing)
    painter.setBrush(QColor(color))
    painter.setPen(QColor(color).darker(120))
    margin = 2
    painter.drawEllipse(margin, margin, size - 2 * margin, size - 2 * margin)
    painter.end()
    return pixmap


# ── Container Monitor ────────────────────────────────────────────────────────


class ContainerMonitor:
    """Polls podman for container status and dispatches actions via mssql.sh."""

    def __init__(self, container_name: str, mssql_sh_path: str):
        self.container_name = container_name
        self.mssql_sh_path = mssql_sh_path
        self._last_status: ContainerStatus | None = None
        self.on_status_change = None  # callback(new_status)

    def check_status(self) -> ContainerStatus:
        """Query podman for the current container status."""
        try:
            result = subprocess.run(
                ["podman", "ps", "--format", "{{.Names}}"],
                capture_output=True,
                text=True,
                timeout=10,
            )
            names = result.stdout.strip().splitlines()
            if self.container_name in names:
                return ContainerStatus.RUNNING
            return ContainerStatus.STOPPED
        except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
            return ContainerStatus.UNKNOWN

    def poll(self):
        """Check status and fire callback if it changed."""
        current = self.check_status()
        if current != self._last_status:
            self._last_status = current
            if self.on_status_change:
                self.on_status_change(current)

    def start(self):
        subprocess.Popen(
            [self.mssql_sh_path, "start"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

    def stop(self):
        subprocess.Popen(
            [self.mssql_sh_path, "stop"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

    def restart(self):
        subprocess.Popen(
            [self.mssql_sh_path, "restart"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )


# ── Tray Application ────────────────────────────────────────────────────────


class MssqlTrayApp:
    """Qt system tray icon for MSSQL container management."""

    def __init__(self, app: QApplication, monitor: ContainerMonitor):
        self.app = app
        self.monitor = monitor

        # Build icons for each status
        self._icons = {
            status: QIcon(build_icon(status.color)) for status in ContainerStatus
        }

        # Tray icon
        self.tray = QSystemTrayIcon()
        self.tray.setIcon(self._icons[ContainerStatus.UNKNOWN])
        self.tray.setToolTip("MSSQL: checking...")

        # Context menu
        self.menu = QMenu()
        self.status_action = QAction("Status: checking...")
        self.status_action.setEnabled(False)
        self.menu.addAction(self.status_action)
        self.menu.addSeparator()

        start_action = QAction("Start", self.menu)
        start_action.triggered.connect(self._on_start)
        self.menu.addAction(start_action)

        stop_action = QAction("Stop", self.menu)
        stop_action.triggered.connect(self._on_stop)
        self.menu.addAction(stop_action)

        restart_action = QAction("Restart", self.menu)
        restart_action.triggered.connect(self._on_restart)
        self.menu.addAction(restart_action)

        self.menu.addSeparator()

        quit_action = QAction("Quit", self.menu)
        quit_action.triggered.connect(self.app.quit)
        self.menu.addAction(quit_action)

        self.tray.setContextMenu(self.menu)

        # Status polling
        self.monitor.on_status_change = self._on_status_change
        self.timer = QTimer()
        self.timer.timeout.connect(self.monitor.poll)
        self.timer.start(POLL_INTERVAL_MS)

        # Initial poll
        self.monitor.poll()

        self.tray.show()

    def _on_status_change(self, status: ContainerStatus):
        self.tray.setIcon(self._icons[status])
        self.tray.setToolTip(f"MSSQL: {status.label}")
        self.status_action.setText(f"Status: {status.label}")

    def _on_start(self):
        self.tray.setToolTip("MSSQL: Starting...")
        self.status_action.setText("Status: Starting...")
        self.tray.setIcon(self._icons[ContainerStatus.UNKNOWN])
        self.monitor.start()

    def _on_stop(self):
        self.tray.setToolTip("MSSQL: Stopping...")
        self.status_action.setText("Status: Stopping...")
        self.tray.setIcon(self._icons[ContainerStatus.UNKNOWN])
        self.monitor.stop()

    def _on_restart(self):
        self.tray.setToolTip("MSSQL: Restarting...")
        self.status_action.setText("Status: Restarting...")
        self.tray.setIcon(self._icons[ContainerStatus.UNKNOWN])
        self.monitor.restart()


# ── Main ─────────────────────────────────────────────────────────────────────


def main():
    # Allow Ctrl+C to work
    signal.signal(signal.SIGINT, signal.SIG_DFL)

    app = QApplication(sys.argv)
    app.setQuitOnLastWindowClosed(False)

    if not QSystemTrayIcon.isSystemTrayAvailable():
        print("Error: System tray is not available.", file=sys.stderr)
        sys.exit(1)

    monitor = ContainerMonitor(
        container_name=CONTAINER_NAME,
        mssql_sh_path=MSSQL_SH_PATH,
    )
    tray_app = MssqlTrayApp(app, monitor)  # noqa: F841

    sys.exit(app.exec_())


if __name__ == "__main__":
    main()
