"""Select unfinished profile tasks using attributed native step evidence."""

ALIASES = {
    '领取邮件': '邮件', '合成树脂': '合成浓缩树脂',
    '领取每日奖励': '冒险家协会', '领取尘歌壶奖励': '尘歌壶',
}
NAVIGATION_FAILURES = (
    '点击传送点后未出现交互面板', '传送至尘歌壶失败',
    '切换区域失败', '切换区域[', '单次传送超过',
)


def enabled_task_ids(profile):
    order = profile.get('TaskOrder') or []
    enabled = profile.get('TaskEnabledList') or {}
    definitions = profile.get('TaskDefinitions') or {}
    if len(order) != len(set(order)) or any(key not in order for key, value in enabled.items() if value):
        raise ValueError('The profile task order is incomplete or duplicated.')
    next_id = profile.get('NextTaskId')
    if next_id in order:
        order = order[order.index(next_id):]
    ids = [key for key in order if enabled.get(key) is True]
    if not ids or any(not definitions.get(key) for key in ids):
        raise ValueError('Enabled task definitions are missing.')
    return ids


def navigation_failed(step):
    return any(cue in message['text'] for kind in ('errors', 'warnings')
               for message in step[kind] for cue in NAVIGATION_FAILURES)


def plan_recovery(profile, summary):
    """Skip completed tasks; never infer a task ID from an ambiguous sequence."""
    result = {'CompletedTaskIds': [], 'RetryTaskIds': [], 'RecoveryRequired': False,
              'RecoverySafe': False, 'RecoveryIssues': []}
    try:
        ids = enabled_task_ids(profile)
        steps = summary['steps']
        if not steps or any('多个 T 实例' in issue for issue in summary['evidence_issues']):
            raise ValueError('No unambiguous native task sequence was recorded.')
        if [step['index'] for step in steps] != list(range(1, len(steps) + 1)):
            raise ValueError('The native task sequence is not a contiguous prefix.')
        completed = []
        navigation_failure = False
        for index, step in enumerate(steps):
            if index >= len(ids) or step['total'] != len(ids):
                raise ValueError('Native task totals do not match the selected profile.')
            task_id = ids[index]
            definition = profile['TaskDefinitions'][task_id]
            if step.get('task_id'):
                if step['task_id'] != task_id or step.get('task_definition') != definition:
                    raise ValueError('Native task identity does not match the selected profile.')
            elif step['name'] != ALIASES.get(definition, definition):
                raise ValueError('Legacy task names do not match the selected profile.')
            failed_navigation = navigation_failed(step)
            navigation_failure |= failed_navigation
            daily_unclaimed = definition == '领取每日奖励' and summary['reward']['state'] == 'unclaimed'
            if step['ended'] and not step['errors'] and not failed_navigation and not daily_unclaimed:
                completed.append(task_id)
        result.update(CompletedTaskIds=completed,
                      RetryTaskIds=[key for key in ids if key not in completed],
                      RecoverySafe=True)
        result['RecoveryRequired'] = navigation_failure and bool(result['RetryTaskIds'])
    except (KeyError, TypeError, ValueError) as error:
        result['RecoveryIssues'].append(str(error))
    return result
