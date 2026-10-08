"""Disposable loopback SSH/SFTP server; all credentials and keys are synthetic."""
import argparse
import json
import logging
import socket
import threading
import time
from pathlib import Path

import paramiko

logging.getLogger("paramiko").setLevel(logging.CRITICAL)
parser = argparse.ArgumentParser()
parser.add_argument("--ready", required=True)
parser.add_argument("--stats", required=True)
args = parser.parse_args()
stats = {"auth": 0, "exec": 0}
lock = threading.Lock()


def count(name):
    with lock:
        stats[name] += 1
        Path(args.stats).write_text(json.dumps(stats), encoding="utf-8")


class Server(paramiko.ServerInterface):
    def get_allowed_auths(self, username):
        return "password"

    def check_auth_password(self, username, password):
        count("auth")
        return paramiko.AUTH_SUCCESSFUL if username == "fixture" and password == "fixture-only" else paramiko.AUTH_FAILED

    def check_channel_request(self, kind, chanid):
        return paramiko.OPEN_SUCCEEDED if kind == "session" else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED

    def check_channel_exec_request(self, channel, command):
        count("exec")
        return False


key = paramiko.RSAKey.generate(2048)
listener = socket.socket()
listener.bind(("127.0.0.1", 0))
listener.listen(8)
Path(args.stats).write_text(json.dumps(stats), encoding="utf-8")
Path(args.ready).write_text(json.dumps({"port": listener.getsockname()[1]}), encoding="utf-8")


def handle(client):
    transport = paramiko.Transport(client)
    try:
        transport.add_server_key(key)
        transport.set_subsystem_handler("sftp", paramiko.SFTPServer, paramiko.SFTPServerInterface)
        transport.start_server(server=Server())
        while transport.is_active():
            time.sleep(0.05)
    except (paramiko.SSHException, EOFError, OSError):
        pass
    finally:
        transport.close()


while True:
    client, address = listener.accept()
    threading.Thread(target=handle, args=(client,), daemon=True).start()
