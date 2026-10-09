"""Pure, bounded explicit MIME projection; no backend or file/network access.

The deadlines here are cooperative. A parent process wall/RSS/CPU guard is not
implemented by this module. Raw MIME and decoded reads have independent quotas.
"""

import base64
import binascii
import json
import re
import sys
import time
from email import policy
from email.headerregistry import HeaderRegistry
from email.message import EmailMessage
from email.parser import BytesFeedParser
import quopri


DECODED_INPUT = 1_048_576
MIME_INPUT = 8_388_608
LINES = 16_384
LINE_BYTES = 16_384
ROOT_HEADERS = 32_768
PART_HEADERS = 8_192
ALL_HEADERS = 65_536
ROOT_FIELDS = 64
PART_FIELDS = 32
ALL_FIELDS = 256
FIELD_BYTES = 4_096
PARTS = 64
DEPTH = 8
BODY_BYTES = 262_144
OUTPUT_BYTES = 524_288
SECONDS = 5.0

_CHARSETS = {
    "utf-8": "utf-8", "utf8": "utf-8",
    "us-ascii": "ascii", "ascii": "ascii",
    "iso-8859-1": "iso-8859-1", "iso8859-1": "iso-8859-1",
    "latin-1": "iso-8859-1", "latin1": "iso-8859-1",
    "windows-1252": "cp1252", "cp1252": "cp1252",
}
_STRUCTURAL = frozenset(("mime-version", "content-type",
                        "content-transfer-encoding", "content-disposition",
                        "content-id"))
_CODES = frozenset(("INPUT_INVALID", "LIMIT_EXCEEDED", "INVALID",
                   "INVALID_ENCODING", "UNSUPPORTED_CHARSET",
                   "UNSUPPORTED_ENCODING", "UNSUPPORTED_ADDRESS",
                   "PARSE_FAILED", "TIMEOUT"))
_WORD = re.compile(r"=\?([^?\s]{1,64})\?([bBqQ])\?([^?\r\n]*)\?=")
_HEX = frozenset(b"0123456789abcdefABCDEF")


class MimeError(Exception):
    """A fixed code, never parser/input/exception text."""

    def __init__(self, code):
        self.code = "SMTP_MIME_" + (code if code in _CODES else "PARSE_FAILED")
        super().__init__(self.code)


def _fail(code):
    raise MimeError(code)


class _Budget:
    def __init__(self):
        self.end = time.monotonic() + SECONDS

    def check(self):
        if time.monotonic() >= self.end:
            _fail("TIMEOUT")


def _scalar_text(text, body=False):
    for c in text:
        n = ord(c)
        if 0xD800 <= n <= 0xDFFF or 127 <= n <= 159 or n < 32 and (
                not body or c not in "\t\r\n"):
            _fail("INVALID_ENCODING")
    return text


def _charset(name):
    if type(name) is not str or name.lower() not in _CHARSETS:
        _fail("UNSUPPORTED_CHARSET")
    return _CHARSETS[name.lower()]


def _text(data, charset, body=False):
    try:
        return _scalar_text(data.decode(_charset(charset), "strict"), body)
    except UnicodeError:
        _fail("INVALID_ENCODING")


def _wire(value):
    try:
        return value.encode("ascii", "surrogateescape")
    except (AttributeError, UnicodeError):
        _fail("INVALID")


def _b64(data, folding):
    if folding:
        data = re.sub(br"[ \t\r\n]", b"", data)
    try:
        result = base64.b64decode(data, validate=True)
        if base64.b64encode(result) != data:
            _fail("INVALID_ENCODING")
        return result
    except (ValueError, binascii.Error):
        _fail("INVALID_ENCODING")


def _qp(data, word=False):
    i = 0
    while i < len(data):
        c = data[i]
        if c > 127:
            _fail("INVALID_ENCODING")
        if c == 61:
            if not word and data[i + 1:i + 3] == b"\r\n":
                i += 3
                continue
            if not word and data[i + 1:i + 2] == b"\n":
                i += 2
                continue
            if i + 2 >= len(data) or data[i + 1] not in _HEX or data[i + 2] not in _HEX:
                _fail("INVALID_ENCODING")
            i += 3
            continue
        if word and (c < 33 or c == 63):
            _fail("INVALID_ENCODING")
        i += 1
    return quopri.decodestring(data, header=word)


def _words(value):
    pos = 0
    while True:
        start = value.find("=?", pos)
        if start < 0:
            return
        match = _WORD.match(value, start)
        if match is None or len(match.group(0)) > 75:
            _fail("INVALID_ENCODING")
        charset, kind, encoded = match.groups()
        try:
            encoded_bytes = encoded.encode("ascii", "strict")
        except UnicodeError:
            _fail("INVALID_ENCODING")
        decoded = _b64(encoded_bytes, False) if kind.lower() == "b" else _qp(encoded_bytes, True)
        _text(decoded, charset)
        pos = match.end()


def _header_value(raw):
    try:
        value = _wire(raw).decode("utf-8", "strict")
    except UnicodeError:
        _fail("INVALID_ENCODING")
    value = re.sub(r"(?:\r\n|\n)[ \t]+", " ", value)
    if "\r" in value or "\n" in value:
        _fail("INVALID")
    # Legal horizontal folding whitespace is presentation whitespace.
    value = value.replace("\t", " ")
    _scalar_text(value)
    _words(value)
    return value


def _preflight(data):
    if type(data) is not bytes:
        _fail("INPUT_INVALID")
    if len(data) > DECODED_INPUT:
        _fail("LIMIT_EXCEEDED")
    if b"\r" in data.replace(b"\r\n", b""):
        _fail("INVALID")
    lines = data.splitlines(keepends=True)
    if len(lines) > LINES or any(len(line) > LINE_BYTES for line in lines):
        _fail("LIMIT_EXCEEDED")
    size = 0
    for line in lines:
        size += len(line)
        if size > ROOT_HEADERS:
            _fail("LIMIT_EXCEEDED")
        if line in (b"\r\n", b"\n"):
            return
    _fail("INVALID")


def _parse(data, budget):
    count = 0
    strict = policy.SMTPUTF8.clone(raise_on_defect=True)

    def factory():
        nonlocal count
        budget.check()
        if count >= PARTS:
            _fail("LIMIT_EXCEEDED")
        count += 1
        return EmailMessage(policy=strict)

    parser = BytesFeedParser(_factory=factory, policy=strict)
    for offset in range(0, len(data), 8192):
        budget.check()
        parser.feed(data[offset:offset + 8192])
    budget.check()
    root = parser.close()
    budget.check()
    return root, count


def _inspect(root, count, budget):
    stack = [(root, 1)]
    nodes = []
    all_fields = all_bytes = 0
    registry = HeaderRegistry()
    headers = {}
    while stack:
        budget.check()
        node, depth = stack.pop()
        if depth > DEPTH:
            _fail("LIMIT_EXCEEDED")
        nodes.append(node)
        if len(nodes) > PARTS or node.defects:
            _fail("INVALID")
        raw = list(node.raw_items())
        size = sum(len(_wire(name)) + 1 + len(_wire(value)) + 2 for name, value in raw)
        all_fields += len(raw)
        all_bytes += size
        if (len(raw) > (ROOT_FIELDS if node is root else PART_FIELDS)
                or size > (ROOT_HEADERS if node is root else PART_HEADERS)
                or all_fields > ALL_FIELDS or all_bytes > ALL_HEADERS):
            _fail("LIMIT_EXCEEDED")
        seen = set()
        structural = {}
        for name, value in raw:
            key = name.lower()
            relevant = key in _STRUCTURAL or node is root and key in ("subject", "from", "to")
            if relevant:
                if key in seen:
                    _fail("INVALID")
                seen.add(key)
                if node is root and key in ("subject", "from", "to") and len(_wire(value)) > FIELD_BYTES:
                    _fail("LIMIT_EXCEEDED")
                decoded_raw = _header_value(value)
                parsed = registry(name, decoded_raw)
                if parsed.defects:
                    if key in ("from", "to") and any(type(d).__name__ == "NonASCIILocalPartDefect" for d in parsed.defects):
                        _fail("UNSUPPORTED_ADDRESS")
                    _fail("INVALID")
                structural[key] = parsed
                if node is root and key in ("subject", "from", "to"):
                    projected = _scalar_text(str(parsed))
                    if len(projected.encode("utf-8")) > FIELD_BYTES:
                        _fail("LIMIT_EXCEEDED")
                    if key != "subject":
                        if len(parsed.addresses) > (8 if key == "from" else 64):
                            _fail("LIMIT_EXCEEDED")
                        for address in parsed.addresses:
                            if not address.addr_spec.isascii():
                                _fail("UNSUPPORTED_ADDRESS")
                    headers[key] = projected
        # Read normalized structural values from validated Unicode headers.
        for key, parsed in structural.items():
            if key in _STRUCTURAL:
                del node[key]
                node[key] = parsed
        if node.get_content_maintype() == "multipart":
            cte = str(node.get("content-transfer-encoding", "7bit")).strip().lower()
            if cte not in ("7bit", "8bit"):
                _fail("UNSUPPORTED_ENCODING")
        if node.is_multipart():
            children = list(node.iter_parts())
            stack.extend((child, depth + 1) for child in reversed(children))
    if len(nodes) != count:
        _fail("PARSE_FAILED")
    return headers, nodes


def _excluded(node):
    if node.get_content_disposition() == "attachment":
        return True
    disposition = node.get("content-disposition")
    content_type = node.get("content-type")
    # Presence only: filenames are not returned or used as paths.
    return bool(disposition is not None and "filename" in disposition.params
                or content_type is not None and "name" in content_type.params)


def _select(node, budget):
    budget.check()
    if _excluded(node):
        return None, "NO_READABLE_BODY", "NONE"
    content_type = node.get_content_type()
    if content_type in ("text/plain", "text/html") and not node.is_multipart():
        return node, "TEXT" if content_type == "text/plain" else "HTML_SOURCE", "LEAF"
    if content_type not in ("multipart/alternative", "multipart/mixed", "multipart/related"):
        return None, "UNSUPPORTED_MULTIPART" if node.get_content_maintype() == "multipart" else "NO_READABLE_BODY", "NONE"
    children = list(node.iter_parts())
    if content_type == "multipart/related":
        start = node.get_param("start")
        if start is None:
            chosen = children[:1]
        else:
            chosen = [c for c in children if str(c.get("content-id", "")) == start]
            if len(chosen) != 1:
                _fail("INVALID")
        if not chosen:
            _fail("INVALID")
        part, status, _ = _select(chosen[0], budget)
        return part, status, "RELATED_ROOT"
    candidates = [_select(child, budget) for child in children]
    if content_type == "multipart/alternative":
        for preferred in ("TEXT", "HTML_SOURCE"):
            for part, status, _ in reversed(candidates):
                if part is not None and status == preferred:
                    return part, status, "ALTERNATIVE_LAST_PLAIN" if preferred == "TEXT" else "ALTERNATIVE_LAST_HTML"
    else:
        for part, status, _ in candidates:
            if part is not None:
                return part, status, "MIXED_FIRST_BODY"
    return None, "NO_READABLE_BODY", "NONE"


def _body(node, budget):
    budget.check()
    cte = str(node.get("content-transfer-encoding", "7bit")).strip().lower()
    if cte in ("7bit", "8bit"):
        data = node.get_payload(decode=True)
        if type(data) is not bytes or cte == "7bit" and not data.isascii():
            _fail("INVALID_ENCODING")
    elif cte in ("base64", "quoted-printable"):
        encoded = node.get_payload(decode=False)
        if type(encoded) is not str or not encoded.isascii():
            _fail("INVALID_ENCODING")
        raw = encoded.encode("ascii")
        data = _b64(raw, True) if cte == "base64" else _qp(raw)
    else:
        _fail("UNSUPPORTED_ENCODING")
    if len(data) > BODY_BYTES:
        _fail("LIMIT_EXCEEDED")
    text = _text(data, node.get_content_charset("us-ascii"), True)
    if len(text) > BODY_BYTES or len(text.encode("utf-8")) > BODY_BYTES:
        _fail("LIMIT_EXCEEDED")
    text = text.replace("\r\n", "\n")
    budget.check()
    return text


def project_decoded(data):
    """Return a complete content DTO or raise a fixed MimeError; no IO."""
    budget = _Budget()
    try:
        _preflight(data)
        budget.check()
        root, count = _parse(data, budget)
        headers, nodes = _inspect(root, count, budget)
        selected, status, rule = _select(root, budget)
        body = None if selected is None else _body(selected, budget)
        if body == "":
            status = "EMPTY_TEXT" if status == "TEXT" else "EMPTY_HTML_SOURCE"
        dto = {"SchemaVersion": 1, "Subject": headers.get("subject"),
               "From": headers.get("from"), "To": headers.get("to"),
               "MissingHeaders": [key for key in ("Subject", "From", "To") if key.lower() not in headers],
               "BodyKind": None if selected is None else "PLAIN_TEXT" if selected.get_content_type() == "text/plain" else "HTML_SOURCE",
               "BodyStatus": status, "Body": body, "SelectionRule": rule,
               "PartCount": count, "IgnoredPartCount": len(nodes) - (1 if selected is not None else 0)}
        _serialize(dto)
        budget.check()
        return dto
    except MimeError:
        raise
    except (MemoryError, RecursionError):
        _fail("PARSE_FAILED")
    except Exception:
        # Defects raised by strict policy are input failures, without their text.
        from email.errors import MessageDefect
        if isinstance(sys.exception(), MessageDefect):
            _fail("INVALID")
        _fail("PARSE_FAILED")


def raw_mime(data):
    """Identity for a separately bounded explicit raw read, without parsing."""
    if type(data) is not bytes:
        _fail("INPUT_INVALID")
    if len(data) > MIME_INPUT:
        _fail("LIMIT_EXCEEDED")
    return data


def _serialize(dto):
    result = json.dumps(dto, ensure_ascii=False, separators=(",", ":"), allow_nan=False).encode("utf-8")
    if len(result) > OUTPUT_BYTES:
        _fail("LIMIT_EXCEEDED")
    return result


def _read(stream, limit, budget):
    data = bytearray()
    try:
        while True:
            budget.check()
            chunk = stream.read(min(8192, limit + 1 - len(data)))
            if type(chunk) is not bytes:
                _fail("INPUT_INVALID")
            if not chunk:
                budget.check()
                return bytes(data)
            data.extend(chunk)
            if len(data) > limit:
                _fail("LIMIT_EXCEEDED")
    finally:
        data[:] = b"\0" * len(data)


def main():
    """Only fixed mode argv; stdin is the explicit content channel."""
    try:
        if len(sys.argv) != 2 or sys.argv[1] not in ("Decoded", "Mime"):
            _fail("INPUT_INVALID")
        mode = sys.argv[1]
        budget = _Budget()
        data = _read(sys.stdin.buffer, DECODED_INPUT if mode == "Decoded" else MIME_INPUT, budget)
        result = _serialize(project_decoded(data)) if mode == "Decoded" else raw_mime(data)
        budget.check()
    except MimeError as exc:
        sys.stderr.write(exc.code + "\n")
        return 1
    except Exception:
        sys.stderr.write("SMTP_MIME_PARSE_FAILED\n")
        return 1
    # Entire result checked before the first output byte; transport write faults
    # still need the future parent's no-partial-commit boundary.
    try:
        sys.stdout.buffer.write(result)
        sys.stdout.buffer.flush()
        return 0
    except Exception:
        sys.stderr.write("SMTP_MIME_PARSE_FAILED\n")
        return 1


if __name__ == "__main__":
    sys.exit(main())
