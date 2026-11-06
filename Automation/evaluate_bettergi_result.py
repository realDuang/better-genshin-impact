#!/usr/bin/env python3
"""Evaluate the final BetterGI attempt offline, without retrying or publishing."""

import argparse
import json
from pathlib import Path
import sys

from compact_bettergi_log import summarize
from publish_bettergi_report import _logs_for_run
from one_dragon_recovery import plan_recovery


def evaluate(status: dict, logs: list[tuple[str, str]], profile=None) -> dict:
    """Keep lifecycle failures and distinguish game errors from missing evidence."""
    process_exit_code = status.get('ProcessExitCode', status.get('ExitCode'))
    # The same parser evaluates game evidence independently of process/cleanup
    # failures. The original lifecycle and every attempt remain unchanged.
    summary = summarize({**status, 'Result': 'exited', 'ExitCode': 0,
                         'ProcessExitCode': 0, 'BusinessOutcome': None,
                         'BusinessEvidenceIssues': []}, logs)
    business_outcome = summary['outcome']
    if business_outcome != 'partial' and summary['evidence_issues']:
        business_outcome = 'incomplete'
    exit_code = status.get('ExitCode')
    if exit_code in (0, '0'):
        exit_code = {'partial': 2, 'incomplete': 3, 'unknown': 3}.get(business_outcome, 0)
    elif exit_code is None:
        exit_code = 1
    result = {
        'ProcessExitCode': process_exit_code,
        'BusinessOutcome': business_outcome,
        'BusinessEvidenceIssues': summary['evidence_issues'],
        'ExitCode': int(exit_code),
    }
    if profile is not None:
        result.update(plan_recovery(profile, summary))
        if result['RecoveryRequired'] and result['ExitCode'] == 0:
            result['BusinessOutcome'] = 'partial'
            result['ExitCode'] = 2
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run-dir', required=True, type=Path)
    parser.add_argument('--profile', type=Path)
    parser.add_argument('--status-file', type=Path)
    parser.add_argument('--install-dir', type=Path, default=Path(__file__).resolve().parent.parent)
    args = parser.parse_args()
    try:
        status = json.loads((args.status_file or args.run_dir / 'status.json').read_text(encoding='utf-8-sig'))
        if not isinstance(status, dict) or status.get('Phase') != 'finished':
            raise ValueError('The run must be finished before evaluating its result.')
        profile = json.loads(args.profile.read_text(encoding='utf-8-sig')) if args.profile else None
        result = evaluate(status, _logs_for_run(status, args.install_dir), profile)
        # ASCII JSON is safe through Windows PowerShell's native stdout decoding.
        print(json.dumps(result))
        return 0
    except (OSError, ValueError, UnicodeError) as error:
        print(f'Business result evaluation failed: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
