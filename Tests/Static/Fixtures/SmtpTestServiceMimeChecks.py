"""Synthetic pure MIME checks. Only fixed case IDs/status/counts are emitted."""

import ast
import base64
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import sys
from unittest.mock import patch


SOURCE = Path(__file__).resolve().parents[3] / "Tools" / "SmtpTestServiceMime.py"
SOURCE_BYTES = SOURCE.read_bytes()
SOURCE_HASH = hashlib.sha256(SOURCE_BYTES).hexdigest()
spec = importlib.util.spec_from_file_location("smtp_mime_pure", SOURCE)
mime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mime)


def mail(body=b"body", extra=b"", headers=b"Subject: synthetic\r\nFrom: sender@example.invalid\r\nTo: receiver@example.invalid\r\n"):
    return headers + extra + b"\r\n" + body


def part(content, body=b"", extra=b""):
    return b"Content-Type: " + content + b"\r\n" + extra + b"\r\n" + body


def multipart(kind, children, extra=b""):
    body = b"".join(b"--bound\r\n" + child + b"\r\n" for child in children) + b"--bound--\r\n"
    return mail(body, b"Content-Type: multipart/" + kind + b"; boundary=bound" + extra + b"\r\n")


def expect_error(data, code):
    try:
        mime.project_decoded(data)
    except mime.MimeError as exc:
        assert exc.code == "SMTP_MIME_" + code
        assert str(exc) == exc.code
        return
    raise AssertionError()


def decoded(data, body, status="TEXT", kind="PLAIN_TEXT"):
    dto = mime.project_decoded(data)
    assert dto["Body"] == body and dto["BodyStatus"] == status and dto["BodyKind"] == kind
    return dto


def nested(depth):
    child = part(b"text/plain", b"body")
    for i in range(depth - 1):
        boundary = ("level" + str(i)).encode("ascii")
        child = part(b"multipart/mixed; boundary=" + boundary,
                     b"--" + boundary + b"\r\n" + child + b"\r\n--" + boundary + b"--\r\n")
    return child


def headers_for_count(n):
    return b"".join(b"X-" + str(i).encode("ascii") + b": value\r\n" for i in range(n))


def main_call(mode, data):
    stdout = io.BytesIO()
    stderr = io.StringIO()
    class Output:
        buffer = stdout
    class Input:
        buffer = io.BytesIO(data)
    with patch.object(sys, "argv", ["fixed-script", mode]), patch.object(sys, "stdin", Input()), patch.object(sys, "stdout", Output()), patch.object(sys, "stderr", stderr):
        result = mime.main()
    return result, stdout.getvalue(), stderr.getvalue()


CASES = []


def case(name):
    def register(fn):
        CASES.append((name, fn))
        return fn
    return register


@case("M01_ASCII_DEFAULT")
def _():
    dto = decoded(mail(), "body")
    assert dto["Subject"] == "synthetic" and dto["PartCount"] == 1 and dto["MissingHeaders"] == []


@case("M02_UTF8_BODY")
def _():
    decoded(mail("Grüße".encode(), b"Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: 8bit\r\n"), "Grüße")


@case("M03_HEADER_BASE64")
def _():
    h = b"Subject: =?utf-8?B?R3LDvMOfZQ==?=\r\n"
    assert decoded(mail(headers=h), "body")["Subject"] == "Grüße"


@case("M04_HEADER_QP")
def _():
    assert decoded(mail(headers=b"Subject: =?iso-8859-1?Q?Gr=FC=DFe_Test?=\r\n"), "body")["Subject"] == "Grüße Test"


@case("M05_UTF8_HEADER_NAMES")
def _():
    h = "Subject: Grüße\r\nFrom: Grüße <sender@example.invalid>\r\nTo: receiver@example.invalid\r\n".encode()
    dto = decoded(mail(headers=h), "body")
    assert dto["Subject"] == "Grüße" and "Grüße" in dto["From"]


@case("M06_FOLD_ADJACENT")
def _():
    h = b"Subject: =?utf-8?Q?Hello?=\r\n =?us-ascii?Q?_World?=\r\n"
    assert decoded(mail(headers=h), "body")["Subject"] == "Hello World"


@case("M07_GROUP_ADDRESS")
def _():
    h = b"From: sender@example.invalid\r\nTo: Group: a@example.invalid, b@example.invalid;\r\n"
    assert "Group" in decoded(mail(headers=h), "body")["To"]


@case("M08_MISSING_HEADERS")
def _():
    dto = decoded(mail(headers=b""), "body")
    assert dto["Subject"] is None and dto["From"] is None and dto["To"] is None
    assert dto["MissingHeaders"] == ["Subject", "From", "To"]


@case("M09_ALTERNATIVE_PREFERS_LAST_PLAIN")
def _():
    children = [part(b"text/plain", b"first"), part(b"text/html", b"<p>html</p>"), part(b"text/plain", b"last")]
    dto = decoded(multipart(b"alternative", children), "last")
    assert dto["SelectionRule"] == "ALTERNATIVE_LAST_PLAIN"


@case("M10_HTML_SOURCE")
def _():
    text = '<script src="https://remote.example.invalid/x">alert(1)</script>'
    decoded(mail(text.encode(), b"Content-Type: text/html; charset=utf-8\r\n"), text, "HTML_SOURCE", "HTML_SOURCE")


@case("M11_RELATED_ROOT")
def _():
    dto = decoded(multipart(b"related", [part(b"text/plain", b"resource", b"Content-ID: <resource>\r\n"),
                  part(b"text/html", b"<img src='cid:resource'>", b"Content-ID: <root>\r\n")], b'; start="<root>"'),
                  "<img src='cid:resource'>", "HTML_SOURCE", "HTML_SOURCE")
    assert dto["SelectionRule"] == "RELATED_ROOT"


@case("M12_MIXED_ATTACHMENT_FIRST")
def _():
    children = [part(b"text/plain", b"attachment", b"Content-Disposition: attachment\r\n"), part(b"text/plain", b"body")]
    decoded(multipart(b"mixed", children), "body")


@case("M13_INLINE_FILENAME_EXCLUDED")
def _():
    dto = mime.project_decoded(mail(b"attachment", b'Content-Type: text/plain\r\nContent-Disposition: inline; filename="file.txt"\r\n'))
    assert dto["Body"] is None and dto["BodyStatus"] == "NO_READABLE_BODY"


@case("M14_EMPTY_BODY")
def _():
    decoded(mail(b""), "", "EMPTY_TEXT")


@case("M15_MESSAGE_ATTACHMENT_EXCLUDED")
def _():
    dto = mime.project_decoded(mail(mail(), b"Content-Type: message/rfc822\r\n"))
    assert dto["Body"] is None and dto["PartCount"] == 2


@case("M16_RAW_IDENTITY_AND_INDEPENDENT_QUOTA")
def _():
    raw = b"\xff\x00invalid\rbytes" * 100_000
    assert len(raw) > mime.DECODED_INPUT and mime.raw_mime(raw) is raw
    expect_error(raw, "LIMIT_EXCEEDED")


@case("M17_DUPLICATE_HEADER")
def _():
    expect_error(mail(headers=b"Subject: one\r\nSubject: two\r\n"), "INVALID")


@case("M18_INVALID_UTF8_HEADER")
def _():
    expect_error(mail(headers=b"Subject: \xff\r\n"), "INVALID_ENCODING")


@case("M19_UNSUPPORTED_CHARSET")
def _():
    expect_error(mail(b"abc", b"Content-Type: text/plain; charset=unsupported-fixed\r\n"), "UNSUPPORTED_CHARSET")


@case("M20_NONASCII_ADDRESS")
def _():
    expect_error(mail(headers="From: useré@example.invalid\r\n".encode()), "UNSUPPORTED_ADDRESS")


@case("M21_UNSUPPORTED_CTE")
def _():
    expect_error(mail(extra=b"Content-Transfer-Encoding: binary\r\n"), "UNSUPPORTED_ENCODING")


@case("M22_STRICT_BASE64_BAD_PADDING")
def _():
    expect_error(mail(b"YQ", b"Content-Transfer-Encoding: base64\r\n"), "INVALID_ENCODING")


@case("M23_BASE64_INVALID_SUFFIX")
def _():
    expect_error(mail(b"YQ==more", b"Content-Transfer-Encoding: base64\r\n"), "INVALID_ENCODING")


@case("M24_STRICT_HEADER_B64_PADDING")
def _():
    expect_error(mail(headers=b"Subject: =?utf-8?B?YQ?=\r\n"), "INVALID_ENCODING")


@case("M25_QP_DANGLING")
def _():
    expect_error(mail(b"body=", b"Content-Transfer-Encoding: quoted-printable\r\n"), "INVALID_ENCODING")


@case("M26_QP_INVALID_HEX")
def _():
    expect_error(mail(b"body=GG", b"Content-Transfer-Encoding: quoted-printable\r\n"), "INVALID_ENCODING")


@case("M27_VALID_QP_AND_BODY_UNDERSCORE")
def _():
    decoded(mail(b"Gr=C3=BC=C3=9Fe_name=\r\nnext", b"Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n"), "Grüße_namenext")


@case("M28_INVALID_CONTENT_TYPE")
def _():
    expect_error(mail(extra=b"Content-Type: invalid\r\n"), "INVALID")


@case("M29_MISSING_BOUNDARY")
def _():
    expect_error(mail(extra=b"Content-Type: multipart/mixed\r\n"), "INVALID")


@case("M30_RELATED_START_MISSING")
def _():
    expect_error(multipart(b"related", [part(b"text/plain", b"body")], b'; start="<missing>"'), "INVALID")


@case("M31_SELECTED_ERROR_NO_HTML_FALLBACK")
def _():
    expect_error(multipart(b"alternative", [part(b"text/plain; charset=unknown", b"body"), part(b"text/html", b"html")]), "UNSUPPORTED_CHARSET")


@case("M32_BINARY_CONTROLS")
def _():
    expect_error(mail(b"body\x00"), "INVALID_ENCODING")
    expect_error(mail(b"body\x85", b"Content-Type: text/plain; charset=iso-8859-1\r\nContent-Transfer-Encoding: 8bit\r\n"), "INVALID_ENCODING")


@case("M33_UTF8_INVALID_BODY")
def _():
    expect_error(mail(b"\xff", b"Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: 8bit\r\n"), "INVALID_ENCODING")


@case("M34_BODY_BOUNDARY")
def _():
    body = (b"a" * 1000 + b"\n") * 261 + b"a" * 883
    assert len(body) == mime.BODY_BYTES
    decoded(mail(body), body.decode())
    expect_error(mail(body + b"a"), "LIMIT_EXCEEDED")


@case("M35_FACTORY_BOUNDARY")
def _():
    children = [part(b"text/plain", b"body") for _ in range(63)]
    dto = mime.project_decoded(multipart(b"mixed", children))
    assert dto["PartCount"] == 64
    expect_error(multipart(b"mixed", children + [part(b"text/plain", b"extra")]), "LIMIT_EXCEEDED")


@case("M36_DEPTH_BOUNDARY")
def _():
    decoded(nested(8), "body")
    expect_error(nested(9), "LIMIT_EXCEEDED")


@case("M37_ROOT_FIELD_BOUNDARY")
def _():
    decoded(mail(headers=headers_for_count(64)), "body")
    expect_error(mail(headers=headers_for_count(65)), "LIMIT_EXCEEDED")


@case("M38_LINE_BOUNDARY")
def _():
    decoded(mail(b"a" * 16_384), "a" * 16_384)
    expect_error(mail(b"a" * 16_385), "LIMIT_EXCEEDED")


@case("M39_HEADER_VALUE_BOUNDARY")
def _():
    dto = mime.project_decoded(mail(headers=b"Subject: " + b"a" * 4096 + b"\r\n"))
    assert len(dto["Subject"]) == 4096
    expect_error(mail(headers=b"Subject: " + b"a" * 4097 + b"\r\n"), "LIMIT_EXCEEDED")


@case("M40_JSON_ESCAPING_OVERFLOW")
def _():
    body = (b"\t" * 1000 + b"\n") * 261 + b"\t" * 883
    expect_error(mail(body), "LIMIT_EXCEEDED")


@case("M41_INPUT_OVERFLOW")
def _():
    expect_error(b"x" * (mime.DECODED_INPUT + 1), "LIMIT_EXCEEDED")


@case("M42_RAW_OVERFLOW")
def _():
    try:
        mime.raw_mime(b"x" * (mime.MIME_INPUT + 1))
    except mime.MimeError as exc:
        assert exc.code == "SMTP_MIME_LIMIT_EXCEEDED"
        return
    raise AssertionError()


@case("M43_UNSUPPORTED_MULTIPART_EXPLICIT")
def _():
    dto = mime.project_decoded(multipart(b"report", [part(b"text/plain", b"body")]))
    assert dto["Body"] is None and dto["BodyStatus"] == "UNSUPPORTED_MULTIPART"


@case("M44_CLI_FIXED_ERROR_CANARY_ABSENT")
def _():
    code, out, err = main_call("Decoded", mail(b"PRIVATE_SYNTHETIC_CANARY", b"Content-Type: multipart/mixed\r\n"))
    assert code == 1 and out == b"" and err == "SMTP_MIME_INVALID\n"


@case("M45_CLI_RAW_IDENTITY")
def _():
    raw = b"\xff\x00\rraw\n"
    code, out, err = main_call("Mime", raw)
    assert code == 0 and out == raw and err == ""


@case("M46_CLI_NO_ARG_CONTENT")
def _():
    code, out, err = main_call("invalid-mode", b"PRIVATE_SYNTHETIC_CANARY")
    assert code == 1 and out == b"" and err == "SMTP_MIME_INPUT_INVALID\n"


@case("M47_COOPERATIVE_DEADLINE")
def _():
    with patch.object(mime.time, "monotonic", side_effect=[0.0, 6.0]):
        expect_error(mail(), "TIMEOUT")


@case("M48_IMPORT_NO_APPLICATION_IO")
def _():
    import types
    with patch("builtins.open", side_effect=AssertionError()), patch("io.open", side_effect=AssertionError()):
        loaded = types.ModuleType("smtp_mime_import_control")
        exec(compile(SOURCE_BYTES, "fixed-source", "exec"), loaded.__dict__)
    assert callable(loaded.project_decoded)


@case("M49_NO_EXTERNAL_ACTIONS_AST")
def _():
    tree = ast.parse(SOURCE_BYTES)
    imported = {n.name.split(".")[0] for node in ast.walk(tree) if isinstance(node, ast.Import) for n in node.names}
    assert not imported.intersection({"socket", "urllib", "requests", "subprocess", "pathlib", "os", "zipfile", "tarfile"})
    calls = {node.func.id for node in ast.walk(tree) if isinstance(node, ast.Call) and isinstance(node.func, ast.Name)}
    assert "open" not in calls


@case("M50_VALID_BASE64")
def _():
    text = "Grüße"
    encoded = base64.b64encode(text.encode())
    decoded(mail(encoded, b"Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n"), text)


@case("M51_LINE_COUNT_BOUNDARY")
def _():
    value = mail(b"\n" * (mime.LINES - 4))
    assert len(value.splitlines(keepends=True)) == mime.LINES
    mime.project_decoded(value)
    expect_error(value + b"\n", "LIMIT_EXCEEDED")


@case("M52_INPUT_EXACT_BOUNDARY")
def _():
    prefix = mail(b"", b"Content-Type: application/octet-stream\r\n")
    remaining = mime.DECODED_INPUT - len(prefix)
    body = (b"x" * 999 + b"\n") * (remaining // 1000) + b"x" * (remaining % 1000)
    value = prefix + body
    assert len(value) == mime.DECODED_INPUT
    assert mime.project_decoded(value)["BodyStatus"] == "NO_READABLE_BODY"
    expect_error(value + b"x", "LIMIT_EXCEEDED")


@case("M53_RAW_EXACT_BOUNDARY")
def _():
    value = b"x" * mime.MIME_INPUT
    assert mime.raw_mime(value) is value


@case("M54_PART_HEADER_BYTES_BOUNDARY")
def _():
    child = part(b"text/plain", b"body", b"X: " + b"a" * 8163 + b"\r\n")
    mime.project_decoded(multipart(b"mixed", [child]))
    expect_error(multipart(b"mixed", [part(b"text/plain", b"body", b"X: " + b"a" * 8164 + b"\r\n")]), "LIMIT_EXCEEDED")


@case("M55_PART_HEADER_FIELDS_BOUNDARY")
def _():
    mime.project_decoded(multipart(b"mixed", [part(b"text/plain", b"body", headers_for_count(31))]))
    expect_error(multipart(b"mixed", [part(b"text/plain", b"body", headers_for_count(32))]), "LIMIT_EXCEEDED")


@case("M56_TOTAL_FIELDS_BOUNDARY")
def _():
    children = [part(b"text/plain", b"body", headers_for_count(31)) for _ in range(7)]
    mime.project_decoded(multipart(b"mixed", children + [part(b"text/plain", b"body", headers_for_count(27))]))
    expect_error(multipart(b"mixed", children + [part(b"text/plain", b"body", headers_for_count(28))]), "LIMIT_EXCEEDED")


@case("M57_TOTAL_HEADER_BYTES_REFUSAL")
def _():
    child = part(b"text/plain", b"body", b"X: " + b"a" * 8163 + b"\r\n")
    expect_error(multipart(b"mixed", [child] * 8), "LIMIT_EXCEEDED")


@case("M58_ADDRESS_COUNTS")
def _():
    for name, count in ((b"From", 8), (b"To", 64)):
        addresses = [b"a" + str(i).encode() + b"@example.invalid" for i in range(count)]
        mime.project_decoded(mail(headers=name + b": " + b", ".join(addresses) + b"\r\n"))
        expect_error(mail(headers=name + b": " + b", ".join(addresses + [b"extra@example.invalid"]) + b"\r\n"), "LIMIT_EXCEEDED")


@case("M59_UTF8_OUTPUT_EXPANSION_REFUSAL")
def _():
    body = (b"\xe9" * 999 + b"\n") * 132
    expect_error(mail(body, b"Content-Type: text/plain; charset=iso-8859-1\r\nContent-Transfer-Encoding: 8bit\r\n"), "LIMIT_EXCEEDED")


@case("M60_READ_BUFFER_FINALLY_OBSERVED")
def _():
    held = []
    class Observed(bytearray):
        def __init__(self):
            super().__init__()
            held.append(self)
    with patch.dict(mime.__dict__, {"bytearray": Observed}):
        try:
            mime._read(io.BytesIO(b"PRIVATE_SYNTHETIC_CANARY"), 5, mime._Budget())
        except mime.MimeError as exc:
            assert exc.code == "SMTP_MIME_LIMIT_EXCEEDED"
        else:
            raise AssertionError()
    assert len(held) == 1 and len(held[0]) == 6 and all(value == 0 for value in held[0])


@case("M61_LITERAL_REPLACEMENT_SCALAR")
def _():
    decoded(mail("\ufffd".encode(), b"Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: 8bit\r\n"), "\ufffd")


@case("M62_DUPLICATE_STRUCTURAL_HEADER")
def _():
    expect_error(mail(extra=b"Content-Type: text/plain\r\nContent-Type: text/html\r\n"), "INVALID")


@case("M63_NO_INPUT_IO")
def _():
    for value in (None, "content", bytearray(b"content")):
        expect_error(value, "INPUT_INVALID")


def main():
    passed = failed = 0
    for name, fn in CASES:
        try:
            fn()
            passed += 1
            print(json.dumps({"Case": name, "Status": "PASS"}, separators=(",", ":")))
        except Exception as exc:
            failed += 1
            code = exc.code if isinstance(exc, mime.MimeError) else "FIXTURE_ASSERTION_FAILED"
            print(json.dumps({"Case": name, "Status": "FAIL", "Code": code}, separators=(",", ":")))
    stable = hashlib.sha256(SOURCE.read_bytes()).hexdigest() == SOURCE_HASH
    print(json.dumps({"Passed": passed, "Failed": failed, "Inventory": len(CASES), "SourceStable": stable,
                      "Python": sys.version.split()[0]}, separators=(",", ":")))
    return 0 if len(CASES) == 63 and passed == 63 and failed == 0 and stable else 1


if __name__ == "__main__":
    sys.exit(main())
