"""Capture provenance before compilation and validate it when packaging."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

NAME = 'WebRTC.build-info.json'


def git(root, *args):
    return subprocess.check_output(['git', '-C', str(root), *args])


def revision(root, exclude_out=False):
    if git(root, 'rev-parse', '--show-prefix').strip():
        raise ValueError(f'{root} must be a standalone Git checkout')
    paths = ['--', '.', ':(exclude)out'] if exclude_out else ['--', '.']
    status = git(root, 'status', '--porcelain', *paths)
    digest = hashlib.sha256()
    digest.update(git(root, 'diff', 'HEAD', '--binary', *paths))
    for name in git(root, 'ls-files', '--others', '--exclude-standard', '-z', *paths).split(b'\0'):
        if name:
            path = root / name.decode()
            digest.update(name)
            digest.update(path.read_bytes() if not path.is_symlink() else str(path.readlink()).encode())
    return {'commit': git(root, 'rev-parse', 'HEAD').decode().strip(),
            'dirty': bool(status), 'changes_sha256': digest.hexdigest() if status else None}


def capture(root, config):
    src = root / 'webrtc' / 'src'
    source = revision(src, True)
    source['reference'] = git(src, 'name-rev', '--name-only', 'HEAD').decode().strip()
    message = git(src, 'log', '-1', '--format=%B').decode()
    source['commit_position'] = next((line[len('Cr-Commit-Position: '):]
                                      for line in message.splitlines()
                                      if line.startswith('Cr-Commit-Position: ')), None)
    return {'schema_version': 1, 'webrtc': source, 'builder': revision(root),
            'configuration': config,
            'toolchain': subprocess.check_output(['xcodebuild', '-version']).decode().strip()}


def write(path, data):
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + '\n')


def manifest_path(framework):
    # Respect macOS versioned bundle layout; flat iOS bundles keep resources at root.
    resources = framework / 'Resources'
    if resources.is_dir():
        return resources / NAME
    version = framework / 'Versions' / 'A'
    if version.is_dir():
        resources = version / 'Resources'
        return resources / NAME
    return framework / NAME


def identity(data):
    return {key: data[key] for key in
            ('schema_version', 'webrtc', 'builder', 'configuration', 'toolchain')}


def main():
    parser = argparse.ArgumentParser(__doc__)
    parser.add_argument('action', choices=['capture', 'embed', 'combine'])
    parser.add_argument('output', type=Path)
    parser.add_argument('inputs', nargs='+')
    args = parser.parse_args()
    if args.action == 'capture':
        write(args.output, capture(Path(args.inputs[0]), args.inputs[1]))
    elif args.action == 'embed':
        snapshot, root, platform, *architectures = args.inputs
        data = json.loads(Path(snapshot).read_text())
        if identity(data) != identity(capture(Path(root), data['configuration'])):
            raise ValueError('Source or toolchain changed during compilation; rebuild required')
        data.update(platform=platform, architectures=architectures)
        destination = manifest_path(args.output)
        destination.parent.mkdir(exist_ok=True)
        write(destination, data)
    else:
        slices = []
        for name in args.inputs:
            framework = Path(name)
            data = json.loads(manifest_path(framework).read_text())
            if data['schema_version'] != 1 or not data['architectures']:
                raise ValueError(f'Invalid build manifest in {framework}')
            if slices and identity(data) != identity(slices[0]):
                raise ValueError('Frameworks have different source identities or build configurations')
            slices.append(data)
        result = identity(slices[0])
        result['slices'] = [{'platform': item['platform'], 'architectures': item['architectures']}
                            for item in slices]
        write(args.output, result)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
        raise SystemExit(f'Build metadata error: {error}')
