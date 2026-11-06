import copy
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Automation'))
import compact_bettergi_log as compact
import evaluate_bettergi_result as evaluator
from one_dragon_recovery import plan_recovery
from test_compact_bettergi_log import FLOW_LOGGER, attempt, record, status


NAMES = ['领取邮件', '合成树脂', '自动秘境', '领取每日奖励', '领取尘歌壶奖励']
IDS = ['mail', 'craft', 'domain', 'guild', 'teapot']
PROFILE = {'Name': 'Fixture', 'TaskOrder': IDS, 'TaskDefinitions': dict(zip(IDS, NAMES)),
           'TaskEnabledList': dict.fromkeys(IDS, True)}
CUES = ['邮件：全部领取', '前往合成台', '自动秘境任务：执行',
        '前往冒险家协会领取奖励', '领取尘歌壶奖励']


def flow(number, ids, *, failed=False, identity=True, claimed=True):
    text = ''
    for index, task_id in enumerate(ids, 1):
        minute, second = 10 + number, index * 5
        def add(body, logger=FLOW_LOGGER, level='INF'):
            return record(f'00:{minute:02}:{second:02}.000', body, pid=200 + number,
                          session=number + 1, logger=logger, level=level)
        text += add(f'一条龙任务执行: {index}/{len(ids)}')
        if identity:
            text += add(f'OneDragon task identity: "{task_id}" / "{NAMES[IDS.index(task_id)]}"')
        text += add(CUES[IDS.index(task_id)], logger='BetterGenshinImpact.GameTask.Common.TaskControl')
        if task_id == 'domain':
            text += add('自动秘境：本轮奖励识别结果 "摩拉 x100"', logger='BetterGenshinImpact.GameTask.Common.TaskControl')
        if failed and task_id in ('guild', 'teapot'):
            text += add('点击传送点后未出现交互面板', level='ERR', logger='BetterGenshinImpact.GameTask.TaskRunner')
        text += add('→ "任务结束"', logger='BetterGenshinImpact.GameTask.TaskRunner')
        if identity:
            text += add(f'OneDragon task finished: "{task_id}"')
    text += record(f'00:{10+number:02}:40.000', '检查每日奖励结果：' + ('已领取' if claimed else '未领取'),
                   pid=200+number, session=number+1)
    text += record(f'00:{10+number:02}:41.000', '一条龙和配置组任务结束',
                   pid=200+number, session=number+1, logger=FLOW_LOGGER)
    return [('better-genshin-impact20261031.log', text)]


class RecoveryTests(unittest.TestCase):
    def test_native_and_legacy_navigation_failures_only_retry_unfinished_tasks(self):
        for identity in (True, False):
            with self.subTest(identity=identity):
                s = status([attempt(1)])
                result = evaluator.evaluate(s, flow(1, IDS, failed=True, identity=identity, claimed=False), PROFILE)
                self.assertEqual(result['ExitCode'], 2)
                self.assertTrue(result['RecoverySafe'])
                self.assertTrue(result['RecoveryRequired'])
                self.assertEqual(result['CompletedTaskIds'], IDS[:3])
                self.assertEqual(result['RetryTaskIds'], IDS[3:])

    def test_identity_mismatch_and_missing_profile_order_block_selective_recovery(self):
        s = status([attempt(1)])
        logs = flow(1, IDS, failed=True)
        altered = copy.deepcopy(PROFILE)
        altered['TaskOrder'] = list(reversed(IDS))
        self.assertFalse(evaluator.evaluate(s, logs, altered)['RecoverySafe'])
        altered['TaskOrder'] = IDS[:-1]
        self.assertFalse(evaluator.evaluate(s, logs, altered)['RecoverySafe'])

    def test_warnings_and_successful_tasks_do_not_request_recovery(self):
        s = status([attempt(1)])
        logs = flow(1, IDS)
        result = evaluator.evaluate(s, logs, PROFILE)
        self.assertFalse(result['RecoveryRequired'])
        self.assertEqual(result['RetryTaskIds'], [])

    def test_selective_report_retains_domain_once_and_replaces_failed_reward_tasks(self):
        first, second = attempt(1), attempt(2)
        first.update(TaskIds=IDS, ExitCode=2, ProcessExitCode=0, Result='failed')
        second.update(TaskIds=IDS[3:], ProcessExitCode=0)
        s = status([first, second])
        s.update(TaskIds=IDS, SelectiveRecovery=True, ProcessExitCode=0)
        logs = [('better-genshin-impact20261031.log',
                 flow(1, IDS, failed=True, claimed=False)[0][1] + flow(2, IDS[3:])[0][1])]
        result = evaluator.evaluate(s, logs)
        report = compact.summarize({**s, **result}, logs)
        self.assertEqual(result['ExitCode'], 0)
        self.assertEqual(report['outcome'], 'finished')
        self.assertEqual(len(report['steps']), 5)
        self.assertEqual(report['steps'][2]['facts']['reward_claims'], 1)
        self.assertFalse(any(step['errors'] for step in report['steps']))
        self.assertIn('第 1 次失败', compact.render_text(report))

    def test_failed_recovery_keeps_second_failure_and_original_success(self):
        first, second = attempt(1), attempt(2)
        first.update(TaskIds=IDS, ExitCode=2, ProcessExitCode=0, Result='failed')
        second.update(TaskIds=IDS[3:], ProcessExitCode=0)
        s = status([first, second])
        s.update(TaskIds=IDS, SelectiveRecovery=True, ProcessExitCode=0)
        logs = [('better-genshin-impact20261031.log',
                 flow(1, IDS, failed=True, claimed=False)[0][1] + flow(2, IDS[3:], failed=True, claimed=False)[0][1])]
        result = evaluator.evaluate(s, logs)
        self.assertEqual(result['ExitCode'], 2)
        self.assertEqual(result['BusinessOutcome'], 'partial')


if __name__ == '__main__':
    unittest.main()
