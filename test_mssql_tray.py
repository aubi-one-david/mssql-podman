"""TDD tests for MSSQL system tray application."""

import os
import subprocess
import sys
import unittest
from unittest.mock import MagicMock, patch

# QPixmap requires a QApplication instance before use
from PyQt5.QtWidgets import QApplication

_app = QApplication.instance() or QApplication(sys.argv + ["-platform", "offscreen"])

from mssql_tray import ContainerStatus, ContainerMonitor, build_icon


class TestContainerStatus(unittest.TestCase):
    """Test the ContainerStatus enum values."""

    def test_enum_values_exist(self):
        self.assertEqual(ContainerStatus.RUNNING.value, "running")
        self.assertEqual(ContainerStatus.STOPPED.value, "stopped")
        self.assertEqual(ContainerStatus.UNKNOWN.value, "unknown")

    def test_colors(self):
        """Each status should map to a color for the tray icon."""
        self.assertEqual(ContainerStatus.RUNNING.color, "green")
        self.assertEqual(ContainerStatus.STOPPED.color, "red")
        self.assertEqual(ContainerStatus.UNKNOWN.color, "yellow")


class TestContainerMonitor(unittest.TestCase):
    """Test ContainerMonitor status checking and callbacks."""

    def setUp(self):
        self.monitor = ContainerMonitor(
            container_name="mssql-server-test",
            mssql_sh_path="/fake/mssql.sh",
        )

    @patch("mssql_tray.subprocess.run")
    def test_check_status_running(self, mock_run):
        """When podman ps lists the container, status should be RUNNING."""
        mock_run.return_value = subprocess.CompletedProcess(
            args=[], returncode=0, stdout="mssql-server-test\n"
        )
        status = self.monitor.check_status()
        self.assertEqual(status, ContainerStatus.RUNNING)
        mock_run.assert_called_once_with(
            ["podman", "ps", "--format", "{{.Names}}"],
            capture_output=True,
            text=True,
            timeout=10,
        )

    @patch("mssql_tray.subprocess.run")
    def test_check_status_stopped_not_listed(self, mock_run):
        """When podman ps doesn't list it, status should be STOPPED."""
        mock_run.return_value = subprocess.CompletedProcess(
            args=[], returncode=0, stdout="other-container\n"
        )
        status = self.monitor.check_status()
        self.assertEqual(status, ContainerStatus.STOPPED)

    @patch("mssql_tray.subprocess.run")
    def test_check_status_stopped_empty(self, mock_run):
        """When podman ps returns empty output, status should be STOPPED."""
        mock_run.return_value = subprocess.CompletedProcess(
            args=[], returncode=0, stdout=""
        )
        status = self.monitor.check_status()
        self.assertEqual(status, ContainerStatus.STOPPED)

    @patch("mssql_tray.subprocess.run")
    def test_check_status_unknown_on_error(self, mock_run):
        """When podman command fails, status should be UNKNOWN."""
        mock_run.side_effect = subprocess.TimeoutExpired(cmd=[], timeout=10)
        status = self.monitor.check_status()
        self.assertEqual(status, ContainerStatus.UNKNOWN)

    @patch("mssql_tray.subprocess.run")
    def test_check_status_unknown_on_exception(self, mock_run):
        """When podman is not found, status should be UNKNOWN."""
        mock_run.side_effect = FileNotFoundError()
        status = self.monitor.check_status()
        self.assertEqual(status, ContainerStatus.UNKNOWN)

    @patch("mssql_tray.subprocess.run")
    def test_check_status_multiple_containers(self, mock_run):
        """Should find our container among multiple running containers."""
        mock_run.return_value = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout="postgres-dev\nmssql-server-test\nredis-cache\n",
        )
        status = self.monitor.check_status()
        self.assertEqual(status, ContainerStatus.RUNNING)

    def test_on_status_change_callback(self):
        """Callback should fire when status transitions."""
        callback = MagicMock()
        self.monitor.on_status_change = callback
        self.monitor._last_status = ContainerStatus.STOPPED

        with patch("mssql_tray.subprocess.run") as mock_run:
            mock_run.return_value = subprocess.CompletedProcess(
                args=[], returncode=0, stdout="mssql-server-test\n"
            )
            self.monitor.poll()

        callback.assert_called_once_with(ContainerStatus.RUNNING)

    def test_no_callback_when_status_unchanged(self):
        """Callback should NOT fire when status stays the same."""
        callback = MagicMock()
        self.monitor.on_status_change = callback
        self.monitor._last_status = ContainerStatus.RUNNING

        with patch("mssql_tray.subprocess.run") as mock_run:
            mock_run.return_value = subprocess.CompletedProcess(
                args=[], returncode=0, stdout="mssql-server-test\n"
            )
            self.monitor.poll()

        callback.assert_not_called()


class TestContainerActions(unittest.TestCase):
    """Test start/stop/restart actions delegate to mssql.sh."""

    def setUp(self):
        self.monitor = ContainerMonitor(
            container_name="mssql-server-test",
            mssql_sh_path="/fake/mssql.sh",
        )

    @patch("mssql_tray.subprocess.Popen")
    def test_start_calls_mssql_sh(self, mock_popen):
        """Start should call mssql.sh start."""
        self.monitor.start()
        mock_popen.assert_called_once_with(
            ["/fake/mssql.sh", "start"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

    @patch("mssql_tray.subprocess.Popen")
    def test_stop_calls_mssql_sh(self, mock_popen):
        """Stop should call mssql.sh stop."""
        self.monitor.stop()
        mock_popen.assert_called_once_with(
            ["/fake/mssql.sh", "stop"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

    @patch("mssql_tray.subprocess.Popen")
    def test_restart_calls_mssql_sh(self, mock_popen):
        """Restart should call mssql.sh restart."""
        self.monitor.restart()
        mock_popen.assert_called_once_with(
            ["/fake/mssql.sh", "restart"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )


class TestBuildIcon(unittest.TestCase):
    """Test that build_icon produces a QPixmap of the right size."""

    def test_icon_size(self):
        """Icon should be 22x22 pixels."""
        pixmap = build_icon("green")
        self.assertEqual(pixmap.width(), 22)
        self.assertEqual(pixmap.height(), 22)

    def test_icon_not_null(self):
        """Icon pixmap should not be null for valid colors."""
        for color in ("green", "red", "yellow"):
            pixmap = build_icon(color)
            self.assertFalse(pixmap.isNull(), f"Pixmap for {color} should not be null")


if __name__ == "__main__":
    unittest.main()
