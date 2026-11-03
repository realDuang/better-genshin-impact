#!/usr/bin/env python3
"""Publish a frozen, deterministic BetterGI report through a Lark bot profile."""

import argparse
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path, PureWindowsPath
import re
import shutil
import subprocess
import sys
import time
import uuid
import zipfile

import compact_bettergi_log as compact


POST_LIMIT_BYTES = 20_000
UNCERTAIN_RETRY_SECONDS = 55 * 60
ARCHIVE_NAME = 'bettergi-report.zip'


class DeliveryError(Exception):
    """A sanitized failure; unknown means the server may have accepted a send."""

    def __init__(self, message, *, unknown=False):
        super().__init__(message)
        self.unknown = unknown


def _now():
    return datetime.now(timezone.utc).isoformat()


def _timestamp(value):
    try:
        value = re.sub(r'(\.\d{6})\d+(?=[+-]|Z|$)', r'\1', str(value))
        parsed = datetime.fromisoformat(value.replace('Z', '+00:00'))
        return parsed if parsed.tzinfo is not None else None
    except (ValueError, TypeError):
        return None


def _json_text(value):
    return json.dumps(value, ensure_ascii=False, indent=2) + '\n'


def _write_json(path, value):
    """Replace the journal atomically so a terminated sender remains retryable."""
    temporary = path.with_name(path.name + '.' + uuid.uuid4().hex + '.tmp')
    try:
        with temporary.open('w', encoding='utf-8', newline='\n') as stream:
            stream.write(_json_text(value))
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


@contextmanager
def _report_lock(directory):
    directory.mkdir(parents=True, exist_ok=True)
    with (directory / '.publish.lock').open('a+b', buffering=0) as lock:
        if lock.seek(0, os.SEEK_END) == 0:
            lock.write(b'\0')
        lock.seek(0)
        try:
            if os.name == 'nt':
                import msvcrt
                msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            raise DeliveryError('Another publisher is already processing this run.') from None
        try:
            yield
        finally:
            lock.seek(0)
            if os.name == 'nt':
                msvcrt.locking(lock.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)


def _run_cli(argv, timeout, *, cwd=None):
    """Run the native executable directly; never disclose raw CLI error output."""
    try:
        result = subprocess.run(
            argv, cwd=cwd, timeout=timeout, shell=False, capture_output=True,
            creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0,
        )
    except subprocess.TimeoutExpired:
        raise DeliveryError('Lark CLI timed out.', unknown=True) from None
    except OSError:
        raise DeliveryError('Lark CLI could not be started.') from None
    output = result.stdout if result.returncode == 0 else result.stderr
    try:
        response = json.loads(output.decode('utf-8-sig'))
    except (UnicodeError, ValueError):
        raise DeliveryError('Lark CLI returned no usable JSON receipt.', unknown=True) from None
    if result.returncode != 0:
        rejected = _definite_rejection(response)
        raise DeliveryError('Lark CLI rejected the request.' if rejected else
                            'Lark CLI exited without a receipt.', unknown=not rejected)
    return response


def _definite_rejection(response):
    if not isinstance(response, dict) or response.get('ok') is not False:
        return False
    error = response.get('error')
    if not isinstance(error, dict):
        return False
    if error.get('type') in {'authorization', 'authentication', 'validation', 'argument',
                             'configuration', 'permission', 'confirmation_required'}:
        return True
    # An explicit platform error code is a rejection; transport errors are not.
    code = error.get('code')
    return isinstance(code, int) and not isinstance(code, bool) and code >= 1000


def _post_payload(text, attachment_enabled):
    def encode(value):
        lines = value.rstrip('\n').split('\n')
        post = {'zh_cn': {'title': lines[0], 'content': [
            [{'tag': 'text', 'text': line}] for line in lines[1:] if line
        ]}}
        return json.dumps(post, ensure_ascii=False, separators=(',', ':'))

    payload = encode(text)
    if len(payload.encode('utf-8')) <= POST_LIMIT_BYTES:
        return payload
    suffix = '\n完整记录见附件。' if attachment_enabled else '\n完整记录已保存在运行目录。'
    raw = text.encode('utf-8')
    low, high = 0, min(len(raw), POST_LIMIT_BYTES)
    while low < high:
        middle = (low + high + 1) // 2
        candidate = encode(raw[:middle].decode('utf-8', errors='ignore').rstrip() + suffix)
        if len(candidate.encode('utf-8')) <= POST_LIMIT_BYTES:
            low = middle
        else:
            high = middle - 1
    return encode(raw[:low].decode('utf-8', errors='ignore').rstrip() + suffix)


def _logs_for_run(status, install_dir):
    start, end = _timestamp(status.get('Started')), _timestamp(status.get('Updated'))
    if not start or not end or end < start:
        return []
    day, final = start.date(), end.astimezone(start.tzinfo).date()
    logs = []
    while day <= final:
        path = install_dir / 'log' / f'better-genshin-impact{day:%Y%m%d}.log'
        if path.is_file():
            logs.append((str(path), path.read_bytes().decode('utf-8-sig')))
        day += timedelta(days=1)
    return logs


def _file_hash(path):
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def _key(binding, part):
    data = json.dumps([binding['app_id'], binding['chat_id'], binding['run_id'], part],
                      ensure_ascii=False, separators=(',', ':'))
    return 'bgi-' + hashlib.sha256(data.encode('utf-8')).hexdigest()[:44]


def _prepare_report(run_dir, install_dir, status, binding, attachment_enabled):
    report_dir = run_dir / 'report'
    journal_path = report_dir / 'delivery.json'
    parts = ['summary', 'attachment'] if attachment_enabled else ['summary']
    if journal_path.exists():
        journal = json.loads(journal_path.read_text(encoding='utf-8-sig'))
        if not isinstance(journal, dict) or not isinstance(journal.get('parts'), dict):
            raise DeliveryError('The saved delivery journal is invalid.')
        if journal.get('binding') != binding or set(journal['parts']) != set(parts):
            raise DeliveryError('The saved report belongs to a different run or delivery target.')
        artifacts = journal.get('artifacts')
        required = {'summary.txt', 'summary.json', 'application.log', 'status.json', 'post.json', ARCHIVE_NAME}
        if not isinstance(artifacts, dict) or not required <= artifacts.keys():
            raise DeliveryError('The saved report has no artifact manifest.')
        for name, digest in artifacts.items():
            if not isinstance(name, str) or name not in required | {'runner.log'} or not (report_dir / name).is_file():
                raise DeliveryError('A frozen report artifact is missing.')
            if _file_hash(report_dir / name) != digest:
                raise DeliveryError('A frozen report artifact was changed.')
        for part in parts:
            entry = journal['parts'][part]
            if not isinstance(entry, dict) or entry.get('state') not in {'ready', 'pending', 'sent', 'failed', 'unknown'}:
                raise DeliveryError('A saved delivery part is invalid.')
            if entry.get('key') != _key(binding, part):
                raise DeliveryError('The saved delivery key does not match this report.')
        return journal

    logs = _logs_for_run(status, install_dir)
    summary = compact.summarize(status, logs)
    text = compact.render_text(summary)
    selected_log = compact.extract_run_log(status, logs)
    staging = report_dir / ('.build-' + uuid.uuid4().hex)
    staging.mkdir()
    try:
        (staging / 'summary.txt').write_text(text, encoding='utf-8')
        (staging / 'summary.json').write_text(_json_text(summary), encoding='utf-8')
        with (staging / 'application.log').open('w', encoding='utf-8', newline='') as stream:
            stream.write(selected_log)
        (staging / 'status.json').write_text(_json_text(status), encoding='utf-8')
        entries = ['summary.txt', 'summary.json', 'application.log', 'status.json']
        if (run_dir / 'runner.log').is_file():
            shutil.copyfile(run_dir / 'runner.log', staging / 'runner.log')
            entries.append('runner.log')
        with zipfile.ZipFile(staging / ARCHIVE_NAME, 'w', zipfile.ZIP_DEFLATED) as archive:
            for name in entries:
                archive.write(staging / name, arcname=name)
        (staging / 'post.json').write_text(_post_payload(text, attachment_enabled), encoding='utf-8')
        entries += [ARCHIVE_NAME, 'post.json']
        artifacts = {name: _file_hash(staging / name) for name in entries}
        for name in entries:
            os.replace(staging / name, report_dir / name)
    finally:
        shutil.rmtree(staging)
    journal = {
        'version': 1, 'binding': binding, 'created_at': _now(), 'artifacts': artifacts,
        'parts': {part: {'state': 'ready', 'key': _key(binding, part)} for part in parts},
    }
    _write_json(journal_path, journal)
    return journal


def _uncertain_since(part):
    if part.get('uncertain_since'):
        return part['uncertain_since']
    if part.get('state') in {'pending', 'unknown'}:
        return part.get('pending_at')
    return None


def _check_retry_window(part):
    if part.get('state') == 'sent':
        if not part.get('message_id'):
            raise DeliveryError('A saved delivery receipt is incomplete.')
        return
    uncertain = _uncertain_since(part)
    if uncertain:
        stamp = _timestamp(uncertain)
        age = (datetime.now(timezone.utc) - stamp).total_seconds() if stamp else float('inf')
        if age < 0 or age >= UNCERTAIN_RETRY_SECONDS:
            raise DeliveryError('An earlier send has no receipt and its retry window has expired.', unknown=True)
    elif part.get('state') in {'pending', 'unknown'}:
        raise DeliveryError('An earlier send has no usable timestamp.', unknown=True)


def _validated_config(config):
    if not isinstance(config, dict):
        raise DeliveryError('The report configuration must be a JSON object.')
    for field in ('profile', 'app_id', 'chat_id', 'cli_path'):
        if not isinstance(config.get(field), str) or not config[field].strip():
            raise DeliveryError(f'The report configuration is missing {field}.')
    if not re.fullmatch(r'cli_[A-Za-z0-9]+', config['app_id']) or not re.fullmatch(r'oc_[A-Za-z0-9]+', config['chat_id']):
        raise DeliveryError('The report requires an application ID and a group chat ID.')
    cli_path = config['cli_path']
    if not (Path(cli_path).is_absolute() or PureWindowsPath(cli_path).is_absolute()):
        raise DeliveryError('Lark CLI must use an absolute executable path.')
    if Path(cli_path).suffix.lower() in {'.cmd', '.bat', '.ps1'}:
        raise DeliveryError('Lark CLI must be a native executable.')
    for field, default in [('command_timeout_seconds', 40), ('total_timeout_seconds', 140)]:
        try:
            value = float(config.get(field, default))
            if not 0 < value <= 600:
                raise ValueError
        except (ValueError, TypeError):
            raise DeliveryError(f'The report configuration has an invalid {field}.') from None
    return config


def publish(run_dir: Path, install_dir: Path, config: dict, dry_run=False, cli_runner=None) -> dict:
    """Generate once and send each report part once; retries reuse frozen files."""
    if isinstance(config, dict) and config.get('enabled') is False:
        return {'ok': True, 'state': 'disabled'}
    config = _validated_config(config)
    deadline = time.monotonic() + float(config.get('total_timeout_seconds', 140))
    run_dir, install_dir = Path(run_dir).resolve(), Path(install_dir).resolve()
    report_dir = run_dir / 'report'
    with _report_lock(report_dir):
        try:
            status = json.loads((run_dir / 'status.json').read_text(encoding='utf-8-sig'))
            if not isinstance(status, dict) or status.get('Phase') != 'finished':
                raise DeliveryError('The run must be finished before publishing.')
            run_id = status.get('RunId')
            if not isinstance(run_id, str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,127}', run_id):
                raise DeliveryError('The run has no valid RunId.')
            binding = {'app_id': config['app_id'], 'chat_id': config['chat_id'], 'run_id': run_id}
            journal = _prepare_report(run_dir, install_dir, status, binding,
                                      config.get('send_log_attachment', True) is True)
        except (OSError, ValueError, UnicodeError):
            raise DeliveryError('The local report could not be generated or verified.') from None

        result = {'ok': True, 'state': 'dry-run' if dry_run else 'sent', 'run_id': run_id,
                  'report_dir': str(report_dir), 'parts': journal['parts']}
        if dry_run:
            return result
        journal_path = report_dir / 'delivery.json'
        runner = cli_runner or (lambda argv, timeout: _run_cli(argv, timeout, cwd=report_dir))

        def call(arguments):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise DeliveryError('The report delivery deadline was reached.')
            return runner([config['cli_path'], '--profile', config['profile']] + arguments,
                          min(float(config.get('command_timeout_seconds', 40)), remaining))

        try:
            for part in journal['parts'].values():
                _check_retry_window(part)
            if all(part.get('state') == 'sent' for part in journal['parts'].values()):
                return result
            profiles = call(['profile', 'list'])
            if isinstance(profiles, dict) and profiles.get('ok') is True:
                profiles = profiles.get('data')
            matching = [profile for profile in profiles if isinstance(profile, dict) and
                        profile.get('name') == config['profile']] if isinstance(profiles, list) else []
            if len(matching) != 1 or matching[0].get('appId') != config['app_id']:
                raise DeliveryError('The Lark CLI profile does not match the configured application.')

            for name, part in journal['parts'].items():
                if part.get('state') == 'sent':
                    continue
                # Check the window again after profile lookup, before any mutation.
                _check_retry_window(part)
                if deadline <= time.monotonic():
                    raise DeliveryError('The report delivery deadline was reached.')
                arguments = ['im', '+messages-send', '--as', 'bot', '--format', 'json',
                             '--chat-id', config['chat_id'],
                             '--idempotency-key', part['key']]
                if name == 'summary':
                    arguments += ['--msg-type', 'post', '--content',
                                  (report_dir / 'post.json').read_text(encoding='utf-8')]
                else:
                    arguments += ['--file', './' + ARCHIVE_NAME]
                uncertain = _uncertain_since(part)
                if uncertain:
                    part['uncertain_since'] = uncertain
                part.update(state='pending', pending_at=_now(), attempts=part.get('attempts', 0) + 1)
                part.pop('error', None)
                _write_json(journal_path, journal)
                try:
                    receipt = call(arguments)
                    if not isinstance(receipt, dict) or receipt.get('ok') is not True:
                        rejected = _definite_rejection(receipt)
                        raise DeliveryError('Lark CLI rejected the message.' if rejected else
                                            'Lark CLI returned no successful receipt.', unknown=not rejected)
                    data = receipt.get('data')
                    message_id = data.get('message_id') if isinstance(data, dict) else None
                    if not isinstance(message_id, str) or not message_id.strip():
                        raise DeliveryError('Lark CLI returned no message ID.', unknown=True)
                    part.update(state='sent', message_id=message_id, sent_at=_now())
                    part.pop('uncertain_since', None)
                    _write_json(journal_path, journal)
                except DeliveryError as error:
                    unknown = error.unknown or bool(uncertain)
                    part.update(state='unknown' if unknown else 'failed', error=str(error))
                    if unknown:
                        part['uncertain_since'] = uncertain or part['pending_at']
                    _write_json(journal_path, journal)
                    raise
                except (OSError, ValueError, TypeError):
                    part.update(state='unknown', error='Delivery ended without a persisted receipt.',
                                uncertain_since=uncertain or part['pending_at'])
                    _write_json(journal_path, journal)
                    raise DeliveryError(part['error'], unknown=True) from None
            journal.pop('last_error', None)
            _write_json(journal_path, journal)
            return result
        except DeliveryError as error:
            journal['last_error'] = {'at': _now(), 'message': str(error)}
            _write_json(journal_path, journal)
            raise
        except (OSError, ValueError, TypeError):
            raise DeliveryError('The report delivery could not be completed.') from None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run-dir', required=True, type=Path)
    parser.add_argument('--config', required=True, type=Path)
    parser.add_argument('--install-dir', type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    try:
        config = json.loads(args.config.read_text(encoding='utf-8-sig'))
        result = publish(args.run_dir, args.install_dir, config, dry_run=args.dry_run)
        print(_json_text(result), end='')
        return 0
    except (DeliveryError, OSError, ValueError, UnicodeError) as error:
        message = str(error) if isinstance(error, DeliveryError) else 'The report configuration could not be read.'
        print(json.dumps({'ok': False, 'error': message}, ensure_ascii=False), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
