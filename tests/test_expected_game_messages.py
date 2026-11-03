"""Keep completed resource/reward branches distinct from actionable warnings."""

import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Automation'))
from compact_bettergi_log import render_text, summarize
from evaluate_bettergi_result import evaluate

FIXTURES = Path(__file__).parent / 'fixtures' / 'completed-branches'
RESIN_END = '体力耗尽或者设置轮次已达标，结束自动秘境'


def captured(name):
    value = json.loads((FIXTURES / f'{name}.json').read_text(encoding='utf-8'))
    return value['status'], [('better-genshin-impact20200103.log', value['native_log'])]


class ExpectedGameMessagesTests(unittest.TestCase):
    def test_completed_native_run_keeps_warning_evidence_as_expected(self):
        status, logs = captured('navigation')
        result = evaluate(status, logs)
        self.assertEqual((result['BusinessOutcome'], result['ExitCode']), ('finished', 0))
        report = summarize(status, logs)
        self.assertEqual(report['outcome'], 'finished')
        warning = report['steps'][2]['warnings'][0]
        self.assertEqual((warning['text'], warning['count'], warning['expected_count']), ('树脂不足', 1, 1))
        text = render_text(report)
        self.assertIn('提示：树脂不足', text)
        self.assertIn('未完成或者已领取', text)
        self.assertIn('未探索完成或已领取', text)

    def test_native_navigation_failure_and_cooldown_warnings_stay_actionable(self):
        for name, outcome, exit_code in [('cooldown', 'partial', 2), ('original', 'needs-attention', 0)]:
            with self.subTest(name=name):
                status, logs = captured(name)
                result = evaluate(status, logs)
                self.assertEqual((result['BusinessOutcome'], result['ExitCode']), (outcome, exit_code))

    def test_resin_exception_requires_ordered_domain_evidence_and_step_end(self):
        status, _ = captured('navigation')
        def record(second, body, level='INF', logger='TaskControl'):
            return (f'[13:31:{second:02}.000] [{level}] [Primary:S31:P2201:T1234] '
                    f'BetterGenshinImpact.GameTask.{logger}\n{body}\n\n')
        for name, events, domain, ended in [
            ('missing-marker', [('树脂不足', 'WRN')], True, True),
            ('marker-before-warning', [(RESIN_END, 'INF'), ('树脂不足', 'WRN')], True, True),
            ('late-warning', [('树脂不足', 'WRN'), (RESIN_END, 'INF'), ('树脂不足', 'WRN')], True, True),
            ('other-stage', [('树脂不足', 'WRN'), (RESIN_END, 'INF')], False, True),
            ('missing-step-end', [('树脂不足', 'WRN'), (RESIN_END, 'INF')], True, False),
            ('other-warning', [('树脂不足', 'WRN'), (RESIN_END, 'INF'), ('OTHER_WARNING', 'WRN')], True, True),
        ]:
            with self.subTest(name=name):
                text = record(0, '一条龙任务执行: 1/1', logger='OneDragonFlowViewModel')
                text += record(1, '自动秘境任务：执行' if domain else '邮件：全部领取')
                text += ''.join(record(index, body, level) for index, (body, level) in enumerate(events, 2))
                if ended:
                    text += record(10, '→ "任务结束"', logger='TaskRunner')
                text += record(11, '检查每日奖励结果：今日奖励已领取')
                text += record(12, '一条龙和配置组任务结束', logger='OneDragonFlowViewModel')
                report = summarize(status, [('better-genshin-impact20200103.log', text)])
                self.assertEqual(report['outcome'], 'needs-attention')
                self.assertTrue(any(w['count'] > w.get('expected_count', 0) for w in report['steps'][0]['warnings']))

    def test_daily_reward_ambiguity_requires_final_claimed_evidence(self):
        status, logs = captured('navigation')
        filename, text = logs[0]
        unknown = text.replace('今日奖励已领取', '今日奖励状态未知')
        self.assertEqual(summarize(status, [(filename, unknown)])['outcome'], 'needs-attention')
        exploration_only = unknown.replace('▶ "领取『每日委托』奖励" 未完成或者已领取', 'No daily commission branch')
        self.assertEqual(summarize(status, [(filename, exploration_only)])['outcome'], 'finished')


if __name__ == '__main__':
    unittest.main()
