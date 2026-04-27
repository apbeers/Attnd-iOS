# iOS Release Pipeline — Setup Guide

The workflow at `.github/workflows/ios-release.yml` triggers on every push to
`main` and uploads a signed IPA to App Store Connect. You must add the secrets
below in **GitHub → Settings → Secrets and variables → Actions** before the
first run.

---

## Secrets required

### 1. `IOS_CERTIFICATE_BASE64`
Your Apple Distribution certificate as a base64 string.

**How to export:**
1. Open **Keychain Access** on your Mac.
2. Find "Apple Distribution: Andrew Beers" (or your team name) under **My Certificates**.
3. Right-click → **Export** → save as `certificate.p12`, set an export password.
4. Run: `base64 -i certificate.p12 | pbcopy`
5. Paste the clipboard value as the secret.

---

### 2. `IOS_CERTIFICATE_PASSWORD`
The export password you set in step 3 above.

---

### 3. `IOS_KEYCHAIN_PASSWORD`
An arbitrary password used to create a temporary keychain on the CI runner.
Any strong random string works — it is thrown away after the job.

Example: `openssl rand -base64 20 | pbcopy`

---

### 4. `IOS_PROVISIONING_PROFILE_BASE64`
Your **App Store Distribution** provisioning profile for `com.arcu.Attnd`.

**How to get it:**
1. Go to [developer.apple.com](https://developer.apple.com) → Certificates, Identifiers & Profiles → Profiles.
2. Create (or download) an **App Store** profile for the `com.arcu.Attnd` App ID.
3. Download it — the file ends in `.mobileprovision`.
4. Run: `base64 -i Attnd_AppStore.mobileprovision | pbcopy`
5. Paste as the secret.

---

### 5. `IOS_PROVISIONING_PROFILE_NAME`
The **display name** of the provisioning profile exactly as it appears in the
Apple Developer portal (not the filename).

Example: `Attnd App Store Distribution`

You can verify the name by opening the `.mobileprovision` file in a text editor
and searching for the `<key>Name</key>` entry.

---

### 6. `ASC_API_KEY_ID`
The short alphanumeric key ID from App Store Connect.

**How to get it:**
1. Log in to [App Store Connect](https://appstoreconnect.apple.com).
2. Go to **Users and Access → Integrations → App Store Connect API**.
3. Click **+** to generate a new key (or use an existing one).
4. Copy the **Key ID** (looks like `AB12CD34EF`).

---

### 7. `ASC_API_ISSUER_ID`
The Issuer ID shown on the same **App Store Connect API** page — a UUID that
looks like `57246542-96fe-1a63-e053-0824d011072a`.

---

### 8. `ASC_API_PRIVATE_KEY`
The `.p8` private key file content downloaded when you created the API key.
**You can only download this once.** If you lost it, delete the key and create
a new one.

**How to add it:**
```bash
cat AuthKey_YOURKEYID.p8 | pbcopy
```
Paste the full content — including the `-----BEGIN PRIVATE KEY-----` and
`-----END PRIVATE KEY-----` lines — as the secret value.

---

### 9. `ATTND_API_KEY`
Already set from the CI test pipeline. No action needed.

---

## Team ID

The team ID `GQQX4L6TE2` is hardcoded into the workflow (it came from the
Xcode project). If you ever change Apple Developer accounts, update it in
`.github/workflows/ios-release.yml` at the `DEVELOPMENT_TEAM` lines.

---

## What happens after upload

The IPA lands in **App Store Connect → TestFlight** automatically. From there:
- Submit to **App Review** manually via App Store Connect to publish to the
  App Store.
- Or promote a TestFlight build to production.

The pipeline does **not** auto-submit for review — that remains a deliberate
manual step.
