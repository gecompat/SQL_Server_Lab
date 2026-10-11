"""Pure checks for the SMTP quota gateway; no listener or container is started."""

import asyncio
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
from unittest.mock import patch


SOURCE = Path(__file__).resolve().parents[3] / "Tools" / "SmtpTestServiceGateway.py"
SOURCE_HASH = hashlib.sha256(SOURCE.read_bytes()).hexdigest()
spec = importlib.util.spec_from_file_location("smtp_gateway_checks", SOURCE)
gateway = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = gateway
spec.loader.exec_module(gateway)


class Response:
    status = 200

    class Headers:
        @staticmethod
        def get_content_type():
            return "application/json"

    headers = Headers()

    def __init__(self, body):
        self._body = body

    def read(self, *_):
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False


def make_quota(messages, max_messages=2, max_bytes=100, max_message_bytes=50, per_minute=2):
    auth = tempfile.NamedTemporaryFile("wt", encoding="utf-8", delete=False)
    try:
        auth.write("synthetic:credential")
        auth.close()
        quota = gateway.Quota("http://127.0.0.1:18025", auth.name, max_messages, max_bytes, max_message_bytes, per_minute)
        body = json.dumps({"messages": messages}).encode("utf-8")
        with patch.object(gateway.urllib.request, "urlopen", return_value=Response(body)):
            yield quota
    finally:
        Path(auth.name).unlink(missing_ok=True)


def check(name, action):
    action()
    return {"Case": name, "Status": "PASS"}


def quota_storage_count():
    for quota in make_quota([{"Size": 10}, {"Size": 20}]):
        rejection, _ = quota.check(1)
        assert rejection == "452 4.3.1 receiver storage quota exceeded"


def quota_storage_bytes():
    for quota in make_quota([{"Size": 91}], max_bytes=100):
        rejection, _ = quota.check(10)
        assert rejection == "452 4.3.1 receiver storage quota exceeded"


def quota_rate_commits_only_on_success():
    for quota in make_quota([], per_minute=1):
        first, stamp = quota.check(10)
        assert first is None and not quota.accepted
        quota.commit(stamp)
        second, _ = quota.check(10)
        assert second == "451 4.7.0 submission rate limit exceeded"


def relay_preserves_bytes():
    observed = {}

    class Client:
        def __init__(self, *_args, **_kwargs):
            pass

        def sendmail(self, sender, recipients, message):
            observed.update(sender=sender, recipients=recipients, message=message)

        def __enter__(self):
            return self

        def __exit__(self, *_):
            return False

    sample = b"Subject: raw\r\n\r\n\x80bytes\r\n"
    with patch.object(gateway.smtplib, "SMTP", Client):
        gateway._relay(sample, "from@example.invalid", ["to@example.invalid"], "receiver", 1025)
    assert observed == {"sender": "from@example.invalid", "recipients": ["to@example.invalid"], "message": sample}


def failed_relay_does_not_consume_rate_quota():
    async def run():
        for quota in make_quota([], per_minute=1):
            with patch.object(gateway, "_relay", side_effect=OSError("synthetic")):
                result = await gateway._accept_message(b"test", "from", ["to"], quota, asyncio.Lock(), ("receiver", 1025))
            assert result == "451 4.4.1 receiver delivery unavailable" and not quota.accepted
    asyncio.run(run())


def esmtp_sender_path_is_not_forwarded_with_parameters():
    assert gateway._smtp_path("FROM:<from@example.invalid> SIZE=28", "FROM:") == "from@example.invalid"
    assert gateway._smtp_path("TO:<to@example.invalid>", "TO:") == "to@example.invalid"
    assert gateway._smtp_path("FROM:from@example.invalid", "FROM:") is None


def main():
    cases = [
        ("G01_STORAGE_COUNT", quota_storage_count),
        ("G02_STORAGE_BYTES", quota_storage_bytes),
        ("G03_RATE_COMMIT", quota_rate_commits_only_on_success),
        ("G04_RAW_RELAY", relay_preserves_bytes),
        ("G05_FAILED_RELAY", failed_relay_does_not_consume_rate_quota),
        ("G06_ESMTP_PATH", esmtp_sender_path_is_not_forwarded_with_parameters),
    ]
    rows = []
    for name, action in cases:
        rows.append(check(name, action))
    rows.append({"Passed": len(cases), "Failed": 0, "SourceSha256": SOURCE_HASH})
    print("\n".join(json.dumps(row, separators=(",", ":")) for row in rows))


if __name__ == "__main__":
    main()
