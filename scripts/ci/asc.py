#!/usr/bin/env python3
"""
App Store Connect automation for CI (App Store Connect API, no fastlane).

    asc.py testflight --version 2.0.57 --build 57 [--group "Internal"]
        Wait for the uploaded build to finish processing, then add it to a TestFlight group.

    asc.py release --version 2.0.57 --build 57 --whats-new "..." [--submit]
        Wait for processing, point the App Store version at this build and set release notes;
        with --submit also submit it for App Review (released automatically after approval).

    asc.py submit
        Submit the editable App Store version (with the build already attached to it) for App Review;
        released automatically after approval. For a version a release run prepared without --submit.

    asc.py metadata [--store store] [--locale en-US] [--version 2.0] [--dry-run]
        Validate the listing text in store/<locale>/ and set it on the editable App Store version:
        version localization (description, keywords, promotional text, what's new, support and
        marketing URLs), app info localization (name, subtitle, privacy policy URL) and the App Review
        details (notes, no demo account; contact from REVIEW_CONTACT_FIRST_NAME / _LAST_NAME / _PHONE /
        _EMAIL when set). --dry-run only validates (no key needed).

    asc.py screenshots [--dir build/screenshots/composed] [--locale en-US] [--version 2.0]
        Replace the editable version's screenshots for our display types with the composed PNGs
        (<dir>/iphone-69 -> APP_IPHONE_67, iphone-63 -> APP_IPHONE_61, iphone-duo (unfolded) then
        iphone-duo-cover (folded) -> APP_IPHONE_DUO),
        in file-name order, and wait until App Store Connect has processed them.

    The editable version is the one in an editable state (e.g. Prepare for Submission). metadata and
    screenshots never rename it; --version is only used to create one when none exists. Nothing goes
    live until that version is submitted and released.

Env: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8, ASC_BUNDLE_ID (default com.arcu.Attnd)
Requires: PyJWT + cryptography (pip install "pyjwt[crypto]").
"""

import argparse
import datetime
import hashlib
import json
import os
import pathlib
import struct
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

API = 'https://api.appstoreconnect.apple.com'
# Versions that can still be edited / re-pointed at a new build
EDITABLE_STATES = 'PREPARE_FOR_SUBMISSION,READY_FOR_REVIEW,DEVELOPER_REJECTED,REJECTED,METADATA_REJECTED,INVALID_BINARY'


def token():
    import jwt  # PyJWT; imported here so `metadata --dry-run` runs without it

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
    groups = must('GET', '/v1/betaGroups', {'filter[app]': app, 'limit': 200,
                                            'fields[betaGroups]': 'name,isInternalGroup,hasAccessToAllBuilds'})['data']
    wanted = args.group.strip().casefold()
    match = [g for g in groups if g['attributes'].get('name', '').strip().casefold() == wanted]
    if not match:
        names = ', '.join(f'"{g["attributes"].get("name")}"' for g in groups) or 'none'
        print(f'::warning::No TestFlight group named "{args.group}" (groups: {names}). '
              'Internal groups with automatic distribution still get the build.')
        return
    group = match[0]
    if group['attributes'].get('isInternalGroup') and group['attributes'].get('hasAccessToAllBuilds'):
        print(f'Build {args.build} is available: "{args.group}" is an internal group that gets every build automatically')
        return
    groups = match
    status, data = call('POST', f'/v1/betaGroups/{groups[0]["id"]}/relationships/builds',
                        body={'data': [{'type': 'builds', 'id': build}]})
    if status >= 300 and 'already' not in data.get('_error', '').lower():
        sys.exit(f'Adding build to group failed ({status}): {data.get("_error", "")[:500]}')
    print(f'Build {args.build} is available to TestFlight group "{args.group}"')


def editable_version(app, version=None, rename=False):
    """The editable App Store version (id, versionString). Reuses one in an editable state (renaming
    it to `version` when `rename`), otherwise creates `version`."""
    versions = must('GET', f'/v1/apps/{app}/appStoreVersions',
                    {'filter[platform]': 'IOS', 'filter[appVersionState]': EDITABLE_STATES})['data']
    if versions:
        version_id = versions[0]['id']
        current = versions[0]['attributes']['versionString']
        if rename and version and current != version:
            must('PATCH', f'/v1/appStoreVersions/{version_id}', body={'data': {
                'type': 'appStoreVersions', 'id': version_id, 'attributes': {'versionString': version}}})
            current = version
        return version_id, current
    if not version:
        sys.exit('No editable App Store version, and no --version to create one with.')
    version_id = must('POST', '/v1/appStoreVersions', body={'data': {
        'type': 'appStoreVersions',
        'attributes': {'platform': 'IOS', 'versionString': version, 'releaseType': 'AFTER_APPROVAL'},
        'relationships': {'app': {'data': {'type': 'apps', 'id': app}}}}})['data']['id']
    print(f'Created App Store version {version}')
    return version_id, version


def release(args, app):
    build = wait_for_build(app, args.version, args.build)

    # Reuse an editable version if one exists (renaming it), otherwise create one.
    version_id, _ = editable_version(app, args.version, rename=True)
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

    if not args.submit:
        print(f'{args.version} ({args.build}) is attached to the App Store version with its listing; not submitted '
              '(submit it with the "Submit for App Review" workflow, or in App Store Connect).')
        return
    submit_version(app, version_id, f'{args.version} ({args.build})')


def submit(args, app):
    """Submit the editable version as it is (its attached build, listing and review notes)."""
    versions = must('GET', f'/v1/apps/{app}/appStoreVersions',
                    {'filter[platform]': 'IOS', 'filter[appVersionState]': EDITABLE_STATES})['data']
    if not versions:
        sys.exit('No editable App Store version to submit (nothing prepared, or it is already in review).')
    version_id = versions[0]['id']
    label = versions[0]['attributes']['versionString']
    build = must('GET', f'/v1/appStoreVersions/{version_id}/build')['data']
    if not build:
        sys.exit(f'App Store version {label} has no build attached yet; run the release first.')
    submit_version(app, version_id, f'{label} (build {build["attributes"].get("version")})')


# The App Clip card (default App Clip experience): a version that ships the App Clip can only be reviewed with
# one. Apple's rules (HIG, App Clips): header image 1800 x 1200 PNG/JPEG without transparency and without text,
# subtitle <= 56 characters, action OPEN for an app like ours. The title is the clip's display name.
CLIP_CARD_DIR = pathlib.Path('store/en-US')
CLIP_ACTION = 'OPEN'


def ensure_clip_card(app, version_id, locale='en-US'):
    clips = must('GET', f'/v1/apps/{app}/appClips')['data']
    if not clips:
        return
    clip = clips[0]['id']
    status, data = call('GET', f'/v1/appStoreVersions/{version_id}/appClipDefaultExperience')
    experience = data.get('data') if status < 300 else None
    if experience:
        experience_id = experience['id']
    else:
        # Copy the newest earlier card when there is one (its texts and image), else start a new one.
        earlier = must('GET', f'/v1/appClips/{clip}/appClipDefaultExperiences')['data']
        relationships = {'appClip': {'data': {'type': 'appClips', 'id': clip}},
                         'releaseWithAppStoreVersion': {'data': {'type': 'appStoreVersions', 'id': version_id}}}
        if earlier:
            relationships['appClipDefaultExperienceTemplate'] = {
                'data': {'type': 'appClipDefaultExperiences', 'id': earlier[-1]['id']}}
        experience_id = must('POST', '/v1/appClipDefaultExperiences', body={'data': {
            'type': 'appClipDefaultExperiences', 'attributes': {'action': CLIP_ACTION},
            'relationships': relationships}})['data']['id']
        print(f'App Clip card created for the version ({"copied from an earlier one" if earlier else "new"})')

    subtitle = (CLIP_CARD_DIR / 'app_clip_subtitle.txt').read_text().strip()[:56]
    localizations = must('GET', f'/v1/appClipDefaultExperiences/{experience_id}/appClipDefaultExperienceLocalizations')['data']
    localization = next((l for l in localizations if l['attributes'].get('locale') == locale), None)
    if localization is None:
        localization = must('POST', '/v1/appClipDefaultExperienceLocalizations', body={'data': {
            'type': 'appClipDefaultExperienceLocalizations', 'attributes': {'locale': locale, 'subtitle': subtitle},
            'relationships': {'appClipDefaultExperience': {
                'data': {'type': 'appClipDefaultExperiences', 'id': experience_id}}}}})['data']
    elif not localization['attributes'].get('subtitle'):
        must('PATCH', f'/v1/appClipDefaultExperienceLocalizations/{localization["id"]}', body={'data': {
            'type': 'appClipDefaultExperienceLocalizations', 'id': localization['id'],
            'attributes': {'subtitle': subtitle}}})

    status, data = call('GET', f'/v1/appClipDefaultExperienceLocalizations/{localization["id"]}/appClipHeaderImage')
    if status < 300 and data.get('data'):
        print('App Clip card ready')
        return
    path = CLIP_CARD_DIR / 'app_clip_header.png'
    image = path.read_bytes()
    created = must('POST', '/v1/appClipHeaderImages', body={'data': {
        'type': 'appClipHeaderImages', 'attributes': {'fileName': path.name, 'fileSize': len(image)},
        'relationships': {'appClipDefaultExperienceLocalization': {
            'data': {'type': 'appClipDefaultExperienceLocalizations', 'id': localization['id']}}}}})['data']
    for operation in created['attributes'].get('uploadOperations') or []:
        offset, length = operation['offset'], operation['length']
        http_upload(operation, image[offset:offset + length])
    must('PATCH', f'/v1/appClipHeaderImages/{created["id"]}', body={'data': {
        'type': 'appClipHeaderImages', 'id': created['id'],
        'attributes': {'uploaded': True, 'sourceFileChecksum': hashlib.md5(image).hexdigest()}}})
    deadline = time.time() + 10 * 60
    while time.time() < deadline:
        state = (must('GET', f'/v1/appClipHeaderImages/{created["id"]}')['data']['attributes']
                 .get('assetDeliveryState') or {})
        if state.get('state') == 'COMPLETE':
            print('App Clip card ready (header image uploaded)')
            return
        if state.get('state') == 'FAILED':
            sys.exit(f'App Clip header image failed: {json.dumps(state.get("errors") or [])[:400]}')
        time.sleep(10)
    sys.exit('Timed out waiting for the App Clip header image to process')


def submit_version(app, version_id, label):
    ensure_clip_card(app, version_id)
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
    print(f'Submitted {label} for App Review; it releases automatically when approved.')


# --- Store listing: metadata ---------------------------------------------------------------------

# file in store/<locale>/ -> (max length, required)
LISTING_FILES = {
    'name': (30, True),
    'subtitle': (30, True),
    'promotional_text': (170, False),
    'description': (4000, True),
    'keywords': (100, True),
    'release_notes': (4000, False),
    'support_url': (None, True),
    'marketing_url': (None, False),
    'privacy_url': (None, True),
    'review_notes': (4000, False),
}


def read_listing(store, locale):
    """Reads and validates store/<locale>/*.txt. Exits with every problem listed."""
    folder = pathlib.Path(store) / locale
    texts, problems = {}, []
    for key, (limit, required) in LISTING_FILES.items():
        path = folder / f'{key}.txt'
        text = path.read_text(encoding='utf-8').strip() if path.exists() else ''
        texts[key] = text
        if required and not text:
            problems.append(f'{path} is missing or empty')
        if limit and len(text) > limit:
            problems.append(f'{path}: {len(text)} characters (max {limit})')
        if key.endswith('_url') and text and (not text.startswith('https://') or any(c.isspace() for c in text)):
            problems.append(f'{path}: not a single https:// URL')
    keywords = texts['keywords']
    if keywords:
        if '\n' in keywords:
            problems.append('keywords.txt: keep the keywords on one line')
        if ', ' in keywords or ' ,' in keywords:
            problems.append('keywords.txt: no spaces around commas (they count against the 100 characters)')
        words = [w.strip().casefold() for w in keywords.split(',')]
        if any(not w for w in words):
            problems.append('keywords.txt: empty keyword (double or trailing comma)')
        if len(set(words)) != len(words):
            problems.append('keywords.txt: repeated keyword')
        name = texts['name'].casefold()
        if name and any(name in w for w in words):
            problems.append('keywords.txt: don\'t repeat the app name (it is indexed already)')
    if problems:
        sys.exit('Store listing problems:\n- ' + '\n- '.join(problems))
    for key, (limit, _) in LISTING_FILES.items():
        if limit and texts[key]:
            print(f'  {key}: {len(texts[key])}/{limit}')
    return texts


def version_localization(version_id, locale):
    locs = must('GET', f'/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations', {'limit': 50})['data']
    for loc in locs:
        if loc['attributes'].get('locale') == locale:
            return loc['id']
    print(f'Creating the {locale} localization of the App Store version')
    return must('POST', '/v1/appStoreVersionLocalizations', body={'data': {
        'type': 'appStoreVersionLocalizations', 'attributes': {'locale': locale},
        'relationships': {'appStoreVersion': {'data': {'type': 'appStoreVersions', 'id': version_id}}}}})['data']['id']


# App info states in which name / subtitle / privacy URL can no longer be edited.
APP_INFO_LOCKED = {'ACCEPTED', 'IN_REVIEW', 'PENDING_RELEASE', 'READY_FOR_DISTRIBUTION', 'READY_FOR_SALE',
                   'REPLACED_WITH_NEW_INFO', 'WAITING_FOR_REVIEW', 'PROCESSING_FOR_APP_STORE',
                   'PENDING_DEVELOPER_RELEASE', 'PENDING_APPLE_RELEASE'}


def set_app_info(app, locale, texts):
    infos = must('GET', f'/v1/apps/{app}/appInfos', {'limit': 10})['data']
    editable = [i for i in infos if (i['attributes'].get('state') or i['attributes'].get('appStoreState')) not in APP_INFO_LOCKED]
    if not editable:
        states = ', '.join(str(i['attributes'].get('state') or i['attributes'].get('appStoreState')) for i in infos)
        print(f'::warning::No editable app info (states: {states}); name, subtitle and privacy URL not changed')
        return
    info_id = editable[0]['id']
    attributes = {'name': texts['name'], 'subtitle': texts['subtitle'], 'privacyPolicyUrl': texts['privacy_url']}
    locs = must('GET', f'/v1/appInfos/{info_id}/appInfoLocalizations', {'limit': 50})['data']
    match = [loc for loc in locs if loc['attributes'].get('locale') == locale]
    if match:
        must('PATCH', f'/v1/appInfoLocalizations/{match[0]["id"]}', body={'data': {
            'type': 'appInfoLocalizations', 'id': match[0]['id'], 'attributes': attributes}})
    else:
        must('POST', '/v1/appInfoLocalizations', body={'data': {
            'type': 'appInfoLocalizations', 'attributes': {'locale': locale, **attributes},
            'relationships': {'appInfo': {'data': {'type': 'appInfos', 'id': info_id}}}}})
    print(f'App info ({locale}): name "{texts["name"]}", subtitle "{texts["subtitle"]}", privacy policy URL')


def set_review_details(version_id, texts):
    attributes = {'demoAccountRequired': False, 'notes': texts['review_notes']}
    contact = {'contactFirstName': 'REVIEW_CONTACT_FIRST_NAME', 'contactLastName': 'REVIEW_CONTACT_LAST_NAME',
               'contactPhone': 'REVIEW_CONTACT_PHONE', 'contactEmail': 'REVIEW_CONTACT_EMAIL'}
    for attribute, env in contact.items():
        if os.environ.get(env, '').strip():
            attributes[attribute] = os.environ[env].strip()
    missing = [env for env in contact.values() if not os.environ.get(env, '').strip()]
    if missing:
        print(f'::notice::Not set (App Review contact left as it is): {", ".join(missing)}')
    status, data = call('GET', f'/v1/appStoreVersions/{version_id}/appStoreReviewDetail')
    if status == 200 and data.get('data'):
        detail_id = data['data']['id']
        must('PATCH', f'/v1/appStoreReviewDetails/{detail_id}', body={'data': {
            'type': 'appStoreReviewDetails', 'id': detail_id, 'attributes': attributes}})
    else:
        must('POST', '/v1/appStoreReviewDetails', body={'data': {
            'type': 'appStoreReviewDetails', 'attributes': attributes,
            'relationships': {'appStoreVersion': {'data': {'type': 'appStoreVersions', 'id': version_id}}}}})
    print('App Review details: notes, no demo account' + ('' if missing else ', contact'))


def metadata(args, app):
    version_id, version_string = editable_version(app, args.version)
    texts = args.texts
    print(f'Editable App Store version: {version_string} ({version_id})')

    loc_id = version_localization(version_id, args.locale)
    attributes = {'description': texts['description'], 'keywords': texts['keywords'],
                  'supportUrl': texts['support_url']}
    if texts['promotional_text']:
        attributes['promotionalText'] = texts['promotional_text']
    if texts['marketing_url']:
        attributes['marketingUrl'] = texts['marketing_url']
    must('PATCH', f'/v1/appStoreVersionLocalizations/{loc_id}', body={'data': {
        'type': 'appStoreVersionLocalizations', 'id': loc_id, 'attributes': attributes}})
    print(f'Version localization ({args.locale}): ' + ', '.join(attributes))

    # "What's New" doesn't exist for an app's first version.
    others = [v for v in must('GET', f'/v1/apps/{app}/appStoreVersions',
                              {'filter[platform]': 'IOS', 'limit': 200})['data'] if v['id'] != version_id]
    if texts['release_notes'] and others:
        status, data = call('PATCH', f'/v1/appStoreVersionLocalizations/{loc_id}', body={'data': {
            'type': 'appStoreVersionLocalizations', 'id': loc_id,
            'attributes': {'whatsNew': texts['release_notes']}}})
        if status >= 300:
            print(f'::warning::Release notes not set ({status}): {data.get("_error", "")[:300]}')
        else:
            print('Release notes set')
    elif texts['release_notes']:
        print('First version of the app: no release notes')

    set_app_info(app, args.locale, texts)
    set_review_details(version_id, texts)


# --- Store listing: screenshots ------------------------------------------------------------------

# Composed folder -> (display type, exact size). 1206x2622 is "iPhone with Dynamic Island (medium
# display)", APP_IPHONE_61; 1320x2868 is the large display, APP_IPHONE_67. APP_IPHONE_DUO (Nov 2026):
# not yet in Apple's ScreenshotDisplayType reference, but the live API creates the set and accepts uploads
# at the inner (2007x2853) and outer (1398x2034) display sizes. Duo screenshots are required from April 2027
# for apps built with the iOS 27.1 SDK or later (we are), and add the "made for iPhone Duo" badge.
# Folder -> (display type, exact size), in upload order. Several folders can share a display type: the
# iPhone Duo set gets the unfolded (inner display) screenshots first, then the folded (cover display) ones.
# (folder, display type, size, slot). Folders that share a slot are alternatives: screenshots.sh writes the
# unfolded iPhone Duo set to iphone-duo (portrait) or iphone-duo-wide (landscape), never both.
SCREENSHOT_TYPES = [
    ('iphone-69', 'APP_IPHONE_67', (1320, 2868), 'iPhone 6.9"'),
    ('iphone-63', 'APP_IPHONE_61', (1206, 2622), 'iPhone 6.3"'),
    ('iphone-duo', 'APP_IPHONE_DUO', (2007, 2853), 'iPhone Duo unfolded'),
    ('iphone-duo-wide', 'APP_IPHONE_DUO', (2853, 2007), 'iPhone Duo unfolded'),
    ('iphone-duo-cover', 'APP_IPHONE_DUO', (1398, 2034), 'iPhone Duo folded'),
]


def png_info(path):
    """(width, height, colour type) from the PNG header; colour type 2 = RGB, 6 = RGBA."""
    with open(path, 'rb') as f:
        head = f.read(26)
    if head[:8] != b'\x89PNG\r\n\x1a\n':
        sys.exit(f'{path} is not a PNG')
    width, height = struct.unpack('>II', head[16:24])
    return width, height, head[25]


def screenshot_plan(root):
    """[(display type, [paths])] with each display type once, files in folder then file-name order."""
    grouped, filled = {}, set()
    for folder, display_type, size, slot in SCREENSHOT_TYPES:
        files = sorted((pathlib.Path(root) / folder).glob('*.png'))
        if not files:
            continue
        filled.add(slot)
        for path in files:
            width, height, colour = png_info(path)
            if (width, height) != size or colour != 2:
                sys.exit(f'{path}: {width}x{height} colour type {colour}; expected {size[0]}x{size[1]} RGB')
        grouped.setdefault(display_type, []).extend(files)
    for slot in dict.fromkeys(slot for *_, slot in SCREENSHOT_TYPES):
        if slot not in filled:
            folders = ' or '.join(f'{root}/{f}' for f, *_, s in SCREENSHOT_TYPES if s == slot)
            print(f'::warning::No {slot} screenshots (expected in {folders})')
    for display_type, files in grouped.items():
        if len(files) > 10:
            sys.exit(f'{display_type}: {len(files)} screenshots (App Store maximum is 10)')
    if not grouped:
        sys.exit(f'No screenshots under {root}')
    return list(grouped.items())


def http_upload(operation, chunk):
    headers = {h['name']: h['value'] for h in operation.get('requestHeaders') or []}
    for attempt in range(1, 4):
        req = urllib.request.Request(operation['url'], data=chunk, method=operation['method'], headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                resp.read()
                return
        except (urllib.error.URLError, TimeoutError) as err:
            if attempt == 3:
                sys.exit(f'Uploading a screenshot part failed: {err}')
            time.sleep(5 * attempt)


def upload_screenshot(set_id, path):
    data = path.read_bytes()
    created = must('POST', '/v1/appScreenshots', body={'data': {
        'type': 'appScreenshots', 'attributes': {'fileName': path.name, 'fileSize': len(data)},
        'relationships': {'appScreenshotSet': {'data': {'type': 'appScreenshotSets', 'id': set_id}}}}})['data']
    for operation in created['attributes'].get('uploadOperations') or []:
        offset, length = operation['offset'], operation['length']
        http_upload(operation, data[offset:offset + length])
    must('PATCH', f'/v1/appScreenshots/{created["id"]}', body={'data': {
        'type': 'appScreenshots', 'id': created['id'],
        'attributes': {'uploaded': True, 'sourceFileChecksum': hashlib.md5(data).hexdigest()}}})
    return created['id']


def wait_for_screenshots(ids, timeout_min=15):
    pending, failed = dict(ids), []
    deadline = time.time() + timeout_min * 60
    while pending and time.time() < deadline:
        for screenshot_id, name in list(pending.items()):
            data = must('GET', f'/v1/appScreenshots/{screenshot_id}',
                        {'fields[appScreenshots]': 'assetDeliveryState,fileName'})['data']
            delivery = data['attributes'].get('assetDeliveryState') or {}
            state = delivery.get('state')
            if state == 'COMPLETE':
                del pending[screenshot_id]
            elif state == 'FAILED':
                del pending[screenshot_id]
                failed.append(f'{name}: {json.dumps(delivery.get("errors") or [])[:300]}')
        if pending:
            print(f'Waiting for App Store Connect to process {len(pending)} screenshot(s)')
            time.sleep(10)
    if failed:
        sys.exit('Screenshot processing failed:\n- ' + '\n- '.join(failed))
    if pending:
        sys.exit(f'Timed out waiting for {len(pending)} screenshot(s) to process')
    print(f'All {len(ids)} screenshots processed')


def screenshots(args, app):
    plan = args.plan
    version_id, version_string = editable_version(app, args.version)
    print(f'Editable App Store version: {version_string} ({version_id})')
    loc_id = version_localization(version_id, args.locale)

    sets = must('GET', f'/v1/appStoreVersionLocalizations/{loc_id}/appScreenshotSets', {'limit': 50})['data']
    print('Existing screenshot sets: ' + (', '.join(s['attributes']['screenshotDisplayType'] for s in sets) or 'none'))
    by_type = {s['attributes']['screenshotDisplayType']: s['id'] for s in sets}

    uploaded, skipped = {}, []
    for display_type, files in plan:
        set_id = by_type.get(display_type)
        if not set_id:
            status, data = call('POST', '/v1/appScreenshotSets', body={'data': {
                'type': 'appScreenshotSets', 'attributes': {'screenshotDisplayType': display_type},
                'relationships': {'appStoreVersionLocalization': {
                    'data': {'type': 'appStoreVersionLocalizations', 'id': loc_id}}}}})
            if status >= 300:
                # 409 lists the accepted display types; print them and carry on with the others.
                print(f'::warning::Could not create a {display_type} screenshot set ({status}): '
                      f'{data.get("_error", "")[:1500]}')
                skipped.append(display_type)
                continue
            set_id = data['data']['id']
        old = must('GET', f'/v1/appScreenshotSets/{set_id}/appScreenshots', {'limit': 50})['data']
        for screenshot in old:
            must('DELETE', f'/v1/appScreenshots/{screenshot["id"]}')
        ids = []
        for path in files:
            ids.append(upload_screenshot(set_id, path))
            uploaded[ids[-1]] = f'{display_type}/{path.name}'
        # Upload order is display order; set it explicitly anyway.
        must('PATCH', f'/v1/appScreenshotSets/{set_id}/relationships/appScreenshots',
             body={'data': [{'type': 'appScreenshots', 'id': i} for i in ids]})
        print(f'{display_type}: replaced {len(old)} with {len(ids)} screenshot(s)')

    if uploaded:
        wait_for_screenshots(uploaded)
    if skipped:
        print(f'::warning::Skipped display types: {", ".join(skipped)}')
    if len(skipped) == len(plan):
        sys.exit('No screenshot set could be updated')


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
        sys.exit('The App Store Connect key works but lacks access (403). It needs the Admin role.')
    if status >= 300:
        sys.exit(f'App Store Connect check failed ({status}): {data.get("_error", "")[:300]}')
    if not data.get('data'):
        sys.exit('Key works, but no app with bundle id com.arcu.Attnd is visible to it.')
    print('App Store Connect key OK; app', data['data'][0]['attributes'].get('name'))


def main():
    if len(sys.argv) > 1 and sys.argv[1] == 'check':
        return check()
    parser = argparse.ArgumentParser()
    parser.add_argument('command', choices=['testflight', 'release', 'submit', 'metadata', 'screenshots'])
    parser.add_argument('--submit', action='store_true',
                        help='release: also submit for App Review (default: prepare the version only)')
    parser.add_argument('--version', default='',
                        help='testflight/release: the build\'s version; metadata/screenshots: only used to '
                             'create a version when none is editable')
    parser.add_argument('--build', default='')
    parser.add_argument('--group', default='')
    parser.add_argument('--whats-new', default='')
    parser.add_argument('--store', default='store', help='metadata: folder with <locale>/*.txt')
    parser.add_argument('--locale', default='en-US')
    parser.add_argument('--dry-run', action='store_true', help='metadata: validate only')
    parser.add_argument('--dir', default='build/screenshots/composed', help='screenshots: composed PNGs')
    args = parser.parse_args()
    if args.command in ('testflight', 'release') and not (args.version and args.build):
        parser.error(f'{args.command} needs --version and --build')
    if args.command == 'metadata':
        args.texts = read_listing(args.store, args.locale)  # validate before touching anything
        if args.dry_run:
            print('Store listing OK')
            return
    if args.command == 'screenshots':
        args.plan = screenshot_plan(args.dir)  # validate sizes before touching anything
    app = app_id(os.environ.get('ASC_BUNDLE_ID', 'com.arcu.Attnd'))
    {'testflight': testflight, 'release': release, 'submit': submit, 'metadata': metadata, 'screenshots': screenshots}[args.command](args, app)


if __name__ == '__main__':
    main()
