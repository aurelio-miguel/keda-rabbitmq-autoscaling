import json
import logging
import math
import os
import signal
import time

import pika

LOGGER = logging.getLogger(__name__)


def read_config():
    try:
        port = int(os.environ.get("RABBITMQ_PORT", "5672"))
        prefetch = int(os.environ.get("PREFETCH_COUNT", "1"))
        delay = float(os.environ.get("PROCESSING_TIME_SECONDS", "2"))
    except ValueError:
        raise ValueError("Port and prefetch must be integers; processing time must be a number") from None
    if not 1 <= port <= 65535:
        raise ValueError("RABBITMQ_PORT must be between 1 and 65535")
    if not 1 <= prefetch <= 65535:
        raise ValueError("PREFETCH_COUNT must be between 1 and 65535")
    if not math.isfinite(delay) or delay < 0:
        raise ValueError("PROCESSING_TIME_SECONDS must be finite and nonnegative")

    config = {
        "host": os.environ.get("RABBITMQ_HOST", "localhost"),
        "port": port,
        "username": os.environ.get("RABBITMQ_USERNAME", ""),
        "password": os.environ.get("RABBITMQ_PASSWORD", ""),
        "queue": os.environ.get("RABBITMQ_QUEUE", "tasks"),
        "prefetch": prefetch,
        "delay": delay,
    }
    for name in ("host", "username", "password", "queue"):
        if not config[name].strip():
            raise ValueError(f"RABBITMQ_{name.upper()} must not be empty")
    return config


def main():
    connection = None
    stopping = False
    try:
        config = read_config()
    except ValueError as error:
        LOGGER.error("Invalid configuration: %s", error)
        return 1

    def request_stop(signum, frame):
        nonlocal stopping
        stopping = True

    previous_handlers = {
        signum: signal.signal(signum, request_stop)
        for signum in (signal.SIGINT, signal.SIGTERM)
    }
    try:
        connection = pika.BlockingConnection(
            pika.ConnectionParameters(
                host=config["host"],
                port=config["port"],
                credentials=pika.PlainCredentials(config["username"], config["password"]),
                heartbeat=60,
                blocked_connection_timeout=30,
                socket_timeout=10,
                stack_timeout=15,
            )
        )
        channel = connection.channel()
        channel.queue_declare(queue=config["queue"], durable=True)
        channel.basic_qos(prefetch_count=config["prefetch"])
        LOGGER.info(
            "Worker ready: queue=%s prefetch=%d processing_seconds=%s",
            config["queue"], config["prefetch"], config["delay"],
        )

        for method, properties, body in channel.consume(
            queue=config["queue"], auto_ack=False, inactivity_timeout=0.2,
        ):
            if stopping:
                break
            if method is None:
                continue
            try:
                payload = json.loads(body)
                if not isinstance(payload, dict):
                    raise ValueError("Expected a JSON object")
                for field in ("message_id", "published_at"):
                    if not isinstance(payload.get(field), str) or not payload[field].strip():
                        raise ValueError("Missing payload field")
            except (ValueError, UnicodeError, TypeError):
                LOGGER.error("Rejected malformed message: delivery_tag=%d", method.delivery_tag)
                channel.basic_nack(delivery_tag=method.delivery_tag, requeue=False)
                continue

            message_id = payload["message_id"]
            LOGGER.info("Processing message_id=%s redelivered=%s", message_id, method.redelivered)
            deadline = time.monotonic() + config["delay"]
            while not stopping:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    break
                connection.process_data_events(time_limit=min(0.2, remaining))
            if stopping:
                LOGGER.info("Processing interrupted: message_id=%s", message_id)
                break
            channel.basic_ack(delivery_tag=method.delivery_tag)
            LOGGER.info("Acknowledged message_id=%s", message_id)

        channel.cancel()
        LOGGER.info("Worker stopped")
        return 0
    except (pika.exceptions.AMQPError, OSError, ValueError) as error:
        LOGGER.error("Worker failed: type=%s", type(error).__name__)
        return 1
    finally:
        try:
            if connection is not None and connection.is_open:
                try:
                    connection.close()
                except pika.exceptions.AMQPError:
                    LOGGER.warning("Connection could not be closed cleanly")
        finally:
            for signum, handler in previous_handlers.items():
                signal.signal(signum, handler)


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    logging.getLogger("pika").setLevel(logging.CRITICAL)
    raise SystemExit(main())
