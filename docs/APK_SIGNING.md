# Film Streaming: stable Android APK signing

Android accepts an APK as an **update** only if both the application ID and
the signing certificate match the APK already installed. This project keeps
the application ID `com.example.filmstream_personal`, but older GitHub Actions
builds used the runner's temporary **debug** signing key. Those APKs may not
be upgrade-compatible with one another.

## One-time setup: create one permanent release keystore

Run on your **own computer** (JDK keytool required):

```sh
keytool -genkeypair -v -keystore filmstream-release.jks -alias filmstream -keyalg RSA -keysize 3072 -validity 10000
```

Choose a strong, saved keystore password and private key password. The alias
must be **filmstream**. Keep a secure private backup of this keystore and both
passwords. **Do not commit or upload the keystore to this public repository.**

Convert the entire .jks file to a one-line Base64 string:

- Windows PowerShell: `[Convert]::ToBase64String([IO.File]::ReadAllBytes("filmstream-release.jks")) | Set-Clipboard`
- macOS/Linux: `base64 < filmstream-release.jks | tr -d '\\n'`

In GitHub repository **Settings → Secrets and variables → Actions → New repository secret**,
create these **three secrets**:

- `FILMSTREAM_KEYSTORE_BASE64`: Base64-encoded contents of the .jks file
- `FILMSTREAM_STORE_PASSWORD`: the keystore password
- `FILMSTREAM_KEY_PASSWORD`: the key password

The Build APK workflow restores the keystore into the ephemeral runner and
passes passwords through environment variables. It uses the same signing key
on every run. Every build also receives an increasing Android version code.
The secrets and signing file are never committed.

## Important limitation for users of earlier APKs

An APK already installed using a different debug certificate **cannot** be
upgraded in place with this new release certificate. Android will correctly
report a signature/package conflict. You must first back up any needed
app-local data, uninstall the incompatible legacy APK, and install the **first**
APK signed with the permanent keystore. Uninstalling or clearing data can
remove local scan queues, saved favorites and history; ensure pending catalog
entries have been merged on GitHub first.

After that one-time transition, **do not regenerate the keystore**: future
APK builds signed with the same .jks and a higher version code can upgrade the
previous permanent-key version normally.

Do not change the application ID to work around a signing conflict; that
installs an unrelated app rather than preserving its data.
