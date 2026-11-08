#!/usr/bin/env python3
"""The inbox over HTTPS: an agent in a cloud sandbox works its node's inbox
(scripts/bidder-inbox.sh puts the node's requests there) from anywhere it can
make HTTPS requests. One server serves every agent on the machine; each agent
has a token and sees only its own inbox. It listens on localhost: a tunnel
(cloudflared) gives it a public hostname, and adds TLS.

  inbox-http.py serve CONFIG              run the server
  inbox-http.py token CONFIG AGENT INBOX  make AGENT a token (printed once) for INBOX

CONFIG is a JSON file: {"listen": "127.0.0.1:8787", "url": "https://...",
"agents": {"claude": {"token_sha256": "...", "inbox": "/path"}}}. `token`
creates it. The API, as an agent sees it, is in deploy/cloud/agent.md, and
GET /v1/instructions serves it with the agent's name and URL filled in.
"""
import hashlib, hmac, http.server, io, json, os, re, subprocess, sys, tarfile, time, secrets, threading

ID = re.compile(r'^[0-9]+-[0-9a-f]+$')
WAIT_MAX = 55            # Cloudflare ends a response at 100 s
BODY_MAX = 8 * 1024 * 1024
HERE = os.path.dirname(os.path.abspath(__file__))


def read(path, default=''):
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return default


def write_atomic(path, text):
    tmp = path + '.tmp'
    with open(tmp, 'w') as f:
        f.write(text)
    os.rename(tmp, path)


def open_requests(inbox):
    try:
        names = sorted(os.listdir(inbox))
    except OSError:
        return []
    return [d for d in names if ID.match(d) and os.path.isfile(os.path.join(inbox, d, 'prompt.txt'))
            and not os.path.exists(os.path.join(inbox, d, 'expired'))]


def seconds_left(r):
    try:
        return int(read(os.path.join(r, 'deadline')).strip()) - int(time.time())
    except ValueError:
        return 0


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = 'pantheon-inbox'
    config = {}

    # -- plumbing ---------------------------------------------------------
    def log_message(self, fmt, *args):
        sys.stderr.write('%s %s\n' % (time.strftime('%H:%M:%S'), fmt % args))

    def send(self, code, obj, headers=None):
        body = (json.dumps(obj, indent=1) + '\n').encode() if not isinstance(obj, (bytes, str)) else \
            (obj.encode() if isinstance(obj, str) else obj)
        self.send_response(code)
        ctype = 'application/json' if not isinstance(obj, (bytes, str)) else \
            ('text/markdown; charset=utf-8' if isinstance(obj, str) else 'application/gzip')
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def fail(self, code, why, next_step=None):
        obj = {'error': why}
        if next_step:
            obj['next'] = next_step
        self.send(code, obj)

    def body(self):
        n = int(self.headers.get('Content-Length') or 0)
        if n > BODY_MAX:
            raise ValueError('the body is %d bytes; the limit is %d' % (n, BODY_MAX))
        return self.rfile.read(n).decode('utf-8', 'replace')

    def agent(self):
        auth = self.headers.get('Authorization', '')
        token = auth[7:].strip() if auth.startswith('Bearer ') else ''
        digest = hashlib.sha256(token.encode()).hexdigest()
        for name, a in self.config.get('agents', {}).items():
            if token and hmac.compare_digest(digest, a.get('token_sha256', '')):
                return name, a['inbox']
        return None, None

    def request_dir(self, inbox, rid):
        if not ID.match(rid):
            self.fail(404, 'no request %s: ids look like 1794091815-1a2b3c4d' % rid, 'GET /v1/list')
            return None
        r = os.path.join(inbox, rid)
        if not os.path.isfile(os.path.join(r, 'prompt.txt')):
            self.fail(404, 'no request %s: it was answered, or it expired and the node moved on' % rid, 'GET /v1/wait')
            return None
        if os.path.exists(os.path.join(r, 'expired')):
            self.fail(410, 'request %s expired: the node moved on without it' % rid, 'GET /v1/wait')
            return None
        return r

    def next_for(self, rid, kind):
        if kind == 'patch':
            return ('GET /v1/checkout/%s.tar.gz, make the change there, then POST /v1/done/%s with '
                    '{"note": "one line on what you changed", "diff": "<the output of git diff>"}; '
                    'or POST /v1/skip/%s with {"why": "..."} if you won\'t bid' % (rid, rid, rid))
        return 'POST /v1/reply/%s with the JSON object the prompt asks for as the body, and nothing else' % rid

    def describe(self, r, rid):
        kind = read(os.path.join(r, 'kind')).strip()
        return {'id': rid, 'kind': kind, 'seconds_left': seconds_left(r),
                'prompt': read(os.path.join(r, 'prompt.txt')), 'next': self.next_for(rid, kind)}

    # -- routes ------------------------------------------------------------
    def do_GET(self):
        path = self.path.split('?', 1)[0]
        if path in ('/', '/health'):
            return self.send(200, {'service': 'pantheon inbox', 'next': 'GET /v1/instructions with your token: '
                                   'Authorization: Bearer <token>'})
        name, inbox = self.agent()
        if not name:
            return self.fail(401, 'no valid token: send the header "Authorization: Bearer <your token>"')
        if path == '/v1/instructions':
            text = read(os.path.join(HERE, '..', 'deploy', 'cloud', 'agent.md'))
            text = text.replace('{{AGENT}}', name).replace('{{URL}}', self.config.get('url', ''))
            return self.send(200, text)
        if path == '/v1/wait':
            q = dict(p.split('=', 1) for p in self.path.split('?', 1)[1].split('&') if '=' in p) if '?' in self.path else {}
            try:
                limit = max(0, min(WAIT_MAX, int(q.get('seconds', WAIT_MAX))))
            except ValueError:
                limit = WAIT_MAX
            end = time.time() + limit
            while True:
                for rid in open_requests(inbox):
                    r = os.path.join(inbox, rid)
                    try:   # claim it: one taker, even with two waits at once
                        os.close(os.open(os.path.join(r, 'claimed'), os.O_CREAT | os.O_EXCL | os.O_WRONLY))
                    except FileExistsError:
                        continue
                    return self.send(200, self.describe(r, rid))
                if time.time() >= end:
                    return self.send(200, {'id': None, 'next': 'no request yet: GET /v1/wait again'})
                time.sleep(1)
        if path == '/v1/list':
            out = []
            for rid in open_requests(inbox):
                r = os.path.join(inbox, rid)
                out.append({'id': rid, 'kind': read(os.path.join(r, 'kind')).strip(), 'seconds_left': seconds_left(r),
                            'taken': os.path.exists(os.path.join(r, 'claimed'))})
            return self.send(200, {'requests': out, 'next': 'GET /v1/request/ID to read one again'})
        m = re.match(r'^/v1/request/([^/]+)$', path)
        if m:
            r = self.request_dir(inbox, m.group(1))
            return r and self.send(200, self.describe(r, m.group(1)))
        m = re.match(r'^/v1/checkout/([^/]+)\.tar\.gz$', path)
        if m:
            rid = m.group(1)
            r = self.request_dir(inbox, rid)
            if not r:
                return
            if read(os.path.join(r, 'kind')).strip() != 'patch':
                return self.fail(400, '%s is not a patch request: it has no checkout' % rid, self.next_for(rid, 'answer'))
            wt = read(os.path.join(r, 'worktree')).strip()
            files = subprocess.run(['git', '-C', wt, 'ls-files', '-z'], capture_output=True).stdout.decode().split('\0')
            commit = subprocess.run(['git', '-C', wt, 'rev-parse', 'HEAD'], capture_output=True, text=True).stdout.strip()
            buf = io.BytesIO()
            with tarfile.open(fileobj=buf, mode='w:gz') as tar:
                for f in filter(None, files):
                    p = os.path.join(wt, f)
                    if os.path.lexists(p):
                        tar.add(p, arcname='checkout/' + f, recursive=False)
            return self.send(200, buf.getvalue(), {'X-Pantheon-Commit': commit,
                                                   'Content-Disposition': 'attachment; filename="%s.tar.gz"' % rid})
        self.fail(404, 'no such endpoint: %s' % path, 'GET /v1/instructions')

    def do_POST(self):
        path = self.path.split('?', 1)[0]
        name, inbox = self.agent()
        if not name:
            return self.fail(401, 'no valid token: send the header "Authorization: Bearer <your token>"')
        try:
            body = self.body()
        except ValueError as e:
            return self.fail(413, str(e))
        if path == '/v1/limited':
            if not body.strip():
                return self.fail(400, 'say what your provider said, with when it resets if it said')
            write_atomic(os.path.join(inbox, 'limited'), body[:2000])
            return self.send(200, {'ok': True, 'next': 'your node holds its requests until the limit should have reset; '
                                   'stop until then, then GET /v1/wait'})
        m = re.match(r'^/v1/(reply|done|skip)/([^/]+)$', path)
        if not m:
            return self.fail(404, 'no such endpoint: %s' % path, 'GET /v1/instructions')
        what, rid = m.groups()
        r = self.request_dir(inbox, rid)
        if not r:
            return
        kind = read(os.path.join(r, 'kind')).strip()
        if what == 'reply':
            if kind == 'patch':
                return self.fail(400, '%s is a patch request' % rid, self.next_for(rid, kind))
            try:
                if not isinstance(json.loads(body), dict):
                    raise ValueError
            except ValueError:
                return self.fail(400, 'the body must be the JSON object the prompt asks for, and nothing else',
                                 self.next_for(rid, kind))
            write_atomic(os.path.join(r, 'reply.txt'), body)
            return self.send(200, {'ok': True, 'next': 'GET /v1/wait'})
        if kind != 'patch':
            return self.fail(400, '%s is not a patch request' % rid, self.next_for(rid, kind))
        try:
            obj = json.loads(body)
            assert isinstance(obj, dict)
        except (ValueError, AssertionError):
            return self.fail(400, 'the body must be a JSON object', self.next_for(rid, kind))
        if what == 'skip':
            write_atomic(os.path.join(r, 'reply.txt'), json.dumps({'edits': [], 'note': 'skipped: ' + str(obj.get('why', ''))[:300]}))
            return self.send(200, {'ok': True, 'next': 'GET /v1/wait'})
        note, diff = str(obj.get('note', '')).strip(), obj.get('diff', '')
        if not isinstance(diff, str) or not diff.strip():
            return self.fail(400, 'no diff: send the output of `git diff` (after `git add -A`, `git diff --cached`, '
                             'so new files are in it) as "diff"; or POST /v1/skip/%s' % rid)
        if not note:
            return self.fail(400, 'no note: say in one line what you changed, as "note"')
        wt = read(os.path.join(r, 'worktree')).strip()
        if os.path.exists(os.path.join(r, 'done')):
            return self.fail(409, 'request %s was already handed in' % rid, 'GET /v1/wait')
        chk = subprocess.run(['git', '-C', wt, 'apply', '--check', '--whitespace=nowarn', '-'], input=diff.encode(), capture_output=True)
        if chk.returncode != 0:
            return self.fail(400, 'the diff does not apply to the checkout: ' + chk.stderr.decode('utf-8', 'replace')[-2000:],
                             'make it against an unchanged copy of GET /v1/checkout/%s.tar.gz and send it again' % rid)
        subprocess.run(['git', '-C', wt, 'apply', '--whitespace=nowarn', '-'], input=diff.encode(), check=True, capture_output=True)
        write_atomic(os.path.join(r, 'done'), note.splitlines()[0][:500] + '\n')
        return self.send(200, {'ok': True, 'next': 'handed in: your node turns the change into your bid. GET /v1/wait'})


def serve(config_path):
    cfg = json.load(open(config_path))
    Handler.config = cfg
    host, port = cfg.get('listen', '127.0.0.1:8787').rsplit(':', 1)
    srv = http.server.ThreadingHTTPServer((host, int(port)), Handler)
    srv.daemon_threads = True
    sys.stderr.write('inbox-http: serving %s on %s:%s\n' % (', '.join(cfg.get('agents', {})), host, port))
    srv.serve_forever()


def token(config_path, agent, inbox):
    cfg = json.load(open(config_path)) if os.path.exists(config_path) else {'listen': '127.0.0.1:8787', 'url': '', 'agents': {}}
    t = 'pti_' + secrets.token_urlsafe(32)
    cfg.setdefault('agents', {})[agent] = {'token_sha256': hashlib.sha256(t.encode()).hexdigest(), 'inbox': os.path.abspath(inbox)}
    write_atomic(config_path, json.dumps(cfg, indent=1) + '\n')
    os.chmod(config_path, 0o600)
    print(t)


if __name__ == '__main__':
    a = sys.argv[1:]
    if a[:1] == ['serve'] and len(a) == 2:
        serve(a[1])
    elif a[:1] == ['token'] and len(a) == 4:
        token(*a[1:])
    else:
        sys.stderr.write(__doc__)
        sys.exit(1)
