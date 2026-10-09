"""Broker-free regression checks for publication and acknowledgement behavior."""

import json
import os
import signal
import unittest
from datetime import datetime
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

import pika

from apps.producer import producer
from apps.worker import worker


class ApplicationTests(unittest.TestCase):
    def setUp(self):
        self.environment = patch.dict(os.environ, {
            "RABBITMQ_USERNAME": "test-user",
            "RABBITMQ_PASSWORD": "test-password-do-not-log",
            "MESSAGE_COUNT": "3",
            "PROCESSING_TIME_SECONDS": "2",
        }, clear=True)
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.connection = MagicMock()
        self.connection.is_open = True
        self.channel = self.connection.channel.return_value
        self.connect = patch.object(pika, "BlockingConnection", return_value=self.connection)
        self.connect_mock = self.connect.start()
        self.addCleanup(self.connect.stop)

    def delivery(self, body=None):
        if body is None:
            body = json.dumps({
                "message_id": "task-1", "published_at": "2026-10-09T00:00:00+00:00",
            }).encode()
        return SimpleNamespace(delivery_tag=7, redelivered=False), None, body

    def test_producer_confirms_persistent_unique_messages(self):
        def publish(**kwargs):
            self.channel.confirm_delivery.assert_called_once()
            self.assertTrue(kwargs["mandatory"])
            self.assertEqual(kwargs["exchange"], "")
            self.assertEqual(kwargs["routing_key"], "tasks")
            self.assertEqual(kwargs["properties"].delivery_mode, 2)

        self.channel.basic_publish.side_effect = publish
        with self.assertLogs(producer.LOGGER, level="INFO") as logs:
            self.assertEqual(producer.main(), 0)
        payloads = [json.loads(call.kwargs["body"]) for call in self.channel.basic_publish.call_args_list]
        self.assertEqual(len(payloads), 3)
        self.assertEqual(len({body["message_id"] for body in payloads}), 3)
        for call, body in zip(self.channel.basic_publish.call_args_list, payloads):
            self.assertEqual(call.kwargs["properties"].message_id, body["message_id"])
            self.assertIsNotNone(datetime.fromisoformat(body["published_at"]).tzinfo)
        self.assertIn("confirmed=3", " ".join(logs.output))
        self.channel.queue_declare.assert_called_once_with(queue="tasks", durable=True)
        self.connection.close.assert_called_once()

    def test_producer_detects_unroutable_and_rejected_publications(self):
        for error in (pika.exceptions.UnroutableError([]), pika.exceptions.NackError([])):
            with self.subTest(error=type(error).__name__):
                self.channel.basic_publish.reset_mock()
                self.connection.close.reset_mock()
                self.channel.basic_publish.side_effect = [None, error]
                with self.assertLogs(producer.LOGGER, level="ERROR") as logs:
                    self.assertEqual(producer.main(), 1)
                self.assertEqual(self.channel.basic_publish.call_count, 2)
                self.assertIn("confirmed=1", " ".join(logs.output))
                self.connection.close.assert_called_once()

    def test_connection_failure_does_not_log_credentials(self):
        self.connect_mock.side_effect = pika.exceptions.AMQPConnectionError("test-password-do-not-log")
        for application in (producer, worker):
            with self.subTest(application=application.__name__), self.assertLogs(application.LOGGER, level="ERROR") as logs:
                self.assertEqual(application.main(), 1)
                self.assertNotIn("test-password-do-not-log", " ".join(logs.output))

    def test_invalid_configuration_does_not_connect(self):
        cases = [
            (producer, "MESSAGE_COUNT", "-1"),
            (producer, "RABBITMQ_PORT", "65536"),
            (worker, "PREFETCH_COUNT", "0"),
            (worker, "PROCESSING_TIME_SECONDS", "nan"),
            (worker, "PROCESSING_TIME_SECONDS", "-1"),
            (worker, "RABBITMQ_PASSWORD", ""),
        ]
        for application, name, value in cases:
            with self.subTest(name=name, value=value), patch.dict(os.environ, {name: value}), self.assertLogs(application.LOGGER, level="ERROR"):
                self.assertEqual(application.main(), 1)
        self.connect_mock.assert_not_called()

    def test_worker_services_heartbeats_before_acknowledging(self):
        self.channel.consume.return_value = iter([self.delivery()])

        def service_events(time_limit):
            self.assertGreater(time_limit, 0)
            self.assertLessEqual(time_limit, 0.2)
            self.channel.basic_ack.assert_not_called()

        self.connection.process_data_events.side_effect = service_events
        with patch.object(worker.time, "monotonic", side_effect=[100, 100.1, 102.1]):
            self.assertEqual(worker.main(), 0)
        self.connection.process_data_events.assert_called_once()
        self.channel.basic_ack.assert_called_once_with(delivery_tag=7)
        self.channel.consume.assert_called_once_with(queue="tasks", auto_ack=False, inactivity_timeout=0.2)
        self.channel.basic_qos.assert_called_once_with(prefetch_count=1)
        self.channel.cancel.assert_called_once()
        self.connection.close.assert_called_once()

    def test_sigterm_during_processing_leaves_message_unacknowledged(self):
        previous = signal.getsignal(signal.SIGTERM)
        self.channel.consume.return_value = iter([self.delivery()])
        self.connection.process_data_events.side_effect = lambda **kwargs: signal.raise_signal(signal.SIGTERM)
        with patch.object(worker.time, "monotonic", side_effect=[100, 100.1]):
            self.assertEqual(worker.main(), 0)
        self.channel.basic_ack.assert_not_called()
        self.channel.basic_nack.assert_not_called()
        self.connection.close.assert_called_once()
        self.assertEqual(signal.getsignal(signal.SIGTERM), previous)

    def test_processing_connection_failure_never_acknowledges(self):
        self.channel.consume.return_value = iter([self.delivery()])
        self.connection.process_data_events.side_effect = pika.exceptions.AMQPError("test-password-do-not-log")
        with patch.object(worker.time, "monotonic", side_effect=[100, 100.1]), self.assertLogs(worker.LOGGER, level="ERROR") as logs:
            self.assertEqual(worker.main(), 1)
        self.channel.basic_ack.assert_not_called()
        self.connection.close.assert_called_once()
        self.assertNotIn("test-password-do-not-log", " ".join(logs.output))

    def test_malformed_messages_are_rejected_without_requeue(self):
        self.channel.consume.return_value = iter([
            self.delivery(body) for body in (b"invalid-json", b"[]", b"{}", b"\xff")
        ])
        with self.assertLogs(worker.LOGGER, level="ERROR"):
            self.assertEqual(worker.main(), 0)
        self.channel.basic_ack.assert_not_called()
        self.assertEqual(self.channel.basic_nack.call_count, 4)
        for call in self.channel.basic_nack.call_args_list:
            self.assertEqual(call.kwargs, {"delivery_tag": 7, "requeue": False})
        self.connection.close.assert_called_once()


if __name__ == "__main__":
    unittest.main()
