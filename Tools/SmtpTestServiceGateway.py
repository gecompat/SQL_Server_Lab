#!/usr/bin/env python3
"""Run-owned SMTP quota gateway used in front of a Mailpit receiver.

This service deliberately implements only SMTP submission.  The receiver API is
queried before every DATA acceptance so configured byte and count limits are
enforced against its actual stored message inventory.
"""
from __future__ import annotations

import asyncio
import base64
import json
import os
import smtplib
import time
import urllib.request
from collections import deque
from dataclasses import dataclass, field


def _required(name: str) -> str:
    value = os.environ.get(name, "")
    if not value:
        raise RuntimeError(f"{name}_REQUIRED")
    return value


def _smtp_path(value: str, prefix: str) -> str | None:
    if not value.upper().startswith(prefix):
        return None
    candidate = value[len(prefix):].lstrip()
    if not candidate.startswith("<"):
        return None
    address, separator, remainder = candidate[1:].partition(">")
    if not separator or not address or any(character.isspace() for character in address):
        return None
    # ESMTP permits MAIL/RCPT parameters after the closing path delimiter.
    if remainder and not remainder[0].isspace():
        return None
    return address


@dataclass
class Quota:
    api_url: str
    api_auth_file: str
    max_messages: int
    max_bytes: int
    max_message_bytes: int
    per_minute: int
    accepted: deque[float] = field(default_factory=deque)

    def _headers(self) -> dict[str, str]:
        with open(self.api_auth_file, "rt", encoding="utf-8") as auth_file:
            credential = auth_file.read().strip()
        if not credential or "\n" in credential or "\r" in credential:
            raise RuntimeError("SMTP_GATEWAY_API_AUTH_INVALID")
        token = base64.b64encode(credential.encode("utf-8")).decode("ascii")
        return {"Authorization": "Basic " + token, "Accept": "application/json"}

    def receiver_usage(self) -> tuple[int, int]:
        request = urllib.request.Request(self.api_url + "/api/v1/messages", headers=self._headers())
        with urllib.request.urlopen(request, timeout=3) as response:
            if response.status != 200 or response.headers.get_content_type() != "application/json":
                raise RuntimeError("SMTP_GATEWAY_RECEIVER_UNAVAILABLE")
            body = json.load(response)
        messages = body.get("messages")
        if not isinstance(messages, list) or len(messages) > self.max_messages:
            raise RuntimeError("SMTP_GATEWAY_RECEIVER_RESPONSE_INVALID")
        sizes = [item.get("Size") for item in messages if isinstance(item, dict)]
        if len(sizes) != len(messages) or any(type(size) is not int or size < 0 for size in sizes):
            raise RuntimeError("SMTP_GATEWAY_RECEIVER_RESPONSE_INVALID")
        return len(messages), sum(sizes)

    def check(self, bytes_count: int) -> tuple[str | None, float]:
        now = time.monotonic()
        while self.accepted and self.accepted[0] <= now - 60:
            self.accepted.popleft()
        if bytes_count > self.max_message_bytes:
            return "552 5.3.4 message size exceeds configured limit", now
        if len(self.accepted) >= self.per_minute:
            return "451 4.7.0 submission rate limit exceeded", now
        count, stored_bytes = self.receiver_usage()
        if count >= self.max_messages or stored_bytes + bytes_count > self.max_bytes:
            return "452 4.3.1 receiver storage quota exceeded", now
        return None, now

    def commit(self, accepted_at: float) -> None:
        self.accepted.append(accepted_at)


def _relay(message: bytes, sender: str, recipients: list[str], host: str, port: int) -> None:
    with smtplib.SMTP(host, port, timeout=8) as client:
        client.sendmail(sender, recipients, message)


async def _accept_message(
    message: bytes,
    sender: str,
    recipients: list[str],
    quota: Quota,
    lock: asyncio.Lock,
    upstream: tuple[str, int],
) -> str | None:
    # Serializing check-and-relay prevents concurrent submissions from both
    # observing the same receiver inventory and exceeding the configured quota.
    async with lock:
        rejection, accepted_at = await asyncio.to_thread(quota.check, len(message))
        if rejection:
            return rejection
        try:
            _relay(message, sender, recipients, *upstream)
        except (OSError, smtplib.SMTPException):
            return "451 4.4.1 receiver delivery unavailable"
        quota.commit(accepted_at)
    return None


async def _session(reader: asyncio.StreamReader, writer: asyncio.StreamWriter, quota: Quota, lock: asyncio.Lock, upstream: tuple[str, int]) -> None:
    sender = ""
    recipients: list[str] = []
    writer.write(b"220 sql-server-lab smtp quota gateway\r\n")
    await writer.drain()
    try:
        while line := await reader.readline():
            if len(line) > 1024:
                writer.write(b"500 5.5.2 command line too long\r\n")
                await writer.drain()
                return
            command, _, value = line.rstrip(b"\r\n").partition(b" ")
            verb = command.decode("ascii", "ignore").upper()
            text = value.decode("utf-8", "replace")
            if verb in ("EHLO", "HELO"):
                writer.write(b"250-localhost\r\n250 SIZE\r\n")
            elif verb == "RSET":
                sender, recipients = "", []
                writer.write(b"250 2.0.0 reset\r\n")
            elif verb == "MAIL":
                path = _smtp_path(text, "FROM:")
                if path:
                    sender, recipients = path, []
                    writer.write(b"250 2.1.0 sender accepted\r\n")
                else:
                    writer.write(b"501 5.5.4 malformed sender path\r\n")
            elif verb == "RCPT" and sender:
                path = _smtp_path(text, "TO:")
                if path:
                    recipients.append(path)
                    writer.write(b"250 2.1.5 recipient accepted\r\n")
                else:
                    writer.write(b"501 5.5.4 malformed recipient path\r\n")
            elif verb == "DATA" and sender and recipients:
                writer.write(b"354 end data with <CR><LF>.<CR><LF>\r\n")
                await writer.drain()
                chunks: list[bytes] = []
                total = 0
                while True:
                    part = await reader.readline()
                    if not part or part == b".\r\n":
                        break
                    if part.startswith(b".."):
                        part = part[1:]
                    total += len(part)
                    if total > quota.max_message_bytes:
                        writer.write(b"552 5.3.4 message size exceeds configured limit\r\n")
                        await writer.drain()
                        return
                    chunks.append(part)
                message = b"".join(chunks)
                rejection = await _accept_message(message, sender, recipients, quota, lock, upstream)
                if rejection:
                    writer.write(rejection.encode("ascii") + b"\r\n")
                else:
                    writer.write(b"250 2.0.0 accepted\r\n")
                sender, recipients = "", []
            elif verb == "QUIT":
                writer.write(b"221 2.0.0 bye\r\n")
                await writer.drain()
                return
            else:
                writer.write(b"503 5.5.1 bad sequence\r\n")
            await writer.drain()
    finally:
        writer.close()
        await writer.wait_closed()


async def main() -> None:
    quota = Quota(
        api_url=_required("SMTP_GATEWAY_API_URL").rstrip("/"),
        api_auth_file=_required("SMTP_GATEWAY_API_AUTH_FILE"),
        max_messages=int(_required("SMTP_GATEWAY_MAX_MESSAGES")),
        max_bytes=int(_required("SMTP_GATEWAY_MAX_BYTES")),
        max_message_bytes=int(_required("SMTP_GATEWAY_MAX_MESSAGE_BYTES")),
        per_minute=int(_required("SMTP_GATEWAY_MAX_PER_UTC60")),
    )
    if min(quota.max_messages, quota.max_bytes, quota.max_message_bytes, quota.per_minute) < 1:
        raise RuntimeError("SMTP_GATEWAY_LIMIT_INVALID")
    upstream = (_required("SMTP_GATEWAY_UPSTREAM_HOST"), int(_required("SMTP_GATEWAY_UPSTREAM_PORT")))
    lock = asyncio.Lock()
    server = await asyncio.start_server(lambda r, w: _session(r, w, quota, lock, upstream), host="0.0.0.0", port=1025, limit=65536)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
