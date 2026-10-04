
import json
import logging
import os
from datetime import datetime, timezone
from uuid import uuid4

import pika

LOGGER = logging.getLogger(__name__)


def read_config():
    try:
        port = int(os.environ.get("RABBITMQ_PORT", "5672"))
        count = int(os.environ.get("MESSAGE_COUNT", "1000"))
    except ValueError:
        raise ValueError("RABBITMQ_PORT and MESSAGE_COUNT must be integers") from None
    if not 1 <= port <= 65535:
        raise ValueError("RABBITMQ_PORT must be between 1 and 65535")
    if count < 0:
        raise ValueError("MESSAGE_COUNT must be nonnegative")

    config = {
        "host": os.environ.get("RABBITMQ_HOST", "localhost"),
        "port": port,
        "username": os.environ.get("RABBITMQ_USERNAME", ""),
        "password": os.environ.get("RABBITMQ_PASSWORD", ""),
        "queue": os.environ.get("RABBITMQ_QUEUE", "tasks"),
        "count": count,
    }
    for name in ("host", "username", "password", "queue"):
        if not config[name].strip():
            raise ValueError(f"RABBITMQ_{name.upper()} must not be empty")
    return config


def main():
    connection = None
    confirmed = 0
    try:
        config = read_config()
    except ValueError as error:
        LOGGER.error("Invalid configuration: %s", error)
        return 1

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
        channel.confirm_delivery()

        for _ in range(config["count"]):
            message_id = str(uuid4())
            payload = {
                "message_id": message_id,
                "published_at": datetime.now(timezone.utc).isoformat(),
            }
            channel.basic_publish(
                exchange="",
                routing_key=config["queue"],
                body=json.dumps(payload).encode("utf-8"),
                properties=pika.BasicProperties(
                    content_type="application/json",
                    delivery_mode=2,
                    message_id=message_id,
                ),
                mandatory=True,
            )
            confirmed += 1

        LOGGER.info("Publication complete: confirmed=%d queue=%s", confirmed, config["queue"])
        return 0
    except KeyboardInterrupt:
        LOGGER.warning("Publication interrupted: confirmed=%d", confirmed)
        return 130
    except (pika.exceptions.AMQPError, OSError, ValueError) as error:
        LOGGER.error("Publication failed: type=%s confirmed=%d", type(error).__name__, confirmed)
        return 1
    finally:
        if connection is not None and connection.is_open:
            try:
                connection.close()
            except pika.exceptions.AMQPError:
                LOGGER.warning("Connection could not be closed cleanly")


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    logging.getLogger("pika").setLevel(logging.CRITICAL)
    raise SystemExit(main())
