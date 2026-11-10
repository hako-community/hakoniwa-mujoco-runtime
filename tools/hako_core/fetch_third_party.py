"""Fetch the Hakoniwa core repositories (third_party) at the commits pinned in third_party.lock.

One lock for every robot (armpi, humanoid, cobot) and drone (hakoniwa-mujoco-drone, hakoniwa-drone-companion):
the Hakoniwa core always follows upstream main, and this file is the single place that says which commit.

    python tools/hako_core/fetch_third_party.py                  # -> <workspace>/third_party (clone if missing, then verify)
    python tools/hako_core/fetch_third_party.py --verify-only    # only compare an existing checkout with the lock
    python tools/hako_core/fetch_third_party.py --latest         # write upstream main's head into the lock (then commit it)
    python tools/hako_core/fetch_third_party.py --latest --dry-run   # only show what --latest would write
    python tools/hako_core/fetch_third_party.py --refresh        # existing checkout differs: move it aside, clone again

<workspace> is the folder holding hakoniwa-mujoco-runtime (e.g. D:/work_build, D:/work_drone/work_git).

Rules:
  * third_party repositories belong to others. This script only clones and checks out a NEW folder; it never
    modifies, commits or pushes them, and never fetches/checks out inside an existing checkout.
  * An existing checkout at another commit is left as it is (error). --refresh renames it to
    third_party.old-<time> (contents untouched) and clones the locked commits again.
  * Submodules are initialised from the parent's own gitlinks; the parent's gitlink and the lock must agree.
Works on Windows and Linux. Needs git (and network access except for --verify-only).
"""
import argparse
import datetime
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
RUNTIME = HERE.parents[1]
DEFAULT_DEST = RUNTIME.parent / 'third_party'


def log(*a):
    print('[fetch_third_party]', *a, flush=True)


def read_lock(path):
    rows = []
    for line in path.read_text(encoding='utf-8').splitlines():
        s = line.strip()
        if not s or s.startswith('#'):
            continue
        name, rel, url, commit, required = (x.strip() for x in s.split('|'))
        rows.append({'name': name, 'path': rel.replace('\\', '/'), 'url': url, 'commit': commit,
                     'required': required == 'yes'})
    return rows


def git(*args, cwd=None, capture=False):
    # core.longpaths: pdu-registry has deep paths that exceed MAX_PATH on Windows (no effect on Linux)
    cmd = ['git', '-c', 'core.longpaths=true', *args]
    log('RUN', ' '.join(cmd))
    r = subprocess.run(cmd, cwd=cwd, check=True, text=True, capture_output=capture)
    return r.stdout.strip() if capture else None


def head(repo):
    r = subprocess.run(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True, capture_output=True)
    return r.stdout.strip() if r.returncode == 0 else ''


def tops_and_subs(rows):
    tops = [r for r in rows if '/' not in r['path']]
    subs = {t['name']: [s for s in rows if s['path'].startswith(t['path'] + '/')] for t in tops}
    return tops, subs


def verify(dest, rows):
    ok = True
    for r in rows:
        repo = dest / r['path']
        if not (repo / '.git').exists():
            print(f'  [{"NG" if r["required"] else "--"}] {r["name"]}: ありません（{repo}）')
            ok &= not r['required']
            continue
        got = head(repo)
        mark = 'OK' if got == r['commit'] else 'NG'
        ok &= got == r['commit']
        print(f'  [{mark}] {r["name"]}: {got[:12]}（lock {r["commit"][:12]}）')
    return ok


def latest(lock, rows, dry_run):
    """Upstream main head for each top repository, and the submodule commits its gitlinks record."""
    tops, subs = tops_and_subs(rows)
    new = {}
    with tempfile.TemporaryDirectory(prefix='hako_latest_') as tmp:
        for t in tops:
            sha = git('ls-remote', t['url'], 'HEAD', capture=True).split()[0]
            new[t['name']] = sha
            if subs[t['name']]:
                d = Path(tmp) / t['name']
                git('clone', '--quiet', '--filter=blob:none', '--no-checkout', t['url'], str(d))
                for s in subs[t['name']]:
                    rel = s['path'][len(t['path']) + 1:]
                    link = git('-C', str(d), 'ls-tree', sha, rel, capture=True).split()
                    if len(link) < 3:
                        sys.exit(f'{t["name"]}@{sha[:12]} has no submodule {rel}')
                    new[s['name']] = link[2]
    changed = False
    for r in rows:
        mark = '  ' if new[r['name']] == r['commit'] else '→ '
        changed |= new[r['name']] != r['commit']
        print(f'  {mark}{r["name"]:22} {r["commit"][:12]} → {new[r["name"]][:12]}')
    if not changed:
        log('lock は上流の最新と同じです')
        return
    if dry_run:
        log('--dry-run: lock は書き換えていません')
        return
    text = lock.read_text(encoding='utf-8')
    for r in rows:
        text = text.replace(r['commit'], new[r['name']])
    lock.write_bytes(text.encode('utf-8'))
    log(f'{lock} を書き換えました。次: fetch_third_party.py --refresh → SDK を作り直す → 確かめてからコミット'
        '（docs/hako_core_update.md）')


def clone(dest, rows):
    tops, subs = tops_and_subs(rows)
    dest.mkdir(parents=True, exist_ok=True)
    for t in tops:
        repo = dest / t['path']
        if repo.exists():
            continue
        git('clone', '--no-checkout', t['url'], str(repo))
        git('-C', str(repo), 'checkout', '--quiet', '--detach', t['commit'])
        if subs[t['name']]:
            rels = []
            for s in subs[t['name']]:
                rel = s['path'][len(t['path']) + 1:]
                link = git('-C', str(repo), 'ls-tree', 'HEAD', rel, capture=True).split()
                if len(link) < 3 or link[2] != s['commit']:
                    sys.exit(f'lock の食い違い: {t["name"]} は {rel} を {link[2] if len(link) > 2 else "?"} で記録、'
                             f'lock は {s["commit"]}')
                rels.append(rel)
            git('-C', str(repo), 'submodule', 'update', '--init', '--', *rels)


def main():
    p = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    p.add_argument('--lock', type=Path, default=HERE / 'third_party.lock')
    p.add_argument('--dest', type=Path, default=DEFAULT_DEST, help=f'third_party の場所（既定 {DEFAULT_DEST}）')
    p.add_argument('--verify-only', action='store_true')
    p.add_argument('--latest', action='store_true', help='上流の main の先頭を lock に書く')
    p.add_argument('--dry-run', action='store_true', help='--latest で書き換えずに表示だけ')
    p.add_argument('--refresh', action='store_true', help='版が違う third_party を退避して取り直す')
    a = p.parse_args()
    rows = read_lock(a.lock)
    dest = a.dest.resolve()

    if a.latest:
        latest(a.lock, rows, a.dry_run)
        return
    if a.verify_only:
        log(f'照合 {dest}')
        sys.exit(0 if verify(dest, rows) else 1)

    tops, _ = tops_and_subs(rows)
    present = [t for t in tops if (dest / t['path']).exists()]
    if present:
        log(f'照合 {dest}')
        if verify(dest, [r for r in rows if any(r['path'] == t['path'] or r['path'].startswith(t['path'] + '/')
                                                for t in present)]):
            if len(present) == len(tops):
                log('OK（既にあります）')
                return
        elif not a.refresh:
            sys.exit('[fetch_third_party] third_party の版が lock と違います。'
                     '取り直すなら --refresh（今のものは third_party.old-<日時> に退避。中身は触らない）')
        else:
            old = dest.with_name(dest.name + '.old-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S'))
            log(f'退避 {dest} → {old}')
            shutil.move(str(dest), str(old))
    clone(dest, rows)
    log(f'照合 {dest}')
    if not verify(dest, rows):
        sys.exit(1)
    log('OK')


if __name__ == '__main__':
    main()
