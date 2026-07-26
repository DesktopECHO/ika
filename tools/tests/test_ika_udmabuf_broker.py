#!/usr/bin/env python3

import errno
import importlib.machinery
import importlib.util
import pathlib
import socket
import sys
import threading
import unittest


SCRIPT = pathlib.Path(__file__).parents[1] / "ika-udmabuf-broker"
LOADER = importlib.machinery.SourceFileLoader("ika_udmabuf_broker", str(SCRIPT))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[LOADER.name] = MODULE
LOADER.exec_module(MODULE)


class BrokerCapacityTest(unittest.TestCase):
    def make_broker(self, entries=(), max_entries=4, max_bytes=4096):
        broker = MODULE.Broker.__new__(MODULE.Broker)
        broker.entries = list(entries)
        broker.max_entries = max_entries
        broker.max_bytes = max_bytes
        broker.total_bytes = sum(entry.size for entry in entries)
        broker.next_ident = len(entries) + 1
        broker.lock = threading.Lock()

        def create(size):
            entry = MODULE.Entry(broker.next_ident, size, -1, -1)
            broker.next_ident += 1
            broker.entries.append(entry)
            broker.total_bytes += size
            return entry

        broker._create_entry = create
        return broker

    def test_reuses_exact_size_at_capacity(self):
        entry = MODULE.Entry(1, 1024, -1, -1)
        broker = self.make_broker(
            [entry], max_entries=1, max_bytes=1024
        )

        self.assertIs(broker._lease(object(), 1024), entry)

    def test_rejects_new_entry_at_count_limit(self):
        broker = self.make_broker(
            [MODULE.Entry(1, 1024, -1, -1)],
            max_entries=1,
            max_bytes=4096,
        )

        with self.assertRaises(OSError) as raised:
            broker._lease(object(), 2048)
        self.assertEqual(raised.exception.errno, errno.ENOSPC)

    def test_rejects_new_entry_over_byte_limit(self):
        broker = self.make_broker(
            [MODULE.Entry(1, 3072, -1, -1)],
            max_entries=4,
            max_bytes=4096,
        )

        with self.assertRaises(OSError) as raised:
            broker._lease(object(), 2048)
        self.assertEqual(raised.exception.errno, errno.ENOSPC)

    def test_creates_entry_within_both_limits(self):
        broker = self.make_broker(max_entries=1, max_bytes=4096)

        entry = broker._lease(object(), 2048)

        self.assertEqual(entry.size, 2048)
        self.assertEqual(broker.total_bytes, 2048)
        self.assertEqual(len(broker.entries), 1)

    def test_capacity_refusal_is_returned_without_descriptors(self):
        broker = MODULE.Broker.__new__(MODULE.Broker)
        broker.uid = MODULE.os.getuid()
        broker.stopping = threading.Event()
        broker.entries = []
        broker.lock = threading.Lock()

        def refuse(_owner, _size):
            raise OSError(errno.ENOSPC, "test limit")

        broker._lease = refuse
        server, client = socket.socketpair(
            socket.AF_UNIX, socket.SOCK_SEQPACKET
        )
        thread = threading.Thread(target=broker._serve_client, args=(server,))
        thread.start()

        client.send(MODULE.REQUEST.pack(MODULE.MAGIC, MODULE.VERSION, 4096))
        payload, ancillary, _flags, _address = client.recvmsg(
            MODULE.RESPONSE.size, socket.CMSG_SPACE(8)
        )
        client.close()
        thread.join(timeout=1)
        self.assertFalse(thread.is_alive())

        magic, status, ident = MODULE.RESPONSE.unpack(payload)
        self.assertEqual(magic, MODULE.MAGIC)
        self.assertEqual(status, -errno.ENOSPC)
        self.assertEqual(ident, 0)
        self.assertEqual(ancillary, [])


if __name__ == "__main__":
    unittest.main()
