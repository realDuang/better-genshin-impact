import copy
from pathlib import Path
import sys
import unittest


sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Automation'))
from compact_bettergi_log import extract_run_log, render_text, summarize


FLOW_LOGGER = 'BetterGenshinImpact.ViewModel.Pages.OneDragonFlowViewModel'


def record(time, body, *, pid=202, session=3, instance=2002, level='INF', logger='BetterGenshinImpact.GameTask.TaskRunner'):
    return f'[{time}] [{level}] [ChildSession:S{session}:P{pid}:T{instance}] {logger}\n{body}\n\n'


def attempt(number, *, failed=False, cleanup=True):
    return {
        'Number': number,
        'Started': f'2026-10-31T00:{10 + number:02}:00+08:00',
        'Updated': f'2026-10-31T00:{10 + number:02}:59+08:00',
        'ChildSession': number + 1, 'BetterGiPid': 200 + number,
        'ExitCode': -1073741819 if failed else 0,
        'Result': 'failed' if failed else 'exited',
        'Detail': 'BetterGI exited with code -1073741819.' if failed else '',
        'CleanupSucceeded': cleanup,
    }


def status(attempts):
    final = attempts[-1]
    return {
        'RunId': '20261031-001000', 'Started': '2026-10-31T00:10:00+08:00',
        'Updated': final['Updated'], 'Phase': 'finished',
        'Result': final['Result'], 'ExitCode': final['ExitCode'],
        'Detail': final['Detail'], 'ChildSession': final['ChildSession'],
        'BetterGiPid': final['BetterGiPid'],
        'AttemptCount': len(attempts), 'Attempts': attempts,
    }


def recovered_log(*, warning=False):
    text = record('00:11:15.000', 'FIRST_ATTEMPT_FAILURE', pid=201, session=2, instance=2001, level='ERR')
    text += record('00:12:10.000', '一条龙任务执行: 1/1', logger=FLOW_LOGGER)
    text += record('00:12:12.000', '邮件：全部领取')
    if warning:
        text += record('00:12:13.000', 'FINAL_ATTEMPT_WARNING', level='WRN')
    text += record('00:12:14.000', '→ "任务结束"')
    text += record('00:12:16.000', '检查每日奖励结果：今日奖励已领取')
    text += record('00:12:18.000', '一条龙和配置组任务结束', logger=FLOW_LOGGER)
    return [('better-genshin-impact20261031.log', text)]


class RetryReportTests(unittest.TestCase):
    def test_recovered_run_keeps_first_crash_without_failing_final_result(self):
        report = summarize(status([attempt(1, failed=True), attempt(2)]), recovered_log())
        self.assertEqual(report['outcome'], 'finished')
        self.assertEqual(report['attempt_count'], 2)
        self.assertEqual(report['attempts'][0]['exit_code'], -1073741819)
        self.assertEqual(report['attempts'][1]['result'], 'exited')
        self.assertFalse(report['global_errors'])
        text = render_text(report)
        self.assertIn('第 1 次', text)
        self.assertIn('第 2 次', text)
        self.assertIn('0xC0000005', text)
        self.assertIn('第 2 次完成', text)

    def test_recovered_run_still_reports_final_attempt_business_warnings(self):
        report = summarize(status([attempt(1, failed=True), attempt(2)]), recovered_log(warning=True))
        self.assertEqual(report['outcome'], 'needs-attention')
        self.assertIn('FINAL_ATTEMPT_WARNING', render_text(report))
        self.assertNotIn('FIRST_ATTEMPT_FAILURE', render_text(report))

    def test_two_failures_remain_failed_and_show_both_attempts(self):
        report = summarize(status([attempt(1, failed=True), attempt(2, failed=True)]), [])
        self.assertEqual(report['outcome'], 'failed')
        self.assertEqual(len(report['attempts']), 2)
        text = render_text(report)
        self.assertIn('第 1 次', text)
        self.assertIn('第 2 次', text)
        self.assertEqual(text.count('0xC0000005'), 2)

    def test_cleanup_failure_explains_why_no_second_attempt_ran(self):
        stopped = attempt(1, failed=True, cleanup=False)
        stopped['Detail'] = 'The child desktop did not finish cleanup.'
        report = summarize(status([stopped]), [])
        self.assertEqual(report['outcome'], 'failed')
        self.assertFalse(report['attempts'][0]['cleanup_succeeded'])
        text = render_text(report)
        self.assertIn('分身清理未完成，未重试', text)
        self.assertNotIn('第 2 次', text)

    def test_attempt_window_excludes_reused_pid_records_from_before_retry(self):
        s = status([attempt(1, failed=True), attempt(2)])
        name, text = recovered_log()[0]
        text = record('00:11:05.000', 'EARLIER_PID_INCARNATION', instance=9999, level='ERR') + text
        report = summarize(s, [(name, text)])
        self.assertEqual(report['outcome'], 'finished')
        self.assertNotIn('EARLIER_PID_INCARNATION', str(report))

    def test_attachment_keeps_both_attempt_logs_but_excludes_foreign_records(self):
        s = status([attempt(1, failed=True), attempt(2)])
        name, text = recovered_log()[0]
        text += record('00:12:20.000', 'FOREIGN_PROCESS', pid=999)
        selected = extract_run_log(s, [(name, text)])
        self.assertIn('FIRST_ATTEMPT_FAILURE', selected)
        self.assertIn('一条龙和配置组任务结束', selected)
        self.assertNotIn('FOREIGN_PROCESS', selected)

    def test_old_schema_render_and_summary_remain_unchanged(self):
        old = status([attempt(2)])
        del old['Attempts'], old['AttemptCount']
        old['Started'] = '2026-10-31T00:12:00+08:00'
        report = summarize(old, recovered_log())
        self.assertEqual(report['outcome'], 'finished')
        self.assertNotIn('attempts', report)
        self.assertNotIn('attempt_count', report)
        self.assertNotIn('尝试', render_text(report))
        empty_history = copy.deepcopy(old)
        empty_history['Attempts'] = []
        self.assertEqual(summarize(empty_history, recovered_log()), report)


if __name__ == '__main__':
    unittest.main()
