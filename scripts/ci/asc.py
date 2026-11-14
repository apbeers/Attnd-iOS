#!/usr/bin/env python3
"""
App Store Connect automation for CI (App Store Connect API, no fastlane).

    asc.py testflight --version 2.0.57 --build 57 [--group "Internal"]
        Wait for the uploaded build to finish processing, then add it to a TestFlight group.

    asc.py release --version 2.0.57 --build 57 --whats-new "..."
        Wait for processing, point the App Store version at this build, set release notes,
        and submit it for App Review (released automatically after approval).

Env: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8, ASC_BUNDLE_ID (default com.arcu.Attnd)
Requires: PyJWT + cryptography (pip install "pyjwt[crypto]").
"""

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

import jwt

API = 'https://api.appstoreconnect.apple.com'
# Versions that can still be edited / re-pointed at a new build
EDITABLE_STATES = 'PREPARE_FOR_SUBMISSION,READY_FOR_REVIEW,DEVELOPER_REJECTED,REJECTED,METADATA_REJECTED,INVALID_BINARY'


def token():
    now = int(time.time())
    return jwt.encode(
        {'iss': os.environ['ASC_ISSUER_ID'], 'iat': now, 'exp': now + 15 * 60, 'aud': 'appstoreconnect-v1'},
        os.environ['ASC_KEY_P8'], algorithm='ES256', headers={'kid': os.environ['ASC_KEY_ID'], 'typ': 'JWT'})


def call(method, path, params=None, body=None, ok=(200, 201, 204)):
    url = API + path + ('?' + urllib.parse.urlencode(params) if params else '')
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={
        'Authorization': f'Bearer {token()}', 'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            raw = resp.read()
            return resp.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as err:
        payload = err.read().decode(errors='replace')
        if err.code in ok:
            return err.code, {}
        return err.code, {'_error': payload}


def must(method, path, params=None, body=None):
    status, data = call(method, path, params, body)
    if status >= 300:
        sys.exit(f'{method} {path} failed ({status}): {data.get("_error", "")[:800]}')
    return data


def app_id(bundle_id):
    data = must('GET', '/v1/apps', {'filter[bundleId]': bundle_id})
    if not data['data']:
        sys.exit(f'No App Store Connect app with bundle id {bundle_id}')
    return data['data'][0]['id']


def wait_for_build(app, version, build, timeout_min=60):
    deadline = time.time() + timeout_min * 60
    while time.time() < deadline:
        data = must('GET', '/v1/builds', {'filter[app]': app, 'filter[version]': build,
                                          'filter[preReleaseVersion.version]': version,
                                          'fields[builds]': 'processingState,version'})
        if data['data']:
            b = data['data'][0]
            state = b['attributes']['processingState']
            print(f'Build {version} ({build}): {state}')
            if state == 'VALID':
                return b['id']
            if state in ('FAILED', 'INVALID'):
                sys.exit(f'Build processing ended in {state}')
        else:
            print(f'Build {version} ({build}) not visible yet')
        time.sleep(30)
    sys.exit('Timed out waiting for build processing')


def testflight(args, app):
    build = wait_for_build(app, args.version, args.build)
    if not args.group:
        print('No TestFlight group given; internal groups with automatic distribution get it automatically.')
        return
    groups = must('GET', '/v1/betaGroups', {'filter[app]': app, 'filter[name]': args.group})['data']
    if not groups:
        sys.exit(f'No TestFlight group named "{args.group}"')
    status, data = call('POST', f'/v1/betaGroups/{groups[0]["id"]}/relationships/builds',
                        body={'data': [{'type': 'builds', 'id': build}]})
    if status >= 300 and 'already' not in data.get('_error', '').lower():
        sys.exit(f'Adding build to group failed ({status}): {data.get("_error", "")[:500]}')
    print(f'Build {args.build} is available to TestFlight group "{args.group}"')


def release(args, app):
    build = wait_for_build(app, args.version, args.build)

    # Reuse an editable version if one exists (renaming it), otherwise create one.
    versions = must('GET', f'/v1/apps/{app}/appStoreVersions',
                    {'filter[platform]': 'IOS', 'filter[appVersionState]': EDITABLE_STATES})['data']
    if versions:
        version_id = versions[0]['id']
        if versions[0]['attributes']['versionString'] != args.version:
            must('PATCH', f'/v1/appStoreVersions/{version_id}', body={'data': {
                'type': 'appStoreVersions', 'id': version_id, 'attributes': {'versionString': args.version}}})
    else:
        version_id = must('POST', '/v1/appStoreVersions', body={'data': {
            'type': 'appStoreVersions',
            'attributes': {'platform': 'IOS', 'versionString': args.version, 'releaseType': 'AFTER_APPROVAL'},
            'relationships': {'app': {'data': {'type': 'apps', 'id': app}}}}})['data']['id']
    print(f'App Store version {args.version}: {version_id}')

    must('PATCH', f'/v1/appStoreVersions/{version_id}/relationships/build',
         body={'data': {'type': 'builds', 'id': build}})

    if args.whats_new:
        locs = must('GET', f'/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations')['data']
        for loc in locs:
            status, data = call('PATCH', f'/v1/appStoreVersionLocalizations/{loc["id"]}', body={'data': {
                'type': 'appStoreVersionLocalizations', 'id': loc['id'],
                'attributes': {'whatsNew': args.whats_new[:4000]}}})
            if status >= 300:  # the very first version of an app has no "What's New"
                print(f'Skipping release notes for {loc["attributes"]["locale"]}: {status}')

    # Find or create a review submission, add the version, submit.
    open_subs = must('GET', '/v1/reviewSubmissions', {'filter[app]': app, 'filter[platform]': 'IOS',
                                                      'filter[state]': 'READY_FOR_REVIEW'})['data']
    if open_subs:
        sub_id = open_subs[0]['id']
    else:
        sub_id = must('POST', '/v1/reviewSubmissions', body={'data': {
            'type': 'reviewSubmissions', 'attributes': {'platform': 'IOS'},
            'relationships': {'app': {'data': {'type': 'apps', 'id': app}}}}})['data']['id']
    status, data = call('POST', '/v1/reviewSubmissionItems', body={'data': {
        'type': 'reviewSubmissionItems',
        'relationships': {'reviewSubmission': {'data': {'type': 'reviewSubmissions', 'id': sub_id}},
                          'appStoreVersion': {'data': {'type': 'appStoreVersions', 'id': version_id}}}}})
    if status >= 300 and 'already' not in data.get('_error', '').lower():
        sys.exit(f'Adding version to review submission failed ({status}): {data.get("_error", "")[:800]}')
    must('PATCH', f'/v1/reviewSubmissions/{sub_id}', body={'data': {
        'type': 'reviewSubmissions', 'id': sub_id, 'attributes': {'submitted': True}}})
    print(f'Submitted {args.version} ({args.build}) for App Review; it releases automatically when approved.')


def check():
    """Fail fast with a clear explanation if the App Store Connect key can't be used."""
    p8 = os.environ.get('ASC_KEY_P8', '')
    problems = []
    if 'BEGIN PRIVATE KEY' not in p8 or 'END PRIVATE KEY' not in p8:
        problems.append('ASC_KEY_P8 does not look like a complete .p8 file (needs the BEGIN/END PRIVATE KEY lines).')
    if len(os.environ.get('ASC_KEY_ID', '')) != 10:
        problems.append('ASC_KEY_ID should be the 10-character Key ID.')
    issuer = os.environ.get('ASC_ISSUER_ID', '')
    if len(issuer) != 36 or issuer.count('-') != 4:
        problems.append('ASC_ISSUER_ID should be the Issuer ID UUID shown above the keys list (xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx).')
    if problems:
        sys.exit('App Store Connect key problem:\n- ' + '\n- '.join(problems))
    status, data = call('GET', '/v1/apps', {'filter[bundleId]': os.environ.get('ASC_BUNDLE_ID', 'com.arcu.Attnd')})
    if status == 401:
        sys.exit('App Store Connect rejected the key (401). Check: the Issuer ID matches the key, the Key ID is right, '
                 'the key is a TEAM key (not an Individual key), and it was not revoked.')
    if status == 403:
        sys.exit('The App Store Connect key works but lacks access (403). It needs the Admin role for cloud signing.')
    if status >= 300:
        sys.exit(f'App Store Connect check failed ({status}): {data.get("_error", "")[:300]}')
    if not data.get('data'):
        sys.exit('Key works, but no app with bundle id com.arcu.Attnd is visible to it.')
    print('App Store Connect key OK; app', data['data'][0]['attributes'].get('name'))


def main():
    if len(sys.argv) > 1 and sys.argv[1] == 'check':
        return check()
    parser = argparse.ArgumentParser()
    parser.add_argument('command', choices=['testflight', 'release'])
    parser.add_argument('--version', required=True)
    parser.add_argument('--build', required=True)
    parser.add_argument('--group', default='')
    parser.add_argument('--whats-new', default='')
    args = parser.parse_args()
    app = app_id(os.environ.get('ASC_BUNDLE_ID', 'com.arcu.Attnd'))
    (testflight if args.command == 'testflight' else release)(args, app)


if __name__ == '__main__':
    main()
