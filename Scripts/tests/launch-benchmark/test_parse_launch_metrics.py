import importlib.util
import json
import pathlib
import subprocess
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[3]
PARSER = ROOT / "Benchmarks" / "parse-launch-metrics.py"
FIXTURES = pathlib.Path(__file__).resolve().parent / "fixtures"

spec = importlib.util.spec_from_file_location("parse_launch_metrics", PARSER)
plm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(plm)


def read(*parts):
    return FIXTURES.joinpath(*parts).read_text()


class ParseTests(unittest.TestCase):
    def test_first_occurrence_of_each_milestone_wins(self):
        found = plm.parse(read("good", "trial-1.log"))
        self.assertEqual(found["first-frame"], 300, "a repeated milestone must not rewrite the timeline")
        self.assertEqual(found["idle"], 800)
        self.assertEqual(found["process-start"], 0)

    def test_other_processes_and_subsystems_are_ignored_by_pid(self):
        text = read("good", "trial-1.log")
        self.assertEqual(plm.parse(text, pid=4101)["first-frame"], 300)
        self.assertEqual(plm.parse(text, pid=777)["first-frame"], 1)
        self.assertEqual(plm.parse(text, pid=1), {})

    def test_unknown_milestones_and_noise_are_ignored(self):
        text = "garbage\n[1:2] launch teleport t+5ms\nBrowsemium[9:a] [x:y] launch idle t+12ms\nlaunch idle t+3ms\n"
        self.assertEqual(plm.parse(text), {"idle": 12})

    def test_empty_input(self):
        self.assertEqual(plm.parse(""), {})


class StatisticsTests(unittest.TestCase):
    def test_median_odd_and_even(self):
        self.assertEqual(plm.median([5, 1, 3]), 3.0)
        self.assertEqual(plm.median([4, 1, 3, 2]), 2.5)
        self.assertEqual(plm.median([7]), 7.0)

    def test_p90_is_nearest_rank(self):
        ten = list(range(100, 1100, 100))
        self.assertEqual(plm.percentile(ten, 0.9), 900, "with ten trials, p90 is the ninth value")
        self.assertEqual(plm.percentile([5], 0.9), 5)
        self.assertEqual(plm.percentile([3, 1, 2], 0.9), 3)
        self.assertEqual(plm.percentile(list(range(1, 21)), 0.9), 18)


class SummaryTests(unittest.TestCase):
    def trials(self, name):
        return [plm.parse(read(name, f"trial-{n}.log"), pid=None) for n in (1, 2, 3)]

    def test_a_complete_run_reports_median_and_p90(self):
        good = [{"first-frame": 300, "idle": 800}, {"first-frame": 340, "idle": 900}, {"first-frame": 280, "idle": 700}]
        result = plm.summarize(good)
        self.assertEqual(result["status"], "ok")
        self.assertEqual(result["trials_valid"], 3)
        self.assertEqual(result["milestones"]["first-frame"]["median_ms"], 300)
        self.assertEqual(result["milestones"]["first-frame"]["p90_ms"], 340)
        self.assertEqual(result["milestones"]["idle"]["median_ms"], 800)
        self.assertIn("first-frame median 300 ms, p90 340 ms", plm.summary_line(result))

    def test_one_trial_without_idle_invalidates_the_run_and_reports_no_numbers(self):
        trials = [{"first-frame": 300, "idle": 800}, {"first-frame": 310, "idle": 850}, {"first-frame": 280}]
        result = plm.summarize(trials)
        self.assertEqual(result["status"], "invalid")
        self.assertEqual(result["milestones"], {})
        self.assertIn("INVALID", plm.summary_line(result))
        self.assertIn("do not publish", plm.summary_line(result))

    def test_fewer_logs_than_requested_is_invalid(self):
        result = plm.summarize([{"first-frame": 1, "idle": 2}], expected=10)
        self.assertEqual(result["status"], "invalid")
        self.assertEqual(result["trials_requested"], 10)

    def test_no_trials_is_invalid(self):
        self.assertEqual(plm.summarize([])["status"], "invalid")


class CommandLineTests(unittest.TestCase):
    def run_cli(self, *args):
        return subprocess.run([sys.executable, str(PARSER), *args], capture_output=True, text=True)

    def test_good_fixture_exits_zero_with_json_and_a_summary_line(self):
        logs = sorted(str(p) for p in (FIXTURES / "good").glob("trial-*.log"))
        done = self.run_cli(*logs, "--pid", "4101", "--pid", "4102", "--pid", "4103")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(json.loads(done.stdout)["status"], "ok")
        self.assertIn("launch: first-frame median 300 ms", done.stderr)

    def test_incomplete_fixture_exits_four(self):
        logs = sorted(str(p) for p in (FIXTURES / "incomplete").glob("trial-*.log"))
        done = self.run_cli(*logs, "--pid", "4201", "--pid", "4202", "--pid", "4103")
        self.assertEqual(done.returncode, 4)
        self.assertEqual(json.loads(done.stdout)["status"], "invalid")

    def test_has_reports_whether_a_milestone_was_reached(self):
        complete = str(FIXTURES / "good" / "trial-1.log")
        partial = str(FIXTURES / "incomplete" / "trial-3.log")
        self.assertEqual(self.run_cli("--has", "idle", "--pid", "4101", complete).returncode, 0)
        self.assertEqual(self.run_cli("--has", "idle", "--pid", "4103", partial).returncode, 1)
        self.assertEqual(self.run_cli("--has", "idle", "--pid", "1", complete).returncode, 1)

    def test_mismatched_pid_count_is_a_usage_error(self):
        done = self.run_cli(str(FIXTURES / "good" / "trial-1.log"), str(FIXTURES / "good" / "trial-2.log"), "--pid", "1")
        self.assertEqual(done.returncode, 2)


if __name__ == "__main__":
    unittest.main()
