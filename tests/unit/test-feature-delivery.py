#!/usr/bin/env python3
"""Offline delivery acceptance through shipped feature adapters and runtime gates."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(os.environ.get('OCTOPUS_FEATURE_TEST_ROOT', Path(__file__).resolve().parents[2])).resolve()

# Keep the production launcher, result nonce, run ledger, scheduler and parent
# validators. External execution and telemetry are isolated for offline checks.
RUNTIME = r'''
source "$PLUGIN/scripts/lib/testing.sh"
source "$PLUGIN/scripts/lib/quality.sh"
source "$PLUGIN/scripts/lib/workflows.sh"
source "$PLUGIN/scripts/lib/parallel.sh"
source "$PLUGIN/scripts/lib/spawn.sh"
source "$PLUGIN/scripts/lib/validation.sh"
source "$PLUGIN/scripts/lib/utils.sh"
source "$PLUGIN/scripts/lib/feature-workflow.sh"
source "$PLUGIN/scripts/lib/feature-scheduler.sh"
PROJECT_ROOT="$OCTOPUS_PROJECT_DIR"; PLUGIN_DIR="$PLUGIN"
WORKSPACE_DIR="$FIXTURE_RUNTIME/workspace"; RESULTS_DIR="$FIXTURE_RUNTIME/results"
LOGS_DIR="$FIXTURE_RUNTIME/logs"; PID_FILE="$WORKSPACE_DIR/pids"
FEATURE_RUNTIME_DIR="$FIXTURE_RUNTIME/feature"; FEATURE_SOURCE_ROOT="$PROJECT_ROOT"
OCTOPUS_RUN_ID="$RUN_ID"; TIMEOUT=30; MAX_PARALLEL=1
TMUX_MODE=false; DRY_RUN=false; LOOP_UNTIL_APPROVED=false; SUPPORTS_PARALLEL_FILE_SAFETY=false
SUPPORTS_DISABLE_CRON_ENV=false; SUPPORTS_STABLE_AUTH=true; OCTOPUS_BACKEND=api
OCTOPUS_ANTISYCOPHANCY=false; OCTOPUS_ENGINEERING_METHODS=off
OCTOPUS_TANGLE_CODE_REVIEW=false; OCTOPUS_TANGLE_MISSING_MARKER_GRACE=0
OCTOPUS_GATE_TANGLE=100; QUALITY_THRESHOLD=100; ON_FAIL_ACTION=auto; AUTONOMY_MODE=autonomous
MAX_QUALITY_RETRIES=0
CLAUDE_TASK_ID=; CODEX_SUBAGENT_PREAMBLE=; PROVIDER_ENV_ARRAY=()
AVAILABLE_AGENTS=codex; CYAN=; MAGENTA=; GREEN=; YELLOW=; RED=; NC=; DIM=
mkdir -p "$WORKSPACE_DIR/.octo/agents" "$RESULTS_DIR" "$LOGS_DIR"
export PROJECT_ROOT WORKSPACE_DIR RESULTS_DIR LOGS_DIR PID_FILE OCTOPUS_RUN_ID
export FEATURE_RUNTIME_DIR FEATURE_SOURCE_ROOT OCTOPUS_ANTISYCOPHANCY
log() { printf '%s\n' "$*" >> "$FIXTURE_RUNTIME/log"; }
get_agent_model() { printf '%s\n' fixture-model; }
get_agent_command() { printf 'python3 %q\n' "$PROVIDER"; }
validate_agent_command() { [[ "$1" == "python3 "* ]]; }
classify_task() { printf '%s\n' standard; }
get_role_for_context() { printf '%s\n' implementer; }
match_routing_rule() { :; }
load_agent_checkpoint() { :; }
apply_persona() { printf '%s' "$2"; }
load_earned_skills() { :; }
build_provider_context() { :; }
enforce_context_budget() { printf '%s' "$1"; }
should_use_agent_teams() { return 1; }
build_provider_env() { PROVIDER_ENV_ARRAY=(); }
# This fixture tests dispatch and parent validation, not OS sandbox support.
octopus_tangle_apply_execution_boundary() { return 0; }
octopus_capture_provider_output() {
    local prompt="$1" input="$3" output="$4" errors="$5"
    shift 5
    printf '%s' "$prompt" > "$input"
    "$@" < "$input" > "$output" 2> "$errors"
}
start_quota_watcher() { :; }; stop_quota_watcher() { :; }
quota_watcher_mark_after_exit() { :; }
octo_provider_identity_from_agent_type() { printf '%s\n' codex; }
octo_append_runtime_identity() { :; }
record_agent_call() { :; }; record_agent_start() { :; }; record_agent_failure() { :; }
update_metrics() { :; }; bridge_register_task() { :; }; update_agent_status() { :; }
write_agent_status() { :; }; append_provider_history() { :; }; record_outcome() { :; }
record_success() { :; }; record_failure() { :; }; record_run_pattern() { :; }
record_task_metric() { :; }; run_drift_check() { :; }; record_error() { :; }
save_agent_checkpoint() { :; }; record_result_hash() { :; }
start_heartbeat_monitor() { :; }; cleanup_heartbeat() { :; }; _octopus_agent_lifecycle_event() { :; }
aggregate_results() { :; }; render_agent_summary() { :; }
octopus_phase_banner() { :; }; reset_provider_lockouts() { :; }
fleet_dispatch_begin() { :; }; fleet_dispatch_end() { :; }
# The production verifier creates a detached worktree and types this response.
# Execute real fixture checks there; never manufacture a verification status.
run_agent_sync() {
    [[ "${5:-}" == tangle-verify ]] || return 91
    printf '%s\n' "$1" >> "$FIXTURE_RUNTIME/resume-verifications"
    python3 - "$PROJECT_ROOT" <<'VERIFY'
import json,subprocess,sys
from pathlib import Path
root=Path(sys.argv[1])
assert root.joinpath('src/export.py').read_text() == 'validated T001\n'
assert subprocess.check_output(['git','-C',str(root),'show','HEAD:src/export.py']).decode() == 'validated T001\n'
assert subprocess.check_output(['git','-C',str(root),'status','--porcelain']) == b''
print(json.dumps({'baselinePassed':True,'defectReproduced':False,'implementationRequired':False,
 'evidence':{'commands':['assert src/export.py content and git show HEAD:src/export.py','git status --porcelain'],
 'failingTests':[],'summary':'Committed export content matches the accepted first task; verification worktree is clean.'}}))
VERIFY
}
feature_workflow_begin develop export false
feature_workflow_preimplement || exit 71
rc=0
feature_tasks_parallel_execute "$FEATURE_TASK_CONTRACT" || rc=$?
printf '\nDELIVERY_RC=%s\n' "$rc"
printf 'DELIVERY_REPORT=%s\n' "$FEATURE_LAST_TASK_REPORT"
exit "$rc"
'''

PROVIDER = r'''
import json,os,sys
from pathlib import Path
prompt=sys.stdin.read()
wave=json.loads(Path(os.environ['OCTOPUS_FEATURE_WAVE_JSON']).read_text())
assert len(wave['selected']) == 1
task=wave['selected'][0]
root=Path(os.environ['OCTOPUS_PROJECT_DIR'])
with open(Path(os.environ['FIXTURE_RUNTIME'])/'dispatches.jsonl','a') as out:
    out.write(json.dumps({'id':task['id'],'prompt':prompt})+'\n')
if os.environ.get('FAIL_TASK') == task['id']:
    print('Fixture intentionally stopped this task.',file=sys.stderr)
    sys.exit(42)
target=root/(task['files'] or task['creates'])[0]
target.parent.mkdir(parents=True,exist_ok=True)
target.write_text('validated '+task['id']+'\n')
print('Implemented '+str(target.relative_to(root))+' for '+task['id']+'. Verified the requested fixture content.')
'''


class FeatureDelivery(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='octopus-feature-delivery-')
        self.base = Path(self.tmp.name).resolve()
        self.root = self.base / 'project'
        self.root.mkdir()
        self.plugin = REPO
        self.home = self.base / 'home'
        self.home.mkdir()
        self.env = {key: os.environ[key] for key in ('PATH', 'LANG', 'LC_ALL', 'TMPDIR', 'SYSTEMROOT')
                    if key in os.environ}
        self.env.update(HOME=str(self.home), OCTOPUS_PROJECT_DIR=str(self.root),
                        CLAUDE_OCTOPUS_WORKSPACE=str(self.base / 'host-runtime'),
                        GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1')
        self.git('init', '-q')
        self.git('config', 'user.name', 'Delivery Fixture')
        self.git('config', 'user.email', 'delivery@example.invalid')
        (self.root / 'AGENTS.md').write_text('Keep the public export API stable.\n')
        (self.root / 'src').mkdir()
        (self.root / 'src/export.py').write_text('pass\n')
        (self.root / 'src/index.py').write_text('pass\n')
        self.git('add', '.')
        self.git('commit', '-qm', 'initial project')

    def tearDown(self):
        self.tmp.cleanup()

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.root), *args], env=self.env, stderr=subprocess.PIPE).decode()

    def command(self, argv, env=None, success=True, timeout=60):
        process = subprocess.run(argv, cwd=self.root, env=env or self.env,
                                 capture_output=True, text=True, timeout=timeout)
        if success:
            self.assertEqual(process.returncode, 0, process.stdout[-4000:] + process.stderr[-6000:])
        else:
            self.assertNotEqual(process.returncode, 0, process.stdout + process.stderr)
        return process

    def adapter(self, *args, success=True):
        process = self.command(['/bin/bash', str(self.plugin / 'scripts/helpers/feature-workflow.sh'), *args], success=success)
        if not success:
            return process
        values = [json.loads(line) for line in process.stdout.splitlines() if line.startswith('{')]
        self.assertTrue(values, process.stdout)
        return values[-1]

    def prepare(self):
        self.context = self.adapter('prepare', 'spec', 'export')
        self.feature = self.root / self.context['feature']
        return self.context

    def spec_and_answer(self):
        spec = self.base / 'accepted-spec.md'
        spec.write_text('''# Export feature
## Purpose
Export saved data.
## Actors
- User: requests an export.
## Behaviors
### FR-001: Export data
Postcondition: the export is saved.
### FR-002: Index exports
Postcondition: saved exports are indexed.
## Constraints
Keep the public export API stable.
## Dependencies
None.
## Acceptance Definition
Given saved data, when export starts, then an export and index exist.
''')
        challenge = self.base / 'challenge.md'
        challenge.write_text('[NEEDS CLARIFICATION: Which export format is in scope?]\n')
        self.adapter('save', 'spec', str(spec), 'claude', 'fixture-author', 'spec-exact-run', self.context['feature'], str(challenge))
        boundary = self.adapter('boundary', 'plan', self.context['feature'])
        self.assertEqual(len(boundary['batch']), 1)
        marker = boundary['markers'][0]
        answers = self.base / 'native-answer.json'
        answers.write_text(json.dumps({'answers': [{'question_id': marker['id'], 'answer': 'CSV only.',
                          'provenance': {'kind': 'native_question_response', 'actor': 'user', 'response_id': 'native-delivery-1'}}]}))
        answered = self.adapter('answer', str(answers), self.context['feature'])
        self.assertEqual(answered['batch'], [])
        self.assertEqual(answered['markers'][0]['status'], 'answered')
        self.marker_id = marker['id']

    def research(self):
        accepted = self.base / 'accepted-run.md'
        accepted.write_text('# PROBE Phase Synthesis\n## Discovery Summary\nCSV exports preserve the requested columns.\n')
        decoy = Path(self.context['runtime_dir']) / 'latest-research.md'
        decoy.write_text('LATEST DECOY MUST NOT BE PUBLISHED\n')
        script = 'source "$PLUGIN/scripts/lib/feature-workflow.sh"; feature_workflow_begin probe export false; feature_workflow_research_completed "$ACCEPTED" codex exact-research-123 false'
        env = dict(self.env, PLUGIN=str(self.plugin), OCTOPUS_FEATURE=self.context['feature'], ACCEPTED=str(accepted))
        self.command(['/bin/bash', '-c', script], env)
        return accepted

    def plan(self):
        tasks = [{'id': 'T%03d' % number, 'title': title, 'kind': 'coding',
                  'requirements': ['FR-%03d' % number], 'files': [path], 'reads': [],
                  'creates': [], 'dependencies': [], 'parallel_hint': True, 'status': 'pending'}
                 for number, title, path in [(1, 'Export saved data', 'src/export.py'), (2, 'Index exports', 'src/index.py')]]
        plan = self.base / 'accepted-plan.md'
        plan.write_text('# Plan\nPreserve the public export API; implement FR-001 and FR-002.\n```octopus-tasks\n' +
                        json.dumps({'schema_version': 1, 'feature_id': self.context['feature_id'], 'tasks': tasks}) + '\n```\n')
        self.adapter('save', 'plan', str(plan), 'claude', 'fixture-author', 'plan-exact-run', self.context['feature'])
        manifest = json.loads((self.feature / 'feature.json').read_text())
        self.contract = manifest['task_history']
        self.assertEqual([task['id'] for task in self.contract['tasks']], ['T001', 'T002'])
        self.assertTrue(all(task['identity'] for task in self.contract['tasks']))

    def runtime(self, name, fail=None, success=True):
        runtime = self.base / name
        runtime.mkdir()
        provider = self.base / 'provider.py'
        provider.write_text(PROVIDER)
        env = dict(self.env, PLUGIN=str(self.plugin), FIXTURE_RUNTIME=str(runtime), PROVIDER=str(provider),
                   OCTOPUS_FEATURE=self.context['feature'], RUN_ID=name, FAIL_TASK=fail or '')
        process = self.command(['/bin/bash', '-c', RUNTIME], env=env, success=success)
        reports = re.findall(r'^DELIVERY_REPORT=(.+)$', process.stdout, re.M)
        self.assertEqual(len(reports), 1, process.stdout + process.stderr)
        return runtime, json.loads(Path(reports[0]).read_text())

    def candidate_package(self):
        package = self.base / 'package'
        package.mkdir()
        owners = {'.claude-plugin', '.codex-plugin', '.cursor-plugin', '.claude', 'commands', 'skills', 'scripts', 'config', 'agents', 'hooks'}
        tracked = subprocess.check_output(['git', '-C', str(REPO), 'ls-files', '-z'], env=self.env).decode().split('\0')
        for relative in tracked:
            if relative and relative.split('/')[0] in owners:
                source = REPO / relative
                if source.is_file():
                    destination = package / relative
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(source, destination)
        return package

    def test_package_discovery_resolves_shipped_owners_and_helpers(self):
        package = self.candidate_package()
        manifest = json.loads((package / '.claude-plugin/plugin.json').read_text())
        for command in ('spec', 'plan', 'develop', 'resume'):
            self.assertIn('./commands/' + command + '.md', manifest['commands'])
            self.assertTrue((package / 'commands' / (command + '.md')).is_file())
            self.assertTrue((package / '.cursor-plugin/commands' / ('octo-' + command + '.md')).is_file())
        codex = json.loads((package / '.codex-plugin/plugin.json').read_text())
        self.assertTrue((package / codex['skills'] / 'flow-spec/SKILL.md').is_file())
        factory = json.loads((package / '.cursor-plugin/plugin.json').read_text())
        self.assertTrue((package / factory['skills'] / 'flow-spec/SKILL.md').is_file())
        self.assertTrue((package / factory['commands'] / 'octo-spec.md').is_file())
        for owner in (package / '.claude/skills', package / 'skills'):
            for skill in ('flow-spec', 'flow-develop', 'skill-resume'):
                self.assertTrue((owner / skill / 'SKILL.md').is_file())
            self.assertIn('scripts/helpers/feature-workflow.sh', (owner / 'flow-spec/SKILL.md').read_text())
            self.assertIn('scripts/helpers/feature-contract.py', (owner / 'skill-resume/SKILL.md').read_text())
        for plan_owner in ('commands/plan.md', '.cursor-plugin/commands/octo-plan.md'):
            self.assertIn('scripts/helpers/feature-workflow.sh', (package / plan_owner).read_text())
        for helper in ('feature-workflow.sh', 'feature-contract.py', 'feature-policy.py', 'feature-clarifications.py', 'feature-tasks.py', 'feature-analysis.py'):
            self.assertTrue((package / 'scripts/helpers' / helper).is_file())
        # Exercise the copied package's adapter, with no installation or ambient HOME.
        self.plugin = package
        context = self.prepare()
        self.assertTrue(context['feature'].startswith('specs/001-export'))
        self.assertFalse((self.home / '.claude/plugins').exists())

    def test_first_repeat_prepare_binds_existing_policy_without_duplication(self):
        context = self.prepare()
        again = self.adapter('prepare', 'spec', 'export', context['feature'])
        self.assertEqual(again['feature_id'], context['feature_id'])
        self.assertEqual(again['feature'], context['feature'])
        self.assertEqual(len(list((self.root / 'specs').glob('[0-9]*'))), 1)
        policy = json.loads(Path(context['policy_snapshot']).read_text())
        self.assertEqual(policy['source'], 'AGENTS.md')
        self.assertEqual(policy['digest'], hashlib.sha256((self.root / 'AGENTS.md').read_bytes()).hexdigest())
        self.assertFalse((self.root / '.specify').exists())

    def test_research_callback_publishes_exact_run_not_latest_decoy(self):
        self.prepare()
        accepted = self.research()
        public = (self.feature / 'research.md').read_text()
        self.assertIn('Runtime run: exact-research-123', public)
        self.assertIn('CSV exports preserve the requested columns.', public)
        self.assertNotIn('DECOY', public)
        self.assertNotIn('PROBE Phase Synthesis', public)
        record = json.loads((Path(self.context['runtime_dir']) / 'last-research.json').read_text())
        self.assertEqual(record['result'], str(accepted))
        self.assertEqual(record['run_id'], 'exact-research-123')

    def test_degraded_research_keeps_raw_result_private(self):
        self.prepare()
        raw = self.base / 'provider-transcript.md'
        raw.write_text('RAW PROVIDER TRANSCRIPT MUST REMAIN PRIVATE\n')
        script = 'source "$PLUGIN/scripts/lib/feature-workflow.sh"; feature_workflow_begin probe export false; feature_workflow_research_completed "$RAW" codex rejected-run-123 true'
        env = dict(self.env, PLUGIN=str(self.plugin), OCTOPUS_FEATURE=self.context['feature'], RAW=str(raw))
        self.command(['/bin/bash', '-c', script], env)
        public = (self.feature / 'research.md').read_text()
        self.assertIn('Content retained in runtime state.', public)
        self.assertNotIn('RAW PROVIDER TRANSCRIPT', public)
        manifest = json.loads((self.feature / 'feature.json').read_text())
        self.assertTrue(manifest['artifacts']['research']['withheld'])
        record = json.loads((Path(self.context['runtime_dir']) / 'last-research.json').read_text())
        self.assertTrue(record['degraded'])
        self.assertEqual(record['result'], str(raw))

    def test_committed_partial_run_resumes_in_fresh_home_only_pending_task(self):
        self.plugin = self.candidate_package()
        self.prepare()
        self.research()
        self.spec_and_answer()
        self.plan()
        self.git('add', '.')
        self.git('commit', '-qm', 'accepted feature artifacts')
        first, report = self.runtime('first-run', fail='T002', success=False)
        self.assertEqual(report['status'], 'partial')
        dispatched = [json.loads(line)['id'] for line in (first / 'dispatches.jsonl').read_text().splitlines()]
        self.assertEqual(dispatched, ['T001', 'T002'])
        manifest = json.loads((self.feature / 'feature.json').read_text())
        self.assertEqual(manifest['analysis']['attempts'], 0)
        completed = {task['id']: task for task in manifest['task_completion']['tasks']}
        self.assertEqual(completed['T001']['status'], 'completed')
        self.assertEqual(completed['T002']['status'], 'failed')
        self.assertNotIn('parent_verified', (self.feature / 'feature.json').read_text())
        self.assertIn('- [x] T001', (self.feature / 'tasks.md').read_text())
        self.assertIn('- [ ] T002', (self.feature / 'tasks.md').read_text())
        validation = list((first / 'results').glob('tangle-validation-*.md'))
        self.assertTrue(validation)
        self.assertTrue(any('PASS: every changed path' in path.read_text() for path in validation))
        ledger = [json.loads(line) for line in (first / 'workspace/runs/first-run/seats.jsonl').read_text().splitlines()]
        self.assertTrue(any(item['transition'] == 'contributed' for item in ledger))
        self.git('add', '.')
        self.git('commit', '-qm', 'validated first task and partial progress')
        tracked = self.git('ls-files').splitlines()
        self.assertFalse(any('runtime' in path or 'raw-' in path or 'answers.json' in path for path in tracked))
        public = '\n'.join((self.root / path).read_text() for path in tracked if path.endswith(('.md', '.json')))
        self.assertNotIn(str(self.base), public)
        self.assertNotIn((self.base / 'native-answer.json').read_text(), public)
        self.assertFalse(any(path == 'native-answer.json' for path in tracked))
        original_ids = [(task['id'], task['identity']) for task in self.contract['tasks']]
        shutil.rmtree(first)
        shutil.rmtree(self.base / 'host-runtime')
        fresh_home = self.base / 'fresh-home'
        fresh_home.mkdir()
        self.env.update(HOME=str(fresh_home), CLAUDE_OCTOPUS_WORKSPACE=str(self.base / 'fresh-host-runtime'))
        resumed = self.adapter('prepare', 'develop', 'export', self.context['feature'])
        self.assertEqual(resumed['feature_id'], self.context['feature_id'])
        policy = json.loads(Path(resumed['policy_snapshot']).read_text())
        self.assertEqual(policy['source'], 'AGENTS.md')
        self.assertEqual(policy['digest'], hashlib.sha256((self.root / 'AGENTS.md').read_bytes()).hexdigest())
        self.assertIn('CSV exports preserve the requested columns.', (self.feature / 'research.md').read_text())
        boundary = self.adapter('boundary', 'plan', self.context['feature'])
        self.assertEqual(boundary['batch'], [])
        self.assertEqual(boundary['markers'][0]['id'], self.marker_id)
        self.assertEqual(boundary['markers'][0]['status'], 'answered')
        second, report = self.runtime('fresh-run')
        self.assertEqual(report['status'], 'complete')
        self.assertEqual(len((second / 'resume-verifications').read_text().splitlines()), 1)
        verification = list((second / 'results').glob('tangle-verification-feature-resume-*.json'))
        self.assertEqual(len(verification), 1)
        checked = json.loads(verification[0].read_text())
        self.assertEqual(checked['status'], 'VERIFIED_NO_CHANGE')
        self.assertEqual(checked['sourceCommit'], self.git('rev-parse', 'HEAD').strip())
        self.assertTrue(checked['evidence']['commands'])
        self.assertEqual(checked['evidence']['failingTests'], [])
        dispatched = [json.loads(line)['id'] for line in (second / 'dispatches.jsonl').read_text().splitlines()]
        self.assertEqual(dispatched, ['T002'])
        final = json.loads((self.feature / 'feature.json').read_text())
        self.assertEqual([(task['id'], task['identity']) for task in final['task_history']['tasks']], original_ids)
        self.assertTrue(all(task['status'] == 'completed' for task in final['task_completion']['tasks']))
        self.assertIn('- [x] T002', (self.feature / 'tasks.md').read_text())



class SpecInstructionAcceptance(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.runtime = self.root / 'runtime'
        self.runtime.mkdir()
        self.text = (REPO / '.claude/skills/flow-spec/SKILL.md').read_text()

    def snippet(self, step):
        section = self.text.split('### STEP ' + step + ':', 1)[1]
        return section.split('```bash\n', 1)[1].split('```', 1)[0]

    def execute(self, code, prefix=''):
        env = dict(os.environ, FEATURE_RUNTIME_DIR=str(self.runtime),
                   SPEC_RESEARCH_RUN='current-spec-run', OCTO_ROOT=str(self.root / 'plugin'),
                   FEATURE_SELECTOR='specs/001-example')
        return subprocess.run(['bash', '-c', prefix + '\n' + code], env=env,
                              capture_output=True, text=True, timeout=10)

    def test_receipt_rejects_other_runs_degraded_missing_and_invalid_results(self):
        result = self.root / 'accepted.md'
        result.write_text('CURRENT ACCEPTED RESEARCH\n')
        receipt = self.runtime / 'last-research.json'
        code = self.snippet('5')
        for fields in [dict(run_id='old-spec-run', degraded=False, result=str(result)),
                       dict(run_id='current-spec-run', degraded=True, result=str(result)),
                       dict(run_id='current-spec-run', degraded=False, result=None),
                       dict(run_id='current-spec-run', degraded=False, result='')]:
            with self.subTest(fields=fields):
                receipt.write_text(json.dumps(fields))
                ran = self.execute(code)
                self.assertNotEqual(ran.returncode, 0)
                self.assertNotIn('CURRENT ACCEPTED RESEARCH', ran.stdout)
        receipt.unlink()
        self.assertNotEqual(self.execute(code).returncode, 0)
        receipt.write_text(json.dumps(dict(run_id='current-spec-run', degraded=False, result=str(result))))
        ran = self.execute(code)
        self.assertEqual(ran.returncode, 0, ran.stderr)
        self.assertIn('CURRENT ACCEPTED RESEARCH', ran.stdout)

    def test_no_external_provider_skips_dispatch_and_keeps_empty_answer(self):
        code = self.snippet('6.5')
        prefix = 'command() { if [[ "$1" == -v && ( "$2" == codex || "$2" == agy ) ]]; then return 1; fi; builtin command "$@"; }'
        ran = self.execute(code, prefix)
        self.assertEqual(ran.returncode, 0, ran.stderr)
        self.assertIn('No external challenge provider', ran.stdout)
        self.assertEqual((self.runtime / 'challenge-answer.md').read_text(), '')

    def test_available_provider_uses_exact_result_and_failure_remains_optional(self):
        plugin = self.root / 'plugin'
        (plugin / 'scripts/lib').mkdir(parents=True)
        (plugin / 'scripts/orchestrate.sh').write_text('printf "%s\\n" "$2" > "$FEATURE_RUNTIME_DIR/dispatched-provider"\nexit 1\n')
        (plugin / 'scripts/lib/result-file.sh').write_text('octo_result_launcher_status() { printf "FAILED\\n"; }\n')
        (self.runtime / 'spec-draft.md').write_text('Draft spec')
        code = self.snippet('6.5')
        for provider in ['codex', 'agy']:
            with self.subTest(provider=provider):
                prefix = 'command() { if [[ "$1" == -v && ( "$2" == codex || "$2" == agy ) ]]; then [[ "$2" == ' + provider + ' ]]; return; fi; builtin command "$@"; }'
                ran = self.execute(code, 'set -e\n' + prefix)
                self.assertEqual(ran.returncode, 0, ran.stderr)
                self.assertEqual((self.runtime / 'dispatched-provider').read_text().strip(), provider)
                self.assertEqual((self.runtime / 'challenge-answer.md').read_text(), '')

    def test_success_reads_only_the_selected_challenge_artifact(self):
        plugin = self.root / 'plugin'
        (plugin / 'scripts/lib').mkdir(parents=True)
        (plugin / 'scripts/orchestrate.sh').write_text('printf "SELECTED CHALLENGE\\n" > "$7/$2-$4.md"\n')
        (plugin / 'scripts/lib/result-file.sh').write_text(
            'octo_result_launcher_status() { [[ -f "$1" ]] && printf "SUCCESS\\n"; }\n'
            'octo_result_framed_sections() { cat "$1"; }\n')
        (self.runtime / 'spec-draft.md').write_text('Draft spec')
        (self.runtime / 'challenge-results').mkdir()
        (self.runtime / 'challenge-results/decoy.md').write_text('DECOY')
        prefix = 'command() { if [[ "$1" == -v && "$2" == codex ]]; then return 0; fi; builtin command "$@"; }'
        ran = self.execute(self.snippet('6.5'), 'set -e\n' + prefix)
        self.assertEqual(ran.returncode, 0, ran.stderr)
        self.assertEqual((self.runtime / 'challenge-answer.md').read_text(), 'SELECTED CHALLENGE\n')

if __name__ == '__main__':
    unittest.main()
