"""Check concise facts against attributed native execution records."""
import unittest

from test_compact_bettergi_log import FLOW_LOGGER, attempt, record, status
from compact_bettergi_log import render_text, summarize

TASK = 'BetterGenshinImpact.GameTask.Common.TaskControl'


def report(events):
    text = record('00:12:10.000', '一条龙任务执行: 1/1', logger=FLOW_LOGGER)
    text += record('00:12:11.000', '自动秘境任务：执行', logger=TASK)
    for index, event in enumerate(events, 12):
        body, level, pid = event if isinstance(event, tuple) else (event, 'INF', 202)
        text += record(f'00:12:{index:02}.000', body, logger=TASK, level=level, pid=pid)
    text += record('00:12:55.000', '→ "任务结束"')
    text += record('00:12:56.000', '检查每日奖励结果：今日奖励已领取', logger=TASK)
    text += record('00:12:57.000', '一条龙和配置组任务结束', logger=FLOW_LOGGER)
    return summarize(status([attempt(2)]), [('better-genshin-impact20261031.log', text)])


class ConciseReportTests(unittest.TestCase):
    def test_challenge_completed_before_resin_stop_is_not_reported_as_skipped(self):
        value = report([
            '提升指南选择秘境："荒坠的圣迹"',
            '检测到秘境结束提示(挑战达成)，结束秘境',
            '原粹树脂：16，浓缩树脂：0',
            ('树脂不足', 'WRN', 202),
            '体力耗尽或者设置轮次已达标，结束自动秘境',
        ])
        text = render_text(value)
        self.assertEqual(value['outcome'], 'finished')
        self.assertIn('通关 1 次', text)
        self.assertIn('树脂不足；未领奖', text)
        for phrase in ['退出码', '分身清理', '证据限制', '不能证明', '无法说明', '以下步骤结果']:
            self.assertNotIn(phrase, text)

    def test_rewards_and_resin_are_counted_once_per_confirmed_result(self):
        value = report([
            '检测到秘境结束提示(挑战达成)，结束秘境',
            '"自动秘境"：使用 "原粹树脂", 数量：20',
            '奖励识别：卡片数量 4',
            '奖励识别：卡片数量 4',
            '自动秘境：本轮奖励识别结果 "摩拉 x3375, 「坚忍」的指引 x2"',
            '检测到秘境结束提示(挑战达成)，结束秘境',
            '"自动秘境"：使用 "原粹树脂", 数量：20',
            '自动秘境：本轮奖励识别结果 "摩拉 x3375, 「坚忍」的指引 x2"',
        ])
        facts = value['steps'][0]['facts']
        self.assertEqual(facts['challenges_completed'], 2)
        self.assertEqual(facts['reward_claims'], 2)
        self.assertEqual(facts['resin_used'], {'原粹树脂': 40})
        self.assertEqual(facts['reward_items'], {'摩拉': 6750, '「坚忍」的指引': 4})
        self.assertIn('领奖 2 次；消耗原粹树脂 40', render_text(value))

    def test_resin_action_without_reward_result_does_not_claim_consumption(self):
        value = report(['"自动秘境"：使用 "原粹树脂", 数量：20'])
        text = render_text(value)
        self.assertNotIn('消耗原粹树脂', text)
        self.assertNotIn('领奖', text)
        self.assertNotIn('resin_used', value['steps'][0]['facts'])

    def test_foreign_process_reward_does_not_enter_factual_totals(self):
        value = report([
            ('自动秘境：本轮奖励识别结果 "摩拉 x999999"', 'INF', 999),
            '自动秘境：本轮奖励识别结果 "摩拉 x3375"',
        ])
        self.assertEqual(value['steps'][0]['facts']['reward_items'], {'摩拉': 3375})
        self.assertNotIn('999999', render_text(value))


if __name__ == '__main__':
    unittest.main()
