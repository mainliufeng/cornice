"""A test-owned native viewer with the same heartbeat as a visible UI.

Requests share one socket and lock. Closing stops polling before disconnect,
so viewer-loss and compositor revocation still exercise production fail-close.
"""
import socket
import threading
from desktop_harness import broker_socket, rpc


class NativeViewer:
    def __init__(self, name):
        self.name = name
        self.connection = socket.socket(socket.AF_UNIX)
        self.connection.settimeout(4)
        self.connection.connect(str(broker_socket()))
        self.lock = threading.Lock()
        self.stopped = threading.Event()
        self.error = None
        self.thread = threading.Thread(target=self.heartbeat, daemon=True)
        self.thread.start()

    def request(self, method, params):
        with self.lock:
            if self.error is not None:
                raise RuntimeError("Private native viewer heartbeat failed") from self.error
            return rpc(self.connection, method, params)

    def heartbeat(self):
        while not self.stopped.wait(.5):
            try:
                self.request("present-status", {"name": self.name})
            except Exception as error:
                self.error = error
                return

    def close(self):
        self.stopped.set()
        self.thread.join(timeout=5)
        try:
            assert not self.thread.is_alive(), "Private viewer heartbeat did not stop"
            if self.error is not None:
                raise RuntimeError("Private native viewer heartbeat failed before close") from self.error
        finally:
            self.connection.close()
