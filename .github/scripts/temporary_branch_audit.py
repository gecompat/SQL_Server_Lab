import json
import os
import urllib.error
import urllib.parse
import urllib.request

TOKEN = os.environ['GH_TOKEN']
REPOSITORY = os.environ['REPOSITORY']
OWNER, _ = REPOSITORY.split('/', 1)
DEFAULT_BRANCH = 'main'
AUDIT_BRANCH = 'automation/branch-audit-cleanup-20260728'
API_ROOT = f'https://api.github.com/repos/{REPOSITORY}'


def request(path):
    req = urllib.request.Request(
        API_ROOT + path,
        headers={
            'Authorization': f'Bearer {TOKEN}',
            'Accept': 'application/vnd.github+json',
            'X-GitHub-Api-Version': '2022-11-28',
            'User-Agent': 'sql-server-lab-branch-audit',
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            body = response.read()
            return json.loads(body) if body else None
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode('utf-8', errors='replace')
        raise RuntimeError(f'GET {path} failed: HTTP {exc.code}: {detail}') from exc


def paged(path):
    page = 1
    items = []
    while True:
        separator = '&' if '?' in path else '?'
        batch = request(f'{path}{separator}per_page=100&page={page}')
        if not batch:
            return items
        items.extend(batch)
        if len(batch) < 100:
            return items
        page += 1


def classify(branch):
    compare_ref = urllib.parse.quote(f'{DEFAULT_BRANCH}...{branch}', safe='.../')
    comparison = request(f'/compare/{compare_ref}')
    ahead = int(comparison.get('ahead_by', 0))
    behind = int(comparison.get('behind_by', 0))
    status = comparison.get('status', 'unknown')

    head = urllib.parse.quote(f'{OWNER}:{branch}', safe=':')
    pull_requests = paged(f'/pulls?state=all&head={head}')
    open_prs = [pr['number'] for pr in pull_requests if pr.get('state') == 'open']
    merged_prs = [pr['number'] for pr in pull_requests if pr.get('merged_at')]

    if branch == AUDIT_BRANCH:
        decision = 'TEMP_AUDIT_BRANCH'
    elif open_prs:
        decision = 'KEEP_OPEN_PR'
    elif ahead == 0:
        decision = 'DELETE_NO_UNIQUE_COMMITS'
    elif merged_prs:
        decision = 'DELETE_MERGED_PR'
    elif branch.startswith('test/'):
        decision = 'DELETE_TEMP_TEST'
    else:
        decision = 'KEEP_UNIQUE_CHANGES'

    return {
        'branch': branch,
        'decision': decision,
        'ahead_by': ahead,
        'behind_by': behind,
        'status': status,
        'open_prs': open_prs,
        'merged_prs': merged_prs,
    }


for branch_info in paged('/branches'):
    branch = branch_info['name']
    if branch == DEFAULT_BRANCH:
        print('AUDIT\t' + json.dumps({'branch': branch, 'decision': 'DEFAULT_BRANCH'}, sort_keys=True))
        continue
    print('AUDIT\t' + json.dumps(classify(branch), sort_keys=True))
