"""Offline task-result regression tests using captured native game messages."""

import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

AUTOMATION = Path(__file__).resolve().parents[1] / 'Automation'
sys.path.insert(0, str(AUTOMATION))
import compact_bettergi_log as compact
import evaluate_bettergi_result as evaluator

FIXTURES = Path(__file__).parent / 'fixtures' / 'business-outcome'


def captured_run(day):
    status = json.loads((FIXTURES / f'{day}-status.json').read_text(encoding='utf-8'))
    path = FIXTURES / f'better-genshin-impact{day}.log'
    return status, [(str(path), path.read_text(encoding='utf-8'))]


class EvaluateResultTests(unittest.TestCase):
    def test_native_business_failures_do_not_pass_the_scheduled_task(self):
        for day, expected_error in [('20200102', '提升指南秘境名称识别'),
                                    ('20200103', '传送失败')]:
            with self.subTest(day=day):
                status, logs = captured_run(day)
                self.assertEqual(status['ExitCode'], 0)
                before = copy.deepcopy(status)
                result = evaluator.evaluate(status, logs)
                self.assertEqual(result['ProcessExitCode'], 0)
                self.assertEqual(result['BusinessOutcome'], 'partial')
                self.assertEqual(result['ExitCode'], 2)
                self.assertEqual(status, before)
                report = compact.summarize({**status, **result}, logs)
                self.assertEqual(report['outcome'], 'partial')
                self.assertIn(expected_error, compact.render_text(report))
                self.assertEqual(report['exit_code'], 2)
                self.assertEqual(report['process_exit_code'], 0)

    def test_warnings_and_sold_out_items_keep_zero_exit(self):
        status, logs = captured_run('20200101')
        self.assertIn('商店物品售空', logs[0][1])
        result = evaluator.evaluate(status, logs)
        self.assertEqual(result['BusinessOutcome'], 'needs-attention')
        self.assertEqual(result['ExitCode'], 0)
        self.assertFalse(result['BusinessEvidenceIssues'])

    def test_missing_or_incomplete_evidence_is_separate_from_business_failure(self):
        status, logs = captured_run('20200101')
        for evidence in [[], [(logs[0][0], logs[0][1].replace('一条龙和配置组任务结束', 'omitted end marker'))]]:
            with self.subTest(evidence=bool(evidence)):
                result = evaluator.evaluate(status, evidence)
                self.assertEqual(result['BusinessOutcome'], 'incomplete')
                self.assertEqual(result['ExitCode'], 3)
                self.assertTrue(result['BusinessEvidenceIssues'])

    def test_crash_and_cleanup_errors_keep_lifecycle_exit_and_business_evidence(self):
        status, logs = captured_run('20200102')
        status.update(Result='failed', ExitCode=-1073741819, ProcessExitCode=-1073741819)
        result = evaluator.evaluate(status, logs)
        self.assertEqual(result['ProcessExitCode'], -1073741819)
        self.assertEqual(result['ExitCode'], -1073741819)
        self.assertEqual(result['BusinessOutcome'], 'partial')
        status, logs = captured_run('20200101')
        status.update(Result='failed', ExitCode=1, ProcessExitCode=0)
        result = evaluator.evaluate(status, logs)
        self.assertEqual(result['ExitCode'], 1)
        self.assertEqual(result['ProcessExitCode'], 0)
        self.assertEqual(result['BusinessOutcome'], 'needs-attention')

    def test_cli_evaluates_without_publishing_or_changing_status(self):
        status, logs = captured_run('20200102')
        with tempfile.TemporaryDirectory() as directory:
            install = Path(directory)
            run = install / 'log' / 'one-dragon-runs' / status['RunId']
            run.mkdir(parents=True)
            source = json.dumps(status)
            (run / 'status.json').write_text(source, encoding='utf-8')
            (install / 'log' / Path(logs[0][0]).name).write_text(logs[0][1], encoding='utf-8')
            output = subprocess.run([sys.executable, str(AUTOMATION / 'evaluate_bettergi_result.py'),
                                     '--run-dir', str(run), '--install-dir', str(install)],
                                    capture_output=True, text=True, check=True)
            result = json.loads(output.stdout)
            self.assertEqual(result['ExitCode'], 2)
            self.assertEqual((run / 'status.json').read_text(encoding='utf-8'), source)
            self.assertFalse((run / 'report').exists())


if __name__ == '__main__':
    unittest.main()
