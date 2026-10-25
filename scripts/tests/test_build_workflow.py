"""Run with: python3 -m unittest discover -s scripts/tests -v

Build tools are mocked: these checks never download or compile WebRTC.
"""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import zipfile
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1]


class WorkflowTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        shutil.copytree(SCRIPTS, self.root / 'scripts', ignore=shutil.ignore_patterns('tests', '__pycache__'))
        self.src = self.root / 'webrtc' / 'src'
        self.src.mkdir(parents=True)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.env = dict(os.environ, PATH=str(self.bin) + ':' + os.environ['PATH'],
                        NO_COLOR='1', CALLS=str(self.root / 'calls'))
        self.stub('uname', '#!/bin/bash\ncase "$1" in -s) echo Darwin ;; *) echo arm64 ;; esac\n')
        self.stub('xcodebuild', '''#!/bin/bash
if [ "$1" = -version ]; then exit 0; fi
if [ "${FAIL_PACKAGE:-0}" = 1 ]; then exit 9; fi
while [ "$#" -gt 0 ]; do
    if [ "$1" = -output ]; then mkdir -p "$2"; echo new > "$2/marker"; exit 0; fi
    shift
done
exit 1
''')
        (self.root / '.gitignore').write_text('webrtc/\nartifacts/\nbin/\ncalls\n__pycache__/\n')
        subprocess.run(['git', 'init', '-q', str(self.root)], check=True)
        subprocess.run(['git', '-C', str(self.root), 'add', '.'], check=True)
        subprocess.run(['git', '-C', str(self.root), '-c', 'user.name=Test',
                        '-c', 'user.email=test@example.test', 'commit', '-qm', 'builder'], check=True)

    def stub(self, name, body, directory=None):
        path = (directory or self.bin) / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body)
        path.chmod(0o755)
        return path

    def run_script(self, name, *args, inputs='', **env):
        return subprocess.run(['/bin/bash', str(self.root / 'scripts' / name), *args],
                              input=inputs, text=True, capture_output=True,
                              env=dict(self.env, **env))

    def init_source(self, dirty=False):
        subprocess.run(['git', 'init', '-q', str(self.src)], check=True)
        (self.src / 'tracked').write_text('original')
        subprocess.run(['git', '-C', str(self.src), 'add', 'tracked'], check=True)
        subprocess.run(['git', '-C', str(self.src), '-c', 'user.name=Test',
                        '-c', 'user.email=test@example.test', 'commit', '-qm', 'fixture'], check=True)
        if dirty:
            (self.src / 'tracked').write_text('changed')

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_dry_run_all_architectures_merge_macos_once(self):
        result = self.run_script('create_lib.sh', '--dry-run', inputs='1\na\n1\n')
        self.assert_success(result)
        self.assertIn('build_ios.sh device:arm64 simulator:arm64 simulator:x64', result.stdout)
        self.assertIn('build_macos.sh arm64 x64', result.stdout)
        self.assertIn('combine_xcframework.sh ios/device ios/simulator macos-universal', result.stdout)
        self.assertFalse((self.root / 'artifacts').exists())

    def test_platform_validation_and_deduplication(self):
        result = self.run_script('create_lib.sh', '--dry-run', inputs='1\n6\n3,3\n2\n')
        self.assert_success(result)
        self.assertIn('Choose numbers 1', result.stdout)
        self.assertIn('build_ios.sh simulator:x64', result.stdout)
        self.assertNotIn('build_macos.sh', result.stdout)
        self.assertIn('combine_xcframework.sh ios/simulator', result.stdout)

    def test_dirty_checkout_blocks_switch_and_defaults_to_no_sync(self):
        self.init_source(dirty=True)
        result = self.run_script('create_lib.sh', '--dry-run', inputs='2\n1\n4\n1\n\n')
        self.assert_success(result)
        self.assertIn('Commit or stash', result.stdout)
        self.assertNotIn('> ' + str(self.root / 'scripts' / 'prepare_webrtc_src.sh'), result.stdout)
        self.assertEqual((self.src / 'tracked').read_text(), 'changed')

    def test_direct_branch_selection(self):
        result = self.run_script('create_lib.sh', '--dry-run', inputs='2\n8078_12\n4\n1\n')
        self.assert_success(result)
        self.assertIn('prepare_webrtc_src.sh --non-interactive 8078_12', result.stdout)

    def test_cancel_and_eof_do_not_build(self):
        for inputs in ('q\n', '', '1\n4\n1\nn\n'):
            with self.subTest(inputs=inputs):
                result = self.run_script('create_lib.sh', inputs=inputs)
                self.assert_success(result)
                self.assertNotIn('> ', result.stdout)

    def test_confirmed_wrapper_calls_only_selected_builders(self):
        self.init_source()
        for name in ('prepare_webrtc_src.sh', 'build_ios.sh', 'build_macos.sh', 'combine_xcframework.sh'):
            self.stub(name, '#!/bin/bash\nprintf "%s %s config=%s\\n" "${0##*/}" "$*" "$BUILD_CONFIG" >> "$CALLS"\n',
                      self.root / 'scripts')
        result = self.run_script('create_lib.sh', inputs='1\n1,3,5\n2\n1\ny\n')
        self.assert_success(result)
        calls = (self.root / 'calls').read_text().splitlines()
        self.assertEqual(calls, [
            'prepare_webrtc_src.sh --non-interactive config=debug',
            'build_ios.sh device:arm64 simulator:x64 config=debug',
            'build_macos.sh x64 config=debug',
            'combine_xcframework.sh ios/device ios/simulator macos-x64 config=debug'])

    def test_ios_receives_exact_architectures_and_configuration(self):
        self.init_source()
        self.stub('build_ios_libs.sh', '#!/bin/bash\nprintf "%s\\n" "$@" > "$CALLS"\nmkdir -p out/ios/simulator/WebRTC.framework\n',
                  self.src / 'tools_webrtc' / 'ios')
        result = self.run_script('build_ios.sh', 'simulator:arm64', BUILD_CONFIG='debug')
        self.assert_success(result)
        args = (self.root / 'calls').read_text().splitlines()
        self.assertEqual(args[-4:], ['--build_config', 'debug', '--arch', 'simulator:arm64'])
        self.assertNotIn('device:arm64', args)
        data = json.loads((self.src / 'out/ios/simulator/WebRTC.framework/WebRTC.build-info.json').read_text())
        self.assertEqual(data['architectures'], ['arm64'])
        self.assertEqual(data['configuration'], 'debug')
        self.assertNotEqual(self.run_script('build_ios.sh', 'bad').returncode, 0)

    def test_prepare_preserves_sync_flags_and_enables_apple_dependencies(self):
        self.init_source()
        (self.root / 'webrtc' / 'depot_tools').mkdir()
        config = self.root / 'webrtc' / '.gclient'
        config.write_text('solutions = []\ntarget_os = ["linux"]\n')
        self.stub('gclient', '#!/bin/bash\nprintf "%s\\n" "$*" > "$CALLS"\n')
        result = self.run_script('prepare_webrtc_src.sh', '--non-interactive')
        self.assert_success(result)
        self.assertEqual((self.root / 'calls').read_text(), 'sync\n')
        self.assertIn("target_os = ['linux', 'ios', 'mac']", config.read_text())

    def test_prepare_refuses_dirty_version_switch(self):
        self.init_source(dirty=True)
        (self.root / 'webrtc' / 'depot_tools').mkdir()
        result = self.run_script('prepare_webrtc_src.sh', '--non-interactive', '8078')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Cannot switch versions', result.stderr)
        self.assertEqual((self.src / 'tracked').read_text(), 'changed')

    def test_macos_universal_merges_framework_and_symbols(self):
        self.init_source()
        headers = self.src / 'sdk/objc/api/peerconnection'
        headers.mkdir(parents=True)
        (headers / 'RTCAudioSource.h').write_text(
            '#import "sdk/objc/base/RTCMacros.h"\n'
            '#import "sdk/objc/api/peerconnection/RTCMediaSource.h"\n'
            '#import "sdk/objc/RTCExample.h"\n')
        self.stub('gn', '''#!/bin/bash
out="$2"
mkdir -p "$out/WebRTC.framework/Versions/A" "$out/WebRTC.framework.dSYM/Contents/Resources/DWARF"
echo binary > "$out/WebRTC.framework/Versions/A/WebRTC"
ln -sf Versions/A/WebRTC "$out/WebRTC.framework/WebRTC"
echo symbols > "$out/WebRTC.framework.dSYM/Contents/Resources/DWARF/WebRTC"
printf '%s\\n' "$*" >> "$CALLS"
''')
        self.stub('ninja', '#!/bin/bash\nexit 0\n')
        self.stub('lipo', '#!/bin/bash\nwhile [ "$#" -gt 0 ]; do if [ "$1" = -output ]; then echo merged > "$2"; exit 0; fi; shift; done\nexit 1\n')
        self.stub('ditto', '#!/usr/bin/env python3\nimport shutil,sys\nshutil.copytree(sys.argv[1],sys.argv[2],symlinks=True)\n')
        result = self.run_script('build_macos.sh', 'arm64', 'x64', BUILD_CONFIG='release')
        self.assert_success(result)
        dest = self.src / 'out' / 'macos-universal'
        self.assertEqual((dest / 'WebRTC.framework' / 'WebRTC').read_text(), 'merged\n')
        self.assertEqual((dest / 'WebRTC.framework.dSYM' / 'Contents' / 'Resources' / 'DWARF' / 'WebRTC').read_text(), 'merged\n')
        expected_header = ('#import <WebRTC/RTCMacros.h>\n'
                           '#import <WebRTC/RTCMediaSource.h>\n'
                           '#import <WebRTC/RTCExample.h>\n')
        for directory in ('macos-arm64', 'macos-x64', 'macos-universal'):
            header = self.src / 'out' / directory / 'WebRTC.framework/Versions/A/Headers/RTCAudioSource.h'
            self.assertEqual(header.read_text(), expected_header)
        self.assertIn('is_debug=false', (self.root / 'calls').read_text())
        data = json.loads((dest / 'WebRTC.framework/Versions/A/Resources/WebRTC.build-info.json').read_text())
        self.assertEqual(data['architectures'], ['arm64', 'x64'])

    def make_manifest(self, framework):
        framework.mkdir(parents=True, exist_ok=True)
        data = {'schema_version': 1, 'webrtc': {'commit': 'source', 'dirty': False},
                'builder': {'commit': 'builder', 'dirty': False}, 'configuration': 'release',
                'toolchain': 'Xcode fixture', 'platform': 'macos', 'architectures': ['arm64']}
        (framework / 'WebRTC.build-info.json').write_text(json.dumps(data))
        return data

    def test_packaging_rejects_mismatched_and_missing_metadata(self):
        first = self.src / 'out/first/WebRTC.framework'
        second = self.src / 'out/second/WebRTC.framework'
        self.make_manifest(first)
        data = self.make_manifest(second)
        for key, value in [('configuration', 'debug'), ('webrtc', {'commit': 'older'}),
                           ('builder', {'commit': 'other'}), ('toolchain', 'Other Xcode')]:
            changed = dict(data, **{key: value})
            (second / 'WebRTC.build-info.json').write_text(json.dumps(changed))
            result = self.run_script('combine_xcframework.sh', 'first', 'second')
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('different source identities', result.stderr)
        (second / 'WebRTC.build-info.json').unlink()
        self.assertNotEqual(self.run_script('combine_xcframework.sh', 'second').returncode, 0)

    def test_source_mutation_during_compilation_is_rejected(self):
        self.init_source()
        self.stub('build_ios_libs.sh', '#!/bin/bash\necho changed > tracked\nmkdir -p out/ios/device/WebRTC.framework\n',
                  self.src / 'tools_webrtc/ios')
        result = self.run_script('build_ios.sh', 'device:arm64')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('changed during compilation', result.stderr)

    def test_local_changes_have_distinct_fingerprints(self):
        self.init_source(dirty=True)
        helper = self.root / 'scripts/lib/build_info.py'
        output = self.root / 'artifacts/snapshot.json'
        output.parent.mkdir()
        def capture():
            subprocess.run(['python3', str(helper), 'capture', str(output),
                            str(self.root), 'release'], env=self.env, check=True)
            return json.loads(output.read_text())['webrtc']
        first = capture()
        (self.src / 'tracked').write_text('different local edit')
        second = capture()
        self.assertTrue(first['dirty'])
        self.assertEqual(first['commit'], second['commit'])
        self.assertNotEqual(first['changes_sha256'], second['changes_sha256'])

    def test_failed_packaging_preserves_previous_artifact(self):
        self.make_manifest(self.src / 'out' / 'macos-arm64' / 'WebRTC.framework')
        old = self.root / 'artifacts' / 'WebRTC.xcframework'
        old.mkdir(parents=True)
        (old / 'marker').write_text('previous')
        symbols = self.root / 'artifacts/WebRTC.symbols.zip'
        symbols.write_bytes(b'previous symbols')
        result = self.run_script('combine_xcframework.sh', 'macos-arm64', FAIL_PACKAGE='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((old / 'marker').read_text(), 'previous')
        self.assertEqual(symbols.read_bytes(), b'previous symbols')
        self.assert_success(self.run_script('combine_xcframework.sh', 'macos-arm64'))
        self.assertEqual((old / 'marker').read_text(), 'new\n')
        manifest = self.root / 'artifacts/WebRTC.build-info.json'
        self.assertEqual(json.loads(manifest.read_text())['webrtc']['commit'], 'source')
        self.assertEqual(manifest.read_text(), (old / 'WebRTC.build-info.json').read_text())
        with zipfile.ZipFile(symbols) as archive:
            self.assertEqual(archive.read('symbols/WebRTC.build-info.json').decode(), manifest.read_text())

    def test_symbols_are_packaged_separately_per_platform(self):
        self.stub('dwarfdump', '#!/bin/bash\necho "UUID: fixture (arm64) $2"\n')
        self.stub('xcodebuild', '''#!/bin/bash
for arg in "$@"; do
    if [ "$arg" = -debug-symbols ]; then exit 8; fi
done
while [ "$#" -gt 0 ]; do
    if [ "$1" = -output ]; then mkdir -p "$2"; exit 0; fi
    shift
done
exit 1
''')
        for platform, name in [('ios/device', 'WebRTC.dSYM'),
                               ('macos-universal', 'WebRTC.framework.dSYM')]:
            directory = self.src / 'out' / platform
            self.make_manifest(directory / 'WebRTC.framework')
            dwarf = directory / name / 'Contents/Resources/DWARF/WebRTC'
            dwarf.parent.mkdir(parents=True)
            dwarf.write_text(platform)
        self.assert_success(self.run_script('combine_xcframework.sh', 'ios/device', 'macos-universal'))
        with zipfile.ZipFile(self.root / 'artifacts/WebRTC.symbols.zip') as archive:
            self.assertEqual(archive.read('symbols/ios/device/WebRTC.dSYM/Contents/Resources/DWARF/WebRTC'), b'ios/device')
            self.assertEqual(archive.read('symbols/macos-universal/WebRTC.framework.dSYM/Contents/Resources/DWARF/WebRTC'), b'macos-universal')
            self.assertEqual(archive.read('symbols/UUIDs.txt').count(b'UUID: fixture'), 2)


class MilestoneTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location('milestones', SCRIPTS / 'lib' / 'milestones.py')
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.module.CACHE = Path(self.temp.name) / 'cache.json'
        self.releases = [
            {'version': '156.0.8078.12', 'serving': {'startTime': '2026-10-07T17:00:00Z'}},
            {'version': '156.0.8078.12', 'serving': {'startTime': '2026-10-08T17:00:00Z'}},
            {'version': '156.0.8078.10', 'serving': {'startTime': '2026-10-01T17:00:00Z'}},
            {'version': '155.0.8059.40', 'serving': {'startTime': '2026-10-06T17:00:00Z'}},
        ]

    def test_version_mapping_and_date_for_displayed_patch(self):
        rows = self.module.records(self.releases)
        self.assertEqual(rows['156']['branch'], '8078')
        self.assertEqual(rows['156']['version'], '156.0.8078.12')
        self.assertEqual(rows['156']['date'], '2026-10-07')

    def test_offline_cache_fallback_and_unknown_milestone_failure(self):
        with mock.patch.object(self.module, 'fetch', return_value={'releases': self.releases}):
            self.module.lookup()
        data = json.loads(self.module.CACHE.read_text())
        data['fetched_at'] = '2020-01-01T00:00:00+00:00'
        self.module.CACHE.write_text(json.dumps(data))
        with mock.patch.object(self.module, 'fetch', side_effect=OSError('offline')):
            self.assertEqual(self.module.lookup('156')['156']['branch'], '8078')
            with self.assertRaisesRegex(ValueError, 'branch-head directly'):
                self.module.lookup('999')

    def test_exact_milestone_query_and_pagination(self):
        with mock.patch.object(self.module, 'fetch', side_effect=[
            {'releases': [], 'nextPageToken': 'next'}, {'releases': self.releases[:1]}]) as fetch:
            self.assertEqual(self.module.lookup('156')['156']['branch'], '8078')
            self.assertEqual(fetch.call_args[0][0]['filter'], 'version>=156,version<157')
            self.assertEqual(fetch.call_args[0][0]['pageToken'], 'next')


if __name__ == '__main__':
    unittest.main()
