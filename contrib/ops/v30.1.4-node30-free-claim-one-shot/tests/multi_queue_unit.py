#!/usr/bin/env python3
"""Offline ownership and immutable-read checks for real API ingress parity."""
import contextlib
import importlib.util
import json
import os
import pathlib
import stat
import tempfile
import types
import unittest
from unittest import mock

TOOL = pathlib.Path(__file__).resolve().parents[1] / "node30_free_claim_durable_requeue.py"
spec = importlib.util.spec_from_file_location("multi_queue_durable", TOOL)
durable = importlib.util.module_from_spec(spec)
spec.loader.exec_module(durable)


class ProducerOwnership(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = pathlib.Path(self.tmp.name).resolve() / "20260904T053945Z-c6c62198.json"
        self.path.write_text(json.dumps(dict(attempts=1, ip="fixture",
                                           quantum_address="qFixture", submitted="fixture")))
        self.path.chmod(0o644)

    @contextlib.contextmanager
    def owner(self, uid, gid, *, nlink=1, mode=0o644, inode_delta=0):
        original_lstat, original_fstat = pathlib.Path.lstat, os.fstat
        def project(st, opened=False):
            values = {k: getattr(st, k) for k in dir(st) if k.startswith("st_")}
            values.update(st_uid=uid, st_gid=gid, st_nlink=nlink,
                          st_mode=stat.S_IFREG | mode)
            values["st_ino"] += inode_delta if opened else 0
            return types.SimpleNamespace(**values)
        def lstat(path):
            st = original_lstat(path)
            return project(st) if path == self.path else st
        with mock.patch.object(durable.legacy, "test_mode", return_value=False), \
                mock.patch.object(pathlib.Path, "lstat", lstat), \
                mock.patch.object(os, "fstat", lambda fd: project(original_fstat(fd), True)):
            yield

    def test_api_owner_is_bound(self):
        with self.owner(99, 100):
            item, _ = durable.queue_file_snapshot(self.path, None, "API queue")
            self.assertEqual((item["uid"], item["gid"], item["mode"]), (99, 100, "0644"))
            durable.queue_file_snapshot(self.path, None, "API queue", item["sha256"], item)

    def test_historical_root_owner_is_bound(self):
        with self.owner(0, 0):
            item, _ = durable.queue_file_snapshot(self.path, None, "operator queue")
            self.assertEqual((item["uid"], item["gid"]), (0, 0))

    def test_historical_paid_done_record(self):
        with self.owner(0, 100, mode=0o640):
            _, st = durable.ingress_file(self.path, "historical paid done", {0o640}, done_entry=True)
            self.assertEqual((st.st_uid, st.st_gid, stat.S_IMODE(st.st_mode)), (0, 100, 0o640))

    def test_done_owner_exception_does_not_apply_to_ingress(self):
        with self.owner(0, 100), self.assertRaises(durable.GateError):
            durable.queue_file_snapshot(self.path, None, "queue cannot use done owner")

    def test_done_owner_exception_requires_exact_mode(self):
        with self.owner(0, 100), self.assertRaises(durable.GateError):
            durable.ingress_file(self.path, "wrong done mode", {0o644}, done_entry=True)

    def test_wrong_api_group(self):
        with self.owner(99, 0), self.assertRaises(durable.GateError):
            durable.queue_file_snapshot(self.path, None, "wrong group")

    def test_wrong_owner(self):
        with self.owner(1000, 100), self.assertRaises(durable.GateError):
            durable.queue_file_snapshot(self.path, None, "wrong owner")

    def test_writeable_item(self):
        with self.owner(99, 100, mode=0o664), self.assertRaises(durable.GateError):
            durable.queue_file_snapshot(self.path, None, "wrong mode")

    def test_hardlink(self):
        with self.owner(99, 100, nlink=2), self.assertRaises(durable.GateError):
            durable.queue_file_snapshot(self.path, None, "hardlink")

    def test_opened_inode_swap(self):
        with self.owner(99, 100, inode_delta=1), self.assertRaises(durable.GateError):
            durable.queue_file_snapshot(self.path, None, "inode swap")

    def test_authorized_identity_cannot_change_owner(self):
        with self.owner(99, 100):
            item, _ = durable.queue_file_snapshot(self.path, None, "API queue")
        with self.owner(0, 0), self.assertRaises(durable.GateError):
            durable.queue_file_snapshot(self.path, None, "changed owner", item["sha256"], item)

    def test_historical_pinned_reader_still_rejects_api_owner(self):
        with self.owner(99, 100), self.assertRaises(durable.legacy.GateError):
            durable.legacy.queue_file_snapshot(self.path, None, "historical reader")

    def test_adapter_does_not_replace_legacy_dependency(self):
        self.assertIsNot(durable.audit_queue, durable.legacy.audit_queue)
        self.assertIs(durable.legacy.stable_live_snapshot.__globals__["audit_queue"],
                      durable.legacy.audit_queue)


if __name__ == "__main__":
    unittest.main()
