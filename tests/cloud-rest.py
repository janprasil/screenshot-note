#!/usr/bin/env python3
"""Run the native client against a disposable loopback REST fixture."""
import datetime
import hashlib
import http.server
import json
import os
import secrets
import socket
import struct
import subprocess
import sys
import threading
import time
import urllib.parse
import uuid
import zlib

owner = str(uuid.uuid4())
connections, jobs, requests = {}, {}, []
shares, share_calls, share_statuses = {}, [], []
dropped = set()
errors = []
# Tým: /me libraries, týmová složka, library_id, author a ztráta členství.
team, team_folder, team_note, bob = (str(uuid.uuid4()) for _ in range(4))
team_state = {'member': True}
team_lists, team_rejects = [], []


def tiny_png():
    raw = b''.join(b'\x00' + b'\x10\x20\x30' * 2 for _ in range(2))
    def chunk(kind, body):
        return struct.pack('>I', len(body)) + kind + body + struct.pack('>I', zlib.crc32(kind + body) & 0xffffffff)
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 2, 2, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b'')


def png(data):
    assert data[:8] == b'\x89PNG\r\n\x1a\n'
    offset, compressed, types = 8, bytearray(), []
    while offset < len(data):
        length, = struct.unpack('>I', data[offset:offset + 4])
        kind = data[offset + 4:offset + 8]
        body = data[offset + 8:offset + 8 + length]
        crc, = struct.unpack('>I', data[offset + 8 + length:offset + 12 + length])
        assert crc == zlib.crc32(kind + body) & 0xffffffff
        types.append(kind)
        if kind == b'IHDR':
            width, height, depth, color, comp, filt, interlace = struct.unpack('>IIBBBBB', body)
            assert width == height == 2 and depth == 8 and color in (2, 6)
            assert comp == filt == interlace == 0
        elif kind == b'IDAT':
            compressed.extend(body)
        else:
            assert kind == b'IEND' and length == 0
        offset += length + 12
    assert types[0] == b'IHDR' and types[-1] == b'IEND'
    assert len(zlib.decompress(compressed)) == height * (1 + width * (4 if color == 6 else 3))


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass

    def body(self):
        assert 'Transfer-Encoding' not in self.headers
        length = int(self.headers.get('Content-Length', 0))
        assert 0 <= length <= 52428800
        return self.rfile.read(length)

    def reply(self, data, status=200):
        body = json.dumps({'data': data}).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def drop(self, stage):
        if stage not in dropped:
            dropped.add(stage)
            self.close_connection = True
            self.connection.shutdown(socket.SHUT_RDWR)
            self.connection.close()
            return True
        return False

    def error(self, status, code, retry=None):
        body = json.dumps({'error': {'code': code, 'message': code}}).encode()
        self.send_response(status)
        if retry:
            self.send_header('Retry-After', retry)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def raw(self, body, kind='image/png'):
        self.send_response(200)
        self.send_header('Content-Type', kind)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def team(self):
        path, _, query = self.path.partition('?')
        params = urllib.parse.parse_qs(query)
        if path == '/api/v1/fixture/team':
            assert self.command == 'POST'
            body = json.loads(self.body())
            team_state['member'] = body['member']
            team_state['leave_after_folders'] = body.get('leave_after_folders', False)
            self.reply(dict(member=team_state['member']))
        elif path == '/api/v1/folders':
            assert self.command == 'GET'
            self.reply([dict(id=team_folder, name='Bugy', revision='1', description='', combined=False, combined_file='Bugy.md',
                             markdown_template=None, combined_template=None, owner_id=team, owner_kind='team',
                             owner_name='Fixture tým', role='member')] if team_state['member'] else [])
            # Souběh: přístup zmizí hned po katalogu.
            if team_state.pop('leave_after_folders', False):
                team_state['member'] = False
                team_state['raced'] = True
        elif path == '/api/v1/sessions':
            assert self.command == 'GET' and params['folder_id'] == [team_folder] and params['library_id'] == [team]
            team_lists.append(query)
            # Nedostupná library vrací prázdný seznam (API-V1), ne 404.
            items = [] if params.get('state') == ['trashed'] or not team_state['member'] else [
                dict(id=team_note, updated_at='2026-11-20T00:00:00Z', created_at='2026-11-20T00:00:00Z', trashed_at=None,
                     author=dict(id=bob, name='Fixture Bob'))]
            self.send_list(items)
        elif path == '/api/v1/sessions/' + team_note:
            if not team_state['member']:
                self.error(404, 'not_found')
                return True
            self.reply(dict(id=team_note, title='Týmový bug', comment='Popis', template='# {title}\n\nAutor: {author}\n\n{screenshots}\n\n{text}\n',
                            captions=[''], updated_at='2026-11-20T00:00:00Z', created_at='2026-11-20T00:00:00Z', owner_id=team, owner_kind='team',
                            author=dict(id=bob, name='Fixture Bob'), images=[dict(index=1, path='/api/v1/sessions/' + team_note + '/images/1')]))
        elif path == '/api/v1/sessions/' + team_note + '/images/1':
            self.raw(tiny_png())
        else:
            return False
        return True

    def send_list(self, items):
        body = json.dumps({'data': items, 'pagination': {'has_more': False}}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def share(self, token):
        assert self.command == 'POST' and connections[token]['active']
        assert self.headers['Content-Type'] == 'application/json'
        assert json.loads(self.body()) == {'audience': 'public'}
        ident = self.path.split('/')[4]
        uuid.UUID(ident)
        share_calls.append(ident)
        address = 'http://127.0.0.1:' + str(self.server.server_port)
        special = {'00000000-0000-4000-8000-000000000409': (409, 'session_trashed'),
                   '00000000-0000-4000-8000-000000000403': (403, 'role_forbidden'),
                   '00000000-0000-4000-8000-000000000413': (413, 'resource_limit'),
                   '00000000-0000-4000-8000-000000000503': (503, 'service_unavailable'),
                   '00000000-0000-4000-8000-000000000401': (400, 'invalid_parameters'),
                   '00000000-0000-4000-8000-000000000429': (429, 'rate_limited'),
                   '00000000-0000-4000-8000-000000000430': (429, 'rate_limited')}
        if ident in special:
            self.error(*special[ident], retry='60' if ident.endswith('429') else None)
            return
        if ident == '00000000-0000-4000-8000-000000000400':
            self.reply(dict(id=str(uuid.uuid4()), audience='public', image_urls=[], created_at='2026-11-20T00:00:00Z',
                            url='https://foreign.invalid/s/sn_share_v1_' + secrets.token_urlsafe(32)), 201)
            return
        if ident not in jobs or jobs[ident]['state'] != 'committed':
            self.error(404, 'not_found')
            return
        status = 200 if ident in shares else 201
        share_statuses.append(status)
        link = shares.setdefault(ident, dict(id=str(uuid.uuid4()), audience='public',
                                             url=address + '/s/sn_share_v1_' + secrets.token_urlsafe(32),
                                             created_at='2026-11-20T00:00:00Z'))
        self.reply(dict(link, image_urls=[link['url'] + '/' + ident + '/1.png']), status)

    def serve(self):
        try:
            assert self.path.startswith('/api/v1/') and ('?' not in self.path or self.path.startswith('/api/v1/sessions?'))
            assert all(h not in self.headers for h in ('Cookie', 'Origin', 'apikey'))
            requests.append((self.command, self.path))
            if self.path == '/api/v1/device-pairings':
                assert self.command == 'POST' and 'Authorization' not in self.headers
                body = json.loads(self.body())
                assert set(body) == {'device_name'}
                if body['device_name'] == 'Rate fixture':
                    self.send_response(429)
                    self.send_header('Retry-After', '60')
                    self.send_header('Content-Length', '2')
                    self.end_headers()
                    self.wfile.write(b'{}')
                    return
                token = 'sn_device_v1_' + secrets.token_urlsafe(32)
                ident = str(uuid.uuid4())
                connections[token] = {'id': ident, 'active': False}
                address = 'http://127.0.0.1:' + str(self.server.server_port)
                uri = address + '/pair-device/' + ident
                if body['device_name'] == 'Unsafe URI':
                    uri = 'https://foreign.invalid/pair-device/' + ident
                expiry = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(minutes=10)).isoformat()
                self.reply(dict(id=ident, device_token=token, verification_uri=uri,
                                comparison_code='AB12CD34', expires_at=expiry, interval=5), 201)
                return
            assert self.headers.get('Authorization', '').startswith('Bearer ')
            token = self.headers['Authorization'][7:]
            assert token in connections
            if self.path == '/api/v1/device-pairing':
                if self.command == 'DELETE':
                    assert not connections[token]['active']
                    self.reply(dict(state='denied', expires_at='2099-01-01T00:00:00Z', interval=5))
                else:
                    connections[token]['active'] = True
                    self.reply(dict(state='active', expires_at='2099-01-01T00:00:00Z', interval=5))
            elif self.path == '/api/v1/me':
                libraries = [dict(id=owner, kind='personal', name=None, role='owner')]
                if team_state['member']:
                    libraries.append(dict(id=team, kind='team', name='Fixture tým', role='member'))
                self.reply(dict(id=owner, email='fixture@example.test', libraries=libraries))
            elif self.team():
                pass
            elif self.path.startswith('/api/v1/sessions/') and self.path.endswith('/share'):
                self.share(token)
            else:
                parts = self.path.split('/')
                assert parts[3] == 'uploads'
                ident = parts[4]
                uuid.UUID(ident)
                if len(parts) == 5:
                    assert self.command == 'PUT'
                    manifest = json.loads(self.body())
                    assert set(manifest) - {'folder_id'} == {'title', 'comment', 'configuration', 'template', 'captions', 'images'}
                    assert len(manifest['images']) == len(manifest['captions']) == 1
                    # Po ztrátě členství je týmová složka nedostupná.
                    if (manifest.get('folder_id') or '').lower() == team_folder and not team_state['member']:
                        team_rejects.append(ident)
                        self.error(404, 'not_found')
                        return
                    if ident not in jobs:
                        digest = hashlib.sha256(json.dumps(manifest, sort_keys=True).encode()).hexdigest()
                        jobs[ident] = dict(manifest=manifest, digest=digest, images={}, state='uploading')
                        if len(jobs) > 1:
                            time.sleep(0.3)
                    assert jobs[ident]['manifest'] == manifest
                    if self.drop('manifest'):
                        return
                elif parts[5] == 'images':
                    assert self.command == 'PUT' and self.headers['Content-Type'] == 'image/png'
                    index = int(parts[6])
                    data = self.body()
                    image = jobs[ident]['manifest']['images'][index - 1]
                    assert len(data) == image['bytes'] and hashlib.sha256(data).hexdigest() == image['sha256']
                    png(data)
                    jobs[ident]['images'][index] = data
                    if self.drop('image'):
                        return
                    self.reply(dict(session_id=ident, index=index, confirmed=True), 201)
                    return
                else:
                    assert self.command == 'POST' and parts[5] == 'commit' and not self.body()
                    assert set(jobs[ident]['images']) == {1}
                    jobs[ident]['state'] = 'committed'
                    if self.drop('commit'):
                        return
                self.reply(dict(session_id=ident, state=jobs[ident]['state'], manifest_digest=jobs[ident]['digest'],
                                confirmed_indices=list(jobs[ident]['images'])))
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as error:
            errors.append(type(error).__name__)
            self.reply({}, 500)

    do_GET = do_POST = do_PUT = do_DELETE = serve


assert len(sys.argv) == 2, 'Supply the built ScreenshotNote binary.'
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
try:
    env = {'PATH': os.environ['PATH'], 'SCREENSHOT_NOTE_TEST_URL': 'http://127.0.0.1:' + str(server.server_port)}
    result = subprocess.run([sys.argv[1], '--cloud-self-test'], env=env, capture_output=True, text=True, timeout=90)
    assert result.returncode == 0, result.stdout + result.stderr
    assert not errors, errors
    assert dropped == {'manifest', 'image', 'commit'}
    assert sum(1 for method, path in requests if method == 'DELETE') == 1
    assert len(jobs) == 4 and all(job['state'] == 'committed' for job in jobs.values())
    # Týmový upload po ztrátě členství: jeden 404, žádná smyčka, po návratu nahrán ručně.
    assert len(team_rejects) == 2 and sum(1 for job in jobs.values() if (job['manifest'].get('folder_id') or '').lower() == team_folder) == 1
    assert team_lists and all('library_id=' + team in query for query in team_lists)
    assert team_state.get('raced') and any(path == '/api/v1/sessions/' + team_note for _, path in requests)
    assert len(shares) == 1 and share_calls.count(next(iter(shares))) == 3
    assert share_calls.count('00000000-0000-4000-8000-000000000429') == 1
    # 12 volání: druhý pokus během Retry-After se na server nedostane.
    assert len(share_calls) == 12 and share_statuses == [201, 200, 200]
    assert all('/auth/' not in path and '/storage/' not in path and '/rest/' not in path for _, path in requests)
    print(result.stdout.strip())
    print('PASS: team folder wire contract (/me libraries, owner fields, library_id, author, membership loss → hidden folder and parked upload without retry loop)')
    print('PASS: loopback-only wire contract, share endpoint (POST public, 201/200 same URL, Retry-After honored), no upstream key/cookies, CRC/RGB8 PNG, frozen manifest and lost-response recovery')
finally:
    server.shutdown()
    server.server_close()
    thread.join()
