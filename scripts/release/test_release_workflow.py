"""Exercise the release workflow's actual gating expression and note script."""
import itertools
import json
import os
import re
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / '.github/workflows/release.yml'


def job(text, name):
    return re.search(rf'^  {name}:\n(.*?)(?=^  \w[\w-]*:\n|\Z)', text, re.M | re.S).group(1)


class ReleaseWorkflowTests(unittest.TestCase):
    def test_components_have_one_retry_and_an_explicit_emergency_opt_out(self):
        workflow = WORKFLOW.read_text()
        self.assertRegex(workflow, r'emergency:\n(?:.*\n){1,4}?        type: boolean')
        self.assertIn("if: ${{ !inputs.emergency }}", job(workflow, 'components'))
        self.assertIn('--retry=1', (ROOT / '.github/workflows/components.yml').read_text())


    def test_draft_gates_all_required_jobs_including_skipped_component_cases(self):
        publish = job(WORKFLOW.read_text(), 'publish')
        dependencies = re.search(r'^    needs: \[([^]]+)\]', publish, re.M).group(1).split(', ')
        self.assertEqual(set(dependencies), {'gate', 'ci', 'components', 'macos', 'windows'})
        match = re.search(r'^    if: \$\{\{ (.+) \}\}', publish, re.M)
        self.assertIsNotNone(match, 'draft needs an explicit condition for emergency skipped components')
        expression = match.group(1)
        for statuses in itertools.product(['success', 'failure', 'skipped', 'cancelled'], repeat=5):
            results = dict(zip(dependencies, statuses))
            for emergency, cancelled in itertools.product([False, True], repeat=2):
                condition = expression.replace('!cancelled()', str(not cancelled))
                condition = condition.replace('inputs.emergency', str(emergency))
                condition = re.sub(r'needs\.(\w+)\.result', lambda m: repr(results[m[1]]), condition)
                condition = condition.replace('&&', ' and ').replace('||', ' or ')
                actual = eval(condition, {'__builtins__': {}}, {})
                expected = not cancelled and all(results[n] == 'success' for n in dependencies if n != 'components') and (
                    results['components'] == 'success' or (emergency and results['components'] == 'skipped'))
                self.assertEqual(actual, expected, (results, emergency, cancelled))


    def test_emergency_component_bypass_is_visible_in_created_release_notes(self):
        workflow = WORKFLOW.read_text()
        publish = job(workflow, 'publish')
        self.assertIn('EMERGENCY_SKIP_COMPONENTS: ${{ inputs.emergency }}', publish)
        step = publish.split('      - name: Create the draft release\n', 1)[1]
        script = textwrap.dedent(step.split('        run: |\n', 1)[1])
        for emergency in ['true', 'false', '']:
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / 'dist').mkdir()
                gh = root / 'gh'
                gh.write_text('#!/bin/sh\ncase "$1 $2" in\n"release view") exit 1;;\n"release list"|"release create") exit 0;;\n*) exit 2;;\nesac\n')
                gh.chmod(0o755)
                result = subprocess.run(['bash', '-euo', 'pipefail', '-c', script], cwd=root,
                    env=dict(os.environ, PATH=f'{root}:{os.environ["PATH"]}', RUNNER_TEMP=directory,
                             TAG='v1.2.3', VERSION='1.2.3', GITHUB_REPOSITORY='example/repo',
                             SIGNPATH_ENABLED='false', EMERGENCY_SKIP_COMPONENTS=emergency), capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                notes = (root / 'notes.md').read_text()
                self.assertEqual('EMERGENCY: Component tests were skipped' in notes, emergency == 'true')



if __name__ == '__main__':
    unittest.main()
