#!/usr/bin/env python3
"""Redact known inherited release credentials before archive output is saved or printed."""
import os
import re
import sys

SECRET_ENV_NAMES = (
    "KEYCHAIN_PASSWORD", "CERTIFICATE_P12_BASE64", "CERTIFICATE_PASSWORD",
    "DEVELOPER_ID_CERTIFICATE_P12_BASE64", "DEVELOPER_ID_CERTIFICATE_PASSWORD",
    "APPLE_ID", "APPLE_APP_SPECIFIC_PASSWORD", "APPLE_TEAM_ID",
    "APPLE_DISTRIBUTION_CERTIFICATE_P12_BASE64", "APPLE_DISTRIBUTION_CERTIFICATE_PASSWORD",
    "MAC_INSTALLER_DISTRIBUTION_CERTIFICATE_P12_BASE64",
    "MAC_INSTALLER_DISTRIBUTION_CERTIFICATE_PASSWORD", "APP_STORE_PROVISIONING_PROFILE_BASE64",
    "APP_STORE_APP_APPLE_ID", "APP_STORE_CONNECT_API_KEY_BASE64",
    "APP_STORE_CONNECT_API_KEY_ID", "APP_STORE_CONNECT_API_ISSUER_ID", "GH_TOKEN", "GITHUB_TOKEN",
)


def redact_stream(source, destination, secrets):
    values = sorted(set(secrets), key=len, reverse=True)
    pattern = re.compile(b"|".join(re.escape(value) for value in values)) if values else None
    keep = max((len(value) for value in values), default=1) - 1
    pending = b""
    while chunk := source.read(8192):
        pending += chunk
        boundary = max(0, len(pending) - keep)
        consumed = 0
        if pattern:
            for match in pattern.finditer(pending):
                if match.start() >= boundary:
                    break
                destination.write(pending[consumed:match.start()])
                destination.write(b"[REDACTED]")
                consumed = match.end()
        boundary = max(boundary, consumed)
        destination.write(pending[consumed:boundary])
        pending = pending[boundary:]
    destination.write(pattern.sub(b"[REDACTED]", pending) if pattern else pending)
    destination.flush()


def main():
    try:
        secrets = [os.fsencode(os.environ[name]) for name in SECRET_ENV_NAMES if os.environ.get(name)]
        redact_stream(sys.stdin.buffer, sys.stdout.buffer, secrets)
    except Exception:
        # Never echo an exception or fall back to raw input: either may contain credentials.
        print("::error::Archive log sanitization failed; raw output was not retained.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
