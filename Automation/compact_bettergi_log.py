#!/usr/bin/env python3
"""Create a deterministic, offline BetterGI report from native logs and run status.

Only explicit run identity, lifecycle, stage boundaries, and fixed message rules
are used. No game actions, network calls, inference service, or third-party
packages are required. A stage ending does not establish that rewards arrived.
"""

import argparse
from datetime import datetime
import json
from pathlib import Path
import re


HEADER = re.compile(
    r'^\[(?P<time>\d{2}:\d{2}:\d{2}(?:\.\d+)?)\] '
    r'\[(?P<level>[A-Z]+)\][ \t]*'
    r'(?:\[(?P<context>[^\]\r\n]+)\][ \t]*)?'
    r'(?P<logger>[^\r\n]*)\r?$', re.MULTILINE)
IDENTITY = re.compile(r'(?:ChildSession|Primary):S(?P<session>\d+):P(?P<pid>\d+):T(?P<instance>\d+)')
DATE_IN_NAME = re.compile(r'(?<!\d)(20\d{6})(?!\d)')
STAGE = re.compile(r'一条龙任务执行\s*[:：]\s*(\d+)\s*/\s*(\d+)')
STAGE_END = re.compile(r'^→\s*["“]?任务结束["”]?\s*$')
ERROR_LEVELS = {'ERR', 'ERROR', 'FTL', 'FATAL'}
WARNING_LEVELS = {'WRN', 'WARN', 'WARNING'}
AMBIGUOUS_REWARDS = ('未完成或者已领取', '未探索完成或已领取')
NAME_CUES = (
    ('邮件：', '邮件'), ('前往合成台', '合成浓缩树脂'),
    ('自动秘境', '自动秘境'), ('前往冒险家协会领取奖励', '冒险家协会'),
    ('领取尘歌壶奖励', '尘歌壶'),
)
OUTCOMES = {
    'failed': '执行失败', 'time-limit': '超时停止', 'skipped': '跳过',
    'partial': '有任务失败', 'finished': '完成',
    'needs-attention': '有提示', 'unknown': '结果未识别', 'incomplete': '记录不完整',
}
REWARDS = {'claimed': '已领取', 'unclaimed': '未领取', 'unknown': '未识别'}


def _add(items, text):
    """Aggregate exact normalized messages without limiting retained evidence."""
    if not text:
        return
    for item in items:
        if item['text'] == text:
            item['count'] += 1
            return
    items.append({'text': text, 'count': 1})



def _record_step_facts(step, body, level, logger):
    """Extract facts from attributed native records without changing outcome rules."""
    if logger != 'TaskControl' or level not in {'INF', 'INFO'}:
        return
    facts = step['facts']
    if step['name'] == '邮件' and '邮件：' in body and '全部领取' in body:
        facts['mail_claim_action'] = True
    if step['name'] == '尘歌壶' and '领取好感和宝钱' in body:
        facts['teapot_claim_action'] = True
    if step['name'] != '自动秘境':
        return
    if '检测到秘境结束提示(挑战达成)' in body:
        facts['challenges_completed'] = facts.get('challenges_completed', 0) + 1
    if match := re.fullmatch(r'提升指南选择秘境："(.+)"', body):
        facts['domain'] = match[1]
    if match := re.fullmatch(r'原粹树脂：(\d+)，浓缩树脂：(\d+)', body):
        facts['resin_remaining'] = {'original': int(match[1]), 'condensed': int(match[2])}
    if match := re.fullmatch(r'"?自动秘境"?：使用\s+"(原粹树脂|浓缩树脂)", 数量：(\d+)', body):
        facts['pending_resin_action'] = (match[1], int(match[2]))
    if match := re.fullmatch(r'自动秘境：本轮奖励识别结果\s+"(.+)"', body):
        facts['reward_claims'] = facts.get('reward_claims', 0) + 1
        if pending := facts.pop('pending_resin_action', None):
            used = facts.setdefault('resin_used', {})
            used[pending[0]] = used.get(pending[0], 0) + pending[1]
        items = facts.setdefault('reward_items', {})
        for item in match[1].split(', '):
            if reward := re.fullmatch(r'(.+?)\s+x(\d+)', item):
                items[reward[1]] = items.get(reward[1], 0) + int(reward[2])


def _compact_error(body):
    """Keep the message and first exception detail; remove stack frames."""
    lines = [line.strip() for line in body.splitlines() if line.strip()]
    if not lines:
        return '(空错误消息)'
    first = re.sub(r'^前往冒险家协会领取奖励执行异常\s*[:：]\s*', '', lines[0])
    for line in lines[1:]:
        if re.search(r'(?:Exception|Error)\s*:', line):
            if line not in first:
                return first + '；' + line
    return first


def _compact_warning(body):
    """Normalize only the known retry counter; keep unknown warnings verbatim."""
    return re.sub(r'进行第\s*\d+/(\d+)\s*次重试', r'进行重试（最多 \1 次）', body.strip())


def _merge_progress_messages(summary, global_key, step_key, values, compact):
    """Keep max(log count, status count) without inventing step attribution."""
    native = {}
    for group in [summary[global_key]] + [step[step_key] for step in summary['steps']]:
        for item in group:
            item['sources'] = ['application_log']
            native.setdefault(item['text'], []).append(item)
    status_items = []
    for value in values:
        _add(status_items, compact(str(value)))
    for item in status_items:
        matches = native.get(item['text'], [])
        for match in matches:
            match['sources'].append('status_progress')
        extra = max(0, item['count'] - sum(match['count'] for match in matches))
        if not extra:
            continue
        global_match = next((match for match in matches if any(match is entry for entry in summary[global_key])), None)
        if global_match:
            global_match['count'] += extra
        else:
            supplement = {'text': item['text'], 'count': extra, 'sources': ['status_progress']}
            if matches:
                supplement['note'] = '运行状态记录的额外次数，无法定位到具体步骤。'
            summary[global_key].append(supplement)
    return status_items


def _aware_time(value):
    try:
        # Windows status uses seven fractional digits; Python 3.9 accepts six.
        value = re.sub(r'(\.\d{6})\d+(?=[+-]|Z|$)', r'\1', str(value))
        result = datetime.fromisoformat(value.replace('Z', '+00:00'))
        return result if result.tzinfo is not None else None
    except (ValueError, TypeError):
        return None


def _matching_records(status, logs, issues):
    start, end = _aware_time(status.get('Started')), _aware_time(status.get('Updated'))
    if not start or not end or end < start:
        issues.append('Started/Updated 缺失、缺少时区或时间区间无效，未关联应用日志。')
        return []
    try:
        pid, session = int(status['BetterGiPid']), int(status['ChildSession'])
        if pid <= 0 or session < 0:
            raise ValueError
    except (KeyError, ValueError, TypeError):
        issues.append('运行缺少有效 PID/ChildSession，未关联其他进程日志。')
        return []
    records = []
    for source_index, (filename, text) in enumerate(logs):
        found = DATE_IN_NAME.findall(Path(filename).name)
        try:
            if len(set(found)) > 1:
                raise ValueError
            day = datetime.strptime(found[0], '%Y%m%d').date() if found else start.date()
        except ValueError:
            issues.append(f'日志文件日期不明确，已忽略：{Path(filename).name}')
            continue
        if not found and start.date() != end.astimezone(start.tzinfo).date():
            issues.append(f'跨日运行的日志缺少文件日期，已忽略：{Path(filename).name}')
            continue
        matches = list(HEADER.finditer(text))
        for record_index, match in enumerate(matches):
            identity = IDENTITY.fullmatch(match['context'] or '')
            if not identity or int(identity['pid']) != pid or int(identity['session']) != session:
                continue
            try:
                stamp = datetime.fromisoformat(f'{day.isoformat()}T{match["time"]}').replace(tzinfo=start.tzinfo)
            except ValueError:
                issues.append(f'日志时间无效，已忽略一条记录：{Path(filename).name}')
                continue
            if not start <= stamp <= end:
                continue
            stop = matches[record_index + 1].start() if record_index + 1 < len(matches) else len(text)
            records.append({
                'time': stamp, 'level': match['level'], 'instance': identity['instance'],
                'logger': match['logger'].strip(), 'body': text[match.end():stop].strip(),
                'raw': text[match.start():stop],
                'order': (source_index, record_index),
            })
    return sorted(records, key=lambda item: (item['time'], item['order']))


def _attempts(status):
    values = status.get('Attempts')
    return [item for item in values if isinstance(item, dict)] if isinstance(values, list) else []


def extract_run_log(status: dict, logs: list[tuple[str, str]]) -> str:
    """Retain each attempt's native records without merging ambiguous instances."""
    selected = {}
    for attempt in _attempts(status) or [status]:
        owned = {**status, **attempt}
        if str(owned.get('Result', '')).lower() == 'skipped' and not owned.get('BetterGiPid'):
            continue
        records = _matching_records(owned, logs, [])
        if len({record['instance'] for record in records}) > 1:
            continue
        for record in records:
            selected[record['order']] = record
    return ''.join(record['raw'] for record in sorted(selected.values(), key=lambda item: (item['time'], item['order'])))


def summarize(status: dict, logs: list[tuple[str, str]]) -> dict:
    """Return complete compact evidence for one exact run; never claim success."""
    result = str(status.get('Result') or '').lower()
    summary = {
        'run_id': status.get('RunId', ''),
        'started': status.get('Started'), 'updated': status.get('Updated'),
        'lifecycle': {'phase': status.get('Phase'), 'result': status.get('Result'),
                      'detail': status.get('Detail') or ''},
        'exit_code': status.get('ExitCode'),
        'process_exit_code': status.get('ProcessExitCode', status.get('ExitCode')),
        'outcome': 'unknown',
        'steps': [], 'reward': {'state': 'unknown', 'raw': ''},
        'global_errors': [], 'global_warnings': [], 'evidence_issues': [],
        'flow_ended': False, 'matched_records': 0, 'legacy_progress': None,
    }
    issues = summary['evidence_issues']
    attempts = _attempts(status)
    if attempts:
        summary['attempt_count'] = len(attempts)
        summary['attempts'] = [{
            'number': item.get('Number', index),
            'started': item.get('Started'), 'updated': item.get('Updated'),
            'child_session': item.get('ChildSession'), 'bettergi_pid': item.get('BetterGiPid'),
            'exit_code': item.get('ExitCode'), 'result': item.get('Result'),
            'detail': item.get('Detail') or '', 'cleanup_succeeded': item.get('CleanupSucceeded'),
        } for index, item in enumerate(attempts, 1)]
        if status.get('AttemptCount') not in (None, len(attempts)):
            issues.append('尝试次数与尝试明细不一致。')
    # Earlier failures remain in attempt history; business results belong to the final attempt.
    log_status = {**status, **attempts[-1]} if attempts else status
    # A prelaunch skip has no process identity and cannot own application logs.
    records = [] if result == 'skipped' and not log_status.get('BetterGiPid') else _matching_records(log_status, logs, issues)
    summary['matched_records'] = len(records)
    instances = {record['instance'] for record in records}
    ambiguous = len(instances) > 1
    if ambiguous:
        issues.append('同一 PID/ChildSession 命中多个 T 实例标志，未合并步骤或奖励终态。')
    current = None
    for record in records:
        body, level, logger = record['body'], record['level'], record['logger'].rsplit('.', 1)[-1]
        if ambiguous:
            prefix = f'实例 T{record["instance"]}：'
            if level in ERROR_LEVELS:
                _add(summary['global_errors'], prefix + _compact_error(body))
            elif level in WARNING_LEVELS:
                _add(summary['global_warnings'], prefix + _compact_warning(body))
            continue
        if logger == 'OneDragonFlowViewModel' and (match := STAGE.search(body)):
            current = {
                'index': int(match[1]), 'total': int(match[2]),
                'name': f'步骤 {int(match[1])}', 'state': 'incomplete',
                'errors': [], 'warnings': [], 'notes': [], 'facts': {}, 'ended': False,
            }
            summary['steps'].append(current)
        # Final reward checks belong to the whole run, even after an unclosed step.
        is_reward = '检查每日奖励结果' in body or '每日委托奖励：' in body
        if is_reward:
            state = 'unknown'
            if not any(cue in body for cue in AMBIGUOUS_REWARDS):
                if '未领取' in body:
                    state = 'unclaimed'
                elif '已领取' in body:
                    state = 'claimed'
            summary['reward'] = {'state': state, 'raw': body}
        if logger == 'OneDragonFlowViewModel' and '一条龙和配置组任务结束' in body:
            summary['flow_ended'] = True
        target = current if current is not None and not is_reward else summary
        error_key = 'errors' if target is current else 'global_errors'
        warning_key = 'warnings' if target is current else 'global_warnings'
        if level in ERROR_LEVELS:
            _add(target[error_key], _compact_error(body))
            if target is current:
                current['state'] = 'failed'
        elif level in WARNING_LEVELS:
            _add(target[warning_key], _compact_warning(body))
        if current is not None and not is_reward:
            for cue, name in NAME_CUES:
                if cue in body and current['name'].startswith('步骤 '):
                    current['name'] = name
                    break
            _record_step_facts(current, body, level, logger)
            if '无需合成浓缩树脂' in body:
                _add(current['notes'], '无需合成浓缩树脂')
            for cue in AMBIGUOUS_REWARDS + ('商店物品售空', '邮件：'):
                if cue in body:
                    _add(current['notes'], body)
                    break
            if (current['name'] == '自动秘境' and logger == 'TaskControl'
                    and level in {'INF', 'INFO'}
                    and body == '体力耗尽或者设置轮次已达标，结束自动秘境'):
                for warning in current['warnings']:
                    if warning['text'] == '树脂不足':
                        # Only warnings preceding this normal stop are covered.
                        warning['expected_count'] = warning['count']
            if logger == 'TaskRunner' and STAGE_END.fullmatch(body):
                current['ended'] = True
                if current['state'] == 'incomplete':
                    current['state'] = 'skipped' if any(note['text'] == '无需合成浓缩树脂' for note in current['notes']) else 'ended'
                current = None
    if not records and result != 'skipped':
        issues.append('没有匹配本次运行的应用日志，无法核对逐步骤结果。')
    progress = status.get('Progress') or {}
    progress_errors = _merge_progress_messages(summary, 'global_errors', 'errors', progress.get('ExecutionErrors') or [], _compact_error)
    progress_warnings = _merge_progress_messages(summary, 'global_warnings', 'warnings', progress.get('ExpectedErrors') or [], _compact_warning)
    if progress:
        summary['legacy_progress'] = {
            'stages_started': progress.get('StagesStarted'),
            'flow_completed': progress.get('Completed'),
            'execution_errors': progress_errors, 'expected_errors': progress_warnings,
            'daily_reward_unclaimed': progress.get('DailyRewardUnclaimed'),
        }
        if progress.get('DailyRewardUnclaimed') is True:
            if not summary['reward']['raw']:
                summary['reward'] = {'state': 'unclaimed', 'raw': 'Progress.DailyRewardUnclaimed=true'}
            elif summary['reward']['state'] == 'claimed':
                issues.append('奖励日志显示已领取，但运行状态仍记录未领取；两来源不一致。')
    steps = summary['steps']
    for step in steps:
        if not step['ended']:
            for warning in step['warnings']:
                warning.pop('expected_count', None)
    if records and not steps:
        issues.append('匹配日志未包含一条龙步骤记录，逐步骤证据不完整。')
    if records and not summary['flow_ended']:
        issues.append('未记录一条龙和配置组任务结束标志。')
    if steps:
        total = steps[0]['total']
        if total < 1 or any(step['total'] != total for step in steps) or [s['index'] for s in steps] != list(range(1, total + 1)):
            issues.append('日志中的步骤序号/总数不完整或不一致。')
        if any(not step['ended'] for step in steps):
            issues.append('存在未记录 TaskRunner 结束标志的步骤。')
    for issue in status.get('BusinessEvidenceIssues') or []:
        if issue not in issues:
            issues.append(issue)
    has_errors = bool(summary['global_errors']) or any(step['errors'] for step in steps)
    has_warnings = bool(summary['global_warnings']) or any(
        warning['count'] > warning.get('expected_count', 0)
        for step in steps for warning in step['warnings'])
    unclear_notes = any(
        ('未完成或者已领取' in note['text'] and not (
            '每日委托' in note['text'] and summary['reward']['state'] == 'claimed'))
        or ('未探索完成或已领取' in note['text'] and '探索派遣' not in note['text'])
        for step in steps for note in step['notes'])
    exit_code = summary['process_exit_code']
    if result in {'failed', 'time-limit', 'skipped'}:
        summary['outcome'] = result
    elif exit_code not in (None, 0, '0'):
        summary['outcome'] = 'failed'
    elif has_errors:
        summary['outcome'] = 'partial'
    elif status.get('BusinessOutcome') == 'incomplete':
        summary['outcome'] = 'incomplete'
    elif not records:
        summary['outcome'] = 'unknown'
    elif issues or has_warnings or unclear_notes or summary['reward']['state'] == 'unclaimed' or status.get('AttentionRequired'):
        summary['outcome'] = 'needs-attention'
    elif steps and summary['flow_ended']:
        summary['outcome'] = 'finished'
    return summary


def _display(item, limit=240):
    text = ' '.join(item['text'].split())
    if len(text) > limit:
        text = text[:limit] + f'…（省略 {len(text) - limit} 字）'
    return text + (f' ×{item["count"]}' if item['count'] > 1 else '')


def _attempt_exit_code(value):
    if value is None:
        return '未记录'
    text = str(value)
    try:
        number = int(value)
        if abs(number) > 255:
            text += f'（0x{number & 0xFFFFFFFF:08X}）'
    except (ValueError, TypeError):
        pass
    return text


def _step_facts_text(step):
    facts = step.get('facts', {})
    details = []
    if facts.get('mail_claim_action'):
        details.append('已执行全部领取')
    if facts.get('teapot_claim_action'):
        details.append('已执行好感和宝钱领取')
    if facts.get('domain'):
        details.append(facts['domain'])
    if facts.get('challenges_completed'):
        details.append(f'通关 {facts["challenges_completed"]} 次')
    if facts.get('reward_claims'):
        details.append(f'领奖 {facts["reward_claims"]} 次')
    for resin, count in facts.get('resin_used', {}).items():
        details.append(f'消耗{resin} {count}')
    expected_resin_stop = any(item['text'] == '树脂不足' and item.get('expected_count')
                              for item in step['warnings'])
    if expected_resin_stop:
        details.append('树脂不足')
        remaining = facts.get('resin_remaining', {})
        if (not facts.get('reward_claims') and remaining.get('original', 20) < 20
                and remaining.get('condensed', 1) == 0):
            details.append('未领奖')
    for note in step['notes']:
        text = note['text']
        if text == '无需合成浓缩树脂':
            details.append('无需合成')
        elif '探索派遣' in text and '未探索完成或已领取' in text:
            details.append('派遣无可领取项')
        elif '每日委托' in text and '未完成或者已领取' in text:
            details.append('已交互')
        elif '商店物品售空' in text:
            details.append('商店物品售空')
        elif '邮件：' not in text:
            details.append(_display(note, limit=100))
    return list(dict.fromkeys(details))


def render_text(summary: dict) -> str:
    """Render concise facts; attribution, lifecycle detail and raw errors stay in JSON."""
    lines = [f'BetterGI｜{OUTCOMES[summary["outcome"]]}']
    start, end = _aware_time(summary.get('started')), _aware_time(summary.get('updated'))
    if start and end:
        finish = end.astimezone(start.tzinfo)
        duration = max(0, int((end - start).total_seconds()))
        lines.append(f'{start:%m/%d %H:%M:%S}–{finish:%H:%M:%S}｜{duration // 60}分{duration % 60}秒')
    attempts = summary.get('attempts', [])
    if len(attempts) > 1 or any(attempt['exit_code'] not in (None, 0, '0') for attempt in attempts):
        parts = []
        for attempt in attempts:
            code = attempt['exit_code']
            outcome = '完成' if attempt['result'] == 'exited' and code in (0, '0') else '失败'
            part = f'第 {attempt["number"]} 次{outcome}'
            if code not in (None, 0, '0'):
                part += f'（{_attempt_exit_code(code)}）'
            parts.append(part)
        lines.append('；'.join(parts))
    if any(attempt['cleanup_succeeded'] is False for attempt in attempts):
        lines.append('分身清理未完成，未重试')
    if not attempts and summary['process_exit_code'] not in (None, 0, '0'):
        lines.append('程序退出：' + _attempt_exit_code(summary['process_exit_code']))
    if summary['lifecycle']['detail'] and not attempts:
        lines.append('运行异常：' + _display({'text': summary['lifecycle']['detail'], 'count': 1}))
    steps = summary['steps']
    shown = sorted(steps, key=lambda step: (not bool(step['errors']), step['index']))[:20]
    for step in sorted(shown, key=lambda item: item['index']):
        details = _step_facts_text(step)
        if step['errors']:
            details.extend('异常：' + _display(item, limit=160) for item in step['errors'][:2])
        warnings = [{**item, 'count': item['count'] - item.get('expected_count', 0)}
                    for item in step['warnings'] if item['count'] > item.get('expected_count', 0)]
        details.extend('警告：' + _display(item, limit=140) for item in warnings[:2])
        if not step['ended']:
            details.insert(0, '未完成')
        if not details:
            details.append({'ended': '已结束', 'skipped': '跳过', 'failed': '异常'}.get(step['state'], '未完成'))
        lines.append(step['name'] + '：' + '；'.join(details))
        if items := step.get('facts', {}).get('reward_items'):
            lines.append('奖励：' + '、'.join(f'{name} ×{count}' for name, count in list(items.items())[:8]))
    lines.append('每日奖励：' + REWARDS[summary['reward']['state']])
    for item in summary['global_errors'][:5]:
        lines.append('异常：' + _display(item))
    for item in summary['global_warnings'][:3]:
        if not item['text'].startswith('检查每日奖励结果'):
            lines.append('警告：' + _display(item, limit=160))
    if summary['evidence_issues']:
        labels = []
        for issue in summary['evidence_issues']:
            if '多个 T' in issue or '不一致' in issue:
                labels.append('运行记录不一致')
            elif '结束' in issue:
                labels.append('结束记录缺失')
            elif '步骤' in issue:
                labels.append('步骤记录不完整')
            else:
                labels.append('运行记录不完整')
        lines.append('记录：' + '；'.join(dict.fromkeys(labels)))
    return '\n'.join(lines) + '\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--status', required=True, type=Path)
    parser.add_argument('--log', action='append', default=[], type=Path)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--json-output', type=Path)
    args = parser.parse_args()
    try:
        status = json.loads(args.status.read_text(encoding='utf-8-sig'))
        if not isinstance(status, dict):
            parser.error('--status must contain a JSON object')
        report = summarize(status, [(str(path), path.read_text(encoding='utf-8-sig')) for path in args.log])
        rendered = render_text(report)
        if args.output:
            args.output.write_text(rendered, encoding='utf-8')
        else:
            print(rendered, end='')
        if args.json_output:
            args.json_output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    except (OSError, ValueError, UnicodeError) as error:
        parser.exit(2, f'报告生成失败：{error}\n')


if __name__ == '__main__':
    main()
